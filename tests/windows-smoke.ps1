$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('herdr-approve-test-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $tmp
$workerPid = $null
function Wait-Until([scriptblock]$Condition, [string]$Message) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (& $Condition)) {
        if ($watch.Elapsed.TotalSeconds -gt 45) { throw $Message }
        Start-Sleep -Milliseconds 100
    }
}
function Send-Count {
    if (Test-Path (Join-Path $tmp 'sent')) { return @(Get-Content (Join-Path $tmp 'sent')).Count }
    return 0
}
function Read-PidFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $raw = [IO.File]::ReadAllText($Path).Trim()
        $parsed = 0
        if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    } catch { }
    return 0
}
try {
    $env:HERDR_PLUGIN_CONFIG_DIR = $tmp
    $env:HERDR_PLUGIN_STATE_DIR = Join-Path $tmp 'state'
    $env:HERDR_BIN_PATH = Join-Path $tmp 'herdr.cmd'
    $env:MOCK_HERDR_DIR = $tmp
    $env:APPROVE_AUTO_POLL_SEC = '0.1'
    $env:APPROVE_SETTLE_SEC = '0.01'
    $env:APPROVE_CONTINUE_COOLDOWN_SEC = '0.05'
    $env:APPROVE_CMD_TIMEOUT_MS = '10000'
    $mock = @'
@echo off
if "%1 %2"=="agent list" echo {"result":{"agents":[{"pane_id":"pane-1","agent":"codex"}]}}
if "%1 %2"=="agent get" if exist "%MOCK_HERDR_DIR%\pending" echo {"result":{"agent":{"agent_status":"blocked"}}}
if "%1 %2"=="agent get" if not exist "%MOCK_HERDR_DIR%\pending" echo {"result":{"agent":{"agent_status":"working"}}}
if "%1 %2"=="agent read" if exist "%MOCK_HERDR_DIR%\fallback_screen.txt" type "%MOCK_HERDR_DIR%\fallback_screen.txt"
if "%1 %2"=="agent read" if exist "%MOCK_HERDR_DIR%\fallback" echo 1. Yes - enter to confirm - esc to cancel
if "%1 %2"=="agent send-keys" goto send
if "%1 %2"=="agent prompt" goto prompt
exit /b 0
:send
if exist "%MOCK_HERDR_DIR%\queued" goto stacked
if exist "%MOCK_HERDR_DIR%\pending" del "%MOCK_HERDR_DIR%\pending"
if exist "%MOCK_HERDR_DIR%\fallback" del "%MOCK_HERDR_DIR%\fallback"
if exist "%MOCK_HERDR_DIR%\fallback_screen.txt" del "%MOCK_HERDR_DIR%\fallback_screen.txt"
echo %4 %5>>"%MOCK_HERDR_DIR%\sent"
exit /b 0
:prompt
if exist "%MOCK_HERDR_DIR%\fallback_screen.txt" del "%MOCK_HERDR_DIR%\fallback_screen.txt"
echo prompt:%4>>"%MOCK_HERDR_DIR%\sent"
exit /b 0
:stacked
del "%MOCK_HERDR_DIR%\queued"
echo %4 %5>>"%MOCK_HERDR_DIR%\sent"
exit /b 0
'@
    [IO.File]::WriteAllText($env:HERDR_BIN_PATH, $mock, [Text.Encoding]::ASCII)
    $script = Join-Path $root 'scripts/approve-windows.ps1'
    Set-Content (Join-Path $tmp 'keys.conf') 'codex=y enter'
    Set-Content (Join-Path $tmp 'pending') ''
    Set-Content (Join-Path $tmp 'queued') ''
    & $script sweep
    if ((Send-Count) -ne 2) { throw 'sweep did not drain stacked prompts' }
    if ((Get-Content (Join-Path $tmp 'sent') | Select-Object -First 1).Trim() -ne 'y enter') { throw 'sweep did not send configured keys' }

    # Verify agy sandbox-bypass prompt (no "esc to cancel" footer) is approved while status is working.
    $bypassScreen = @"
Requesting permission for:
   node "C:\scratch\find_reg_mac_formula.js"

Allow sandbox bypass for command execution?
> 1. Yes, run command
  2. Yes, and always allow in this conversation
  3. Yes, and always allow (Persist to settings.json)
  4. No, cancel
"@
    [IO.File]::WriteAllText((Join-Path $tmp 'fallback_screen.txt'), $bypassScreen, [Text.Encoding]::UTF8)
    & $script sweep
    if ((Send-Count) -ne 3) { throw 'sweep missed agy sandbox-bypass prompt without esc to cancel' }

    # Verify agy outside-workspace file access prompt (no "esc to cancel" footer) is approved while status is working.
    $outsideScreen = @"
Reason: outside workspace

Allow access to this file?
> 1. Yes, allow access
  2. No, deny access
"@
    [IO.File]::WriteAllText((Join-Path $tmp 'fallback_screen.txt'), $outsideScreen, [Text.Encoding]::UTF8)
    & $script sweep
    if ((Send-Count) -ne 4) { throw 'sweep missed agy outside-workspace file access prompt' }

    # Verify transient network issue screen submits "continue".
    $rule = ([string][char]0x2500) * 60
    $warn = [string][char]0x26a0
    $netErrorScreen = @"
$warn There was a network issue connecting to the server, please try again.
Error ID: 4e1156e0-393c-4a95-a07c-c79c7e8ec0bb-937

$rule
> 
$rule
? for shortcuts                               accept-edits
"@
    [IO.File]::WriteAllText((Join-Path $tmp 'fallback_screen.txt'), $netErrorScreen, [Text.Encoding]::UTF8)
    & $script sweep
    if ((Send-Count) -ne 5) { throw 'sweep did not submit continue on network error screen' }
    if ((Get-Content (Join-Path $tmp 'sent') | Select-Object -Last 1).Trim() -ne 'prompt:continue') { throw 'sweep did not send continue prompt' }

    # Verify subagent approval banner ("ctrl+k approve · alt+j manage") sends ctrl+k even above an active composer box.
    $bar = [string][char]0x2503
    $dot = [string][char]0x25cf
    $mid = [string][char]0x00b7
    $subagentScreen = @"
$bar self needs approval for Bash
 $bar $rule
 $bar
 $bar $dot Bash(git -C /home-mc/CORP/meeso.kim/GMBT-AX/MX_B2B_Orbit_Dev show --stat prototype/ai-discussion-20261105)
 $bar
 $bar ctrl+k approve $mid alt+j manage
$rule
> 
$rule
? for shortcuts                               accept-edits
"@
    [IO.File]::WriteAllText((Join-Path $tmp 'fallback_screen.txt'), $subagentScreen, [Text.Encoding]::UTF8)
    & $script sweep
    if ((Send-Count) -ne 6) { throw 'sweep did not send ctrl+k on subagent approval screen' }
    if ((Get-Content (Join-Path $tmp 'sent') | Select-Object -Last 1).Trim() -ne 'ctrl+k') { throw 'sweep did not send ctrl+k key' }

    # Verify normal working screen with markdown list + quoted network error + quoted ctrl+k banner + composer box does NOT false-trigger.
    $workingScreen = @"
  1. First normal markdown list item in scrollback
  2. Second normal markdown list item in scrollback
  > 1. Yes, allow access
  > $warn There was a network issue connecting to the server, please try again.
    Error ID: 4e1156e0-393c-4a95-a07c-c79c7e8ec0bb-937
  > $bar self needs approval for Bash
   $bar $rule
   $bar $dot Bash(git status)
   $bar ctrl+k approve $mid alt+j manage

Running command...

$rule
> 
$rule
esc to cancel                               accept-edits
"@
    [IO.File]::WriteAllText((Join-Path $tmp 'fallback_screen.txt'), $workingScreen, [Text.Encoding]::UTF8)
    & $script sweep
    if ((Send-Count) -ne 6) { throw 'sweep falsely triggered on normal working screen with scrollback' }
    Remove-Item -LiteralPath (Join-Path $tmp 'fallback_screen.txt') -Force -ErrorAction SilentlyContinue

    & $script on
    if (-not (Test-Path (Join-Path $tmp 'auto-approve'))) { throw 'on did not create flag' }
    $pidFile = Join-Path $env:HERDR_PLUGIN_STATE_DIR 'monitor.pid'
    Wait-Until { (Read-PidFile $pidFile) -gt 0 } 'monitor did not start'
    $workerPid = Read-PidFile $pidFile
    # No event is dispatched for any of these prompts, including a prompt whose
    # semantic status stays working. The same worker must handle every wave.
    Set-Content (Join-Path $tmp 'pending') ''
    Wait-Until { (Send-Count) -ge 7 } 'first automatic prompt was missed'
    Wait-Until { -not (Test-Path (Join-Path $tmp 'pending')) } 'first prompt did not settle'
    Set-Content (Join-Path $tmp 'pending') ''
    Wait-Until { (Send-Count) -ge 8 } 'second automatic prompt was missed'
    Wait-Until { -not (Test-Path (Join-Path $tmp 'pending')) } 'second prompt did not settle'
    Set-Content (Join-Path $tmp 'fallback') ''
    Wait-Until { (Send-Count) -ge 9 } 'prompt reported as working was missed'
    & $script startup
    if ((Read-PidFile $pidFile) -ne $workerPid) { throw 'startup replaced an active monitor' }
    & $script off
    if (Test-Path (Join-Path $tmp 'auto-approve')) { throw 'off did not remove flag' }
    Wait-Until { -not (Test-Path $pidFile) } 'monitor did not stop after off'
    $count = Send-Count
    Set-Content (Join-Path $tmp 'pending') ''
    $env:HERDR_PLUGIN_EVENT_JSON = '{"data":{"agent_status":"blocked","pane_id":"pane-1","agent":"codex"}}'
    & $script event
    if ((Send-Count) -ne $count) { throw 'disabled auto mode sent keys' }
    # Restore a persisted ON toggle at startup without calling the ON action.
    Set-Content (Join-Path $tmp 'auto-approve') ''
    & $script startup
    Wait-Until { (Send-Count) -gt $count } 'startup did not restore persisted auto mode'
    Wait-Until { (Read-PidFile $pidFile) -gt 0 } 'restored monitor did not write PID'
    $workerPid = Read-PidFile $pidFile
    & $script off
    Wait-Until { -not (Test-Path $pidFile) } 'restored monitor did not stop'
    'Windows smoke test passed'
} finally {
    Remove-Item -LiteralPath (Join-Path $tmp 'auto-approve') -Force -ErrorAction SilentlyContinue
    if ($workerPid) {
        # This PID came from the worker spawned with this test's unique config.
        $worker = Get-Process -Id $workerPid -ErrorAction SilentlyContinue
        if ($worker -and $worker.ProcessName -eq 'powershell') { $worker | Stop-Process -Force }
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
