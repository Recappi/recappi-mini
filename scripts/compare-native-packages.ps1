param(
    [Parameter(Mandatory)][string]$BaselineReleaseDirectory,
    [Parameter(Mandatory)][string]$CandidateReleaseDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$baselineRoot = (Resolve-Path -LiteralPath $BaselineReleaseDirectory).Path.TrimEnd('\', '/')
$candidateRoot = (Resolve-Path -LiteralPath $CandidateReleaseDirectory).Path.TrimEnd('\', '/')
$output = [IO.Path]::GetFullPath($OutputDirectory)
foreach ($releaseRoot in @($baselineRoot, $candidateRoot)) {
    if ($output.Equals($releaseRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $output.StartsWith($releaseRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Write comparison evidence outside both release directories.'
    }
}
if (Test-Path -LiteralPath $output) { throw 'Use a new output directory to preserve previous evidence.' }
$baseline = Get-Content -LiteralPath (Join-Path $baselineRoot 'release-report.json') -Raw | ConvertFrom-Json
$candidate = Get-Content -LiteralPath (Join-Path $candidateRoot 'release-report.json') -Raw | ConvertFrom-Json
if ($baseline.sourceDirty -ne $false -or $candidate.sourceDirty -ne $false -or
    $baseline.sourceCommit -notmatch '^[0-9a-f]{40}$' -or $baseline.sourceCommit -ne $candidate.sourceCommit) {
    throw 'Compare builds from the same clean source commit.'
}
$runtimes = @('win-x64', 'win-arm64')
foreach ($release in @($baseline, $candidate)) {
    if ($release.packageType -ne 'portable-zip' -or $release.artifacts.Count -ne 2 -or
        @($release.artifacts.runtime | Sort-Object -Unique).Count -ne 2 -or
        @($release.artifacts | Where-Object { $_.runtime -notin $runtimes }).Count) {
        throw 'Both releases must contain exactly x64 and ARM64 portable artifacts.'
    }
}
[void][IO.Directory]::CreateDirectory($output)
$comparisons = @()
foreach ($runtime in $runtimes) {
    $before = $baseline.artifacts | Where-Object runtime -eq $runtime
    $after = $candidate.artifacts | Where-Object runtime -eq $runtime
    if ($before.version -ne $after.version -or !$before.selfContained -or !$after.selfContained -or
        $before.resourceOptimizationCandidate -ne $false -or $after.resourceOptimizationCandidate -ne $true) {
        throw 'Require the same version and self-contained baseline/optimization candidate configuration.'
    }
    $inventories = @{}
    foreach ($name in @('baseline', 'candidate')) {
        $releaseRoot = if ($name -eq 'baseline') { $baselineRoot } else { $candidateRoot }
        $artifact = if ($name -eq 'baseline') { $before } else { $after }
        $package = Join-Path $releaseRoot $runtime
        $archive = Join-Path $releaseRoot ([IO.Path]::GetFileName($artifact.archive))
        if ((Get-Item -LiteralPath $archive).Length -ne $artifact.archiveBytes -or
            (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $artifact.sha256) {
            throw "Archive bytes/hash no longer match the release report: $name $runtime."
        }
        $inventoryPath = Join-Path $output "$name-$runtime.json"
        & (Join-Path $PSScriptRoot 'inspect-native-package.ps1') -PackageDirectory $package -ReportPath $inventoryPath | Out-Null
        $inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
        if ($inventory.fileCount -ne $artifact.fileCount -or $inventory.totalBytes -ne $artifact.publishedBytes) {
            throw "Published payload differs from release report: $name $runtime."
        }
        $inventories[$name] = $inventory
    }
    $beforeFiles = @{}; foreach ($file in $inventories.baseline.files) { $beforeFiles[$file.path] = $file }
    $afterFiles = @{}; foreach ($file in $inventories.candidate.files) { $afterFiles[$file.path] = $file }
    foreach ($file in $inventories.candidate.files) {
        if (!$beforeFiles.ContainsKey($file.path) -or $beforeFiles[$file.path].sha256 -ne $file.sha256) {
            throw "Candidate added or changed retained payload: $runtime/$($file.path)."
        }
    }
    $removed = @($inventories.baseline.files | Where-Object { !$afterFiles.ContainsKey($_.path) })
    foreach ($file in $removed) {
        if ($file.group -eq 'symbols') {
            $symbol = Join-Path $candidateRoot ("symbols/$runtime/" + $file.path)
            if (!(Test-Path -LiteralPath $symbol -PathType Leaf) -or
                (Get-FileHash -LiteralPath $symbol -Algorithm SHA256).Hash -ne $file.sha256) {
                throw "Separated symbol missing or changed: $runtime/$($file.path)."
            }
        }
        elseif ($file.group -ne 'satellite-resources' -or $file.path -notmatch '^[^/]+/[^/]+\.resources\.dll$' -or
            $file.path.StartsWith('zh-Hans/', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Unexpected removed payload: $runtime/$($file.path)."
        }
    }
    if (!$afterFiles.ContainsKey('zh-Hans/PresentationFramework.resources.dll')) { throw 'Candidate lacks simplified Chinese WPF resources.' }
    $reduction = [long]$before.publishedBytes - [long]$after.publishedBytes
    if ($reduction -le 0 -or ($removed | Measure-Object bytes -Sum).Sum -ne $reduction) { throw 'Size reduction is not explained by removed files.' }
    $comparisons += [pscustomobject][ordered]@{
        runtime = $runtime; version = $before.version; retainedFilesIdentical = $afterFiles.Count;
        removedFiles = $removed; symbolsPreserved = @($removed | Where-Object group -eq 'symbols').Count;
        baselineZipBytes = $before.archiveBytes; candidateZipBytes = $after.archiveBytes;
        zipReductionBytes = $before.archiveBytes - $after.archiveBytes;
        zipReductionPercent = 100 * ($before.archiveBytes - $after.archiveBytes) / $before.archiveBytes;
        baselineLogicalBytes = $before.publishedBytes; candidateLogicalBytes = $after.publishedBytes;
        logicalReductionBytes = $reduction; logicalReductionPercent = 100 * $reduction / $before.publishedBytes;
        baselineZipSha256 = $before.sha256; candidateZipSha256 = $after.sha256
    }
}
$report = [ordered]@{
    comparedAt = [DateTimeOffset]::UtcNow.ToString('O'); sourceCommit = $baseline.sourceCommit; sourceDirty = $false;
    baselineRelease = $baselineRoot; candidateRelease = $candidateRoot;
    scope = 'Same clean revision and version; ZIP hashes, identical retained payload, removed language resources and preserved symbols. Published logical sizes only, not installed allocation or Store transfer. Behavior/startup evidence must be collected separately.';
    architectures = $comparisons
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'comparison.json') -Encoding utf8
$comparisons | Select-Object runtime, retainedFilesIdentical, zipReductionBytes, zipReductionPercent, logicalReductionBytes, symbolsPreserved | ConvertTo-Json
