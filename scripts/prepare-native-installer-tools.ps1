$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repository 'build/native-installer-tools/inno-7.1.0'
$compiler = Join-Path $toolsRoot 'ISCC.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    throw 'Install official Inno Setup 7.1.0 x64 in portable mode into build/native-installer-tools/inno-7.1.0, then rerun this preflight.'
}
$signature = Get-AuthenticodeSignature -LiteralPath $compiler
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=Pyrsys B\.V\.') { throw 'Existing compiler signature is not trusted.' }
Write-Output $compiler
