param([Parameter(Mandatory = $true)][string]$AudioPath)
$ErrorActionPreference = 'Stop'
$player = New-Object System.Media.SoundPlayer($AudioPath)
try {
    $player.Load()
    $player.PlayLooping()
    [Console]::WriteLine('ready')
    [Console]::ReadLine() | Out-Null
} finally {
    $player.Stop()
    $player.Dispose()
}
