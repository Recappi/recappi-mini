param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [ValidatePattern('^[A-Za-z0-9.-]{3,50}$')][string]$IdentityName = 'Recappi.Mini.Development',
    [string]$Publisher = 'CN=Recappi Development',
    [string]$PublisherDisplayName = 'Recappi',
    [string]$PackageVersion = '1.0.0.0',
    [string]$MakeAppxPath
)
$ErrorActionPreference = 'Stop'
$version = $null
if (-not [Version]::TryParse($PackageVersion, [ref]$version) -or $version.Major -lt 1 -or
    $version.Revision -ne 0 -or $version.Major -gt 65535 -or $version.Minor -gt 65535 -or $version.Build -gt 65535) {
    throw 'Use a Store version Major.Minor.Patch.0 with major >= 1 and components <= 65535.'
}
if ([string]::IsNullOrWhiteSpace($Publisher) -or [string]::IsNullOrWhiteSpace($PublisherDisplayName)) { throw 'Publisher values must not be empty.' }
$repository = Split-Path -Parent $PSScriptRoot
$source = (Resolve-Path -LiteralPath $PackageDirectory).Path
if (-not $MakeAppxPath) {
    $sdk = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
    $MakeAppxPath = Get-ChildItem -LiteralPath $sdk -Directory | Where-Object Name -match '^10\.0\.\d+\.0$' |
        Sort-Object { [Version]$_.Name } -Descending | ForEach-Object { Join-Path $_.FullName 'x64/makeappx.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $MakeAppxPath -or -not (Test-Path -LiteralPath $MakeAppxPath -PathType Leaf)) { throw 'Windows SDK MakeAppx.exe is required.' }
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
Copy-Item -LiteralPath (Join-Path $repository 'native/desktop/Recappi.Desktop/Assets/Recappi.png') -Destination $assets
[xml]$manifest = Get-Content -LiteralPath (Join-Path $repository 'native/desktop/packaging/AppxManifest.xml') -Raw
$manifest.Package.Identity.Name = $IdentityName
$manifest.Package.Identity.Publisher = $Publisher
$manifest.Package.Identity.Version = $version.ToString(4)
$manifest.Package.Identity.ProcessorArchitecture = $architecture
$manifest.Package.Properties.PublisherDisplayName = $PublisherDisplayName
$manifest.Save((Join-Path $stage 'AppxManifest.xml'))
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
$report = [ordered]@{ createdAt = [DateTimeOffset]::UtcNow.ToString('O'); sourcePackage = $source;
    identityName = $IdentityName; publisher = $Publisher; packageVersion = $version.ToString(4); architecture = $architecture;
    package = $package; bytes = (Get-Item -LiteralPath $package).Length;
    sha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant();
    payloadFilesVerified = $expected.Count; signed = $false; installed = $false; storeReady = $false;
    limitations = 'Unsigned packaging candidate only; identity, artwork, OS floor, Store update routing, lifecycle and certification require validation.' }
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $output 'msix-report.json') -Encoding utf8
$report | ConvertTo-Json -Depth 4
