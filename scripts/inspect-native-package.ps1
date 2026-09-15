param(
    [Parameter(Mandatory)][string]$PackageDirectory,
    [Parameter(Mandatory)][string]$ReportPath
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $PackageDirectory).Path.TrimEnd('\', '/')
$required = @('Recappi Mini.exe', 'Recappi Mini.dll', 'Recappi.Core.dll',
    'Recappi Mini.deps.json', 'Recappi Mini.runtimeconfig.json', 'coreclr.dll',
    'hostfxr.dll', 'PresentationFramework.dll', 'PresentationFramework.Fluent.dll', 'NAudio.Wasapi.dll')
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)) { throw "Required payload missing: $name" }
}
$runtime = Get-Content -LiteralPath (Join-Path $root 'Recappi Mini.runtimeconfig.json') -Raw | ConvertFrom-Json
if (-not $runtime.runtimeOptions.includedFrameworks) { throw 'Expected a self-contained native package.' }
$dependencies = Get-Content -LiteralPath (Join-Path $root 'Recappi Mini.deps.json') -Raw | ConvertFrom-Json
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
    $group = if ($_.Extension -eq '.pdb') { 'symbols' }
        elseif ($_.Name -like '*.resources.dll') { 'satellite-resources' }
        elseif ($_.Name -match '^(Recappi|NAudio)') { 'application-and-audio' }
        else { 'runtime-and-other' }
    [pscustomobject][ordered]@{ path = $relative; bytes = $_.Length; group = $group;
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
})
$forbidden = @($files | Where-Object { $_.path -match '(?i)(^|/)(node\.(exe|dll)|.*WebView.*|.*DirectML.*|.*onnx.*|Microsoft\.WindowsApp.*|RecappiAudioCapture\.exe)$' })
if ($forbidden.Count) { throw ('Unexpected runtime payload: ' + ($forbidden.path -join ', ')) }
$groups = @($files | Group-Object { $_.group } | ForEach-Object {
    [ordered]@{ name = $_.Name; files = $_.Count; bytes = ($_.Group | Measure-Object bytes -Sum).Sum }
})
$duplicates = @($files | Group-Object { $_.sha256 } | Where-Object Count -gt 1 | ForEach-Object {
    [ordered]@{ sha256 = $_.Name; paths = @($_.Group.path); bytesPerCopy = $_.Group[0].bytes }
})
$libraries = @($dependencies.libraries.PSObject.Properties | ForEach-Object {
    [ordered]@{ nameAndVersion = $_.Name; type = $_.Value.type; sha512 = $_.Value.sha512 }
})
$report = [ordered]@{ createdAt = [DateTimeOffset]::UtcNow.ToString('O'); packageDirectory = $root;
    scope = 'Published file logical lengths, hashes and deps.json library inventory; not installed allocated space, Store download, or proof of removable dependencies';
    includedFrameworks = $runtime.runtimeOptions.includedFrameworks;
    fileCount = $files.Count; totalBytes = ($files | Measure-Object bytes -Sum).Sum;
    groups = $groups; duplicateContent = $duplicates; libraries = $libraries; files = $files }
$destination = [IO.Path]::GetFullPath($ReportPath)
if ($destination.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Write the inventory outside the package so inspecting never changes the payload.'
}
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $destination -Encoding utf8
[ordered]@{ report = $destination; fileCount = $files.Count; totalBytes = $report.totalBytes; groups = $groups; duplicateGroups = $duplicates.Count } | ConvertTo-Json -Depth 4
