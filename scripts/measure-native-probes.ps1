param([string]$OutputDirectory = 'build/native-desktop-validation')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$outputRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDirectory))
$runRoot = Join-Path $outputRoot ('run-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $runRoot | Out-Null
$results = @()
foreach ($entry in @(@{ Name='wpf'; Exe='WpfProbe' }, @{ Name='winui'; Exe='WinUIProbe' })) {
    $publishDirectory = Join-Path $outputRoot ($entry.Name + '-publish')
    $exePath = Join-Path $publishDirectory ($entry.Exe + '.exe')
    if (-not (Test-Path -LiteralPath $exePath)) { throw "Publish probe first: $exePath" }
    $resultPath = Join-Path $runRoot ($entry.Name + '.json')
    $process = Start-Process -FilePath $exePath -ArgumentList ('"' + $resultPath + '"') -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(45000)) {
        # This process was created by this measurement and owns no recording data.
        $process.Kill()
        $process.WaitForExit()
        throw "Probe did not exit cleanly: $($entry.Name). Results are not accepted."
    }
    if ($process.ExitCode -ne 0) { throw "Probe failed: $($entry.Name), exit $($process.ExitCode)" }
    if (-not (Test-Path -LiteralPath $resultPath)) { throw "Probe produced no measurement: $($entry.Name)" }
    $result = Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json
    $result | Add-Member -NotePropertyName publishBytes -NotePropertyValue ((Get-ChildItem -LiteralPath $publishDirectory -File -Recurse | Measure-Object Length -Sum).Sum)
    $results += $result
}
$report = [ordered]@{ measuredAt=[DateTimeOffset]::Now.ToString('o'); os=[Environment]::OSVersion.VersionString; architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); processorCount=[Environment]::ProcessorCount; results=$results }
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runRoot 'report.json')
$report | ConvertTo-Json -Depth 8
