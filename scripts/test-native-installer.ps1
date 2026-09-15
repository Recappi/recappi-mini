param(
    [Parameter(Mandatory = $true)][string]$PreviousReleaseReport,
    [Parameter(Mandatory = $true)][string]$NextReleaseReport
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$root = Join-Path $repository ('build/native-desktop-validation/installer-smoke-' + [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $root 'installed'
$dataRoot = Join-Path $root 'user-data'
$productId = '{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'
$productName = 'Recappi Mini Install Test ' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $productId + '_is1'
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) ($productName + '\' + $productName + '.lnk')
[IO.Directory]::CreateDirectory($root) | Out-Null
Write-Output "Installer validation workspace: $root"
[IO.Directory]::CreateDirectory($dataRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $dataRoot 'recording-sentinel.wav'), 'controlled recording sentinel')
[IO.File]::WriteAllText((Join-Path $dataRoot 'account-sentinel.bin'), 'controlled account sentinel')
try {
    $existing = [Threading.Mutex]::OpenExisting('Local\RecappiMini.Desktop.InstallGuard')
    $existing.Dispose()
    throw 'A Recappi Mini app is running. This test will not stop an existing app.'
} catch [Threading.WaitHandleCannotBeOpenedException] { }
if ((Test-Path -LiteralPath $registryPath) -or (Test-Path -LiteralPath $shortcut)) { throw 'Test identity already exists.' }
$results = [Collections.Generic.List[string]]::new()
function Compile-Installer([string]$Report) {
    $output = & (Join-Path $PSScriptRoot 'build-native-installer.ps1') -ReleaseReport $Report -ProductId $productId -ProductName $productName
    $reportLine = @($output | Where-Object { $_ -is [string] -and $_.StartsWith('Installer report: ') })
    if ($reportLine.Count -ne 1) { throw 'Installer build did not produce exactly one report.' }
    Get-Content -LiteralPath $reportLine[0].Substring('Installer report: '.Length) -Raw | ConvertFrom-Json
}
function Run-Package([string]$Package, [string]$Scenario, [bool]$Uninstall = $false) {
    if ($Uninstall -and -not ([IO.Path]::GetFullPath($Package)).StartsWith($installRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Uninstaller path escaped this test installation.' }
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/LOG="' + (Join-Path $root ($Scenario + '.log')) + '"'))
    if (-not $Uninstall) { $arguments += ('/DIR="' + $installRoot + '"') }
    $process = Start-Process -FilePath $Package -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Write-Output "Running $Scenario PID $($process.Id)"
    if (-not $process.WaitForExit(60000)) { throw "$Scenario is still running as PID $($process.Id); inspect it before retrying." }
    $script:packageExitCode = $process.ExitCode
}
function Shortcut-Target {
    if (-not (Test-Path -LiteralPath $shortcut)) { throw 'Start menu shortcut is missing.' }
    $shell = New-Object -ComObject WScript.Shell
    try { $shell.CreateShortcut($shortcut).TargetPath }
    finally { [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null }
}
function Assert-Sentinels {
    if ([IO.File]::ReadAllText((Join-Path $dataRoot 'recording-sentinel.wav')) -ne 'controlled recording sentinel' -or
        [IO.File]::ReadAllText((Join-Path $dataRoot 'account-sentinel.bin')) -ne 'controlled account sentinel' -or
        [IO.File]::ReadAllText((Join-Path $installRoot 'user-added.txt')) -ne 'keep user file') { throw 'Installation touched user data.' }
}
$old = Compile-Installer $PreviousReleaseReport
$next = Compile-Installer $NextReleaseReport
$appProcess = $null
$priorDataOverride = $env:RECAPPI_DESKTOP_DATA_DIR
try {
    Run-Package $old.path 'install'
    if ($script:packageExitCode -ne 0) { throw 'Initial install failed.' }
    [IO.File]::WriteAllText((Join-Path $installRoot 'user-added.txt'), 'keep user file')
    $oldTarget = Shortcut-Target
    $expectedOld = Join-Path $installRoot ('versions\' + $old.versionFolder + '\Recappi Mini.exe')
    if ($oldTarget -ne $expectedOld -or -not (Test-Path -LiteralPath $registryPath)) { throw 'Installer registration or shortcut is incorrect.' }
    $oldHash = (Get-FileHash -LiteralPath $oldTarget -Algorithm SHA256).Hash
    $results.Add('Per-user install and Start menu registration')
    $env:RECAPPI_DESKTOP_DATA_DIR = Join-Path $dataRoot 'Recordings'
    $appProcess = Start-Process -FilePath $oldTarget -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 3
    $appProcess.Refresh()
    if ($appProcess.HasExited -or $appProcess.MainWindowHandle -eq 0) { throw 'Installed native app did not open a window.' }
    Run-Package $next.path 'running-app-guard'
    if ($script:packageExitCode -eq 0 -or (Shortcut-Target) -ne $oldTarget) { throw 'Installer did not reject an active app.' }
    $appProcess.Refresh()
    if ($appProcess.HasExited) { throw 'Installer stopped the running app.' }
    $results.Add('Installed application launches; active application blocks upgrade without termination')
    if ($appProcess.Path -ne $oldTarget) { throw 'Unexpected owned application path.' }
    Stop-Process -Id $appProcess.Id
    $appProcess.WaitForExit(5000) | Out-Null
    $appProcess = $null
    $blocker = Join-Path $installRoot ('versions\' + $next.versionFolder + '\coreclr.dll')
    [IO.Directory]::CreateDirectory($blocker) | Out-Null
    Run-Package $next.path 'interrupted-upgrade'
    if ($script:packageExitCode -eq 0 -or (Shortcut-Target) -ne $oldTarget -or (Get-FileHash -LiteralPath $oldTarget -Algorithm SHA256).Hash -ne $oldHash) { throw 'Failed upgrade did not preserve the previous application.' }
    if (-not ([IO.Path]::GetFullPath($blocker)).StartsWith($installRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Test blocker path escaped installation.' }
    [IO.Directory]::Delete($blocker, $false)
    Assert-Sentinels
    $results.Add('Native file-write failure preserves previous executable, shortcut and user data')
    Run-Package $next.path 'upgrade'
    $newTarget = Join-Path $installRoot ('versions\' + $next.versionFolder + '\Recappi Mini.exe')
    if ($script:packageExitCode -ne 0 -or (Shortcut-Target) -ne $newTarget -or -not (Test-Path -LiteralPath $newTarget)) { throw 'Successful upgrade did not switch the shortcut.' }
    Assert-Sentinels
    $results.Add('Upgrade switches Start menu only after successful file installation')
    Run-Package $old.path 'downgrade'
    if ($script:packageExitCode -eq 0 -or (Shortcut-Target) -ne $newTarget) { throw 'Downgrade was not rejected.' }
    $results.Add('Downgrade rejected')
    $uninstall = Join-Path $installRoot 'unins000.exe'
    Run-Package $uninstall 'uninstall' $true
    if ($script:packageExitCode -ne 0 -or (Test-Path -LiteralPath $registryPath) -or (Test-Path -LiteralPath $shortcut) -or (Test-Path -LiteralPath $oldTarget) -or (Test-Path -LiteralPath $newTarget)) { throw 'Uninstall left registered application components.' }
    Assert-Sentinels
    $results.Add('Uninstall removes both installed versions and registration while retaining user-created files and external data')
    [ordered]@{ completedAt = [DateTimeOffset]::UtcNow.ToString('O'); passed = $results; productId = $productId; productName = $productName; previous = $old; next = $next } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'results.json') -Encoding utf8
    Write-Output "Installer validation: $root"
} finally {
    $env:RECAPPI_DESKTOP_DATA_DIR = $priorDataOverride
    if ($appProcess -and -not $appProcess.HasExited -and $appProcess.Path.StartsWith($installRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $appProcess.Id }
}
