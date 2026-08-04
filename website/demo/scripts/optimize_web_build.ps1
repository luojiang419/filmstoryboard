param(
  [string]$BuildDirectory = (Join-Path $PSScriptRoot '..\build\web')
)

$ErrorActionPreference = 'Stop'
$target = (Resolve-Path -LiteralPath $BuildDirectory).Path
$expectedTail = [IO.Path]::Combine('website', 'demo', 'build', 'web')
if (-not $target.EndsWith($expectedTail, [StringComparison]::OrdinalIgnoreCase)) {
  throw "仅允许精简 website/demo/build/web，当前目标为：$target"
}

$remove = @(
  'canvaskit\skwasm.js',
  'canvaskit\skwasm.js.symbols',
  'canvaskit\skwasm.wasm',
  'canvaskit\skwasm_heavy.js',
  'canvaskit\skwasm_heavy.js.symbols',
  'canvaskit\skwasm_heavy.wasm',
  'canvaskit\canvaskit.js.symbols',
  'canvaskit\chromium\canvaskit.js.symbols'
)

foreach ($relativePath in $remove) {
  $file = Join-Path $target $relativePath
  if (Test-Path -LiteralPath $file) {
    Remove-Item -LiteralPath $file -Force
  }
}

$worker = Join-Path $target 'flutter_service_worker.js'
$lines = Get-Content -LiteralPath $worker
$filtered = $lines | Where-Object {
  $_ -notmatch 'canvaskit/(skwasm|skwasm_heavy|.*\.js\.symbols)'
}
[IO.File]::WriteAllLines($worker, [string[]]$filtered, [Text.UTF8Encoding]::new($false))

$totalBytes = (Get-ChildItem -LiteralPath $target -Recurse -File |
  Measure-Object -Property Length -Sum).Sum
Write-Output "已精简 Web 产物：$([Math]::Round($totalBytes / 1MB, 2)) MB"
