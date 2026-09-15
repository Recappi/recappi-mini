param([ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $repository 'native/desktop/installer/dotnet-prerequisites.json') -Raw | ConvertFrom-Json
if ($manifest.version -notmatch '^10\.0\.\d+$') { throw 'Unsupported prerequisite version.' }
$entry = $manifest.runtimes.$Runtime
$expectedUrl = "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/$($manifest.version)/windowsdesktop-runtime-$($manifest.version)-$Runtime.exe"
if ($entry.url -cne $expectedUrl -or $entry.sha512 -notmatch '^[0-9a-f]{128}$') { throw 'Invalid pinned runtime prerequisite.' }
$root = Join-Path $repository "build/native-installer-tools/dotnet-$($manifest.version)-$Runtime"
[void][IO.Directory]::CreateDirectory($root)
$file = Join-Path $root 'windowsdesktop-runtime.exe'
if (-not (Test-Path -LiteralPath $file)) {
    $temporary = Join-Path $root ([guid]::NewGuid().ToString('N') + '.download')
    try {
        Invoke-WebRequest -Uri $entry.url -OutFile $temporary -TimeoutSec 180
        if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA512).Hash.ToLowerInvariant() -ne $entry.sha512) { throw 'Downloaded prerequisite checksum mismatch.' }
        Move-Item -LiteralPath $temporary -Destination $file
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
if ((Get-FileHash -LiteralPath $file -Algorithm SHA512).Hash.ToLowerInvariant() -ne $entry.sha512) { throw 'Cached prerequisite checksum mismatch.' }
$signature = Get-AuthenticodeSignature -LiteralPath $file
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)' -or
    $signature.SignerCertificate.Subject -notmatch '^CN=(?:\.NET|Microsoft Corporation),') { throw 'Runtime prerequisite does not have a valid Microsoft signature.' }
# Downloaded for build-time verification only. Never execute a runtime installer here.
[pscustomobject]@{ version = $manifest.version; runtime = $Runtime; url = $entry.url; path = $file;
    sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant();
    bytes = (Get-Item -LiteralPath $file).Length }
