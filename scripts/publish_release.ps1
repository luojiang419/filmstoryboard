param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseRepo,
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [Parameter(Mandatory = $true)]
    [string]$SourceRepo,
    [Parameter(Mandatory = $true)]
    [string]$SourceSha,
    [Parameter(Mandatory = $true)]
    [string]$AssetPath,
    [Parameter(Mandatory = $true)]
    [string]$ChecksumPath,
    [Parameter(Mandatory = $true)]
    [string]$ReleaseNotesPath,
    [Parameter(Mandatory = $true)]
    [string]$SignatureStatus
)

$ErrorActionPreference = 'Stop'

if (-not $env:GH_TOKEN) {
    throw 'GH_TOKEN is required for cross-repository publishing.'
}
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "Invalid four-part version: $Version"
}

$AssetPath = (Resolve-Path -LiteralPath $AssetPath).Path
$ChecksumPath = (Resolve-Path -LiteralPath $ChecksumPath).Path
$ReleaseNotesPath = (Resolve-Path -LiteralPath $ReleaseNotesPath).Path
$asset = Get-Item -LiteralPath $AssetPath
$checksum = Get-Item -LiteralPath $ChecksumPath
$assetName = $asset.Name
$checksumName = $checksum.Name
$expectedAssetName = "filmstoryboard-Setup-$Version.exe"
if ($assetName -ne $expectedAssetName) {
    throw "Unexpected installer name: $assetName"
}

$sha256 = (Get-FileHash -LiteralPath $AssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
$expectedChecksum = "$sha256  $assetName"
$actualChecksum = (Get-Content -Raw -LiteralPath $ChecksumPath).Trim()
if ($actualChecksum -ne $expectedChecksum) {
    throw 'Checksum file does not match the installer.'
}

$headers = @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $env:GH_TOKEN"
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'filmstoryboardReleaseWorkflow'
}
$apiBase = "https://api.github.com/repos/$ReleaseRepo"
$tag = "v$Version"
$tagPath = [Uri]::EscapeDataString($tag)
$manifestPath = "releases/$tag.json"
$releaseId = $null
$targetSha = $null
$tagCreated = $false
$published = $false

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [object]$Body,
        [string]$InFile,
        [string]$ContentType = 'application/json'
    )

    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
    }
    if ($null -ne $Body) {
        $parameters.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $parameters.ContentType = $ContentType
    }
    if ($InFile) {
        $parameters.InFile = $InFile
        $parameters.ContentType = $ContentType
    }
    Invoke-RestMethod @parameters
}

function Try-GetGitHubApi {
    param([Parameter(Mandatory = $true)][string]$Uri)
    try {
        Invoke-GitHubApi -Method Get -Uri $Uri
    } catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
}

try {
    $allReleases = @(Invoke-GitHubApi -Method Get -Uri "$apiBase/releases?per_page=100")
    $sameTag = @($allReleases | Where-Object { $_.tag_name -eq $tag })
    foreach ($existingRelease in $sameTag) {
        if (-not $existingRelease.draft) {
            throw "A published release already exists for $tag."
        }
        if ($existingRelease.body -notlike "*source-sha:$SourceSha*") {
            throw "A draft for $tag belongs to a different source commit."
        }
        Invoke-GitHubApi -Method Delete -Uri "$apiBase/releases/$($existingRelease.id)" | Out-Null
    }

    $manifest = [ordered]@{
        version = $Version
        tag = $tag
        sourceRepository = $SourceRepo
        sourceSha = $SourceSha
        assetName = $assetName
        assetSize = $asset.Length
        sha256 = $sha256
        signatureStatus = $SignatureStatus
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 5
    $existingManifest = Try-GetGitHubApi -Uri "$apiBase/contents/$manifestPath"
    if ($null -eq $existingManifest) {
        $manifestBytes = [Text.Encoding]::UTF8.GetBytes($manifestJson + "`n")
        $content = [Convert]::ToBase64String($manifestBytes)
        $createManifest = Invoke-GitHubApi -Method Put -Uri "$apiBase/contents/$manifestPath" -Body @{
            message = "release: $tag"
            content = $content
            branch = 'main'
        }
        $targetSha = $createManifest.commit.sha
    } else {
        $decoded = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String(($existingManifest.content -replace '\s', ''))
        ) | ConvertFrom-Json
        if ($decoded.sourceSha -ne $SourceSha) {
            throw "Existing manifest for $tag belongs to another source commit."
        }
        $commits = @(Invoke-GitHubApi -Method Get -Uri "$apiBase/commits?path=$([Uri]::EscapeDataString($manifestPath))&per_page=1")
        if ($commits.Count -ne 1) {
            throw "Cannot resolve the manifest commit for $tag."
        }
        $targetSha = $commits[0].sha
    }

    $tagRef = Try-GetGitHubApi -Uri "$apiBase/git/ref/tags/$tagPath"
    if ($null -eq $tagRef) {
        Invoke-GitHubApi -Method Post -Uri "$apiBase/git/refs" -Body @{
            ref = "refs/tags/$tag"
            sha = $targetSha
        } | Out-Null
        $tagCreated = $true
    } elseif ($tagRef.object.sha -ne $targetSha) {
        throw "Tag $tag already points to $($tagRef.object.sha), expected $targetSha."
    }

    $notes = Get-Content -Raw -LiteralPath $ReleaseNotesPath
    $runUrl = if ($env:GITHUB_RUN_ID) {
        "https://github.com/$SourceRepo/actions/runs/$env:GITHUB_RUN_ID"
    } else {
        'local-release-run'
    }
    $body = @"
$notes

---

- 源提交：$SourceSha
- 云端构建：$runUrl
- SHA-256：$sha256
- 签名状态：$SignatureStatus

<!-- source-sha:$SourceSha -->
"@

    $draft = Invoke-GitHubApi -Method Post -Uri "$apiBase/releases" -Body @{
        tag_name = $tag
        target_commitish = $targetSha
        name = "filmstoryboard $tag"
        body = $body
        draft = $true
        prerelease = $false
    }
    $releaseId = $draft.id

    $uploadBase = $draft.upload_url -replace '\{\?name,label\}$', ''
    $uploadedInstaller = Invoke-GitHubApi -Method Post -Uri "${uploadBase}?name=$([Uri]::EscapeDataString($assetName))" -InFile $AssetPath -ContentType 'application/octet-stream'
    $uploadedChecksum = Invoke-GitHubApi -Method Post -Uri "${uploadBase}?name=$([Uri]::EscapeDataString($checksumName))" -InFile $ChecksumPath -ContentType 'text/plain'

    $draftCheck = Invoke-GitHubApi -Method Get -Uri "$apiBase/releases/$releaseId"
    $remoteAssets = @($draftCheck.assets)
    if ($remoteAssets.Count -ne 2) {
        throw "Expected exactly two release assets, found $($remoteAssets.Count)."
    }
    $remoteInstaller = @($remoteAssets | Where-Object { $_.name -eq $assetName })
    $remoteChecksum = @($remoteAssets | Where-Object { $_.name -eq $checksumName })
    if ($remoteInstaller.Count -ne 1 -or $remoteChecksum.Count -ne 1) {
        throw 'Release asset names are missing or duplicated.'
    }
    if ($remoteInstaller[0].state -ne 'uploaded' -or $remoteInstaller[0].size -ne $asset.Length) {
        throw 'Remote installer size or upload state is invalid.'
    }
    if ($remoteChecksum[0].state -ne 'uploaded' -or $remoteChecksum[0].size -ne $checksum.Length) {
        throw 'Remote checksum size or upload state is invalid.'
    }
    if ($remoteInstaller[0].digest -and $remoteInstaller[0].digest -ne "sha256:$sha256") {
        throw "GitHub asset digest mismatch: $($remoteInstaller[0].digest)"
    }

    $branchRef = Invoke-GitHubApi -Method Get -Uri "$apiBase/git/ref/heads/main"
    $verifiedTagRef = Invoke-GitHubApi -Method Get -Uri "$apiBase/git/ref/tags/$tagPath"
    if ($branchRef.object.sha -ne $targetSha -or $verifiedTagRef.object.sha -ne $targetSha) {
        throw 'Release branch, manifest commit, and tag do not point to the same SHA.'
    }

    $formal = Invoke-GitHubApi -Method Patch -Uri "$apiBase/releases/$releaseId" -Body @{
        draft = $false
        prerelease = $false
        make_latest = 'true'
    }
    $published = $true

    $latest = $null
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $latest = Invoke-GitHubApi -Method Get -Uri "$apiBase/releases/latest"
        if ($latest.tag_name -eq $tag -and -not $latest.draft -and -not $latest.prerelease) {
            break
        }
        Start-Sleep -Seconds 5
    }
    if ($latest.tag_name -ne $tag -or $latest.draft -or $latest.prerelease) {
        throw "Latest Release did not converge to $tag."
    }
    if ($latest.target_commitish -ne $targetSha) {
        throw 'Latest Release target does not match the public release commit.'
    }

    $latestInstaller = @($latest.assets | Where-Object { $_.name -eq $assetName })
    $latestChecksum = @($latest.assets | Where-Object { $_.name -eq $checksumName })
    if ($latestInstaller.Count -ne 1 -or $latestChecksum.Count -ne 1) {
        throw 'Latest Release does not expose the exact installer contract.'
    }

    $downloadRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $downloadedInstaller = Join-Path $downloadRoot "verified-$assetName"
    $downloadedChecksum = Join-Path $downloadRoot "verified-$checksumName"
    Invoke-WebRequest -Uri $latestInstaller[0].browser_download_url -OutFile $downloadedInstaller
    Invoke-WebRequest -Uri $latestChecksum[0].browser_download_url -OutFile $downloadedChecksum
    $downloadedSha = (Get-FileHash -LiteralPath $downloadedInstaller -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($downloadedSha -ne $sha256) {
        throw 'Downloaded installer SHA-256 does not match the build artifact.'
    }
    if ((Get-Content -Raw -LiteralPath $downloadedChecksum).Trim() -ne $expectedChecksum) {
        throw 'Downloaded checksum file content is invalid.'
    }

    if ($env:GITHUB_OUTPUT) {
        "tag=$tag" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8
        "release_url=$($formal.html_url)" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8
        "asset_url=$($latestInstaller[0].browser_download_url)" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8
        "sha256=$sha256" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8
        "target_sha=$targetSha" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8
    }

    [ordered]@{
        tag = $tag
        releaseUrl = $formal.html_url
        assetUrl = $latestInstaller[0].browser_download_url
        sha256 = $sha256
        targetSha = $targetSha
    } | ConvertTo-Json -Compress
} catch {
    if ($releaseId -and -not $published) {
        try {
            Invoke-GitHubApi -Method Delete -Uri "$apiBase/releases/$releaseId" | Out-Null
        } catch {
            Write-Warning "Failed to remove draft release $releaseId."
        }
    }
    if ($tagCreated -and $targetSha) {
        try {
            $currentTag = Try-GetGitHubApi -Uri "$apiBase/git/ref/tags/$tagPath"
            if ($currentTag -and $currentTag.object.sha -eq $targetSha) {
                Invoke-GitHubApi -Method Delete -Uri "$apiBase/git/refs/tags/$tagPath" | Out-Null
            }
        } catch {
            Write-Warning "Failed to remove tag $tag created by this run."
        }
    }
    throw
}
