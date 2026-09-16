# Shared by artifact producers and the explicit cleanup command. Never dot-source
# this file from a pipeline: its functions return objects, not console summaries.
function Assert-NativeArtifactDirectory {
    param([Parameter(Mandatory)][string]$Directory)
    $resolved = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
    $ancestor = $resolved
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Artifact path contains a link: $ancestor" }
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    return $resolved
}

function Enter-NativeArtifactLock {
    param([Parameter(Mandatory)][string]$BuildRoot)
    $root = Assert-NativeArtifactDirectory $BuildRoot
    [void][IO.Directory]::CreateDirectory($root)
    $lockPath = Join-Path $root '.native-artifact-operation.lock'
    if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Artifact operation lock must not be a link.'
    }
    try { return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another native publish, packaging or cleanup operation is using build artifacts. Retry after it finishes.' }
}

function Get-NativeArtifactFiles {
    param([Parameter(Mandatory)][string]$Directory)
    $root = Assert-NativeArtifactDirectory $Directory
    $pendingDirectories = [Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($root)
    while ($pendingDirectories.Count) {
        $currentDirectory = $pendingDirectories.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $currentDirectory -Force -ErrorAction Stop) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Artifact contains a link: $($item.FullName)" }
            if ($item.PSIsContainer) { $pendingDirectories.Push($item.FullName) }
            else { $item }
        }
    }
}

function Get-NativeArtifactFingerprint {
    param([object[]]$Files)
    $rows = @($Files | Sort-Object FullName | ForEach-Object { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks })
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($rows -join "`n")))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-NativeArtifactPayloadFiles {
    param([object[]]$Files, [string]$Kind)
    # Keep historical reports in place so documentation links still resolve.
    # Validation screenshots/videos are evidence, not disposable test payload.
    $retainedExtensions = @('.json', '.jsonl', '.log', '.txt', '.md', '.csv', '.html')
    if ($Kind -eq 'test') { $retainedExtensions += @('.png', '.jpg', '.jpeg', '.mp4', '.webm') }
    @($Files | Where-Object { $_.Extension.ToLowerInvariant() -notin $retainedExtensions -and $_.Name -ne '.keep' })
}

function Get-NativeArtifactUsage {
    $runningPaths = @()
    $testRunning = $false
    foreach ($process in @(Get-Process -Name 'Recappi Mini', 'Recappi.Core.Tests', 'Recappi.Desktop.Tests' -ErrorAction SilentlyContinue)) {
        if ($process.ProcessName -like 'Recappi.*.Tests') { $testRunning = $true }
        try {
            $processPath = $process.Path
            if ([string]::IsNullOrWhiteSpace($processPath)) { throw 'Process path unavailable.' }
            $runningPaths += $processPath
        } catch { throw 'Cannot inspect a running Recappi process; leave artifacts untouched.' }
    }
    # Development registrations can point at an unpacked build even when its app
    # is not running. Protect those locations too, not just live EXE handles.
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        try {
            foreach ($package in @(Get-AppxPackage -ErrorAction Stop)) {
                if ($package.InstallLocation) { $runningPaths += [string]$package.InstallLocation }
            }
        } catch { throw 'Cannot inspect registered packages; leave artifacts untouched.' }
    }
    [pscustomobject]@{ paths = $runningPaths; testsRunning = $testRunning }
}

function New-NativeArtifactCleanupPlan {
    param(
        [Parameter(Mandatory)][string]$BuildRoot,
        [ValidateRange(1, 30)][int]$KeepLatest = 3,
        [switch]$IncludeLegacy,
        [switch]$IncludeTestRuns
    )
    $root = Assert-NativeArtifactDirectory $BuildRoot
    $entries = [Collections.Generic.List[object]]::new()
    $skipped = [Collections.Generic.List[object]]::new()
    $usage = Get-NativeArtifactUsage
    $runningPaths = @($usage.paths)
    $testRunning = $usage.testsRunning
    $categories = @('native-desktop-release', 'native-msix')
    if ($IncludeTestRuns) { $categories += 'native-desktop-validation' }
    foreach ($category in $categories) {
        $parent = Join-Path $root $category
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
        [void](Assert-NativeArtifactDirectory $parent)
        foreach ($directory in Get-ChildItem -LiteralPath $parent -Directory -Force) {
            $relative = $category + '/' + $directory.Name
            $isTest = $category -eq 'native-desktop-validation'
            if (($isTest -and $directory.Name -notmatch '^(core-tests|ui-smoke)-[a-f0-9]{32}$') -or
                (-not $isTest -and $directory.Name -notmatch '^[a-f0-9]{32}$')) { continue }
            try {
                [void](Assert-NativeArtifactDirectory $directory.FullName)
                if (Test-Path -LiteralPath (Join-Path $directory.FullName '.artifact-pruned.json')) { continue }
                if (Test-Path -LiteralPath (Join-Path $directory.FullName '.keep')) { throw 'Pinned with .keep.' }
                if (@($runningPaths | Where-Object { $_.Equals($directory.FullName, [StringComparison]::OrdinalIgnoreCase) -or $_.StartsWith($directory.FullName + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Application is running or registered from this artifact.' }
                $created = $directory.CreationTimeUtc
                if ($isTest) {
                    if ($testRunning) { throw 'Native tests are running.' }
                    if ($directory.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddHours(-24)) { throw 'Test evidence is less than 24 hours old.' }
                    $kind = 'test'
                    $artifactProfile = 'test:' + ($directory.Name -replace '-[a-f0-9]{32}$', '')
                } else {
                    $kind = if ($category -eq 'native-msix') { 'msix' } else { 'release' }
                    $reportName = if ($kind -eq 'msix') { 'msix-report.json' } else { 'release-report.json' }
                    $reportPath = Join-Path $directory.FullName $reportName
                    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw 'No completion report; preserve incomplete or unknown output.' }
                    $reportFile = Get-Item -LiteralPath $reportPath -Force
                    if (($reportFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $reportFile.Length -gt 4MB) { throw 'Unsafe completion report.' }
                    $report = Get-Content -LiteralPath $reportPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $managed = $report.retentionPolicyVersion -eq 1
                    $managedPath = Join-Path $directory.FullName '.artifact-managed.json'
                    if (-not $managed -and (Test-Path -LiteralPath $managedPath -PathType Leaf)) {
                        $managedFile = Get-Item -LiteralPath $managedPath -Force
                        if (($managedFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $managedFile.Length -gt 4KB) { throw 'Unsafe retention marker.' }
                        $managed = (Get-Content -LiteralPath $managedPath -Raw | ConvertFrom-Json -ErrorAction Stop).retentionPolicyVersion -eq 1
                    }
                    if (-not $IncludeLegacy -and -not $managed) { throw 'Legacy output requires an explicit cleanup preview.' }
                    if ($report.signed -eq $true -or $report.installed -eq $true -or $report.storeReady -eq $true) { throw 'Signed, installed or Store-ready output is protected.' }
                    $created = ([DateTimeOffset]::Parse($report.createdAt)).UtcDateTime
                    if ($kind -eq 'msix') {
                        if ($report.architecture -notin @('x64', 'arm64')) { throw 'Unknown MSIX architecture.' }
                        $artifactProfile = 'msix:' + $report.architecture
                    } else {
                        $artifacts = @($report.artifacts)
                        if ($artifacts.Count -lt 1 -or $artifacts.Count -gt 2 -or @($artifacts | Where-Object { $_.runtime -notin @('win-x64', 'win-arm64') }).Count) { throw 'Unknown release architecture set.' }
                        $parts = @($artifacts | Sort-Object runtime | ForEach-Object { $_.runtime + ':self=' + [bool]$_.selfContained + ':optimized=' + [bool]$_.resourceOptimizationCandidate })
                        $artifactProfile = 'release:' + ($parts -join ',')
                    }
                }
                $files = @(Get-NativeArtifactFiles $directory.FullName)
                foreach ($installerReport in @($files | Where-Object Name -eq 'installer-report.json')) {
                    if ($installerReport.Length -gt 4MB) { throw 'Unsafe installer report.' }
                    $installer = Get-Content -LiteralPath $installerReport.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
                    if ($installer.signed -eq $true) { throw 'Release contains a signed installer.' }
                }
                $payload = @(Get-NativeArtifactPayloadFiles -Files $files -Kind $kind)
                $entries.Add([pscustomobject]@{ relativePath = $relative; kind = $kind; profile = $artifactProfile; createdAt = $created.ToString('O');
                    bytes = [long](($payload | Measure-Object Length -Sum).Sum); files = $payload.Count; fingerprint = Get-NativeArtifactFingerprint $files })
            } catch { $skipped.Add([pscustomobject]@{ relativePath = $relative; reason = $_.Exception.Message }) }
        }
    }
    $candidates = @()
    $retained = @()
    foreach ($group in $entries | Group-Object profile) {
        $ordered = @($group.Group | Sort-Object createdAt, relativePath -Descending)
        $retained += @($ordered | Select-Object -First $KeepLatest)
        $candidates += @($ordered | Select-Object -Skip $KeepLatest | Where-Object bytes -gt 0)
    }
    $largeEvidence = @()
    $evidenceInventoryError = $null
    $validationRoot = Join-Path $root 'native-desktop-validation'
    if ($IncludeTestRuns -and (Test-Path -LiteralPath $validationRoot -PathType Container)) {
        try {
            $candidateRoots = @($candidates | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $root $_.relativePath)) + [IO.Path]::DirectorySeparatorChar })
            $largeEvidence = @(Get-NativeArtifactFiles $validationRoot | Where-Object { $_.Length -ge 100MB -and $_.Extension.ToLowerInvariant() -in @('.wav', '.mp3', '.m4a', '.dmp') } | ForEach-Object {
                $file = $_
                if (-not @($candidateRoots | Where-Object { $file.FullName.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) {
                    [pscustomobject]@{ relativePath = $file.FullName.Substring($root.Length + 1).Replace('\', '/'); bytes = $file.Length; action = 'retained; requires separate evidence review' }
                }
            } | Sort-Object bytes -Descending)
        } catch { $evidenceInventoryError = $_.Exception.Message }
    }
    [pscustomobject][ordered]@{
        schemaVersion = 1; createdAt = [DateTimeOffset]::UtcNow.ToString('O'); buildRoot = $root;
        keepLatest = $KeepLatest; includeLegacy = [bool]$IncludeLegacy; includeTestRuns = [bool]$IncludeTestRuns;
        candidateBytes = [long](($candidates | Measure-Object bytes -Sum).Sum); candidates = $candidates; retained = $retained; skipped = @($skipped.ToArray());
        largeEvidence = $largeEvidence; evidenceInventoryError = $evidenceInventoryError
    }
}

function Invoke-NativeArtifactCleanupPlan {
    param([Parameter(Mandatory)][string]$BuildRoot, [Parameter(Mandatory)]$Plan)
    $root = Assert-NativeArtifactDirectory $BuildRoot
    if ($Plan.schemaVersion -ne 1 -or -not $root.Equals([string]$Plan.buildRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup plan belongs to another build directory.' }
    $lease = Enter-NativeArtifactLock $root
    try {
        $current = New-NativeArtifactCleanupPlan -BuildRoot $root -KeepLatest $Plan.keepLatest -IncludeLegacy:$Plan.includeLegacy -IncludeTestRuns:$Plan.includeTestRuns
        $eligible = @{}
        foreach ($entry in $current.candidates) { $eligible[$entry.relativePath] = $entry }
        $retained = @{}
        foreach ($entry in $current.retained) { $retained[$entry.relativePath] = $entry }
        # Validate the entire reviewed set before deleting any payload. New candidates
        # are deliberately not added to an already-reviewed plan.
        $seen = @{}
        foreach ($entry in $Plan.candidates) {
            if ($seen.ContainsKey($entry.relativePath)) { throw 'Duplicate artifact in cleanup plan.' }
            $seen[$entry.relativePath] = $true
            if (-not $eligible.ContainsKey($entry.relativePath) -or $eligible[$entry.relativePath].fingerprint -ne $entry.fingerprint) {
                throw "Artifact changed or is protected; generate a fresh preview: $($entry.relativePath)"
            }
        }
        if ($Plan.includeLegacy) {
            foreach ($entry in $Plan.retained) {
                if (-not $retained.ContainsKey($entry.relativePath) -or $retained[$entry.relativePath].fingerprint -ne $entry.fingerprint) {
                    throw "Retained artifact changed; generate a fresh preview: $($entry.relativePath)"
                }
            }
        }
        $removedBytes = 0L
        foreach ($requested in $Plan.candidates) {
            $entry = $eligible[$requested.relativePath]
            $target = [IO.Path]::GetFullPath((Join-Path $root $entry.relativePath))
            if (-not $target.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Cleanup target escaped build.' }
            [void](Assert-NativeArtifactDirectory $target)
            $files = @(Get-NativeArtifactFiles $target)
            if ((Get-NativeArtifactFingerprint $files) -ne $entry.fingerprint) { throw 'Artifact changed during cleanup.' }
            foreach ($file in @(Get-NativeArtifactPayloadFiles -Files $files -Kind $entry.kind)) {
                $resolvedFile = (Resolve-Path -LiteralPath $file.FullName -ErrorAction Stop).Path
                if (-not $resolvedFile.StartsWith($target + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Payload escaped artifact directory.' }
                $length = $file.Length
                Remove-Item -LiteralPath $resolvedFile -Force -ErrorAction Stop
                $removedBytes += $length
            }
            [ordered]@{ prunedAt = [DateTimeOffset]::UtcNow.ToString('O'); removedBytes = $entry.bytes; removedFiles = $entry.files;
                note = 'Binary payload removed by retention policy; reports preserved. Historical report paths do not imply binaries remain available.' } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target '.artifact-pruned.json') -Encoding utf8
        }
        $adopted = 0
        if ($Plan.includeLegacy) {
            foreach ($approved in $Plan.retained) {
                $entry = $retained[$approved.relativePath]
                if ($entry.kind -eq 'test') { continue }
                $target = Assert-NativeArtifactDirectory (Join-Path $root $entry.relativePath)
                [ordered]@{ retentionPolicyVersion = 1; adoptedAt = [DateTimeOffset]::UtcNow.ToString('O') } |
                    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target '.artifact-managed.json') -Encoding utf8
                $adopted++
            }
        }
        [pscustomobject]@{ prunedArtifacts = @($Plan.candidates).Count; removedBytes = $removedBytes; retainedArtifactsEnrolled = $adopted }
    } finally { $lease.Dispose() }
}

function Invoke-NativeArtifactAutoRetention {
    param([Parameter(Mandatory)][string]$BuildRoot, [ValidateRange(1, 30)][int]$KeepLatest = 3)
    try {
        $plan = New-NativeArtifactCleanupPlan -BuildRoot $BuildRoot -KeepLatest $KeepLatest
        if (@($plan.candidates).Count) {
            $result = Invoke-NativeArtifactCleanupPlan -BuildRoot $BuildRoot -Plan $plan
            Write-Host ("Pruned {0} old managed artifacts ({1:N2} GiB); reports retained." -f $result.prunedArtifacts, ($result.removedBytes / 1GB))
        }
    } catch { Write-Warning ("Artifact retention could not finish; run clean-native-artifacts.ps1 to inspect: " + $_.Exception.Message) }
}
