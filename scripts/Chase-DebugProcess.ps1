param(
    [string]$LogFile           = "$PWD\debug-capture.log",
    [int]$DetectionWindowSec   = 30,
    [string]$ReadyFile         = "",
    [string]$TestHistoryDir    = "",   # override auto-detected path
    [int]$TestHistoryGraceMs   = 1500, # wait after JVM exit before scanning testHistory for the XML
    [switch]$MinimizeIntelliJ
)

. "$PSScriptRoot\WinApi.ps1"

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding            = [System.Text.Encoding]::UTF8

# --- Locate IntelliJ test history directory ---
# Explicit override wins; otherwise try modern path (IntelliJ 2020+), then legacy (pre-2020).
# Custom idea.system.path in idea.vmoptions/idea.properties is not handled automatically —
# if both standard locations miss, pass -TestHistoryDir '<path>\testHistory' explicitly.
if ($TestHistoryDir) {
    $testHistoryDir = $TestHistoryDir
} else {
    $ideaDir = Get-ChildItem "$env:LOCALAPPDATA\JetBrains" -Filter "IntelliJIdea*" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName

    if (-not $ideaDir) {
        # Legacy path used by IntelliJ 2019 and earlier
        $ideaDir = Get-ChildItem "$env:USERPROFILE" -Filter ".IntelliJIdea*" -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1 |
            ForEach-Object { Join-Path $_.FullName "system" }
    }

    if (-not $ideaDir) {
        Write-Warning "[chaser] Could not find IntelliJ IDEA data directory under LOCALAPPDATA\JetBrains or USERPROFILE\.IntelliJIdea*. If you use a custom idea.system.path, pass -TestHistoryDir '<path>\testHistory' to this script."
    }
    $testHistoryDir = if ($ideaDir) { "$ideaDir\testHistory" } else { "" }
}

# --- Snapshot baselines BEFORE the parent fires Shift+F9 ---
$baselineXml = @{}
Get-ChildItem "$testHistoryDir\*\*.xml" -ErrorAction SilentlyContinue | ForEach-Object {
    $baselineXml[$_.FullName] = $_.LastWriteTime
}
$baselinePids = @((Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue).ProcessId)

# Signal parent: baselines captured, safe to fire the keystroke now
if ($ReadyFile) { '' | Out-File $ReadyFile -Encoding ASCII }

Write-Host "[chaser] armed. Detection window: ${DetectionWindowSec}s for test runner to start."

# --- Phase 1: detect IntelliJ test/app-runner java.exe OR an early XML ---
# idea_rt.jar appears in many IntelliJ-spawned JVMs. Exclude the infrastructure
# daemons (build, Maven server, Kotlin daemon, etc.) that also include it but
# are NOT the test/run target — they're long-living and would hang Phase 2.
$infraPattern = 'BuildMain|jps-launcher|RemoteMavenServer|kotlin\.daemon|MavenServerCmdReader|JpsBootstrap'

$detectionDeadline = (Get-Date).AddSeconds($DetectionWindowSec)
$testProcess = $null
$earlyXml    = $null

while ((Get-Date) -lt $detectionDeadline) {
    Start-Sleep -Milliseconds 500

    # New java.exe with IntelliJ's test-runner classpath, but not infra?
    $currentJava = Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue
    foreach ($proc in $currentJava) {
        if ($proc.ProcessId -in $baselinePids) { continue }
        if ($proc.CommandLine -match 'idea_rt\.jar' -and $proc.CommandLine -notmatch $infraPattern) {
            $testProcess = Get-Process -Id $proc.ProcessId -ErrorAction SilentlyContinue
            if ($testProcess) {
                Write-Host "[chaser] test runner detected, PID $($proc.ProcessId)"
                break
            }
        }
    }
    if ($testProcess) { break }

    # Or an XML appeared faster than we could see the JVM
    $candidate = Get-ChildItem "$testHistoryDir\*\*.xml" -ErrorAction SilentlyContinue |
        Where-Object {
            -not $baselineXml.ContainsKey($_.FullName) -or
            $_.LastWriteTime -gt $baselineXml[$_.FullName]
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($candidate) {
        $earlyXml = $candidate
        Write-Host "[chaser] test results appeared early: $($candidate.Name)"
        break
    }
}

if (-not $testProcess -and -not $earlyXml) {
    Write-Error "[chaser] no IntelliJ test runner detected within ${DetectionWindowSec}s. Shift+F9 may not have reached IntelliJ (modal dialog, focus issue, no run config selected). Increase with -DetectionWindowSec."
    exit 1
}

# --- Phase 2: wait for test runner to exit, with heartbeat (no timeout) ---
if ($testProcess) {
    $start    = Get-Date
    $lastBeat = $start
    Write-Host "[chaser] waiting for test runner to exit..."
    while (-not $testProcess.HasExited) {
        Start-Sleep -Milliseconds 500
        $now = Get-Date
        if (($now - $lastBeat).TotalSeconds -ge 10) {
            $elapsed = [int]($now - $start).TotalSeconds
            Write-Host "[chaser] still running... ${elapsed}s elapsed"
            $lastBeat = $now
        }
    }
    $totalSec = [int]((Get-Date) - $start).TotalSeconds
    Write-Host "[chaser] test runner exited after ${totalSec}s"
    Start-Sleep -Milliseconds $TestHistoryGraceMs  # give IntelliJ time to finalize the XML (raise for large Debug suites)
}

# --- Phase 3: find the test-results XML (latest new/modified) ---
$latest = $earlyXml
if (-not $latest) {
    $latest = Get-ChildItem "$testHistoryDir\*\*.xml" -ErrorAction SilentlyContinue |
        Where-Object {
            -not $baselineXml.ContainsKey($_.FullName) -or
            $_.LastWriteTime -gt $baselineXml[$_.FullName]
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

# --- Output: log file ---
if (Test-Path $LogFile) {
    Write-Host "[chaser] === LOG FILE: $LogFile ==="
    Get-Content $LogFile
} else {
    Write-Host "[chaser] === LOG FILE: not found ==="
    Write-Host "[chaser] HINT: the IntelliJ Run/Debug Configuration is missing one or both of:"
    Write-Host "[chaser]   1. Logs tab -> 'Save console output to file:' (target path)"
    Write-Host "[chaser]   2. VM options -> -Dlogging.file.name=<path>  (for Spring Boot apps)"
}

# --- Output: test results (if any) ---
if ($latest) {
    Write-Host "`n[chaser] === TEST HISTORY XML: $($latest.FullName) ==="
    $raw  = ([System.IO.File]::ReadAllText($latest.FullName, [System.Text.Encoding]::UTF8)) -replace 'version="1\.1"','version="1.0"'
    [xml]$xml = $raw
    $counts = @{}
    $xml.SelectNodes("//count") | ForEach-Object { $counts[$_.name] = $_.value }
    $total  = $counts['total']
    $passed = if ($counts['passed']) { $counts['passed'] } else { '0' }
    $failed = if ($counts['failed']) { $counts['failed'] } else { '0' }
    Write-Host "Total: $total  Passed: $passed  Failed: $failed"
    Write-Host ""
    foreach ($test in $xml.testrun.test) {
        $icon = if ($test.status -eq 'passed') { 'PASS' } else { 'FAIL' }
        $dur  = if ($test.duration) { "$($test.duration)ms" } else { '?' }
        Write-Host "[$icon] $($test.name) ($dur)"
        if ($test.status -ne 'passed') {
            $test.output | Where-Object type -eq 'stderr' | ForEach-Object { Write-Host $_.'#text' }
        }
    }
} else {
    Write-Host "`n[chaser] (no new test results XML - may have been a build-only or non-test debug run)"
}

# --- Minimize IntelliJ so Claude Code surfaces ---
if ($MinimizeIntelliJ) {
    $ideaHandles = [WinApiShared]::FindByClass("SunAwtFrame")
    if ($ideaHandles.Count -gt 0) {
        [WinApiShared]::ShowWindow($ideaHandles[0], 6) | Out-Null
        Write-Host "[chaser] IntelliJ minimized; Claude Code surfaces"
    }
}
