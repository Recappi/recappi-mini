param([Parameter(Mandatory = $true)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
$fixturePath = [System.IO.Path]::GetFullPath($OutputPath)
[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($fixturePath)) | Out-Null
$voice = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
    $voice.SetOutputToWaveFile($fixturePath)
    $voice.Speak('This is a Recappi native Windows caption test. The team will review the design tomorrow. Please send the meeting notes after the review.')
}
finally { $voice.Dispose() }
Write-Output $fixturePath
