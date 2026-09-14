param([ValidateSet('x64', 'arm64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repoRoot 'native/windows/RecappiAudioCapture.csproj'
$destination = Join-Path $repoRoot "cli/helpers/win32-$Architecture"
dotnet publish $project -c Release -r "win-$Architecture" -o $destination
if ($LASTEXITCODE -ne 0) { throw 'Windows helper build failed.' }

# Include the notices from the exact .NET runtime restored for this build.
$assets = Get-Content -Raw (Join-Path $repoRoot 'native/windows/obj/project.assets.json') | ConvertFrom-Json
$runtimeName = "Microsoft.NETCore.App.Runtime.win-$Architecture"
$runtime = $assets.project.frameworks.PSObject.Properties.Value.downloadDependencies | Where-Object name -eq $runtimeName | Select-Object -First 1
if (!$runtime) { throw 'Could not resolve bundled .NET runtime notices.' }
$runtimeVersion = ($runtime.version.Trim('[', ']') -split ',')[0].Trim()
$runtimeDirectory = $null
foreach ($folder in $assets.packageFolders.PSObject.Properties.Name) {
    $candidate = Join-Path $folder "$($runtimeName.ToLowerInvariant())/$runtimeVersion"
    if (Test-Path (Join-Path $candidate 'LICENSE.TXT')) { $runtimeDirectory = $candidate; break }
}
if (!$runtimeDirectory) { throw 'Bundled .NET runtime license was not found.' }
$licenses = Join-Path $destination 'licenses'
New-Item -ItemType Directory -Force -Path $licenses | Out-Null
Copy-Item -LiteralPath (Join-Path $runtimeDirectory 'LICENSE.TXT') -Destination (Join-Path $licenses 'DOTNET-LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $runtimeDirectory 'THIRD-PARTY-NOTICES.TXT') -Destination (Join-Path $licenses 'DOTNET-NOTICES.txt')
Copy-Item -LiteralPath (Join-Path $repoRoot 'native/windows/NAudio-NOTICES.txt') -Destination $licenses
