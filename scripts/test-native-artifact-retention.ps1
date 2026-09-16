$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-artifact-retention.ps1')
$repository = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $repository ('build/native-artifact-retention-tests/' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$passed = [Collections.Generic.List[string]]::new()
function Check { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Expect-Rejection {
    param([scriptblock]$Action, [string]$Message)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Check $rejected $Message
}
function New-TestBuild {
    param([string]$Name)
    $path = Join-Path $testRoot ($Name + '/build')
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}
function New-TestArtifact {
    param([string]$Build, [int]$Age, [string]$Kind = 'release', [string]$Architecture = 'win-x64', [bool]$Optimized = $false, [bool]$Managed = $true, [bool]$Signed = $false)
    $category = if ($Kind -eq 'msix') { 'native-msix' } else { 'native-desktop-release' }
    $path = Join-Path $Build ($category + '/' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory((Join-Path $path 'payload'))
    [IO.File]::WriteAllBytes((Join-Path $path 'payload/sample.dll'), [byte[]](1..100))
    $report = [ordered]@{ createdAt = [DateTimeOffset]::UtcNow.AddDays(-$Age).ToString('O'); signed = $Signed }
    if ($Managed) { $report.retentionPolicyVersion = 1 }
    if ($Kind -eq 'msix') { $report.architecture = $Architecture; $name = 'msix-report.json' }
    else {
        $report.artifacts = @($Architecture.Split(',') | ForEach-Object { @{runtime = $_; selfContained = $true; resourceOptimizationCandidate = $Optimized} })
        $name = 'release-report.json'
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $path $name) -Encoding utf8
    return $path
}

$build = New-TestBuild 'profiles'
foreach ($age in 1..4) {
    [void](New-TestArtifact $build $age)
    [void](New-TestArtifact $build $age -Optimized $true)
    [void](New-TestArtifact $build $age -Architecture 'win-x64,win-arm64')
    [void](New-TestArtifact $build $age -Kind msix -Architecture x64)
    [void](New-TestArtifact $build $age -Kind msix -Architecture arm64)
}
$before = Get-NativeArtifactFingerprint @(Get-NativeArtifactFiles $build)
$plan = New-NativeArtifactCleanupPlan $build
Check (@($plan.candidates).Count -eq 5 -and @($plan.retained).Count -eq 15) 'Retention mixed architectures or optimization profiles.'
Check ((Get-NativeArtifactFingerprint @(Get-NativeArtifactFiles $build)) -eq $before) 'Preview modified fixture files.'
$reportsBefore = @(Get-ChildItem $build -Filter '*-report.json' -Recurse | ForEach-Object { @{path = $_.FullName; hash = (Get-FileHash $_.FullName).Hash} })
$result = Invoke-NativeArtifactCleanupPlan $build $plan
Check ($result.prunedArtifacts -eq 5 -and $result.removedBytes -eq 500) 'Cleanup byte count did not match removed payload.'
Check (@(Get-ChildItem $build -Filter sample.dll -Recurse).Count -eq 15) 'Cleanup did not keep three payloads per profile.'
foreach ($report in $reportsBefore) { Check ((Get-FileHash $report.path).Hash -eq $report.hash) 'Cleanup changed historical report bytes.' }
Check (@(New-NativeArtifactCleanupPlan $build).candidates.Count -eq 0) 'Pruned history was treated as runnable payload.'
$passed.Add('profile/architecture retention, preview is read-only, exact byte count, historical reports retained, idempotence')

$build = New-TestBuild 'legacy-and-pins'
foreach ($age in 1..3) { [void](New-TestArtifact $build $age) }
$legacy = New-TestArtifact $build 4 -Managed $false
Check (@((New-NativeArtifactCleanupPlan $build).candidates).Count -eq 0) 'Automatic policy touched pre-policy legacy artifacts.'
$legacyPlan = New-NativeArtifactCleanupPlan $build -IncludeLegacy
Check (@($legacyPlan.candidates).Count -eq 1) 'Explicit legacy preview did not include eligible old output.'
[IO.File]::WriteAllText((Join-Path $legacy '.keep'), 'Retain a performance baseline.')
Expect-Rejection { Invoke-NativeArtifactCleanupPlan $build $legacyPlan } 'An artifact pinned after preview was deleted.'
Check (Test-Path (Join-Path $legacy 'payload/sample.dll')) 'Pinned payload was changed.'
[void](New-TestArtifact $build 5 -Signed $true)
$signedInstaller = New-TestArtifact $build 6
[IO.File]::WriteAllText((Join-Path $signedInstaller 'installer-report.json'), '{"signed":true}')
Check (@((New-NativeArtifactCleanupPlan $build -IncludeLegacy).candidates).Count -eq 0) 'Signed output was not protected.'
$passed.Add('legacy opt-in, pins added after preview, signed package and nested signed installer protection')

$build = New-TestBuild 'legacy-adoption'
foreach ($age in 1..4) { [void](New-TestArtifact $build $age -Managed $false) }
$plan = New-NativeArtifactCleanupPlan $build -IncludeLegacy
$result = Invoke-NativeArtifactCleanupPlan $build $plan
Check ($result.retainedArtifactsEnrolled -eq 3) 'Legacy migration did not enroll retained history.'
[void](New-TestArtifact $build 0)
Invoke-NativeArtifactAutoRetention $build
Check (@(Get-ChildItem $build -Filter sample.dll -Recurse).Count -eq 3) 'Migrated legacy history accumulated alongside new output.'
$passed.Add('explicit legacy migration enrolls retained output without changing original reports; later auto retention stays bounded')

$build = New-TestBuild 'stale-plan'
foreach ($age in 1..5) { [void](New-TestArtifact $build $age) }
$plan = New-NativeArtifactCleanupPlan $build
$last = Join-Path $build ($plan.candidates[-1].relativePath + '/payload/sample.dll')
[IO.File]::AppendAllText($last, 'changed after review')
Expect-Rejection { Invoke-NativeArtifactCleanupPlan $build $plan } 'Stale payload inventory was accepted.'
Check (@(Get-ChildItem $build -Filter sample.dll -Recurse).Count -eq 5) 'Stale-plan rejection happened after some files were deleted.'
$fresh = New-NativeArtifactCleanupPlan $build
$lease = Enter-NativeArtifactLock $build
try { Expect-Rejection { Invoke-NativeArtifactCleanupPlan $build $fresh } 'Cleanup ignored another artifact operation.' }
finally { $lease.Dispose() }
$fresh.candidates[0].relativePath = '../outside'
Expect-Rejection { Invoke-NativeArtifactCleanupPlan $build $fresh } 'A plan path outside build was accepted.'
Check (@(Get-ChildItem $build -Filter sample.dll -Recurse).Count -eq 5) 'Rejected cleanup changed payload files.'
$passed.Add('all-candidate stale-plan preflight, real operation lock and path traversal rejection')

$build = New-TestBuild 'running-and-locked'
foreach ($age in 1..3) { [void](New-TestArtifact $build $age) }
$old = New-TestArtifact $build 4
$runningExe = Join-Path $old 'Recappi Mini.exe'
Add-Type -TypeDefinition 'public static class ArtifactHold { public static void Main() { System.Threading.Thread.Sleep(30000); } }' -OutputAssembly $runningExe -OutputType ConsoleApplication
$plan = New-NativeArtifactCleanupPlan $build
$heldProcess = Start-Process -FilePath $runningExe -WindowStyle Hidden -PassThru
try {
    Check (-not $heldProcess.HasExited) 'Fixture process did not start.'
    Expect-Rejection { Invoke-NativeArtifactCleanupPlan $build $plan } 'Cleanup removed an artifact with a running executable.'
    Check (Test-Path -LiteralPath $runningExe) 'Running executable was removed.'
} finally {
    if (-not $heldProcess.HasExited) { $heldProcess.Kill(); $heldProcess.WaitForExit() }
}
$plan = New-NativeArtifactCleanupPlan $build
$lockedFile = Join-Path $old 'payload/sample.dll'
$heldFile = [IO.File]::Open($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
try {
    Expect-Rejection { Invoke-NativeArtifactCleanupPlan $build $plan } 'Locked payload deletion was reported as successful.'
    Check (Test-Path -LiteralPath $lockedFile) 'Locked file disappeared.'
    Check (-not (Test-Path -LiteralPath (Join-Path $old '.artifact-pruned.json'))) 'Partial cleanup was marked complete.'
} finally { $heldFile.Dispose() }
$passed.Add('real running executable protected; locked payload failure is surfaced and not marked complete')

$build = New-TestBuild 'junction'
foreach ($age in 1..3) { [void](New-TestArtifact $build $age) }
$old = New-TestArtifact $build 4
$plan = New-NativeArtifactCleanupPlan $build
$outside = Join-Path $testRoot 'outside-sentinel'
[void][IO.Directory]::CreateDirectory($outside)
[IO.File]::WriteAllText((Join-Path $outside 'retain.bin'), 'not an artifact')
New-Item -ItemType Junction -Path (Join-Path $old 'linked') -Target $outside | Out-Null
Expect-Rejection { Invoke-NativeArtifactCleanupPlan $build $plan } 'Cleanup traversed a junction added after review.'
Check ((Get-Content (Join-Path $outside 'retain.bin') -Raw) -eq 'not an artifact') 'Cleanup changed data outside its artifact.'
$passed.Add('actual Windows junction rejected and external sentinel preserved')

$build = New-TestBuild 'tests'
foreach ($index in 1..4) {
    $path = Join-Path $build ('native-desktop-validation/core-tests-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    [IO.File]::WriteAllText((Join-Path $path 'audio.wav'), 'synthetic fixture')
    [IO.File]::WriteAllText((Join-Path $path 'results.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $path 'screenshot.png'), 'retained evidence')
    [IO.Directory]::SetCreationTimeUtc($path, [DateTime]::UtcNow.AddDays(-$index))
    [IO.Directory]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-$index))
}
$named = Join-Path $build 'native-desktop-validation/import-complete-ui-01'
[void][IO.Directory]::CreateDirectory($named)
[IO.File]::WriteAllText((Join-Path $named 'audio.wav'), 'manual acceptance sample')
Check (@((New-NativeArtifactCleanupPlan $build).candidates).Count -eq 0) 'Default cleanup included test data.'
$plan = New-NativeArtifactCleanupPlan $build -IncludeTestRuns
Check (@($plan.candidates).Count -eq 1) 'Explicit old test retention did not keep the latest three runs.'
Invoke-NativeArtifactCleanupPlan $build $plan | Out-Null
Check ((Get-Content (Join-Path $named 'audio.wav') -Raw) -eq 'manual acceptance sample') 'Named acceptance recording was changed.'
Check (@(Get-ChildItem $build -Filter screenshot.png -Recurse).Count -eq 4) 'Test cleanup removed screenshots.'
$passed.Add('test cleanup is explicit, named recordings protected, screenshots and results retained')

$build = New-TestBuild 'automatic'
foreach ($age in 1..4) { [void](New-TestArtifact $build $age) }
Invoke-NativeArtifactAutoRetention $build
Check (@(Get-ChildItem $build -Filter sample.dll -Recurse).Count -eq 3) 'Producer automatic retention did not enforce the limit.'
$passed.Add('producer automatic retention removes only eligible managed history')

[ordered]@{ completedAt = [DateTimeOffset]::UtcNow.ToString('O'); passed = $passed.ToArray(); fixtureRoot = $testRoot; scope = 'Tiny synthetic artifact trees; includes real file lock, junction and file deletion. No existing release or validation artifacts deleted.' } |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $testRoot 'results.json') -Encoding utf8
Write-Output ("PASS {0} artifact-retention groups: {1}" -f $passed.Count, $testRoot)
