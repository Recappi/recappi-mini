param(
    [Parameter(Mandatory = $true)][ValidateSet('Prepare', 'Play')][string]$Mode,
    [Parameter(Mandatory = $true)][string]$OutputRoot,
    [ValidateSet(443, 997)][int]$Tone = 443,
    [ValidateRange(1, 300)][int]$Seconds = 180,
    [string]$AudioPath
)
$ErrorActionPreference = 'Stop'
$fixtureRoot = [IO.Path]::GetFullPath($OutputRoot)
if ($Mode -eq 'Prepare') {
    if (Test-Path -LiteralPath $fixtureRoot) { throw 'Use a new fixture directory.' }
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    foreach ($frequency in @(443, 997)) {
        $stream = [IO.File]::Create((Join-Path $fixtureRoot "tone-$frequency.wav"))
        $writer = [IO.BinaryWriter]::new($stream)
        try {
            $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
            $writer.Write([uint32](36 + 48000 * 2))
            $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
            $writer.Write([uint32]16)
            $writer.Write([uint16]1)
            $writer.Write([uint16]1)
            $writer.Write([uint32]48000)
            $writer.Write([uint32]96000)
            $writer.Write([uint16]2)
            $writer.Write([uint16]16)
            $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
            $writer.Write([uint32](48000 * 2))
            for ($sample = 0; $sample -lt 48000; $sample++) {
                $writer.Write([int16][Math]::Round([Math]::Sin(2 * [Math]::PI * $frequency * $sample / 48000) * 1800))
            }
        } finally { $writer.Dispose() }
    }
    Write-Output $fixtureRoot
    exit 0
}
$audioPath = if ($AudioPath) { (Resolve-Path -LiteralPath $AudioPath).Path } else { Join-Path $fixtureRoot "tone-$Tone.wav" }
$stopFile = Join-Path $fixtureRoot "stop-$Tone"
$player = New-Object System.Media.SoundPlayer($audioPath)
try {
    $player.Load()
    $player.PlayLooping()
    Write-Output "Fixture player ready: PID=$PID frequency=$Tone"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $Seconds -and -not (Test-Path -LiteralPath $stopFile)) { Start-Sleep -Milliseconds 200 }
} finally { $player.Stop(); $player.Dispose() }
