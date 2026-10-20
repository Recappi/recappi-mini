param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [ValidatePattern('^[A-Za-z0-9.-]{3,50}$')][string]$IdentityName = 'Recappi.Mini.Development',
    [string]$Publisher = 'CN=Recappi Development',
    [string]$PublisherDisplayName = 'Recappi',
    [string]$PackageVersion = '1.0.0.0',
    [string]$MakeAppxPath,
    [string]$MakePriPath,
    [ValidateRange(1, 30)][int]$KeepHistory = 3,
    [switch]$KeepStaging
)
$ErrorActionPreference = 'Stop'
$version = $null
if (-not [Version]::TryParse($PackageVersion, [ref]$version) -or $version.Major -lt 1 -or
    $version.Revision -ne 0 -or $version.Major -gt 65535 -or $version.Minor -gt 65535 -or $version.Build -gt 65535) {
    throw 'Use a Store version Major.Minor.Patch.0 with major >= 1 and components <= 65535.'
}
if ([string]::IsNullOrWhiteSpace($Publisher) -or [string]::IsNullOrWhiteSpace($PublisherDisplayName)) { throw 'Publisher values must not be empty.' }
$repository = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'native-artifact-retention.ps1')
$artifactLease = Enter-NativeArtifactLock (Join-Path $repository 'build')
try {
$source = (Resolve-Path -LiteralPath $PackageDirectory).Path
if (-not $MakeAppxPath) {
    $sdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
    $MakeAppxPath = Get-ChildItem -LiteralPath $sdk -Directory | Where-Object Name -match '^10\.0\.\d+\.0$' |
        Sort-Object { [Version]$_.Name } -Descending | ForEach-Object { Join-Path $_.FullName 'x64/makeappx.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $MakeAppxPath -or -not (Test-Path -LiteralPath $MakeAppxPath -PathType Leaf)) { throw 'Windows SDK MakeAppx.exe is required.' }
if (-not $MakePriPath) { $MakePriPath = Join-Path (Split-Path -Parent $MakeAppxPath) 'makepri.exe' }
if (-not (Test-Path -LiteralPath $MakePriPath -PathType Leaf)) { throw 'Windows SDK MakePri.exe is required.' }
$output = Join-Path $repository ('build/native-msix/' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($output)
& (Join-Path $PSScriptRoot 'inspect-native-package.ps1') -PackageDirectory $source -ReportPath (Join-Path $output 'source-inventory.json') | Out-Null
$binary = [IO.File]::ReadAllBytes((Join-Path $source 'Recappi Mini.exe'))
$machine = [BitConverter]::ToUInt16($binary, [BitConverter]::ToInt32($binary, 0x3c) + 4)
$architecture = switch ($machine) { 0x8664 { 'x64' } 0xaa64 { 'arm64' } default { throw 'Unsupported native architecture.' } }
$stage = Join-Path $output 'payload'
[void][IO.Directory]::CreateDirectory($stage)
Get-ChildItem -LiteralPath $source -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $stage -Recurse }
$assets = Join-Path $stage 'Assets'
[void][IO.Directory]::CreateDirectory($assets)
Copy-Item -LiteralPath (Join-Path $repository 'native/desktop/Assets/Recappi.png') -Destination $assets
# Each manifest logo has its own required scale-100 dimensions. A shared 256px
# image passes MakeAppx but fails the Windows App Certification Kit resource test.
Add-Type -AssemblyName System.Drawing
$logo = [Drawing.Bitmap]::new((Join-Path $assets 'Recappi.png'))
try {
    $logoAssets = @(
        @{ Name = 'StoreLogo.png'; Size = 50 },
        @{ Name = 'Square44x44Logo.png'; Size = 44 },
        @{ Name = 'Square150x150Logo.png'; Size = 150 }
    )
    # The shell otherwise adds an accent-color backplate behind transparent corners.
    foreach ($size in @(16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 256)) {
        foreach ($form in @('', '_altform-unplated', '_altform-lightunplated')) {
            $logoAssets += @{ Name = "Square44x44Logo.targetsize-$size$form.png"; Size = $size }
        }
    }
    foreach ($asset in $logoAssets) {
        $bitmap = [Drawing.Bitmap]::new($asset.Size, $asset.Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage($logo, 0, 0, $asset.Size, $asset.Size)
            $bitmap.Save((Join-Path $assets $asset.Name), [Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
} finally { $logo.Dispose() }
[xml]$manifest = Get-Content -LiteralPath (Join-Path $repository 'native/desktop/packaging/AppxManifest.xml') -Raw
$manifest.Package.Identity.Name = $IdentityName
$manifest.Package.Identity.Publisher = $Publisher
$manifest.Package.Identity.Version = $version.ToString(4)
$manifest.Package.Identity.ProcessorArchitecture = $architecture
$manifest.Package.Properties.PublisherDisplayName = $PublisherDisplayName
$manifest.Save((Join-Path $stage 'AppxManifest.xml'))
# Merge shell assets and existing WinUI resources into the package's primary PRI.
# Disable resource-package splitting so every target size stays in this MSIX.
$priConfig = Join-Path $output 'priconfig.xml'
$priRoot = Join-Path $output 'shell-resources'
[void][IO.Directory]::CreateDirectory($priRoot)
$priAssets = Join-Path $priRoot 'Assets'
[void][IO.Directory]::CreateDirectory($priAssets)
foreach ($asset in $logoAssets) { Copy-Item -LiteralPath (Join-Path $assets $asset.Name) -Destination $priAssets }
# The application PRI already includes its WinUI dependencies and original assets.
Copy-Item -LiteralPath (Join-Path $source 'Recappi Mini.pri') -Destination $priRoot
& $MakePriPath createconfig /cf $priConfig /dq en-US /o *> (Join-Path $output 'makepri-config.log')
if ($LASTEXITCODE -ne 0) { throw 'MakePri configuration generation failed.' }
[xml]$priXml = Get-Content -LiteralPath $priConfig -Raw
[void]$priXml.resources.RemoveChild($priXml.resources.packaging)
foreach ($indexer in @($priXml.resources.index.'indexer-config')) {
    if ($indexer.type -notin @('folder', 'PRI')) { [void]$priXml.resources.index.RemoveChild($indexer) }
}
$priXml.Save($priConfig)
& $MakePriPath new /pr $priRoot /cf $priConfig /in $IdentityName /of (Join-Path $stage 'resources.pri') /o *> (Join-Path $output 'makepri.log')
if ($LASTEXITCODE -ne 0) { throw "MakePri indexing failed. See $output/makepri.log" }
$priDump = Join-Path $output 'shell-resources.xml'
& $MakePriPath dump /if (Join-Path $stage 'resources.pri') /of $priDump /o *> (Join-Path $output 'makepri-dump.log')
if ($LASTEXITCODE -ne 0) { throw 'MakePri resource verification failed.' }
[xml]$resourceIndex = Get-Content -LiteralPath $priDump -Raw
if (-not $resourceIndex.SelectSingleNode("//NamedResource[@name='App.xbf']/Candidate[@type='EmbeddedData']")) {
    throw 'The package resource index is missing the embedded WinUI application resources.'
}
$shellLogo = $resourceIndex.SelectSingleNode("//NamedResource[@uri='ms-resource://$IdentityName/Files/Assets/Square44x44Logo.png']")
if (-not $shellLogo -or @($shellLogo.Candidate | Where-Object qualifiers -match 'AlternateForm-(LIGHTUNPLATED|UNPLATED)').Count -ne 28) {
    throw 'The shell icon resource index is missing unplated target-size variants.'
}
$package = Join-Path $output ('Recappi-Mini-' + $version.ToString(4) + '-' + $architecture + '-unsigned.msix')
& $MakeAppxPath pack /d $stage /p $package /o *> (Join-Path $output 'makeappx.log')
if ($LASTEXITCODE -ne 0) { throw "MakeAppx validation failed. See $output/makeappx.log" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($package)
try {
    # MSIX uses OPC part names, e.g. Recappi%20Mini.exe for a filename with spaces.
    $entries = @{}
    foreach ($item in $zip.Entries) {
        $decoded = [Uri]::UnescapeDataString($item.FullName)
        if ($entries.ContainsKey($decoded)) { throw "Ambiguous MSIX part name: $decoded" }
        $entries[$decoded] = $item
    }
    $expected = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
    foreach ($file in $expected) {
        $relative = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
        $entry = $entries[$relative]
        if (-not $entry -or $entry.Length -ne $file.Length) { throw "MSIX payload mismatch: $relative" }
        $stream = $entry.Open()
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $actual = [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose(); $hash.Dispose() }
        if ($actual -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) { throw "MSIX content hash mismatch: $relative" }
    }
} finally { $zip.Dispose() }
if (-not $KeepStaging) {
    $stagePath = (Resolve-Path -LiteralPath $stage).Path
    $outputPath = (Resolve-Path -LiteralPath $output).Path
    if (-not $stagePath.Equals((Join-Path $outputPath 'payload'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected MSIX staging path.' }
    [void]@(Get-NativeArtifactFiles $stagePath) # Reject links before recursive removal.
    Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction Stop
}
$report = [ordered]@{ createdAt = [DateTimeOffset]::UtcNow.ToString('O'); sourcePackage = $source;
    identityName = $IdentityName; publisher = $Publisher; packageVersion = $version.ToString(4); architecture = $architecture;
    package = $package; bytes = (Get-Item -LiteralPath $package).Length;
    sha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant();
    payloadFilesVerified = $expected.Count; signed = $false; installed = $false; storeReady = $false; retentionPolicyVersion = 1;
    stagingPayloadRetained = [bool]$KeepStaging;
    limitations = 'Unsigned packaging candidate only; identity, artwork, OS floor, Store update routing, lifecycle and certification require validation.' }
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'msix-report.json') -Encoding utf8
$report | ConvertTo-Json -Depth 4
} finally { $artifactLease.Dispose() }
Invoke-NativeArtifactAutoRetention -BuildRoot (Join-Path $repository 'build') -KeepLatest $KeepHistory
