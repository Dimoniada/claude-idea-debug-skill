param(
    [string]$LogFile           = "$PWD\debug-capture.log",
    [string]$KeyDebug          = "+{F9}",   # SendKeys notation: + Shift, % Alt, ^ Ctrl
    [int]$DetectionWindowSec   = 30,
    [string]$TestHistoryDir    = "",        # override auto-detected testHistory path
    [int]$TestHistoryGraceMs   = 1500       # wait after JVM exit before scanning testHistory (raise for large Debug suites)
)

. "$PSScriptRoot\WinApi.ps1"

# Fail fast BEFORE spawning the chaser - distinguish "not running" from "hidden".
if (-not (Get-Process -Name idea64, idea -ErrorAction SilentlyContinue)) {
    Write-Error "IntelliJ IDEA is not running. Start it (with your project open and a Run/Debug config selected), then try again."
    exit 1
}
$ideaHandles = [WinApiShared]::FindByClass("SunAwtFrame")
if ($ideaHandles.Count -eq 0) {
    Write-Error "IntelliJ IDEA is running but no visible window was found. It may be minimized to the system tray - restore it from the tray and try again."
    exit 1
}

if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

# Sentinel file: chaser touches this once it has snapshotted baselines
$readyFile = "$env:TEMP\idea-chaser-ready.tmp"
if (Test-Path $readyFile) { Remove-Item $readyFile -Force }

# Launch chaser. No stdout/stderr redirection — chaser prints to this console live.
$chaserArgs = "-NonInteractive -ExecutionPolicy Bypass -File `"$PSScriptRoot\Chase-DebugProcess.ps1`" " +
              "-LogFile `"$LogFile`" -DetectionWindowSec $DetectionWindowSec -ReadyFile `"$readyFile`" -TestHistoryGraceMs $TestHistoryGraceMs -MinimizeIntelliJ" +
              $(if ($TestHistoryDir) { " -TestHistoryDir `"$TestHistoryDir`"" } else { "" })
$chaser = Start-Process powershell -ArgumentList $chaserArgs -NoNewWindow -PassThru

# Wait for chaser to signal "baselines snapshotted, safe to send keystroke"
$readyDeadline = (Get-Date).AddSeconds(10)
while ((Get-Date) -lt $readyDeadline -and -not (Test-Path $readyFile)) {
    Start-Sleep -Milliseconds 100
}
if (-not (Test-Path $readyFile)) {
    $chaser | Stop-Process -Force
    Write-Error "Chaser failed to ready up within 10s. Possibly slow PowerShell startup or script error."
    exit 1
}
Remove-Item $readyFile -Force -ErrorAction SilentlyContinue

# Bring IntelliJ forward and send the keystroke (handle was found upfront)
Invoke-BringToForeground $ideaHandles[0]

# SendKeys via fresh wscript.exe (interactive user session)
$vbs = "$env:TEMP\idea-send-key.vbs"
"Set WshShell = WScript.CreateObject(`"WScript.Shell`")`nWshShell.SendKeys `"$KeyDebug`"" | Out-File $vbs -Encoding ASCII
Start-Process "wscript.exe" -ArgumentList "`"$vbs`"" -Wait
Remove-Item $vbs -Force -ErrorAction SilentlyContinue

Write-Host "[parent] $KeyDebug sent. Chaser is watching."

$chaser.WaitForExit()
