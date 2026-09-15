param([Parameter(Mandatory)][string]$PackageDirectory)
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $PackageDirectory).Path
$configurationPath = Join-Path $package 'Recappi Mini.runtimeconfig.json'
$configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
if ($configuration.runtimeOptions.includedFrameworks -or
    @($configuration.runtimeOptions.frameworks | Where-Object name -eq 'Microsoft.WindowsDesktop.App').Count -ne 1) {
    throw 'Select a framework-dependent Windows desktop candidate.'
}
$repository = Split-Path -Parent $PSScriptRoot
$root = Join-Path $repository ('build/native-desktop-validation/framework-dependency-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$copy = Join-Path $root 'unavailable-framework'
[void][IO.Directory]::CreateDirectory($copy)
Get-ChildItem -LiteralPath $package -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $copy -Recurse }
$originalHash = (Get-FileHash -LiteralPath $configurationPath).Hash
# Only the isolated copy asks for an unavailable Desktop framework. Leave the
# machine's installed runtimes and the distributable candidate unchanged.
$desktop = $configuration.runtimeOptions.frameworks | Where-Object name -eq 'Microsoft.WindowsDesktop.App'
$desktop.version = '99.0.0'
$configuration.runtimeOptions | Add-Member -NotePropertyName rollForward -NotePropertyValue LatestPatch -Force
$configuration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $copy 'Recappi Mini.runtimeconfig.json') -Encoding utf8
$readyPath = Join-Path $root 'unexpected-ready.json'
$child = New-Object Diagnostics.Process
$child.StartInfo.FileName = Join-Path $copy 'Recappi Mini.exe'
$child.StartInfo.WorkingDirectory = $copy
$child.StartInfo.UseShellExecute = $false
$child.StartInfo.CreateNoWindow = $true
$child.StartInfo.RedirectStandardError = $true
$child.StartInfo.EnvironmentVariables['DOTNET_DISABLE_GUI_ERRORS'] = '1'
$child.StartInfo.EnvironmentVariables['DOTNET_ROLL_FORWARD'] = 'LatestPatch'
$child.StartInfo.EnvironmentVariables['RECAPPI_DESKTOP_DATA_DIR'] = Join-Path $root 'Recordings'
$child.StartInfo.EnvironmentVariables['RECAPPI_DESKTOP_STARTUP_REPORT'] = $readyPath
$child.StartInfo.EnvironmentVariables['RECAPPI_DESKTOP_STARTUP_EXIT'] = '1'
try {
    if (-not $child.Start()) { throw 'Could not start dependency probe.' }
    $errorTask = $child.StandardError.ReadToEndAsync()
    if (-not $child.WaitForExit(10000)) { throw "Dependency probe remains running: PID $($child.Id). Inspect it before retrying." }
    $errorText = $errorTask.GetAwaiter().GetResult()
    if ($child.ExitCode -eq 0 -or $errorText -notmatch 'Microsoft.WindowsDesktop.App' -or $errorText -notmatch '99\.0\.0' -or
        (Test-Path -LiteralPath $readyPath)) { throw 'Missing framework did not produce the expected pre-start dependency failure.' }
    if ((Get-FileHash -LiteralPath $configurationPath).Hash -ne $originalHash) { throw 'Original candidate configuration changed.' }
    $report = [ordered]@{ package = $package; exitCode = $child.ExitCode; rejectedBeforeReady = $true;
        originalConfigurationUnchanged = $true; requiredMissingFramework = 'Microsoft.WindowsDesktop.App 99.0.0';
        limitation = 'Injected unavailable framework in an isolated copy; not a clean Windows installation or automatic prerequisite-install test.' }
    $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'results.json') -Encoding utf8
    Write-Output "PASS unavailable framework is rejected before app startup: $root"
} finally { $child.Dispose() }
