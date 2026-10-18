param([Parameter(Mandatory)][string]$BinaryDirectory, [switch]$UpdateChannels, [switch]$RecorderOnly, [switch]$RecorderFlow, [switch]$InteractiveStart)
$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
$binary = [IO.Path]::GetFullPath((Join-Path $workspace $BinaryDirectory))
$executable = Join-Path $binary 'Recappi.WinUI.Tests.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Build the native preview test host first.' }
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
$previewArgument = if ($UpdateChannels) { '--capture-update-previews' } else { '--capture-native-previews' }
$previewArguments = @($previewArgument)
if ($RecorderOnly) { $previewArguments = @('--capture-recorder-previews') }
if ($RecorderFlow) { $previewArguments = @('--only', 'recorder-saved-processing', '--capture-recorder-flow') }
if ($InteractiveStart) { $previewArguments += '--interactive-preview' }
$process = Start-Process -FilePath $executable -ArgumentList $previewArguments -WorkingDirectory $workspace -WindowStyle Hidden -PassThru
$null = $process.Handle
$resultRoot = $null
$identityRoot = $null
$frames = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.HashSet[string]]::new()
try {
    $deadline = (Get-Date).AddSeconds($(if ($InteractiveStart) { 90 } else { 30 }))
    while (-not $resultRoot -and (Get-Date) -lt $deadline) {
        $process.Refresh()
        foreach ($candidate in @(Get-ChildItem (Join-Path $workspace 'build/native-desktop-validation') -Directory -Filter 'winui-tests-*' | Sort-Object LastWriteTime -Descending | Select-Object -First 4)) {
            $identityPath = Join-Path $candidate.FullName 'run-identity.json'
            if (Test-Path -LiteralPath $identityPath) {
                try { $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json } catch { $identity = $null }
                if ($identity.processId -eq $process.Id) { $identityRoot = $candidate.FullName }
            }
            $statePath = Join-Path $candidate.FullName 'capture-state.json'
            if (Test-Path -LiteralPath $statePath) {
                $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                if ($state.processId -eq $process.Id) { $resultRoot = $candidate.FullName; break }
            }
        }
        if ($process.HasExited) {
            $stage = if ($identityRoot -and (Test-Path -LiteralPath (Join-Path $identityRoot 'stage.txt'))) { Get-Content -LiteralPath (Join-Path $identityRoot 'stage.txt') -Raw } else { 'unknown' }
            throw "Native preview exited before becoming ready ($($process.ExitCode)). Stage: $stage Evidence: $identityRoot"
        }
        if (-not $resultRoot) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $resultRoot) {
        $stage = if ($identityRoot -and (Test-Path -LiteralPath (Join-Path $identityRoot 'stage.txt'))) { Get-Content -LiteralPath (Join-Path $identityRoot 'stage.txt') -Raw } else { 'unknown' }
        throw "Native preview did not publish its own capture bounds. Stage: $stage Evidence: $identityRoot"
    }
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Test-Path -LiteralPath (Join-Path $resultRoot 'capture-complete.json'))) {
        $process.Refresh()
        if ($process.HasExited) { throw "Native preview exited during capture ($($process.ExitCode)). Evidence: $resultRoot" }
        if ((Get-Date) -gt $deadline) { throw "Native capture timed out. Evidence: $resultRoot" }
        $state = Get-Content -LiteralPath (Join-Path $resultRoot 'capture-state.json') -Raw | ConvertFrom-Json
        if ($state.processId -ne $process.Id) { throw 'Capture process identity changed.' }
        if ($seen.Contains($state.name)) { Start-Sleep -Milliseconds 100; continue }
        if ($state.name -notmatch '^[a-z-]+$' -or $state.width -lt 20 -or $state.height -lt 20 -or $state.width -gt 10000 -or $state.height -gt 10000) { throw 'Invalid native capture bounds.' }
        if ($state.showMode -eq 'normal' -and $state.foregroundAtCapture -ne $true) {
            throw "Target was not foreground at capture readiness: $($state.name). Leave this batch unverified and retry when the desktop is available. Evidence: $resultRoot"
        }
        $video = Join-Path $resultRoot ($state.name + '.mp4')
        $frame = Join-Path $resultRoot ($state.name + '.png')
        & $ffmpeg -hide_banner -loglevel error -f gdigrab -framerate 20 -offset_x $state.x -offset_y $state.y -video_size "$($state.width)x$($state.height)" -i desktop -t 2 -vf 'pad=ceil(iw/2)*2:ceil(ih/2)*2' -c:v libx264 -pix_fmt yuv420p -y $video
        if ($LASTEXITCODE -ne 0) { throw "Video capture failed: $($state.name)" }
        & $ffmpeg -hide_banner -loglevel error -ss 0.7 -i $video -frames:v 1 -y $frame
        if ($LASTEXITCODE -ne 0) { throw "Keyframe extraction failed: $($state.name)" }
        $frames.Add($state); $null = $seen.Add($state.name)
        [IO.File]::WriteAllText((Join-Path $resultRoot ($state.name + '.captured')), 'captured')
    }
    if (-not $process.WaitForExit(5000)) { throw "Native preview did not exit after capture. Evidence: $resultRoot" }
    if ($process.ExitCode -ne 0) { throw "Native preview failed during teardown ($($process.ExitCode)). Evidence: $resultRoot" }
    [ordered]@{
        kind = 'native-production-controls-with-controlled-data'
        inputValidation = 'not-run; native windows activated, states driven by test host'
        realDeviceRecording = $(if ($UpdateChannels) { 'not-run; settings-only capture' } else { 'not-run; recorder uses generated signal' })
        visualReview = 'pending'
        exitCode = $process.ExitCode
        executableHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
        managedAssemblyHash = (Get-FileHash -LiteralPath (Join-Path $binary 'Recappi.WinUI.Tests.dll') -Algorithm SHA256).Hash
        states = $frames
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $resultRoot 'native-preview-report.json') -Encoding utf8
    Write-Output $resultRoot
} finally {
    $process.Refresh()
    if (-not $process.HasExited) {
        if (-not $process.WaitForExit(1500)) {
            $owned = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
            if ($owned -and $owned.Path -eq $executable) { Stop-Process -Id $owned.Id }
        }
    }
}
