param([Parameter(Mandatory)][string]$InstallerReport)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent $PSScriptRoot
$reportPath = (Resolve-Path -LiteralPath $InstallerReport).Path
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
if (-not $report.frameworkDependentCandidate -or $report.runtime -ne 'win-x64') { throw 'Select an x64 online installer candidate report.' }
$builtRoot = Split-Path -Parent $reportPath
$root = Join-Path $repository ('build/native-desktop-validation/online-installer-guard-' + [guid]::NewGuid().ToString('N'))
$probe = Join-Path $root 'probe'
[void][IO.Directory]::CreateDirectory($probe)
Get-ChildItem -LiteralPath (Join-Path $builtRoot 'runtime-probe') -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $probe }
$configPath = Join-Path $probe 'Recappi.RuntimeProbe.runtimeconfig.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
($config.runtimeOptions.frameworks | Where-Object name -eq 'Microsoft.WindowsDesktop.App').version = '99.0.0'
$config.runtimeOptions | Add-Member -NotePropertyName rollForward -NotePropertyValue LatestPatch -Force
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding utf8
$productId = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
$productName = 'Recappi Runtime Guard ' + [guid]::NewGuid().ToString('N').Substring(0,8)
$registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $productId + '_is1'
$installRoot = Join-Path $root 'installed'
$compiler = Join-Path $repository 'build/native-installer-tools/inno-7.1.0/ISCC.exe'
$definitions = @('/Qp', "/DSourceRoot=$(Join-Path $builtRoot 'payload')", '/DReleaseVersion=1.0.0', '/DVersionFolder=guard-test',
    '/DInstallerVersion=1.0.0.0', '/DAllowedArchitecture=x64os', '/DRuntime=win-x64', "/DOutputRoot=$root",
    "/DProductId=$productId", "/DProductName=$productName", '/DFrameworkDependentCandidate', "/DProbeRoot=$probe",
    "/DRuntimeDownloadUrl=$($report.runtimePrerequisite.url)", "/DRuntimeDownloadSha256=$($report.runtimePrerequisite.sha256)", '/DInstallerSuffix=-MissingRuntimeTest')
& $compiler @definitions (Join-Path $repository 'native/desktop/installer/RecappiMini.iss')
if ($LASTEXITCODE -ne 0) { throw 'Guard fixture compilation failed.' }
$package = Join-Path $root 'Recappi-Mini-1.0.0-win-x64-MissingRuntimeTest-Setup.exe'
$log = Join-Path $root 'install.log'
$child = Start-Process -FilePath $package -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',('/DIR="' + $installRoot + '"'),('/LOG="' + $log + '"')) -PassThru -WindowStyle Hidden
if (-not $child.WaitForExit(30000)) { throw "Guard installer remains running: PID $($child.Id)." }
$logText = Get-Content -LiteralPath $log -Raw
if ($child.ExitCode -eq 0 -or (Test-Path -LiteralPath $registryPath) -or (Test-Path -LiteralPath (Join-Path $installRoot 'versions/guard-test/Recappi Mini.exe')) -or
    $logText -notmatch 'Runtime probe result: -?\d+' -or $logText -match 'Runtime probe result: 0') { throw 'Missing-runtime guard did not prevent installation.' }
[ordered]@{ installerExitCode=$child.ExitCode; applicationNotInstalled=$true; registryNotCreated=$true;
    limitation='Isolated probe runtimeconfig requires unavailable WindowsDesktop 99.0.0. Silent path must not download or install prerequisites. Real clean-system interactive installation remains unverified.' } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'results.json') -Encoding utf8
Write-Output "PASS missing runtime stops silent installation before application writes: $root"
