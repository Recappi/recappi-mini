param([Parameter(Mandatory)][string]$Executable)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$expected = (Resolve-Path -LiteralPath $Executable).Path
if ([IO.Path]::GetFileName($expected) -ne 'Recappi Mini.exe') { throw 'Select the published desktop executable.' }
$package = Split-Path -Parent $expected
$runtime = Get-Content -LiteralPath (Join-Path $package 'Recappi Mini.runtimeconfig.json') -Raw | ConvertFrom-Json
if (-not $runtime.runtimeOptions.includedFrameworks) { throw 'Use a self-contained application.' }
if (@(Get-Process -Name 'Recappi Mini' -ErrorAction SilentlyContinue).Count) { throw 'An existing application instance would invalidate startup recovery.' }
$fixtureExe = Join-Path $repository 'native/desktop/Recappi.Core.Tests/bin/Release/net10.0-windows/Recappi.Core.Tests.exe'
if (-not (Test-Path -LiteralPath $fixtureExe)) { throw 'Build Release core tests first.' }
$root = Join-Path $repository ('build/native-desktop-validation/startup-recovery-' + [Guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $root 'Recordings'
[void][IO.Directory]::CreateDirectory($dataRoot)
[ordered]@{ onboardingCompleted = $true; theme = 'light'; autoUpload = $false; captionsEnabled = $false;
    includeMicrophone = $false; recordingSuggestions = $false; inactivityReminders = $false;
    sourceId = 'system'; recordingsRoot = $dataRoot } | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $root 'settings.json') -Encoding utf8
$fixture = [Diagnostics.Process]::new()
$fixture.StartInfo = [Diagnostics.ProcessStartInfo]::new($fixtureExe)
$fixture.StartInfo.UseShellExecute = $false
$fixture.StartInfo.CreateNoWindow = $true
$fixture.StartInfo.ArgumentList.Add('--interrupted-recording-child')
$fixture.StartInfo.ArgumentList.Add($dataRoot)
$fixtureStarted = $false
try {
    $fixtureStarted = $fixture.Start()
    if (-not $fixtureStarted) { throw 'Fixture did not start.' }
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    $signal = Join-Path $dataRoot 'ready'
    while (-not (Test-Path -LiteralPath $signal)) {
        if ($fixture.HasExited -or $deadline.Elapsed.TotalSeconds -gt 15) { throw 'Fixture did not reach recording.' }
        Start-Sleep -Milliseconds 50
    }
    if ([int](Get-Content -LiteralPath $signal -Raw) -ne $fixture.Id) { throw 'Fixture signal PID mismatch.' }
    $fixture.Kill() # Only this owned synthetic-audio child; intentionally bypass finalization.
    if (-not $fixture.WaitForExit(10000)) { throw 'Fixture did not terminate.' }
} finally {
    if ($fixtureStarted -and -not $fixture.HasExited) { $fixture.Kill(); [void]$fixture.WaitForExit(10000) }
    $fixture.Dispose()
}
$metadataFiles = @(Get-ChildItem -LiteralPath $dataRoot -Filter desktop-session.json -File -Recurse)
if ($metadataFiles.Count -ne 1) { throw 'Expected exactly one isolated recording.' }
$metadataPath = $metadataFiles[0].FullName
$before = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
if ($before.State -ne 'Recording') { throw 'Fixture finalized instead of leaving interrupted recording.' }
$audioPath = Join-Path $metadataFiles[0].DirectoryName 'audio.wav'
$beforeBytes = $null
for ($attempt = 0; $attempt -lt 100; $attempt++) {
    try { $beforeBytes = [IO.File]::ReadAllBytes($audioPath); break }
    catch [IO.IOException] {
        if (($_.Exception.HResult -band 0xffff) -notin 32,33) { throw }
        Start-Sleep -Milliseconds 50
    }
}
if ($null -eq $beforeBytes) { throw 'Terminated fixture retained an audio file lock.' }
$payloadHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$beforeBytes[44..($beforeBytes.Length - 1)]))
$readyPath = Join-Path $root 'app-ready.json'
$app = [Diagnostics.Process]::new()
$app.StartInfo = [Diagnostics.ProcessStartInfo]::new($expected)
$app.StartInfo.UseShellExecute = $false
$app.StartInfo.CreateNoWindow = $true
$app.StartInfo.WorkingDirectory = $package
$app.StartInfo.ArgumentList.Add('--validation-data-dir')
$app.StartInfo.ArgumentList.Add($dataRoot)
$app.StartInfo.Environment['RECAPPI_DESKTOP_STARTUP_REPORT'] = $readyPath
$app.StartInfo.Environment['RECAPPI_DESKTOP_STARTUP_EXIT'] = '1'
$app.StartInfo.Environment['PATH'] = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
$appStarted = $false
try {
    $appStarted = $app.Start()
    if (-not $appStarted -or -not $app.WaitForExit(30000)) { throw 'Application did not finish its startup/normal-quit probe.' }
    if ($app.ExitCode -ne 0) { throw 'Application exited with failure.' }
    $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
    if ($ready.processId -ne $app.Id -or -not $ready.ready -or $ready.recordingState -ne 'Idle' -or $ready.accountState -ne 'SignedOut') { throw 'Wrong application readiness state.' }
    $after = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $afterBytes = [IO.File]::ReadAllBytes($audioPath)
    $afterHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$afterBytes[44..($afterBytes.Length - 1)]))
    if ($after.State -ne 'Error' -or $after.DurationMs -lt 300 -or -not $after.Error -or $payloadHash -ne $afterHash -or
        [BitConverter]::ToUInt32($afterBytes, 40) -ne ($afterBytes.Length - 44)) { throw 'Startup did not preserve and recover the interrupted audio.' }
    [ordered]@{ verifiedAt = [DateTimeOffset]::UtcNow.ToString('O'); executable = $expected;
        assemblySha256 = (Get-FileHash -LiteralPath (Join-Path $package 'Recappi Mini.dll') -Algorithm SHA256).Hash;
        scope = 'Synthetic PCM engine child abruptly terminated; actual self-contained App startup recovery and normal idle quit. No WASAPI, network, UI/video acceptance, or power-loss claim.';
        processId = $app.Id; normalExitCode = $app.ExitCode; beforeState = $before.State; afterState = $after.State;
        recoveredDurationMs = $after.DurationMs; retainedPayloadSha256 = $afterHash; payloadPreserved = $true;
        nodeAbsentFromChildPath = $true } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'results.json') -Encoding utf8
    Write-Output ('Recovery report: ' + (Join-Path $root 'results.json'))
} finally {
    if ($appStarted -and -not $app.HasExited) { Write-Warning ('Application remains open for inspection: PID ' + $app.Id) }
    $app.Dispose()
}
