[CmdletBinding()]
param(
    [string]$PluginSource,
    [string]$PluginDestinationRoot,
    [string]$SdkExamplesRoot,
    [string]$ErrorLogPath,
    [switch]$ElevateIfNeeded,
    [switch]$SkipResolveProcessCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pluginId = 'com.filmstoryboard.timelinebridge'

trap {
    $errorText = ($_ | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($ErrorLogPath)) {
        try {
            $errorLogParent = Split-Path -Parent $ErrorLogPath
            if (-not [string]::IsNullOrWhiteSpace($errorLogParent)) {
                New-Item -ItemType Directory -Path $errorLogParent -Force | Out-Null
            }
            [System.IO.File]::WriteAllText(
                $ErrorLogPath,
                $errorText,
                [System.Text.UTF8Encoding]::new($true)
            )
        } catch {
            # 错误日志写入失败不应遮蔽原始部署异常。
        }
    }
    [Console]::Error.WriteLine($errorText)
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($ErrorLogPath) -and
    (Test-Path -LiteralPath $ErrorLogPath -PathType Leaf)) {
    [System.IO.File]::Delete($ErrorLogPath)
}

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-QuotedArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ($Value.Contains('"')) {
        throw "命令参数不能包含双引号：$Value"
    }
    return '"' + $Value + '"'
}

if ($ElevateIfNeeded -and -not (Test-IsAdministrator)) {
    $elevatedArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (ConvertTo-QuotedArgument -Value $PSCommandPath)
    )
    if (-not [string]::IsNullOrWhiteSpace($PluginSource)) {
        $elevatedArguments += '-PluginSource'
        $elevatedArguments += ConvertTo-QuotedArgument -Value $PluginSource
    }
    if (-not [string]::IsNullOrWhiteSpace($PluginDestinationRoot)) {
        $elevatedArguments += '-PluginDestinationRoot'
        $elevatedArguments += ConvertTo-QuotedArgument -Value $PluginDestinationRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($SdkExamplesRoot)) {
        $elevatedArguments += '-SdkExamplesRoot'
        $elevatedArguments += ConvertTo-QuotedArgument -Value $SdkExamplesRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorLogPath)) {
        $elevatedArguments += '-ErrorLogPath'
        $elevatedArguments += ConvertTo-QuotedArgument -Value $ErrorLogPath
    }
    if ($SkipResolveProcessCheck) {
        $elevatedArguments += '-SkipResolveProcessCheck'
    }

    try {
        $elevated = Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList $elevatedArguments `
            -Verb RunAs `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
    } catch {
        throw "无法取得管理员权限，插件安装已取消：$($_.Exception.Message)"
    }
    exit $elevated.ExitCode
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath($Path.TrimEnd('\', '/'))
}

function Assert-DirectChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $rootPath = Get-FullPath -Path $Root
    $childPath = Get-FullPath -Path $Child
    $childParent = Split-Path -Parent $childPath
    if (-not [string]::Equals($rootPath, $childParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝操作目标目录之外的路径：$childPath"
    }
}

function Assert-NotReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "拒绝操作重解析点：$Path"
    }
}

function Remove-DeploymentDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    Assert-DirectChildPath -Root $Root -Child $Path
    Assert-NotReparsePoint -Path $Path
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

if ([string]::IsNullOrWhiteSpace($env:ProgramData) -and
    [string]::IsNullOrWhiteSpace($PluginDestinationRoot)) {
    throw '未找到 PROGRAMDATA，且未显式指定插件目标目录。'
}

if ([string]::IsNullOrWhiteSpace($PluginSource)) {
    $PluginSource = Join-Path $PSScriptRoot '..\com.filmstoryboard.timelinebridge'
}
if ([string]::IsNullOrWhiteSpace($PluginDestinationRoot)) {
    $PluginDestinationRoot = Join-Path $env:ProgramData 'Blackmagic Design\DaVinci Resolve\Support\Workflow Integration Plugins'
}
if ([string]::IsNullOrWhiteSpace($SdkExamplesRoot) -and
    -not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
    $SdkExamplesRoot = Join-Path $env:ProgramData 'Blackmagic Design\DaVinci Resolve\Support\Developer\Workflow Integrations\Examples'
}

$PluginSource = Get-FullPath -Path $PluginSource
$PluginDestinationRoot = Get-FullPath -Path $PluginDestinationRoot
$destination = Join-Path $PluginDestinationRoot $pluginId
$nativeModule = $null
if (-not [string]::IsNullOrWhiteSpace($SdkExamplesRoot)) {
    $SdkExamplesRoot = Get-FullPath -Path $SdkExamplesRoot
    $nativeModule = Join-Path $SdkExamplesRoot 'SamplePromisePlugin\WorkflowIntegration.node'
}

if (-not (Test-Path -LiteralPath $PluginSource -PathType Container)) {
    throw "插件源目录不存在：$PluginSource"
}
foreach ($requiredFile in @('manifest.xml', 'package.json', 'main.js')) {
    $requiredPath = Join-Path $PluginSource $requiredFile
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "插件源目录缺少 $requiredFile：$PluginSource"
    }
}

$manifestPath = Join-Path $PluginSource 'manifest.xml'
$manifestText = [System.IO.File]::ReadAllText(
    $manifestPath,
    [System.Text.Encoding]::UTF8
)
[xml]$manifest = $manifestText
if ($manifest.BlackmagicDesign.Plugin.Id -ne $pluginId) {
    throw "插件清单 Id 必须为 $pluginId。"
}

New-Item -ItemType Directory -Path $PluginDestinationRoot -Force | Out-Null
Assert-NotReparsePoint -Path $PluginDestinationRoot
Assert-DirectChildPath -Root $PluginDestinationRoot -Child $destination
Assert-NotReparsePoint -Path $destination

$operationId = [Guid]::NewGuid().ToString('N')
$stage = Join-Path $PluginDestinationRoot ".$pluginId.install-$operationId"
$backup = Join-Path $PluginDestinationRoot ".$pluginId.backup-$operationId"
Assert-DirectChildPath -Root $PluginDestinationRoot -Child $stage
Assert-DirectChildPath -Root $PluginDestinationRoot -Child $backup

$oldInstallationMoved = $false
$newInstallationCommitted = $false
$nativeModuleCopied = $false
try {
    New-Item -ItemType Directory -Path $stage | Out-Null

    Get-ChildItem -LiteralPath $PluginSource -File | Where-Object {
        $_.Name -ne 'WorkflowIntegration.node'
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage $_.Name) -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($nativeModule) -and
        (Test-Path -LiteralPath $nativeModule -PathType Leaf) -and
        (Get-Item -LiteralPath $nativeModule).Length -gt 0) {
        Copy-Item -LiteralPath $nativeModule -Destination (Join-Path $stage 'WorkflowIntegration.node') -Force
        $nativeModuleCopied = $true
    }

    foreach ($requiredFile in @('manifest.xml', 'package.json', 'main.js')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $requiredFile) -PathType Leaf)) {
            throw "插件暂存目录缺少 $requiredFile。"
        }
    }

    if (Test-Path -LiteralPath $destination) {
        Move-Item -LiteralPath $destination -Destination $backup
        $oldInstallationMoved = $true
    }

    try {
        Move-Item -LiteralPath $stage -Destination $destination
        $newInstallationCommitted = $true
    } catch {
        if ($oldInstallationMoved -and -not (Test-Path -LiteralPath $destination)) {
            Move-Item -LiteralPath $backup -Destination $destination
            $oldInstallationMoved = $false
        }
        throw
    }

    if ($oldInstallationMoved) {
        try {
            Remove-DeploymentDirectory -Root $PluginDestinationRoot -Path $backup
        } catch {
            Write-Warning "新插件已安装，但旧版本备份清理失败：$($_.Exception.Message)"
        }
    }
} finally {
    if (-not $newInstallationCommitted -and (Test-Path -LiteralPath $stage)) {
        Remove-DeploymentDirectory -Root $PluginDestinationRoot -Path $stage
    }
}

Write-Output "FilmStoryboard Resolve 插件文件已复制：$destination"
if ($nativeModuleCopied) {
    Write-Output "检测到 SDK 原生模块并已复制：$nativeModule"
} else {
    Write-Output '未检测到 SDK 原生模块；已按内置插件包完成复制。是否能够加载由目标机 Resolve 环境决定。'
}
