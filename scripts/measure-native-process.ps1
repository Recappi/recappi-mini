param(
    [Parameter(Mandatory)][int]$TargetProcessId,
    [Parameter(Mandatory)][string]$ExpectedExecutable,
    [Parameter(Mandatory)][string]$Scenario,
    [ValidateRange(5, 60)][int]$DurationSeconds = 30
)
$ErrorActionPreference = 'Stop'
$expected = (Resolve-Path -LiteralPath $ExpectedExecutable).Path
$target = Get-Process -Id $TargetProcessId
if ($target.Path -ne $expected) { throw 'Target executable does not match.' }
$started = $target.StartTime
$known = @{}
$samples = @()
$complete = $true
$clock = [Diagnostics.Stopwatch]::StartNew()
for ($sampleIndex = 0; $sampleIndex -le $DurationSeconds; $sampleIndex++) {
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
    }
    if (@($known.Keys | Where-Object { -not $ids.Contains($_) }).Count -gt 0) { $complete = $false }
    $samples += [ordered]@{ elapsedMs = $clock.Elapsed.TotalMilliseconds; cpuMs = ($known.Values | ForEach-Object { $_.cpuMs } | Measure-Object -Sum).Sum; workingSetBytes = $working; privateBytes = $private; processCount = $ids.Count }
    if ($sampleIndex -lt $DurationSeconds) { Start-Sleep -Seconds 1 }
}
$first = $samples[0]; $last = $samples[-1]
$report = [ordered]@{ measuredAt = [DateTimeOffset]::UtcNow.ToString('O'); scenario = $Scenario; executable = $expected; processIds = @($known.Keys); completeObservedProcessLifetimes = $complete; scope = 'Existing application and descendants observed at one-second snapshots; excludes launcher, startup, and short-lived children between snapshots'; elapsedMs = $last.elapsedMs - $first.elapsedMs; cpuPercentOneCore = ($last.cpuMs - $first.cpuMs) / ($last.elapsedMs - $first.elapsedMs) * 100; samples = $samples }
$directory = Join-Path (Split-Path $PSScriptRoot -Parent) ('build/native-desktop-validation/process-profile-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($directory)
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $directory 'results.json') -Encoding utf8
[ordered]@{ scenario = $Scenario; elapsedMs = $report.elapsedMs; cpuPercentOneCore = $report.cpuPercentOneCore; workingSetBytes = $last.workingSetBytes; privateBytes = $last.privateBytes; processIds = $report.processIds; report = (Join-Path $directory 'results.json') } | ConvertTo-Json -Depth 4
