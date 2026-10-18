param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$DataDirectory,
    [Parameter(Mandatory)][string]$Report
)
$ErrorActionPreference = 'Stop'
$binary = (Resolve-Path -LiteralPath $Executable).Path
if ([IO.Path]::GetFileName($binary) -ne 'Recappi Mini.exe') { throw 'Select the native application executable.' }
if (@(Get-Process -Name 'Recappi Mini' -ErrorAction SilentlyContinue).Count) { throw 'An application instance already exists; this check must own its process.' }
$dataPath = [IO.Path]::GetFullPath($DataDirectory)
if (Test-Path -LiteralPath (Join-Path $dataPath 'desktop-cloud-fixture.json')) {
    throw 'DataDirectory is the recording-store directory. For a desktop cloud fixture, pass its Recordings subdirectory.'
}
$reportPath = [IO.Path]::GetFullPath($Report)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reportPath))
$started = [DateTimeOffset]::UtcNow
$binaryHash = (Get-FileHash -LiteralPath (Join-Path (Split-Path $binary) 'Recappi Mini.dll') -Algorithm SHA256).Hash
$child = Start-Process -FilePath $binary -ArgumentList @('--validation-data-dir', ('"' + $dataPath + '"')) -WindowStyle Hidden -PassThru
# Acquire the handle while the process is alive so exit status survives teardown.
$null = $child.Handle
Write-Output "Watching native application PID $($child.Id)"
while (-not $child.WaitForExit(30000)) { Write-Output "Native application PID $($child.Id) is still running." }
[ordered]@{
    executable = $binary; applicationDllSha256 = $binaryHash; dataDirectory = $dataPath;
    processId = $child.Id; startedAt = $started.ToString('O'); endedAt = [DateTimeOffset]::UtcNow.ToString('O');
    exitCode = $child.ExitCode; cleanExit = $child.ExitCode -eq 0;
    scope = 'Process exit observation only; interaction evidence is recorded separately.'
} | ConvertTo-Json | Set-Content -LiteralPath $reportPath -Encoding utf8
Write-Output "Exit: $($child.ExitCode); report: $reportPath"
if ($child.ExitCode -ne 0) { throw 'Native application did not exit cleanly; preserve the report and crash evidence.' }
