[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$projectDir = Split-Path -Parent $PSScriptRoot
$cacheDir = Join-Path $projectDir '.build/downloads'
$toolDir = Join-Path $projectDir 'tools'
$noticeDir = Join-Path $toolDir 'licenses'
New-Item -ItemType Directory -Force -Path $cacheDir,$toolDir,$noticeDir | Out-Null

function Get-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '') }
        finally { $hash.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-VerifiedAsset($name, $url, $sha256) {
    $asset = Join-Path $cacheDir $name
    if (!(Test-Path -LiteralPath $asset) -or (Get-Sha256 $asset) -ne $sha256) {
        Write-Host "Descargando $name"
        $curl = Join-Path ([Environment]::SystemDirectory) 'curl.exe'
        & $curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 2 --max-time 240 --output "$asset.download" $url
        if ($LASTEXITCODE -ne 0) { throw "No se pudo descargar $name." }
        if ((Get-Sha256 "$asset.download") -ne $sha256) {
            throw "SHA-256 incorrecto para $name. El archivo no se usará."
        }
        Move-Item -LiteralPath "$asset.download" -Destination $asset -Force
    }
    return $asset
}

function Copy-ZipEntry($zip, $entryName, $target) {
    $entries = @($zip.Entries | Where-Object { $_.FullName -cmatch $entryName })
    if ($entries.Count -ne 1) { throw "Falta la entrada $entryName en $($zip.ToString())." }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0], $target, $true)
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$ytPath = Join-Path $toolDir 'yt-dlp.exe'
$denoPath = Join-Path $toolDir 'deno.exe'
$ffmpegPath = Join-Path $toolDir 'ffmpeg.exe'
$ffprobePath = Join-Path $toolDir 'ffprobe.exe'
if (!(Test-Path -LiteralPath $ytPath -PathType Leaf)) {
    $yt = Get-VerifiedAsset 'yt-dlp-2026.10.26.exe' `
        'https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp.exe' `
        'f5389d3698ecde4ef06f4e6b1ce0294fe9ac1396228c8990b8d3416d6d177a7d'
    Copy-Item -LiteralPath $yt -Destination "$ytPath.download"
    Move-Item -LiteralPath "$ytPath.download" -Destination $ytPath
}
if (!(Test-Path -LiteralPath $denoPath -PathType Leaf)) {
    $deno = Get-VerifiedAsset 'deno-2.9.8.zip' `
        'https://github.com/denoland/deno/releases/download/v2.9.8/deno-x86_64-pc-windows-msvc.zip' `
        'cba84b26e0df5ae7f74fc66b86a95b866872a86292ebd84fa1e959927edd93bf'
    $zip = [IO.Compression.ZipFile]::OpenRead($deno)
    try {
        Copy-ZipEntry $zip '^deno\.exe$' "$denoPath.download"
        Move-Item -LiteralPath "$denoPath.download" -Destination $denoPath
    } finally { $zip.Dispose() }
}
if (!(Test-Path -LiteralPath $ffmpegPath -PathType Leaf) -or !(Test-Path -LiteralPath $ffprobePath -PathType Leaf)) {
    $ffmpeg = Get-VerifiedAsset 'ffmpeg-9.0.2-essentials.zip' `
        'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip' `
        '60f467265b1e312373dbcd92200c2618a74850f98d3d078e94296bb3fa2047ba'
    $zip = [IO.Compression.ZipFile]::OpenRead($ffmpeg)
    try {
        Copy-ZipEntry $zip '/bin/ffmpeg\.exe$' "$ffmpegPath.download"
        Copy-ZipEntry $zip '/bin/ffprobe\.exe$' "$ffprobePath.download"
        Copy-ZipEntry $zip '/LICENSE$' (Join-Path $noticeDir 'FFmpeg-LICENSE.txt')
        Copy-ZipEntry $zip '/README\.txt$' (Join-Path $noticeDir 'FFmpeg-README.txt')
        Move-Item -LiteralPath "$ffmpegPath.download" -Destination $ffmpegPath -Force
        Move-Item -LiteralPath "$ffprobePath.download" -Destination $ffprobePath -Force
    } finally { $zip.Dispose() }
}

@'
yt-dlp 2026.10.26
https://github.com/yt-dlp/yt-dlp/tree/2026.10.26
https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26

Deno 2.9.8 (MIT)
https://github.com/denoland/deno/blob/v2.9.8/LICENSE.md
https://github.com/denoland/deno/releases/tag/v2.9.8

FFmpeg / ffprobe 9.0.2 essentials (GPLv3)
https://www.gyan.dev/ffmpeg/builds/
https://github.com/FFmpeg/FFmpeg/commit/946fcce07b
'@ | Set-Content -LiteralPath (Join-Path $noticeDir 'Fuentes.txt') -Encoding utf8
Write-Host "Herramientas listas en $toolDir"
