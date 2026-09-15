param(
    [Parameter(Mandatory)][string]$Executable,
    [ValidateRange(1, 10)][int]$Iterations = 5
)
$ErrorActionPreference = 'Stop'
$expected = (Resolve-Path -LiteralPath $Executable).Path
if ([IO.Path]::GetFileName($expected) -ne 'Recappi Mini.exe') { throw 'Select the published native desktop executable.' }
$package = Split-Path -Parent $expected
$runtime = Get-Content -LiteralPath (Join-Path $package 'Recappi Mini.runtimeconfig.json') -Raw | ConvertFrom-Json
if (-not $runtime.runtimeOptions.includedFrameworks) { throw 'Measure a self-contained publish output.' }
if (@(Get-Process -Name 'Recappi Mini' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Close existing Recappi Mini instances before benchmarking.' }
$repository = Split-Path -Parent $PSScriptRoot
$root = Join-Path $repository ('build/native-desktop-validation/startup-profile-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$samples = @()
for ($index = 0; $index -lt $Iterations; $index++) {
    $sampleRoot = Join-Path $root ('sample-' + ($index + 1))
    [void][IO.Directory]::CreateDirectory($sampleRoot)
    $dataRoot = Join-Path $sampleRoot 'Recordings'
    [ordered]@{ onboardingCompleted = $true; theme = 'light'; autoUpload = $false; captionsEnabled = $false;
        includeMicrophone = $false; recordingSuggestions = $false; inactivityReminders = $false;
        sourceId = 'system'; recordingsRoot = $dataRoot } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sampleRoot 'settings.json') -Encoding utf8
    $readyPath = Join-Path $sampleRoot 'ready.json'
    $child = New-Object Diagnostics.Process
    $child.StartInfo = New-Object Diagnostics.ProcessStartInfo
    $child.StartInfo.FileName = $expected
    $child.StartInfo.WorkingDirectory = $package
    $child.StartInfo.UseShellExecute = $false
    $child.StartInfo.CreateNoWindow = $true
    $child.StartInfo.EnvironmentVariables['RECAPPI_DESKTOP_DATA_DIR'] = $dataRoot
    $child.StartInfo.EnvironmentVariables['RECAPPI_DESKTOP_STARTUP_REPORT'] = $readyPath
    $child.StartInfo.EnvironmentVariables['RECAPPI_DESKTOP_STARTUP_EXIT'] = '1'
    $child.StartInfo.EnvironmentVariables['PATH'] = (Join-Path $env:SystemRoot 'System32') + ';' + $env:SystemRoot
    $child.StartInfo.EnvironmentVariables['DOTNET_MULTILEVEL_LOOKUP'] = '0'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $started = $false
    try {
        $started = $child.Start()
        if (-not $started) { throw 'Could not start the native application.' }
        while (-not (Test-Path -LiteralPath $readyPath)) {
            if ($child.HasExited) { throw 'Application exited before producing a readiness report.' }
            if ($clock.Elapsed.TotalSeconds -gt 30) { throw 'Application did not reach readiness within 30 seconds.' }
            Start-Sleep -Milliseconds 20
        }
        $elapsedMs = $clock.Elapsed.TotalMilliseconds
        $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
        if ($ready.processId -ne $child.Id -or -not $ready.ready -or -not $ready.canStart -or $ready.accountState -ne 'SignedOut' -or $ready.recordingState -ne 'Idle') {
            throw 'Readiness report does not describe this isolated idle process.'
        }
        if (-not $child.WaitForExit(10000) -or $child.ExitCode -ne 0) { throw 'Benchmark application did not finish the normal quit path.' }
        $samples += [ordered]@{ iteration = $index + 1; processId = $child.Id; launchToReadyObservedMs = $elapsedMs;
            firstFrameAfterStartupMs = $ready.firstFrameAfterStartupMs; readyAfterStartupMs = $ready.readyAfterStartupMs;
            sourceCount = $ready.sourceCount; microphoneCount = $ready.microphoneCount;
            framework = $ready.framework; architecture = $ready.architecture; normalExit = $true }
    }
    finally {
        # Do not force-kill an application whose readiness/recording state is unknown.
        if ($started -and -not $child.HasExited) { Write-Warning ('Benchmark process remains open for inspection: PID ' + $child.Id) }
        $child.Dispose()
    }
}
$ordered = @($samples | ForEach-Object { $_.launchToReadyObservedMs } | Sort-Object)
$middle = [int][Math]::Floor($ordered.Count / 2)
$median = if ($ordered.Count % 2 -eq 0) { ($ordered[$middle - 1] + $ordered[$middle]) / 2 } else { $ordered[$middle] }
$report = [ordered]@{
    measuredAt = [DateTimeOffset]::UtcNow.ToString('O'); executable = $expected;
    assemblySha256 = (Get-FileHash -LiteralPath (Join-Path $package 'Recappi Mini.dll') -Algorithm SHA256).Hash.ToLowerInvariant();
    os = [Environment]::OSVersion.VersionString; logicalProcessors = [Environment]::ProcessorCount;
    scope = 'Fresh process launch to observed first ContentRendered plus device enumeration and signed-out account restore; OS file cache is not cleared; includes report publication and up to one polling interval; no recording, onboarding or network login';
    childPath = 'Windows System32 and Windows directory only'; pollingIntervalMs = 20;
    medianMs = $median; minimumMs = $ordered[0]; maximumMs = $ordered[-1]; samples = $samples
}
$reportPath = Join-Path $root 'results.json'
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding utf8
[ordered]@{ iterations = $samples.Count; medianMs = $median; minimumMs = $ordered[0]; maximumMs = $ordered[-1]; report = $reportPath } | ConvertTo-Json
