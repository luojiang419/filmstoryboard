param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [string]$Root = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'

if ($Version -notmatch '^(\d+)\.(\d+)\.(\d+)\.(\d+)$') {
    throw "Invalid four-part version: $Version"
}

$flutterVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3])+$($Matches[4])"
$appPath = Join-Path $Root 'build\windows\x64\runner\Release\filmstoryboard.exe'
$bundledFfmpegPath = Join-Path $Root 'build\windows\x64\runner\Release\ffmpeg\bin\ffmpeg.exe'
$bundledFfprobePath = Join-Path $Root 'build\windows\x64\runner\Release\ffmpeg\bin\ffprobe.exe'
$bundledDwPoseDetectorPath = Join-Path $Root 'build\windows\x64\runner\Release\data\dwpose\models\yolox_l.onnx'
$bundledDwPosePosePath = Join-Path $Root 'build\windows\x64\runner\Release\data\dwpose\models\dw-ll_ucoco_384.onnx'
$assetName = "filmstoryboard-Setup-$Version.exe"
$assetPath = Join-Path $Root "dist\installer\$assetName"

foreach ($requiredPath in @(
    $appPath,
    $bundledFfmpegPath,
    $bundledFfprobePath,
    $bundledDwPoseDetectorPath,
    $bundledDwPosePosePath,
    $assetPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Missing release artifact: $requiredPath"
    }
}

$dwPoseModels = @(
    @{
        Path = $bundledDwPoseDetectorPath
        Length = 216746733
        Sha256 = '7860ae79de6c89a3c1eb72ae9a2756c0ccfbe04b7791bb5880afabd97855a411'
    },
    @{
        Path = $bundledDwPosePosePath
        Length = 134399116
        Sha256 = '724f4ff2439ed61afb86fb8a1951ec39c6220682803b4a8bd4f598cd913b1843'
    }
)
foreach ($model in $dwPoseModels) {
    $file = Get-Item -LiteralPath $model.Path
    if ($file.Length -ne $model.Length) {
        throw "Bundled DWPose model size mismatch: $($model.Path)"
    }
    $modelSha256 = (Get-FileHash -LiteralPath $model.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($modelSha256 -ne $model.Sha256) {
        throw "Bundled DWPose model SHA-256 mismatch: $($model.Path)"
    }
}

foreach ($toolPath in @($bundledFfmpegPath, $bundledFfprobePath)) {
    $tool = Get-Item -LiteralPath $toolPath
    if ($tool.Length -lt 1MB) {
        throw "Bundled FFmpeg tool is unexpectedly small: $toolPath"
    }
}

$appVersion = (Get-Item -LiteralPath $appPath).VersionInfo.ProductVersion.Trim()
if ($appVersion -ne $flutterVersion) {
    throw "Application version mismatch: expected $flutterVersion, got $appVersion"
}

$asset = Get-Item -LiteralPath $assetPath
$installerVersion = $asset.VersionInfo.ProductVersion.Trim()
if ($installerVersion -ne $Version) {
    throw "Installer version mismatch: expected $Version, got $installerVersion"
}
if ($asset.Length -lt 5MB) {
    throw "Installer is unexpectedly small: $($asset.Length) bytes"
}

$signatureStatus = (Get-AuthenticodeSignature -LiteralPath $assetPath).Status.ToString()
if ($signatureStatus -notin @('Valid', 'NotSigned')) {
    throw "Installer signature validation failed: $signatureStatus"
}

$sha256 = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumPath = "$assetPath.sha256"
$checksumText = "$sha256  $assetName`n"
[System.IO.File]::WriteAllText($checksumPath, $checksumText, [System.Text.UTF8Encoding]::new($false))

$values = [ordered]@{
    asset_name = $assetName
    asset_path = (Resolve-Path -LiteralPath $assetPath).Path
    checksum_path = (Resolve-Path -LiteralPath $checksumPath).Path
    sha256 = $sha256
    size = $asset.Length
    signature_status = $signatureStatus
}

if ($env:GITHUB_OUTPUT) {
    foreach ($entry in $values.GetEnumerator()) {
        "$($entry.Key)=$($entry.Value)" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8
    }
}

$values | ConvertTo-Json -Compress
