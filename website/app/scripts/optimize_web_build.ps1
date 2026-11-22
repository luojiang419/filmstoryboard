param(
  [string]$BuildDirectory = (Join-Path $PSScriptRoot '..\build\web')
)

$ErrorActionPreference = 'Stop'
$target = (Resolve-Path -LiteralPath $BuildDirectory).Path
$expectedTail = [IO.Path]::Combine('website', 'app', 'build', 'web')
if (-not $target.EndsWith($expectedTail, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Only website/app/build/web may be optimized. Target: $target"
}

$bootstrap = Get-Content -Raw -LiteralPath (Join-Path $target 'flutter_bootstrap.js')
if ($bootstrap -notmatch '"renderer":"canvaskit"' -or $bootstrap -match '"renderer":"skwasm"') {
  throw 'The build is not CanvasKit-only. Refusing to remove skwasm files.'
}
if ($bootstrap -notmatch "canvasKitBaseUrl:\s*'canvaskit'") {
  throw 'CanvasKit is not pinned to the bundled local assets.'
}
if ($bootstrap -notmatch "fontFallbackBaseUrl:\s*'assets/assets/fonts/fallback/'") {
  throw 'Font fallback is not pinned to the bundled local assets.'
}
$index = Get-Content -Raw -LiteralPath (Join-Path $target 'index.html')
if ($index -notmatch 'flutter_bootstrap\.js\?v=\d+') {
  throw 'The Flutter bootstrap URL is not cache-busted by the build version.'
}

$fontManifestPath = Join-Path $target 'assets\FontManifest.json'
$regularFontPath = Join-Path $target 'assets\assets\fonts\NotoSansSC-Regular.otf'
$fontLicensePath = Join-Path $target 'assets\assets\fonts\OFL.txt'
$fallbackRoot = Join-Path $target 'assets\assets\fonts\fallback'
$fallbackFiles = @(
  'roboto\v32\KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2',
  'notosanssc\v37\k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.115.woff2',
  'notosanssc\v37\k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.117.woff2',
  'notosanssc\v37\k3kCo84MPvpLmixcA63oeAL7Iqp5IZJF9bmaG9_FnYkldv7JjxkkgFsFSSOPMOkySAZ73y9ViAt3acb8NexQ2w.118.woff2',
  'Roboto-OFL.txt'
)
if (-not (Test-Path -LiteralPath $fontManifestPath) -or
    -not (Test-Path -LiteralPath $regularFontPath) -or
    -not (Test-Path -LiteralPath $fontLicensePath)) {
  throw 'Bundled Noto Sans SC font or its OFL license is missing.'
}
foreach ($fallbackFile in $fallbackFiles) {
  if (-not (Test-Path -LiteralPath (Join-Path $fallbackRoot $fallbackFile))) {
    throw "Bundled fallback asset is missing: $fallbackFile"
  }
}
$fontManifest = Get-Content -Raw -LiteralPath $fontManifestPath
if ($fontManifest -notmatch '"family":"NotoSansSC"' -or
    $fontManifest -notmatch '"asset":"assets/fonts/NotoSansSC-Regular.otf"' -or
    $fontManifest -match 'NotoSansSC-Bold.otf') {
  throw 'FontManifest does not register only the bundled static NotoSansSC regular font.'
}

$remove = @(
  '.last_build_id',
  'assets\assets\fonts\NotoSansSC-VF.ttf',
  'assets\assets\fonts\NotoSansCJKsc-Regular.otf',
  'assets\assets\fonts\NotoSansSC-Bold.otf',
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
[IO.File]::WriteAllLines(
  $worker,
  [string[]]$filtered,
  [Text.UTF8Encoding]::new($false)
)

$totalBytes = (Get-ChildItem -LiteralPath $target -Recurse -File |
  Measure-Object -Property Length -Sum).Sum
Write-Output "Optimized remote Web build: $([Math]::Round($totalBytes / 1MB, 2)) MB"
