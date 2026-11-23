param(
    [string]$BuildDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'build/windows/x64/runner/Release'),
    [string]$InstallDirectory = 'D:\Program Files\filmstoryboard',
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath($BuildDirectory).TrimEnd('\')
$installRoot = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
if ($sourceRoot -eq $installRoot) { throw 'Build and installation must be different directories.' }
$sourceExe = Join-Path $sourceRoot 'filmstoryboard.exe'
$installedExe = Join-Path $installRoot 'filmstoryboard.exe'
if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) { throw 'Existing installation not found.' }
function Get-ProductVersion([string]$File) {
    $info = (Get-Item -LiteralPath $File).VersionInfo
    return "$($info.ProductMajorPart).$($info.ProductMinorPart).$($info.ProductBuildPart).$($info.ProductPrivatePart)"
}
if ((Get-ProductVersion $sourceExe) -ne $Version) { throw 'Build product version does not match requested version.' }
$uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{EAD11C88-C57C-4E8E-A5AB-A5F75D05B9CE}_is1'
$registration = Get-ItemProperty -LiteralPath $uninstallKey
if ([IO.Path]::GetFullPath($registration.InstallLocation).TrimEnd('\') -ne $installRoot) {
    throw 'Registered installation location does not match the target.'
}

# Only application payload is eligible. Project databases, user files, model
# weights, web assets and the existing uninstaller are never enumerated here.
$files = @(
    Get-ChildItem -LiteralPath $sourceRoot -File | Where-Object {
        $_.Name -eq 'filmstoryboard.exe' -or $_.Extension -eq '.dll' -or $_.Name -eq 'native_assets.json'
    }
    Get-Item -LiteralPath (Join-Path $sourceRoot 'data/app.so')
    Get-Item -LiteralPath (Join-Path $sourceRoot 'data/icudtl.dat')
    Get-Item -LiteralPath (Join-Path $sourceRoot 'data/person-depth/runtime/person-depth-worker.exe')
    Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'data/flutter_assets') -Recurse -File
)
$manifest = foreach ($file in $files) {
    $relative = $file.FullName.Substring($sourceRoot.Length + 1)
    $target = [IO.Path]::GetFullPath((Join-Path $installRoot $relative))
    if (-not $target.StartsWith($installRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Payload path escapes the installation.'
    }
    [PSCustomObject]@{
        Source = $file.FullName; Relative = $relative; Target = $target
        Hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        Existed = Test-Path -LiteralPath $target -PathType Leaf
    }
}
if ($CheckOnly) {
    Write-Output "Validated $($manifest.Count) application files for $Version -> $installRoot"
    return
}

$processes = @(Get-Process filmstoryboard -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $installedExe })
foreach ($process in $processes) {
    if (-not $process.CloseMainWindow() -or -not $process.WaitForExit(15000)) {
        throw 'Application did not close normally; no installation files were changed.'
    }
}
$backupRoot = Join-Path (Split-Path $PSScriptRoot -Parent) "dist/local-update-backup/$Version-$(Get-Date -Format yyyyMMdd-HHmmss)"
New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
$registration | Select-Object DisplayName, DisplayVersion, InstallLocation |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupRoot 'registration.json') -Encoding utf8
foreach ($entry in $manifest) {
    if ($entry.Existed) {
        $backup = Join-Path $backupRoot $entry.Relative
        New-Item -ItemType Directory -Path (Split-Path $backup -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $entry.Target -Destination $backup -Force
    }
}
$changed = [Collections.Generic.List[object]]::new()
try {
    foreach ($entry in $manifest) {
        New-Item -ItemType Directory -Path (Split-Path $entry.Target -Parent) -Force | Out-Null
        $changed.Add($entry)
        Copy-Item -LiteralPath $entry.Source -Destination $entry.Target -Force
        if ((Get-FileHash -LiteralPath $entry.Target -Algorithm SHA256).Hash -ne $entry.Hash) {
            throw "Payload verification failed: $($entry.Relative)"
        }
    }
    Set-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -Value $Version
    Set-ItemProperty -LiteralPath $uninstallKey -Name DisplayName -Value "filmstoryboard version $Version"
    if ((Get-ProductVersion $installedExe) -ne $Version -or
        (Get-ItemProperty -LiteralPath $uninstallKey).DisplayVersion -ne $Version) {
        throw 'Installed product and registry versions do not match.'
    }
} catch {
    foreach ($entry in $changed) {
        if ($entry.Existed) {
            Copy-Item -LiteralPath (Join-Path $backupRoot $entry.Relative) -Destination $entry.Target -Force
        } elseif (Test-Path -LiteralPath $entry.Target -PathType Leaf) {
            Remove-Item -LiteralPath $entry.Target
        }
    }
    Set-ItemProperty -LiteralPath $uninstallKey -Name DisplayVersion -Value $registration.DisplayVersion
    Set-ItemProperty -LiteralPath $uninstallKey -Name DisplayName -Value $registration.DisplayName
    throw
}
if ($processes.Count -gt 0) {
    Start-Process -FilePath $installedExe -WorkingDirectory $installRoot -WindowStyle Hidden | Out-Null
}
Write-Output "Updated and SHA-256 verified $($manifest.Count) files. Product/registry version: $Version. Backup: $backupRoot"
