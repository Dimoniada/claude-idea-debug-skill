---
name: idea-debug
description: Trigger an IntelliJ IDEA debug/test run from Claude Code on Windows and capture the console output and test results back into the conversation for analysis. Use this skill ONLY when the user explicitly types or says the phrase "idea-debug" (or close variants like "run idea-debug", "do an idea-debug"). Do NOT trigger on generic words like "debug", "run tests", or "recompile" on their own — the explicit phrase is the trigger. After capturing output, analyze it, summarize what passed/failed, and suggest fixes. Then stop.
---

# idea-debug

Wraps a PowerShell toolkit that sends the user's configured "Debug" shortcut (default Shift+F9) to IntelliJ IDEA, detects the spawned test-runner JVM, waits for it to exit, and pipes the console log plus the parsed JUnit results back into Claude Code's terminal.

## Trigger

Only when the user explicitly invokes the phrase `idea-debug` (with or without surrounding words like "run" or "do a"). Generic mentions of debugging, testing, or compiling do **not** trigger this skill — the user has other ways to ask for those.

## Path resolution

Two independent paths matter:

- **Toolkit scripts** live inside this skill, in `scripts/` next to `SKILL.md`. They were bundled with the skill at install time.
- **Project / log file** lives wherever Claude Code is opened (`$PWD`). The IntelliJ run config writes `debug-capture.log` here, and the script's default `-LogFile` is `$PWD\debug-capture.log` — so they align automatically with no parameter needed.

## How to run

Always invoke via `powershell -ExecutionPolicy Bypass -File`:

```powershell
powershell -ExecutionPolicy Bypass -File "<absolute-path-to-this-skill>\scripts\Debug-And-Capture.ps1"
```

Do not use `& "...ps1"` — that subjects the script to the system's execution policy and may fail with `cannot be loaded because running scripts is disabled on this system`. The `-ExecutionPolicy Bypass` form works on every Windows machine without setup.

The `-File` parameter inherits the parent shell's working directory, so `$PWD` inside the script resolves to the user's project folder. `$PSScriptRoot` resolves to the skill's `scripts/` folder, so it correctly finds `Chase-DebugProcess.ps1` and `WinApi.ps1`.

## Configuration (per-conversation prompt)

The script accepts a `-KeyDebug` parameter in WshShell.SendKeys notation: `+` = Shift, `%` = Alt, `^` = Ctrl. Examples: `+{F9}` = Shift+F9 (default), `+%{F10}` = Shift+Alt+F10, `^{F9}` = Ctrl+F9.

**Protocol — ask once per conversation, then remember within the conversation:**

1. The **first time** the user invokes `/idea-debug` in this conversation, do NOT run the script yet. Ask:

   > "What's your IntelliJ shortcut for 'Re-run Debug'? Default is Shift+F9 (`+{F9}`).
   >
   > Reply 'default', OR a human-readable form (e.g. 'Shift+Alt+F10', 'Ctrl+F9'), OR raw SendKeys notation (e.g. `+%{F10}`, `^{F9}`)."

   Accept any of these input forms:
   - "default" / "yes" / empty → use `+{F9}`
   - Human-readable like "Shift+Alt+F10" → translate to SendKeys (`+` Shift, `%` Alt, `^` Ctrl): `+%{F10}`
   - Already-formatted SendKeys notation (starts with `+`, `%`, `^`, or `{`) → use as-is

   Pass the resulting value as `-KeyDebug "<value>"` to the script. Remember it for the rest of this conversation.

2. On **every subsequent `/idea-debug` in the same conversation**, reuse the remembered value silently — do NOT ask again.

3. If the user explicitly says they want to change the shortcut mid-conversation, ask once and use the new value going forward.

4. **Do NOT persist the value** to any memory file or config. It is conversation-scoped. The next conversation will ask again — that is intentional.

## What the script does

1. Spawns `Chase-DebugProcess.ps1` as a background watcher (`Start-Process -NoNewWindow`, no stdout/stderr redirection — the chaser prints live into the same console as the parent).
2. The watcher snapshots existing `*.xml` files in `%LOCALAPPDATA%\JetBrains\IntelliJIdea*\testHistory\` AND existing `java.exe` PIDs, then writes a sentinel "ready" file in `$env:TEMP`.
3. The parent **waits for the sentinel** before sending the keystroke (eliminates the race where slow PowerShell startup means the chaser hasn't snapshotted yet).
4. The parent uses `BringToForeground` (AttachThreadInput + SetForegroundWindow) to surface IntelliJ.
5. The parent writes a tiny `.vbs` and runs it via `wscript.exe`, which sends `$KeyDebug` (default `+{F9}`) from the **interactive user session**. The keypress would be silently dropped if sent from the non-interactive PowerShell subprocess.
6. The watcher polls for either: (a) a new `java.exe` whose command-line contains `idea_rt.jar` AND does NOT match an infrastructure pattern (BuildMain, jps-launcher, kotlin.daemon, etc.), or (b) a new/modified testHistory XML (fallback for sub-second tests where the JVM disappears between polls). Detection times out after `-DetectionWindowSec` (default 30s).
7. Once the test-runner JVM is detected, the watcher waits for it to exit — **with no timeout** — printing a `[chaser] still running... Ns elapsed` heartbeat every 10 seconds.
8. After exit (plus a grace period for IntelliJ to finalize the XML — `-TestHistoryGraceMs`, default 1500), the watcher reads `debug-capture.log` and parses the latest test-history XML to print pass/fail counts and per-test results.
9. The watcher minimizes IntelliJ via `ShowWindow(SW_MINIMIZE)`. This is a cross-process call that does NOT require focus-stealing privileges, and the next window in the Z-order (Claude Code) surfaces naturally — without burning the user's Alt+Tab MRU slot.

## Design notes (do not undo)

- **Use `wscript.exe` for SendKeys, not `WScript.Shell.SendKeys` directly or `keybd_event`.** Both fail when called from Claude Code's non-interactive subprocess. `wscript.exe` runs at the top of the process tree with interactive desktop access.
- **Use temp files in `$env:TEMP`, not `$PSScriptRoot`.** Skill directories may not be writable from non-interactive subprocesses.
- **Use a sentinel-file handshake, not a fixed sleep.** The chaser writes a ready-file after snapshotting baselines; the parent waits for it before firing the keystroke. PowerShell startup can take 2–5 seconds — without the handshake, fast tests finish before the chaser even snapshots, polluting the baseline.
- **Filter `java.exe` by classpath AND exclude infrastructure.** IntelliJ DOES spawn a fresh `java.exe` per test/run (with `idea_rt.jar` in the classpath). But its own daemons (JPS BuildMain, jps-launcher, RemoteMavenServer, kotlin.daemon, MavenServerCmdReader, JpsBootstrap) ALSO include `idea_rt.jar` and are long-living — without exclusion, the watcher locks onto the build daemon and hangs forever. Use the early-XML check as a fallback for tests that finish faster than 500ms (the JVM exits between two polls).
- **No timeout once the test JVM is detected.** Detection itself has `-DetectionWindowSec` (default 30s), but once we have a process handle we `WaitForExit` indefinitely with a 10s heartbeat. Long-running suites (Spring Boot, Testcontainers) work without ceremony.
- **Don't redirect chaser stdout.** The original implementation captured chaser output to a file and printed it after `WaitForExit`. That hides progress and breaks the heartbeat. Use `-NoNewWindow` so the chaser shares the parent's console and prints live.
- **Minimize IntelliJ to return focus, do not try to bring Claude Code forward.** Cross-process focus-stealing is blocked by Windows from a deep subprocess (just flashes the taskbar icon). Minimizing the foreground window is unrestricted and lets the previous window surface cleanly.

## Reading the output

The output is divided into clearly-labeled sections:

- **Chaser status lines** prefixed `[chaser]` — process tracking, not user-facing content.
- **`=== LOG FILE: <path> ===`** — the contents of `debug-capture.log` if found. If not found, the section reads `=== LOG FILE: not found ===` followed by a HINT explaining which two IntelliJ run-config settings to enable (`Save console output to file` and `-Dlogging.file.name=`).
- **`=== TEST HISTORY XML: <full-path-to-xml> ===`** — parsed JUnit results from the latest IntelliJ test-history XML:
  ```
  [chaser] === TEST HISTORY XML: C:\...\testHistory\<hash>\<TestName> - <timestamp>.xml ===
  Total: N  Passed: N  Failed: N

  [PASS] testName (Xms)
  [FAIL] otherTestName (Yms)
  <stderr from failed test>
  ```

The full path is shown so the user can open the XML directly. If a `[FAIL]` shows duration `(?)` and no stderr, the test never actually ran — typically a Spring/JUnit bootstrap failure (e.g. a Testcontainer dependency was unavailable). Look at the LOG FILE section to find the root cause.

## What to do with the output

1. **Summarize the result first**: pass/fail counts if tests ran, or build success/failure otherwise. One or two lines.
2. **Read the XML file.** The chaser prints the full path as `=== TEST HISTORY XML: <path> ===`. Always read that file with the Read tool — it contains `<output type="stdout">` blocks with the full JVM console output (Testcontainers errors, Spring context failures, stack traces) that are NOT echoed by the chaser script. Extract any error messages, stack traces, or `Caused by:` lines and include them verbatim in your response.
3. **Identify the actual problem.** Look at:
   - Compiler errors (line numbers, file paths)
   - Test failures and their stderr
   - `Caused by:` lines and stack traces from the XML stdout blocks
   - Stack traces in the console log
4. **Suggest concrete fixes.** Reference specific files and line numbers from the project where possible. If a test failed, name the test and explain why.
5. **Stop.** Do not re-run the skill automatically. Wait for the user to apply a fix and ask again.

## Setup requirements (mention to user if a run fails)

The user must configure these once per project in the IntelliJ Run/Debug Configuration:

- **Logs tab → "Save console output to file"** = `<project-folder>\debug-capture.log` (the same folder Claude Code is opened in).
- **VM options → `-Dlogging.file.name=<project-folder>\debug-capture.log`** (for Spring Boot apps — ensures app logs land in the same file).

The chaser will print this exact hint if it can't find the log file after a run.

IntelliJ must be open, not minimized to tray, with a recent run config so the Debug shortcut has something to re-run.

## Failure modes

| Symptom | Likely cause |
|---|---|
| `IntelliJ IDEA is not running.` | No `idea64.exe` / `idea.exe` process at all. Start IntelliJ. |
| `IntelliJ IDEA is running ... but no visible window was found.` | Process is up but minimized to system tray. Restore it from the tray. (Minimized to the taskbar is fine — only tray-minimized counts as hidden.) |
| `[chaser] no IntelliJ test runner detected within Ns` | Shift+F9 didn't reach IntelliJ (modal dialog, focus issue, no run config selected). Long-running tests are NOT the cause — once the JVM is detected, the chaser waits with no timeout. Raise the initial window with `-DetectionWindowSec`. |
| `[chaser] no log file found` (with HINT) | The run config is missing one or both of "Save console output to file" / `-Dlogging.file.name`. Follow the hint. |
| `[chaser] Could not find IntelliJ IDEA data directory` | The user is on IntelliJ 2019 or earlier (legacy path not found), OR has a custom `idea.system.path` set in `idea.vmoptions`/`idea.properties`, OR uses JetBrains Toolbox with "Override data directory". Ask the user for the path to their `testHistory` folder and pass it as `-TestHistoryDir "<path>"` to both scripts. |
| `cannot be loaded because running scripts is disabled` | The skill was invoked with `& "...ps1"` instead of `powershell -ExecutionPolicy Bypass -File`. |
| `[chaser] (no new test results XML ...)` on what was clearly a JUnit run | A large Debug run finalized its test-history XML *after* the grace window closed. IntelliJ writes the XML asynchronously; big suites under the debugger can flush slower than the default 1500 ms. Raise it, e.g. `-TestHistoryGraceMs 5000`. |
| Empty test results section | Last run wasn't a JUnit test run. Normal for build-only runs. |

## What NOT to do

- Do not try to run the scripts yourself by reading them and translating to bash — they use Win32 API and only work on Windows PowerShell.
- Do not re-trigger the skill without an explicit user request.
- Do not hallucinate test results if the chaser output is empty — say the run produced no parseable output and ask the user to check IntelliJ.
- Do not copy the scripts out of the skill into the project folder. They run fine in place.
- Do not pass a `-LogFile` parameter unless the user explicitly asks for the log to be written somewhere other than the project root — the default (`$PWD\debug-capture.log`) is correct.
- Do not pass a `-TestHistoryDir` parameter unless the chaser warned it could not find the data directory automatically — the auto-detection covers the standard modern and legacy paths.
- Do not pass a `-TestHistoryGraceMs` parameter unless a run that clearly executed tests reports `(no new test results XML ...)` — the default 1500 ms is correct for normal runs. Only raise it (e.g. `5000`) for large debug suites whose XML is finalized after the default window.
