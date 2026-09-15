param(
    [Parameter(Mandatory = $true)][string]$ReleaseReport,
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [ValidatePattern('^\{[0-9A-Fa-f-]{36}\}$')][string]$ProductId = '{749D413C-9DC3-4D4C-AED4-C91D6485932B}',
    [ValidatePattern('^[A-Za-z0-9 .-]+$')][string]$ProductName = 'Recappi Mini',
    [switch]$FrameworkDependentCandidate
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$repository = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path $repository 'build/native-installer-tools/inno-7.1.0/ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Run scripts/prepare-native-installer-tools.ps1 first.' }
$reportPath = (Resolve-Path -LiteralPath $ReleaseReport).Path
$releaseRoot = Split-Path -Parent $reportPath
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$artifact = @($report.artifacts | Where-Object runtime -eq $Runtime)
if ($artifact.Count -ne 1) { throw 'Expected one artifact for the requested architecture.' }
$artifact = $artifact[0]
if ($FrameworkDependentCandidate) {
    if ($artifact.selfContained -ne $false -or $artifact.frameworkDependentCandidate -ne $true) { throw 'Select an explicitly marked framework-dependent candidate.' }
} elseif ($artifact.selfContained -ne $true) { throw 'This installer requires a self-contained release unless the online candidate is explicitly selected.' }
if ($artifact.version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-preview\.([1-9][0-9]*))?$') { throw 'Installer versions must use major.minor.patch or major.minor.patch-preview.N.' }
$numericVersion = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], $(if ($Matches[4]) { [int]$Matches[4] } else { 65535 }))
if (@($numericVersion | Where-Object { $_ -gt 65535 }).Count -or ($artifact.version.Contains('-') -and $numericVersion[3] -eq 65535)) { throw 'Installer version component is out of range.' }
$archive = (Resolve-Path -LiteralPath $artifact.archive).Path
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $artifact.sha256) { throw 'Release archive checksum does not match report.' }
$versionFolder = $artifact.version + '-' + $artifact.sha256.Substring(0, 12)
$output = Join-Path $releaseRoot ('installer-' + $Runtime + '-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($output) | Out-Null
$source = Join-Path $output 'payload'
$archiveCheck = [IO.Compression.ZipFile]::OpenRead($archive)
try {
    if ($archiveCheck.Entries.Count -gt 5000 -or ($archiveCheck.Entries | Measure-Object -Property Length -Sum).Sum -gt 1GB) { throw 'Release archive exceeds package limits.' }
    foreach ($entry in $archiveCheck.Entries) {
        $target = [IO.Path]::GetFullPath((Join-Path $source $entry.FullName))
        if (-not $target.StartsWith($source + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
            $entry.FullName.Contains(':') -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe release archive entry.' }
    }
} finally { $archiveCheck.Dispose() }
[IO.Compression.ZipFile]::ExtractToDirectory($archive, $source)
$runtimeConfiguration = Get-Content -LiteralPath (Join-Path $source 'Recappi Mini.runtimeconfig.json') -Raw | ConvertFrom-Json
if ($FrameworkDependentCandidate) {
    $frameworks = @($runtimeConfiguration.runtimeOptions.frameworks)
    if ($runtimeConfiguration.runtimeOptions.includedFrameworks -or (Test-Path -LiteralPath (Join-Path $source 'coreclr.dll')) -or
        $frameworks.Count -ne 2 -or @($frameworks | Where-Object { $_.name -in @('Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App') -and $_.version -eq '10.0.0' }).Count -ne 2) {
        throw 'Online candidate requires the supported .NET 10 application framework contract.'
    }
} elseif (-not $runtimeConfiguration.runtimeOptions.includedFrameworks -or
    -not (Test-Path -LiteralPath (Join-Path $source 'coreclr.dll'))) { throw 'Installer payload is not self-contained, regardless of release report metadata.' }
$executable = Join-Path $source 'Recappi Mini.exe'
$binary = [IO.File]::ReadAllBytes($executable)
$machine = [BitConverter]::ToUInt16($binary, [BitConverter]::ToInt32($binary, 0x3c) + 4)
$expectedMachine = if ($Runtime -eq 'win-arm64') { 0xaa64 } else { 0x8664 }
if ($machine -ne $expectedMachine) { throw 'Release executable architecture mismatch.' }
$allowed = if ($Runtime -eq 'win-arm64') { 'arm64' } else { 'x64os' }
$definitions = @('/Qp', "/DSourceRoot=$source", "/DReleaseVersion=$($artifact.version)", "/DVersionFolder=$versionFolder", "/DInstallerVersion=$($numericVersion -join '.')", "/DAllowedArchitecture=$allowed", "/DRuntime=$Runtime", "/DOutputRoot=$output", "/DProductId=$ProductId", "/DProductName=$ProductName")
$prerequisite = $null
$installerSuffix = ''
if ($FrameworkDependentCandidate) {
    $probe = Join-Path $output 'runtime-probe'
    & dotnet publish (Join-Path $repository 'native/desktop/Recappi.RuntimeProbe/Recappi.RuntimeProbe.csproj') -c Release -r $Runtime --self-contained false -p:RestoreLockedMode=true -o $probe
    if ($LASTEXITCODE -ne 0) { throw 'Runtime probe build failed.' }
    Copy-Item -LiteralPath (Join-Path $source 'Recappi Mini.runtimeconfig.json') -Destination (Join-Path $probe 'Recappi.RuntimeProbe.runtimeconfig.json') -Force
    $prerequisite = & (Join-Path $PSScriptRoot 'prepare-native-runtime-prerequisite.ps1') -Runtime $Runtime
    $installerSuffix = '-Online-Candidate'
    $definitions += @('/DFrameworkDependentCandidate', "/DProbeRoot=$probe", "/DRuntimeDownloadUrl=$($prerequisite.url)", "/DRuntimeDownloadSha256=$($prerequisite.sha256)", "/DInstallerSuffix=$installerSuffix")
}
& $compiler @definitions (Join-Path $repository 'native/desktop/installer/RecappiMini.iss')
if ($LASTEXITCODE -ne 0) { throw 'Native installer compilation failed.' }
$package = Join-Path $output "Recappi-Mini-$($artifact.version)-$Runtime$installerSuffix-Setup.exe"
if (-not (Test-Path -LiteralPath $package)) { throw 'Installer artifact is missing.' }
$result = [ordered]@{ createdAt = [DateTimeOffset]::UtcNow.ToString('O'); runtime = $Runtime; version = $artifact.version; versionFolder = $versionFolder; productId = $ProductId; productName = $ProductName; path = $package; bytes = (Get-Item -LiteralPath $package).Length; sha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant(); signed = (Get-AuthenticodeSignature -LiteralPath $package).Status -eq 'Valid' }
$result.frameworkDependentCandidate = [bool]$FrameworkDependentCandidate
$result.runtimePrerequisite = $prerequisite
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'installer-report.json') -Encoding utf8
Write-Output "Installer report: $(Join-Path $output 'installer-report.json')"
