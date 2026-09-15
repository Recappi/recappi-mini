param(
    [Parameter(Mandatory)][int]$TargetProcessId,
    [Parameter(Mandatory)][string]$ExpectedExecutable,
    [Parameter(Mandatory)][string]$Scenario,
    [ValidateRange(5, 60)][int]$DurationSeconds = 30,
    [switch]$IncludeThreads,
    [ValidateRange(0, 2147483647)][int]$RequiredInputProcessId = 0
)
$ErrorActionPreference = 'Stop'
$expected = (Resolve-Path -LiteralPath $ExpectedExecutable).Path
$target = Get-Process -Id $TargetProcessId
if ($target.Path -ne $expected) { throw 'Target executable does not match.' }
$started = $target.StartTime
$inputProcess = if ($RequiredInputProcessId) { Get-Process -Id $RequiredInputProcessId } else { $null }
$inputStarted = if ($inputProcess) { $inputProcess.StartTime } else { $null }
$measurementStartedAt = [DateTimeOffset]::UtcNow.ToString('O')
$known = @{}
$threads = @{}
$threadReadFailures = 0
$samples = @()
$complete = $true
$clock = [Diagnostics.Stopwatch]::StartNew()
for ($sampleIndex = 0; $sampleIndex -le $DurationSeconds; $sampleIndex++) {
    if ($RequiredInputProcessId) {
        $inputProcess = Get-Process -Id $RequiredInputProcessId -ErrorAction Stop
        if ($inputProcess.StartTime -ne $inputStarted) { throw 'Controlled input process identity changed.' }
    }
    $target = Get-Process -Id $TargetProcessId
    if ($target.Path -ne $expected -or $target.StartTime -ne $started) { throw 'Target process identity changed.' }
    $processTree = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId)
    $ids = [Collections.Generic.HashSet[int]]::new()
    [void]$ids.Add($TargetProcessId)
    do {
        $added = $false
        foreach ($entry in $processTree) {
            if ($ids.Contains([int]$entry.ParentProcessId) -and $ids.Add([int]$entry.ProcessId)) { $added = $true }
        }
    } while ($added)
    $working = 0L; $private = 0L
    foreach ($processIdValue in $ids) {
        $observed = Get-Process -Id $processIdValue -ErrorAction SilentlyContinue
        if ($null -eq $observed) { $complete = $false; continue }
        if ($known.ContainsKey($processIdValue) -and $known[$processIdValue].started -ne $observed.StartTime) { throw 'Observed process ID was reused.' }
        $known[$processIdValue] = @{ started = $observed.StartTime; cpuMs = $observed.TotalProcessorTime.TotalMilliseconds }
        $working += $observed.WorkingSet64; $private += $observed.PrivateMemorySize64
        if ($IncludeThreads) {
            foreach ($thread in $observed.Threads) {
                try {
                    $threadStarted = $thread.StartTime.ToUniversalTime()
                    $threadKey = '{0}/{1}/{2}' -f $processIdValue, $thread.Id, $threadStarted.Ticks
                    $cpu = $thread.TotalProcessorTime.TotalMilliseconds
                    $user = $thread.UserProcessorTime.TotalMilliseconds
                    $kernel = $thread.PrivilegedProcessorTime.TotalMilliseconds
                    if (-not $threads.ContainsKey($threadKey)) {
                        $threads[$threadKey] = @{ processId = $processIdValue; threadId = $thread.Id; startedAt = $threadStarted.ToString('O');
                            firstCpuMs = $cpu; firstUserMs = $user; firstKernelMs = $kernel; firstObservedMs = $clock.Elapsed.TotalMilliseconds; observations = 0 }
                    }
                    $item = $threads[$threadKey]
                    $item.cpuMs = $cpu; $item.userMs = $user; $item.kernelMs = $kernel
                    $item.lastObservedMs = $clock.Elapsed.TotalMilliseconds; $item.observations++
                } catch { $threadReadFailures++ } # Threads can exit between enumeration and the counter reads.
                finally { $thread.Dispose() }
            }
        }
    }
    if (@($known.Keys | Where-Object { -not $ids.Contains($_) }).Count -gt 0) { $complete = $false }
    $samples += [ordered]@{ elapsedMs = $clock.Elapsed.TotalMilliseconds; cpuMs = ($known.Values | ForEach-Object { $_.cpuMs } | Measure-Object -Sum).Sum; workingSetBytes = $working; privateBytes = $private; processCount = $ids.Count }
    if ($sampleIndex -lt $DurationSeconds) { Start-Sleep -Seconds 1 }
}
$first = $samples[0]; $last = $samples[-1]
$report = [ordered]@{ measuredAt = [DateTimeOffset]::UtcNow.ToString('O'); scenario = $Scenario; executable = $expected; processIds = @($known.Keys); completeObservedProcessLifetimes = $complete; scope = 'Existing application and descendants observed at one-second snapshots; excludes launcher, startup, and short-lived children between snapshots'; elapsedMs = $last.elapsedMs - $first.elapsedMs; cpuPercentOneCore = ($last.cpuMs - $first.cpuMs) / ($last.elapsedMs - $first.elapsedMs) * 100; samples = $samples }
$report.startedAt = $measurementStartedAt
if ($RequiredInputProcessId) {
    $report.requiredInput = [ordered]@{ processId = $RequiredInputProcessId; startedAt = $inputStarted.ToUniversalTime().ToString('O'); aliveAtEverySnapshot = $true; scope = 'Input process identity checked at every snapshot; does not prove audio is non-silent or flowing.' }
}
if ($IncludeThreads) {
    $report.threadScope = 'Actual per-thread CPU counters, not wall-clock stack samples; deltas between first/last successful observations keyed by PID/TID/start time. Omits partial first intervals and short-lived/exited threads; reads are not atomic with process samples.'
    $report.threadReadFailures = $threadReadFailures
    $report.threads = @($threads.Values | ForEach-Object {
        [ordered]@{ processId = $_.processId; threadId = $_.threadId; startedAt = $_.startedAt; observations = $_.observations;
            firstObservedMs = $_.firstObservedMs; lastObservedMs = $_.lastObservedMs;
            cpuMs = $_.cpuMs - $_.firstCpuMs; userMs = $_.userMs - $_.firstUserMs; kernelMs = $_.kernelMs - $_.firstKernelMs;
            cpuPercentOneCore = ($_.cpuMs - $_.firstCpuMs) / $report.elapsedMs * 100 }
    } | Sort-Object { $_.cpuMs } -Descending)
}
$directory = Join-Path (Split-Path $PSScriptRoot -Parent) ('build/native-desktop-validation/process-profile-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $directory 'results.json') -Encoding utf8
[ordered]@{ scenario = $Scenario; elapsedMs = $report.elapsedMs; cpuPercentOneCore = $report.cpuPercentOneCore; workingSetBytes = $last.workingSetBytes; privateBytes = $last.privateBytes; processIds = $report.processIds; report = (Join-Path $directory 'results.json'); topThreads = @($report.threads | Select-Object -First 5) } | ConvertTo-Json -Depth 4
