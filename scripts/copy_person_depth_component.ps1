param(
    [string]$SourceProject = 'E:\APP\SHIYIN-AI',
    [string]$Root = (Split-Path $PSScriptRoot -Parent)
)
$ErrorActionPreference = 'Stop'
$sourceBase = Join-Path $SourceProject 'data/system/components/person-depth'
$active = Get-Content -LiteralPath (Join-Path $sourceBase 'current.json') -Raw | ConvertFrom-Json
$source = [IO.Path]::GetFullPath((Join-Path $sourceBase "installations/$($active.installation)"))
if (-not $source.StartsWith(([IO.Path]::GetFullPath($sourceBase) + [IO.Path]::DirectorySeparatorChar))) { throw 'Invalid component path' }
$destination = Join-Path $Root 'local_components/person-depth'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$files = @(Get-ChildItem -LiteralPath $source -File -Recurse)
$manifest = @()
foreach ($file in $files) {
    $relative = $file.FullName.Substring($source.TrimEnd('\').Length + 1)
    $target = Join-Path $destination $relative
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    $expected = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) { throw "Component copy mismatch: $relative" }
    $manifest += @{path=$relative.Replace('\','/'); size=$file.Length; sha256=$actual}
}
@{component='person-depth'; version=$active.version; files=$manifest} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $destination 'copy-manifest.json') -Encoding utf8
Write-Output "Copied and SHA-256 verified $($files.Count) files to $destination"
