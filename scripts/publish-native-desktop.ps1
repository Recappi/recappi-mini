param(
    [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')]
    [string]$Version = '0.1.0-preview.1',
    [ValidateSet('win-x64', 'win-arm64')]
    [string[]]$Runtimes = @('win-x64', 'win-arm64'),
    [switch]$ResourceOptimizationCandidate,
    [switch]$FrameworkDependentCandidate,
    [ValidateRange(1, 30)][int]$KeepHistory = 3
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'native-artifact-retention.ps1')
$artifactLease = Enter-NativeArtifactLock (Join-Path $repository 'build')
try {
$sourceCommit = (& git -C $repository rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not identify release source revision.' }
$sourceStatus = @(& git -C $repository status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect release source changes.' }
$sourceDirty = $sourceStatus.Count -gt 0
$project = Join-Path $repository 'native/desktop/Recappi.WinUI/Recappi.WinUI.csproj'
$runtimeManifest = Get-Content -LiteralPath (Join-Path $repository 'native/desktop/installer/dotnet-prerequisites.json') -Raw | ConvertFrom-Json
$pinnedRuntimeVersion = [string]$runtimeManifest.version
if ($pinnedRuntimeVersion -notmatch '^10\.0\.\d+$') { throw 'Expected a pinned stable .NET 10 runtime version.' }
$destination = Join-Path $repository ('build/native-desktop-release/' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($destination) | Out-Null
$artifacts = @()
foreach ($runtime in $Runtimes) {
    $output = Join-Path $destination $runtime
    $optimizationArguments = @()
    # WinUI language resources stay in PRI; this option only filters managed satellite resources.
    if ($ResourceOptimizationCandidate) { $optimizationArguments += '-p:SatelliteResourceLanguages=zh-Hans' }
    $selfContained = (-not $FrameworkDependentCandidate).ToString().ToLowerInvariant()
    $runtimeArguments = @()
    if (-not $FrameworkDependentCandidate) { $runtimeArguments += "-p:RecappiRuntimeVersion=$pinnedRuntimeVersion" }
    & dotnet publish $project --configuration Release --runtime $runtime --self-contained $selfContained --output $output -p:RestoreLockedMode=true "-p:Version=$Version" @optimizationArguments @runtimeArguments
    if ($LASTEXITCODE -ne 0) { throw "Native publish failed for $runtime." }
    if ($ResourceOptimizationCandidate) {
        $symbols = Join-Path $destination ('symbols/' + $runtime)
        [void][IO.Directory]::CreateDirectory($symbols)
        Get-ChildItem -LiteralPath $output -File -Filter '*.pdb' | ForEach-Object {
            Move-Item -LiteralPath $_.FullName -Destination (Join-Path $symbols $_.Name)
        }
    }
    $executable = Join-Path $output 'Recappi Mini.exe'
    $binary = [IO.File]::ReadAllBytes($executable)
    $peOffset = [BitConverter]::ToInt32($binary, 0x3c)
    $machine = [BitConverter]::ToUInt16($binary, $peOffset + 4)
    $expected = if ($runtime -eq 'win-x64') { 0x8664 } else { 0xaa64 }
    if ($machine -ne $expected) { throw "Unexpected executable architecture for $runtime." }
    $configuration = Get-Content -LiteralPath (Join-Path $output 'Recappi Mini.runtimeconfig.json') -Raw | ConvertFrom-Json
    $requiredFrameworks = @()
    $includedFrameworks = @()
    if ($FrameworkDependentCandidate) {
        $requiredFrameworks = @(@($configuration.runtimeOptions.frameworks) + @($configuration.runtimeOptions.framework) | Where-Object { $_ })
        if ($configuration.runtimeOptions.includedFrameworks -or
            @($requiredFrameworks | Where-Object name -eq 'Microsoft.WindowsDesktop.App').Count -ne 0 -or
            @($requiredFrameworks | Where-Object name -eq 'Microsoft.NETCore.App').Count -ne 1 -or
            (Test-Path -LiteralPath (Join-Path $output 'coreclr.dll'))) { throw 'Invalid framework-dependent candidate runtime metadata.' }
    } else {
        $includedFrameworks = @($configuration.runtimeOptions.includedFrameworks)
        foreach ($frameworkName in @('Microsoft.NETCore.App')) {
            $matchingFramework = @($includedFrameworks | Where-Object name -eq $frameworkName)
            if ($matchingFramework.Count -ne 1 -or $matchingFramework[0].version -ne $pinnedRuntimeVersion) {
                throw "Published $frameworkName does not match pinned runtime $pinnedRuntimeVersion."
            }
        }
        if (@($includedFrameworks | Where-Object name -eq 'Microsoft.WindowsDesktop.App').Count) { throw 'Unexpected WPF/Windows Forms framework dependency.' }
    }
    foreach ($required in @('Microsoft.WinUI.dll', 'Microsoft.UI.Xaml.dll', 'Recappi Mini.pri')) {
        if (-not (Test-Path -LiteralPath (Join-Path $output $required))) { throw "WinUI payload missing: $required" }
    }
    $legacyUi = @(Get-ChildItem -LiteralPath $output -Recurse -File | Where-Object Name -match '^(PresentationFramework.*|PresentationCore|System.Windows.Forms.*)\.dll$')
    if ($legacyUi.Count) { throw 'WPF/Windows Forms payload must not be shipped in the WinUI release.' }
    if ((Test-Path -LiteralPath (Join-Path $output 'node.exe')) -or (Test-Path -LiteralPath (Join-Path $output 'node.dll'))) { throw 'Unexpected Node runtime in native release.' }
    $candidateSuffix = if ($FrameworkDependentCandidate) { '-requires-dotnet-candidate' } else { '' }
    $archive = Join-Path $destination "Recappi-Mini-$Version-$runtime$candidateSuffix.zip"
    [IO.Compression.ZipFile]::CreateFromDirectory($output, $archive)
    $files = @(Get-ChildItem -LiteralPath $output -File -Recurse)
    $archiveCheck = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        if ($archiveCheck.Entries.Count -ne $files.Count -or
            ($archiveCheck.Entries | Measure-Object -Property Length -Sum).Sum -ne ($files | Measure-Object -Property Length -Sum).Sum) {
            throw "Archive file count or uncompressed length mismatch for $runtime."
        }
    } finally { $archiveCheck.Dispose() }
    $artifacts += [ordered]@{
        runtime = $runtime
        uiFramework = 'WinUI3'
        version = $Version
        executable = $executable
        executableMachine = ('0x{0:x4}' -f $machine)
        selfContained = -not [bool]$FrameworkDependentCandidate
        frameworkDependentCandidate = [bool]$FrameworkDependentCandidate
        requiredFrameworks = $requiredFrameworks
        includedFrameworks = $includedFrameworks
        fileCount = $files.Count
        publishedBytes = ($files | Measure-Object -Property Length -Sum).Sum
        archive = $archive
        archiveBytes = (Get-Item -LiteralPath $archive).Length
        sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        resourceOptimizationCandidate = [bool]$ResourceOptimizationCandidate
    }
}
$report = Join-Path $destination 'release-report.json'
$packageType = if ($FrameworkDependentCandidate) { 'framework-dependent-candidate-zip' } else { 'portable-zip' }
[ordered]@{ createdAt = [DateTimeOffset]::UtcNow.ToString('O'); uiFramework = 'WinUI3'; sourceCommit = $sourceCommit; sourceDirty = $sourceDirty; artifacts = $artifacts; packageType = $packageType; signed = $false; retentionPolicyVersion = 1 } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $report -Encoding utf8
Write-Output "Release report: $report"
} finally { $artifactLease.Dispose() }
Invoke-NativeArtifactAutoRetention -BuildRoot (Join-Path $repository 'build') -KeepLatest $KeepHistory
