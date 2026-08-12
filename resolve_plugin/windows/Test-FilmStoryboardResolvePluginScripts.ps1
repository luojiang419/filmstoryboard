[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw "断言失败：$Message"
    }
}

function Assert-Utf8Bom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasUtf8Bom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    Assert-True $hasUtf8Bom $Message
}

$installScript = Join-Path $PSScriptRoot 'Install-FilmStoryboardResolvePlugin.ps1'
$uninstallScript = Join-Path $PSScriptRoot 'Uninstall-FilmStoryboardResolvePlugin.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("filmstoryboard-resolve-plugin-test-" + [Guid]::NewGuid().ToString('N'))

Assert-Utf8Bom $installScript '安装脚本必须使用 UTF-8 BOM，避免 Windows PowerShell 5.1 按 ANSI 误解析中文字符串'
Assert-Utf8Bom $uninstallScript '卸载脚本必须使用 UTF-8 BOM，避免 Windows PowerShell 5.1 按 ANSI 误解析中文字符串'
Assert-Utf8Bom $PSCommandPath '测试脚本必须使用 UTF-8 BOM，确保可直接在 Windows PowerShell 5.1 运行'

try {
    $source = Join-Path $testRoot 'source\com.filmstoryboard.timelinebridge'
    $sdkExamples = Join-Path $testRoot 'sdk\Examples'
    $nativeDirectory = Join-Path $sdkExamples 'SamplePromisePlugin'
    $destinationRoot = Join-Path $testRoot 'plugins'
    New-Item -ItemType Directory -Path $source, $nativeDirectory, $destinationRoot -Force | Out-Null

    $manifestText = @'
<?xml version="1.0" encoding="UTF-8"?>
<BlackmagicDesign><Plugin><Id>com.filmstoryboard.timelinebridge</Id><Name>FilmStoryboard 时间线桥接</Name></Plugin></BlackmagicDesign>
'@
    [System.IO.File]::WriteAllText(
        (Join-Path $source 'manifest.xml'),
        $manifestText,
        [System.Text.UTF8Encoding]::new($false)
    )
    $manifestBytes = [System.IO.File]::ReadAllBytes((Join-Path $source 'manifest.xml'))
    Assert-True (-not ($manifestBytes[0] -eq 0xEF -and $manifestBytes[1] -eq 0xBB -and $manifestBytes[2] -eq 0xBF)) '测试清单必须保持 UTF-8 无 BOM，复现安装包真实载荷'
    '{"name":"test-plugin","version":"1.0.0"}' | Set-Content -LiteralPath (Join-Path $source 'package.json') -Encoding UTF8
    'module.exports = {};' | Set-Content -LiteralPath (Join-Path $source 'main.js') -Encoding UTF8
    'source-v1' | Set-Content -LiteralPath (Join-Path $source 'renderer.js') -Encoding UTF8
    'forbidden-bundled-binary' | Set-Content -LiteralPath (Join-Path $source 'WorkflowIntegration.node') -Encoding UTF8
    'sdk-native-v1' | Set-Content -LiteralPath (Join-Path $nativeDirectory 'WorkflowIntegration.node') -Encoding UTF8

    & $installScript -PluginSource $source -PluginDestinationRoot $destinationRoot -SdkExamplesRoot $sdkExamples -SkipResolveProcessCheck

    $installed = Join-Path $destinationRoot 'com.filmstoryboard.timelinebridge'
    Assert-True (Test-Path -LiteralPath (Join-Path $installed 'main.js') -PathType Leaf) '首次安装应复制插件文件'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $installed 'WorkflowIntegration.node')).Trim() -eq 'sdk-native-v1') '原生模块必须来自 SDK，而不是插件源目录'

    'stale' | Set-Content -LiteralPath (Join-Path $installed 'stale.js') -Encoding UTF8
    'source-v2' | Set-Content -LiteralPath (Join-Path $source 'renderer.js') -Encoding UTF8
    'sdk-native-v2' | Set-Content -LiteralPath (Join-Path $nativeDirectory 'WorkflowIntegration.node') -Encoding UTF8
    & $installScript -PluginSource $source -PluginDestinationRoot $destinationRoot -SdkExamplesRoot $sdkExamples -SkipResolveProcessCheck

    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installed 'stale.js'))) '重复安装应移除旧版本遗留文件'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $installed 'renderer.js')).Trim() -eq 'source-v2') '重复安装应更新插件文件'
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $installed 'WorkflowIntegration.node')).Trim() -eq 'sdk-native-v2') '重复安装应重新取得目标机 SDK 原生模块'

    Remove-Item -LiteralPath (Join-Path $nativeDirectory 'WorkflowIntegration.node') -Force
    'source-v3' | Set-Content -LiteralPath (Join-Path $source 'renderer.js') -Encoding UTF8
    $missingSdkOutput = & $installScript -PluginSource $source -PluginDestinationRoot $destinationRoot -SdkExamplesRoot $sdkExamples -SkipResolveProcessCheck
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $installed 'renderer.js')).Trim() -eq 'source-v3') 'SDK 缺失时仍应更新插件文件'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installed 'WorkflowIntegration.node'))) 'SDK 缺失时不应复制插件源目录中的机器相关二进制'
    Assert-True (($missingSdkOutput -join "`n") -like '*已按内置插件包完成复制*') 'SDK 缺失时应明确提示已完成文件复制'

    $invalidSource = Join-Path $testRoot 'invalid-source\com.filmstoryboard.timelinebridge'
    New-Item -ItemType Directory -Path $invalidSource -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $invalidSource -Force
    '<invalid>' | Set-Content -LiteralPath (Join-Path $invalidSource 'manifest.xml') -Encoding ASCII
    $errorLog = Join-Path $testRoot 'logs\install-error.log'
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installScript -PluginSource $invalidSource -PluginDestinationRoot $destinationRoot -SdkExamplesRoot $sdkExamples -ErrorLogPath $errorLog -SkipResolveProcessCheck 2>$null
    $invalidFailed = $LASTEXITCODE -ne 0
    $ErrorActionPreference = $previousErrorActionPreference
    Assert-True $invalidFailed '无效插件清单应返回失败'
    Assert-True (Test-Path -LiteralPath $errorLog -PathType Leaf) '部署失败时应生成 UTF-8 错误日志供安装器展示'
    Assert-Utf8Bom $errorLog '部署错误日志必须使用 UTF-8 BOM'

    & $uninstallScript -PluginDestinationRoot $destinationRoot -SkipResolveProcessCheck
    Assert-True (-not (Test-Path -LiteralPath $installed)) '首次卸载应移除插件目录'
    & $uninstallScript -PluginDestinationRoot $destinationRoot -SkipResolveProcessCheck
    Assert-True (-not (Test-Path -LiteralPath $installed)) '重复卸载应保持成功'

    Write-Output 'FilmStoryboard Resolve 插件安装/卸载脚本测试通过。'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
