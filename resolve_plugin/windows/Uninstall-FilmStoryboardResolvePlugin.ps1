[CmdletBinding()]
param(
    [string]$PluginDestinationRoot,
    [switch]$SkipResolveProcessCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pluginId = 'com.filmstoryboard.timelinebridge'

if ([string]::IsNullOrWhiteSpace($PluginDestinationRoot)) {
    if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
        throw '未找到 PROGRAMDATA，且未显式指定插件目标目录。'
    }
    $PluginDestinationRoot = Join-Path $env:ProgramData 'Blackmagic Design\DaVinci Resolve\Support\Workflow Integration Plugins'
}

$root = [System.IO.Path]::GetFullPath($PluginDestinationRoot.TrimEnd('\', '/'))
$destination = [System.IO.Path]::GetFullPath((Join-Path $root $pluginId))
if (-not [string]::Equals($root, (Split-Path -Parent $destination), [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝操作目标目录之外的路径：$destination"
}

if (-not $SkipResolveProcessCheck -and
    (Get-Process -Name 'Resolve' -ErrorAction SilentlyContinue)) {
    throw 'DaVinci Resolve 正在运行。请关闭 Resolve 后重试插件卸载。'
}

if (-not (Test-Path -LiteralPath $destination)) {
    Write-Output "FilmStoryboard Resolve 插件未安装，无需卸载：$destination"
    return
}

$item = Get-Item -LiteralPath $destination -Force
if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "拒绝删除重解析点：$destination"
}

Remove-Item -LiteralPath $destination -Recurse -Force
Write-Output "FilmStoryboard Resolve 插件已卸载：$destination"
