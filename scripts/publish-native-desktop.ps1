param(
    [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')]
    [string]$Version = '0.1.0-preview.1',
    [ValidateSet('win-x64', 'win-arm64')]
    [string[]]$Runtimes = @('win-x64', 'win-arm64'),
    [switch]$ResourceOptimizationCandidate
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repository = Split-Path -Parent $PSScriptRoot
$sourceCommit = (& git -C $repository rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not identify release source revision.' }
$sourceStatus = @(& git -C $repository status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect release source changes.' }
$sourceDirty = $sourceStatus.Count -gt 0
$project = Join-Path $repository 'native/desktop/Recappi.Desktop/Recappi.Desktop.csproj'
$destination = Join-Path $repository ('build/native-desktop-release/' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($destination) | Out-Null
$artifacts = @()
foreach ($runtime in $Runtimes) {
    $output = Join-Path $destination $runtime
    $optimizationArguments = @()
    # .NET Desktop ships simplified Chinese under zh-Hans; English is neutral.
    if ($ResourceOptimizationCandidate) { $optimizationArguments += '-p:SatelliteResourceLanguages=zh-Hans' }
    & dotnet publish $project --configuration Release --runtime $runtime --self-contained true --output $output -p:RestoreLockedMode=true "-p:Version=$Version" @optimizationArguments
    if ($LASTEXITCODE -ne 0) { throw "Native publish failed for $runtime." }
    if ($ResourceOptimizationCandidate) {
        if (-not (Test-Path -LiteralPath (Join-Path $output 'zh-Hans/PresentationFramework.resources.dll'))) {
            throw 'Candidate is missing simplified Chinese WPF resources.'
        }
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
    if (-not $configuration.runtimeOptions.includedFrameworks) { throw 'Publish output is not self-contained.' }
    if (-not (Test-Path -LiteralPath (Join-Path $output 'PresentationFramework.Fluent.dll'))) { throw 'Native theme runtime is missing.' }
    if ((Test-Path -LiteralPath (Join-Path $output 'node.exe')) -or (Test-Path -LiteralPath (Join-Path $output 'node.dll'))) { throw 'Unexpected Node runtime in native release.' }
    $archive = Join-Path $destination "Recappi-Mini-$Version-$runtime.zip"
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
        version = $Version
        executable = $executable
        executableMachine = ('0x{0:x4}' -f $machine)
        selfContained = $true
        fileCount = $files.Count
        publishedBytes = ($files | Measure-Object -Property Length -Sum).Sum
        archive = $archive
        archiveBytes = (Get-Item -LiteralPath $archive).Length
        sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        resourceOptimizationCandidate = [bool]$ResourceOptimizationCandidate
    }
}
$report = Join-Path $destination 'release-report.json'
[ordered]@{ createdAt = [DateTimeOffset]::UtcNow.ToString('O'); sourceCommit = $sourceCommit; sourceDirty = $sourceDirty; artifacts = $artifacts; packageType = 'portable-zip'; signed = $false } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $report -Encoding utf8
Write-Output "Release report: $report"
