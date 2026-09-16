[CmdletBinding(DefaultParameterSetName = 'Preview')]
param(
    [Parameter(ParameterSetName = 'Preview')][ValidateRange(1, 30)][int]$KeepLatest = 3,
    [Parameter(ParameterSetName = 'Preview')][switch]$IncludeLegacy,
    [Parameter(ParameterSetName = 'Preview')][switch]$IncludeTestRuns,
    [Parameter(ParameterSetName = 'Preview')][string]$ReportPath,
    [Parameter(Mandatory, ParameterSetName = 'Apply')][string]$ApplyPlan
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native-artifact-retention.ps1')
$buildRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'build'
if ($PSCmdlet.ParameterSetName -eq 'Apply') {
    $plan = Get-Content -LiteralPath $ApplyPlan -Raw | ConvertFrom-Json
    Invoke-NativeArtifactCleanupPlan -BuildRoot $buildRoot -Plan $plan | ConvertTo-Json
} else {
    $plan = New-NativeArtifactCleanupPlan -BuildRoot $buildRoot -KeepLatest $KeepLatest -IncludeLegacy:$IncludeLegacy -IncludeTestRuns:$IncludeTestRuns
    if ($ReportPath) {
        $destination = [IO.Path]::GetFullPath($ReportPath)
        if ($destination.StartsWith(([IO.Path]::GetFullPath($buildRoot) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetDirectoryName($destination) -ne [IO.Path]::GetFullPath($buildRoot)) { throw 'Write cleanup previews at build root or outside build, never inside an artifact.' }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        $plan | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $destination -Encoding utf8
    }
    $plan.candidates | Select-Object relativePath, kind, files, @{n='GiB';e={[math]::Round($_.bytes / 1GB, 3)}} | Format-Table -AutoSize
    Write-Output ("Preview only: {0} artifacts, {1:N2} GiB eligible; {2} retained, {3} protected/skipped." -f @($plan.candidates).Count, ($plan.candidateBytes / 1GB), @($plan.retained).Count, @($plan.skipped).Count)
    if ($ReportPath) { Write-Output "Reviewed plan: $destination" }
}
