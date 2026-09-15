$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repository = Split-Path -Parent $PSScriptRoot
$source = [Drawing.Bitmap]::new((Join-Path $repository 'RecappiMini/Resources/Logo.png'))
$destination = Join-Path $repository 'native/desktop/Recappi.Desktop/Assets'
[void][IO.Directory]::CreateDirectory($destination)

# Package the existing Recappi mark into standard Windows ICO sizes. The neutral
# tile keeps its black silhouette readable on both light and dark system chrome.
function Write-ApplicationIcon([string]$Name, [bool]$Recording) {
    $sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
    $frames = [Collections.Generic.List[byte[]]]::new()
    foreach ($size in $sizes) {
        $bitmap = [Drawing.Bitmap]::new($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $path = [Drawing.Drawing2D.GraphicsPath]::new()
        $buffer = [IO.MemoryStream]::new()
        try {
            $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $inset = [single]($size / 32)
            $edge = [single]($size - 2 * $inset)
            $arc = [single]($size * 0.4)
            $path.AddArc($inset, $inset, $arc, $arc, 180, 90)
            $path.AddArc($inset + $edge - $arc, $inset, $arc, $arc, 270, 90)
            $path.AddArc($inset + $edge - $arc, $inset + $edge - $arc, $arc, $arc, 0, 90)
            $path.AddArc($inset, $inset + $edge - $arc, $arc, $arc, 90, 90)
            $path.CloseFigure()
            $graphics.FillPath([Drawing.Brushes]::White, $path)
            $logoInset = [single]($size * 0.13)
            $graphics.DrawImage($source, $logoInset, $logoInset, [single]($size - 2 * $logoInset), [single]($size - 2 * $logoInset))
            if ($Recording) {
                $graphics.FillEllipse([Drawing.Brushes]::White, [single]($size * 0.58), [single]($size * 0.58), [single]($size * 0.42), [single]($size * 0.42))
                $graphics.FillEllipse([Drawing.Brushes]::Crimson, [single]($size * 0.64), [single]($size * 0.64), [single]($size * 0.30), [single]($size * 0.30))
            }
            $bitmap.Save($buffer, [Drawing.Imaging.ImageFormat]::Png)
            if ($size -eq 256 -and -not $Recording) {
                $bitmap.Save((Join-Path $destination 'Recappi.png'), [Drawing.Imaging.ImageFormat]::Png)
            }
            $frames.Add($buffer.ToArray())
        } finally { $buffer.Dispose(); $path.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
    }
    $file = [IO.File]::Create((Join-Path $destination $Name))
    $writer = [IO.BinaryWriter]::new($file)
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($index = 0; $index -lt $sizes.Count; $index++) {
            $dimension = if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }
            $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
            $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([uint16]1); $writer.Write([uint16]32)
            $writer.Write([uint32]$frames[$index].Length); $writer.Write([uint32]$offset)
            $offset += $frames[$index].Length
        }
        foreach ($frame in $frames) { $writer.Write($frame) }
    } finally { $writer.Dispose(); $file.Dispose() }
}
try {
    Write-ApplicationIcon 'Recappi.ico' $false
    Write-ApplicationIcon 'Recappi.Recording.ico' $true
} finally { $source.Dispose() }
