param(
    [string]$Destination = (Join-Path (Get-Location).Path 'build\windows\x64\bundled_ffmpeg'),
    [string]$DownloadUrl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
    [string]$Root = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

$binDir = Join-Path $Destination 'bin'
$ffmpeg = Join-Path $binDir 'ffmpeg.exe'
$ffprobe = Join-Path $binDir 'ffprobe.exe'

if ((Test-Path -LiteralPath $ffmpeg -PathType Leaf) -and
    (Test-Path -LiteralPath $ffprobe -PathType Leaf)) {
    Write-Host "Bundled FFmpeg already exists: $binDir"
    exit 0
}

New-Item -ItemType Directory -Path $binDir -Force | Out-Null

$candidateBins = @(
    (Join-Path $Root 'third_party\ffmpeg\windows\bin')
)
if ($env:LOCALAPPDATA) {
    $candidateBins += Join-Path $env:LOCALAPPDATA 'FilmStoryboard\tools\ffmpeg\bin'
}
$candidateBins = $candidateBins |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }

foreach ($candidateBin in $candidateBins) {
    $candidateFfmpeg = Join-Path $candidateBin 'ffmpeg.exe'
    $candidateFfprobe = Join-Path $candidateBin 'ffprobe.exe'
    if ((Test-Path -LiteralPath $candidateFfmpeg -PathType Leaf) -and
        (Test-Path -LiteralPath $candidateFfprobe -PathType Leaf)) {
        Copy-Item -LiteralPath $candidateFfmpeg -Destination $ffmpeg -Force
        Copy-Item -LiteralPath $candidateFfprobe -Destination $ffprobe -Force
        Write-Host "Bundled FFmpeg copied from $candidateBin"
        exit 0
    }
}

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('filmstoryboard-ffmpeg-' + [guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $workDir 'ffmpeg-release-essentials.zip'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

function Invoke-Download {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [string]$OutFile,
        [string]$Proxy
    )

    $parameters = @{
        Uri = $Uri
        OutFile = $OutFile
        UseBasicParsing = $true
    }
    if ($Proxy) {
        $parameters.Proxy = "http://$Proxy"
    }
    Invoke-WebRequest @parameters
}

try {
    try {
        Invoke-Download -Uri $DownloadUrl -OutFile $zipPath
    } catch {
        Write-Warning "Direct FFmpeg download failed: $($_.Exception.Message)"
        Invoke-Download -Uri $DownloadUrl -OutFile $zipPath -Proxy '127.0.0.1:7890'
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $targets = @{
            'ffmpeg.exe' = $ffmpeg
            'ffprobe.exe' = $ffprobe
        }
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('\', '/').ToLowerInvariant()
            $fileName = [System.IO.Path]::GetFileName($entryName)
            if (-not $targets.ContainsKey($fileName)) {
                continue
            }
            if (-not $entryName.Contains('/bin/')) {
                continue
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile(
                $entry,
                $targets[$fileName],
                $true
            )
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
        [System.IO.File]::Delete($zipPath)
    }
    if (Test-Path -LiteralPath $workDir -PathType Container) {
        [System.IO.Directory]::Delete($workDir, $true)
    }
}

if (-not (Test-Path -LiteralPath $ffmpeg -PathType Leaf)) {
    throw "ffmpeg.exe was not prepared at $ffmpeg"
}
if (-not (Test-Path -LiteralPath $ffprobe -PathType Leaf)) {
    throw "ffprobe.exe was not prepared at $ffprobe"
}

Write-Host "Bundled FFmpeg prepared: $binDir"
