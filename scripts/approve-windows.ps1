param(
    [Parameter(Mandatory=$true)][ValidateSet('sweep','on','off','event','startup','monitor')][string]$Mode,
    [string]$ConfigDir = '',
    [string]$StateDir = '',
    [string]$HerdrBin = ''
)
$ErrorActionPreference = 'Stop'
if ($ConfigDir) { $env:HERDR_PLUGIN_CONFIG_DIR = $ConfigDir }
if ($StateDir) { $env:HERDR_PLUGIN_STATE_DIR = $StateDir }
if ($HerdrBin) { $env:HERDR_BIN_PATH = $HerdrBin }
$herdr = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else {
    $cmd = Get-Command 'herdr' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $cmd.Source } else { 'herdr' }
}
$config = $env:HERDR_PLUGIN_CONFIG_DIR
if (-not $config) { throw 'HERDR_PLUGIN_CONFIG_DIR is required' }
$flag = Join-Path $config 'auto-approve'
$state = if ($env:HERDR_PLUGIN_STATE_DIR) { $env:HERDR_PLUGIN_STATE_DIR } else { Join-Path $config 'state' }
$automatic = $Mode -in @('event', 'monitor')
$script:lastContinueAt = @{}

function Number-Setting([string]$Name, [double]$Default) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    $parsed = 0.0
    if ($value -and [double]::TryParse($value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -ge 0) { return $parsed }
    return $Default
}
function Invoke-Herdr([string[]]$Arguments, [int]$TimeoutMs = 0) {
    if ($TimeoutMs -le 0) { $TimeoutMs = [int](Number-Setting 'APPROVE_CMD_TIMEOUT_MS' 4000) }
    $argString = ($Arguments | ForEach-Object {
        if ($_.Length -eq 0) { '""' }
        elseif ($_ -notmatch '[\s"]') { $_ }
        else { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
    }) -join ' '
    $psi = [Diagnostics.ProcessStartInfo]::new($herdr, $argString)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $null = & taskkill.exe /F /T /PID $proc.Id 2>$null } catch { }
            try { $proc.Kill() } catch { }
            throw "herdr command timed out after ${TimeoutMs}ms: $($Arguments -join ' ')"
        }
        $null = $outTask.Wait(1000)
        if ($proc.ExitCode -ne 0) { throw "herdr command failed: $($Arguments -join ' ')" }
        $output = $outTask.GetAwaiter().GetResult()
        return ($output -replace "`r`n", "`n").TrimEnd("`r", "`n")
    } finally {
        $proc.Dispose()
    }
}
function Notify([string]$Message) {
    try { $null = Invoke-Herdr @('notification','show',$Message,'--sound','none') } catch { }
}
function New-PluginMutex([string]$Name) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$config/$Name"))).Replace('-','') } finally { $sha.Dispose() }
    return [Threading.Mutex]::new($false, "Local\herdr-approve-all-$hash")
}
function Lock-Mutex($Mutex, [int]$Timeout = 0) {
    try { return $Mutex.WaitOne($Timeout) } catch [Threading.AbandonedMutexException] { return $true }
}
function Test-MonitorRunning {
    $mutex = New-PluginMutex 'monitor'
    $locked = $false
    try {
        $locked = Lock-Mutex $mutex 0
        return (-not $locked)
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
function Stop-Monitor {
    $pidFile = Join-Path $state 'monitor.pid'
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $raw = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
            $parsedPid = 0
            if ([int]::TryParse($raw, [ref]$parsedPid) -and $parsedPid -gt 0 -and $parsedPid -ne $PID) {
                $proc = Get-Process -Id $parsedPid -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -match 'powershell') {
                    Stop-Process -Id $parsedPid -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
    if (-not $env:MOCK_HERDR_DIR) {
        try {
            $orphans = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'approve-windows\.ps1.*monitor' }
            foreach ($o in $orphans) {
                Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}
function Start-Monitor {
    # Probe the same mutex as the worker, rather than trusting a reusable PID.
    if (Test-MonitorRunning) { return }
    $null = New-Item -ItemType Directory -Path $state -Force
    $psExe = Join-Path $PSHOME 'powershell.exe'
    $workerArguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" monitor -ConfigDir "' + $config + '" -StateDir "' + $state + '" -HerdrBin "' + $herdr + '"'
    # When invoked by Herdr on Windows, short-lived action/event/startup hooks
    # may run inside a Job Object that terminates child processes on exit.
    # Spawning via WMI (Win32_Process.Create) places the worker under WmiPrvSE.exe
    # outside the hook's Job Object. Fall back to Start-Process in mock tests.
    if (-not $env:MOCK_HERDR_DIR) {
        try {
            $startupClass = Get-CimClass -ClassName Win32_ProcessStartup -ErrorAction Stop
            $startupInfo = New-CimInstance -CimClass $startupClass -ClientOnly -Property @{ ShowWindow = [uint16]0 }
            $cimResult = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
                CommandLine = ('"' + $psExe + '" ' + $workerArguments)
                ProcessStartupInformation = $startupInfo
            } -ErrorAction Stop
            if ($cimResult -and $cimResult.ReturnValue -eq 0) { return }
        } catch { }
    }
    $null = Start-Process -FilePath $psExe -ArgumentList $workerArguments -WindowStyle Hidden
}
function Test-PromptVisible([string]$Screen) {
    if (-not $Screen) { return $false }
    $rule = [string][char]0x2500
    $cursor = [string][char]0x276f
    $hasCue = $false
    $hasOpt1 = $false
    $matched = $false
    $inUserQuote = $false
    $opt1Pattern = '(?i)^\s*(?:[\u2503\u2502|]\s*)?[' + $cursor + '>]\s*1\.\s+(?:Yes|Allow|Accept)\b'
    $optNPattern = '(?i)^\s*(?:[\u2503\u2502|]\s*)?[2-9]\.\s+(?:Yes|No|Allow|Deny|Accept|Reject)\b'
    $classicLinePattern = '(?i)^\s*(?:[\u2503\u2502|]\s*)?(?:[' + $cursor + '>]\s*\d+\.\s+|1\.\s+(?:Yes|Allow|Accept)\b).*(?:enter to (?:confirm|select)|esc to cancel)'
    $cuePattern = '(?i)Allow (?:sandbox bypass|access|calling|creation|administrator|remote)\b|Accept this file edit\?|Confirm the command is safe|Requesting permission for:|Run this command\?|Reason:\s*outside workspace|Do you want to'
    $footerCuePattern = '(?i)^\s*(?:[\u2503\u2502|]\s*)?(?:.*(?:Navigate|tab Amend|ctrl\+g|enter to (?:confirm|select))|esc to cancel\s*$)'
    $resetActivityPattern = '(?i)Running command\.\.\.|Reading file\.\.\.|Editing file|Thinking\.\.\.|Loading\.\.\.|Thought for \d|\d+(?:\.\d+)?k\s+in\s*\||Conversation compacted'
    foreach ($line in ($Screen -split "\r?\n")) {
        if ($line -match ('^\s*' + $rule + '{10,}\s*$') -and $line -notmatch '^\s*[\u2503\u2502|]') {
            $inUserQuote = $false
            continue
        }
        if ($line -match '^\s*>\s*$') { continue }
        if ($line -match $resetActivityPattern) {
            $hasCue = $false; $hasOpt1 = $false; $matched = $false; $inUserQuote = $false
            continue
        }
        if (-not $inUserQuote -and $line -match $classicLinePattern) {
            $hasOpt1 = $true; $matched = $true
            continue
        }
        if (-not $inUserQuote -and $line -match $opt1Pattern) {
            $hasOpt1 = $true
            if ($hasCue) { $matched = $true }
            continue
        }
        if ($line -match '^\s*>') {
            $inUserQuote = $true
            $hasCue = $false; $hasOpt1 = $false; $matched = $false
            continue
        }
        if ($inUserQuote) {
            if ($line -match '^\s*$' -or ($line -match '^\s+' -and $line -notmatch '^\s*[\u2503\u2502|\u25cf\u25cb\u273b]')) {
                continue
            }
            $inUserQuote = $false
        }
        if ($hasOpt1 -and ($line -match $optNPattern -or $line -match $footerCuePattern)) {
            $matched = $true
            continue
        }
        if ($line -match $cuePattern) {
            $hasCue = $true
            continue
        }
        if (-not $matched -and $hasOpt1 -and $line -notmatch '^\s*$') {
            $hasOpt1 = $false
        }
    }
    return $matched
}
function Test-FalseBlockedScreen([string]$Screen) {
    if (-not $Screen) { return $false }
    $rule = [string][char]0x2500
    return ($Screen -match ($rule + '{20,}\r?\n\s*>\s*\r?\n' + $rule + '{20,}') -and $Screen -match '(?i)Running command\.\.\.|Reading file\.\.\.|Thinking\.\.\.|Press up to edit queued messages')
}
function Test-ContinueNeeded([string]$Screen) {
    if (-not $Screen) { return $false }
    $rule = [string][char]0x2500
    $matched = $false
    $sawErrorId = $false
    $box = 0
    $errPattern = '(?i)There was a network issue connecting to the server,\s*please try again\.|agent executor error:|stream reading error:|stream idle timeout|context deadline exceeded'
    foreach ($line in ($Screen -split "\r?\n")) {
        if ($line -notmatch '^\s*>' -and $line -match $errPattern) {
            $matched = $true
            $sawErrorId = $false
            $box = 0
            continue
        }
        if ($matched) {
            if ($line -match '^\s*$') { continue }
            if ($line -match '(?i)^\s*Error ID:\s*\S+') { $sawErrorId = $true; continue }
            if ($box -eq 0 -and -not $sawErrorId -and $line -notmatch '^\s*>' -and $line -match '(?i)generating and executing|stream|timeout|deadline exceeded|please try again') { continue }
            if ($box -eq 0 -and $line -match ('^\s*' + $rule + '{10,}\s*$')) { $box = 1; continue }
            if ($box -eq 1 -and $line -match '^\s*>\s*$') { $box = 2; continue }
            if ($box -eq 2 -and $line -match ('^\s*' + $rule + '{10,}\s*$')) { $box = 3; continue }
            if ($box -eq 3) {
                if ($line -match '(?i)Running command|Reading file|Thinking') { $matched = $false; $box = 0 }
                continue
            }
            $matched = $false
            $sawErrorId = $false
            $box = 0
        }
    }
    return ($matched -and ($box -eq 0 -or $box -eq 3))
}
function Test-CtrlKNeeded([string]$Screen) {
    if (-not $Screen) { return $false }
    $rule = [string][char]0x2500
    $hasHeader = $false
    $matched = $false
    $box = 0
    foreach ($line in ($Screen -split "\r?\n")) {
        if ($line -match ('^\s*' + $rule + '{10,}\s*$') -and $line -notmatch '^\s*[\u2503\u2502|]') {
            if ($matched) {
                if ($box -eq 0) { $box = 1; continue }
                if ($box -eq 2 -or $box -eq 1 -or $box -eq 3) { $box = 3; continue }
            }
            continue
        }
        if ($line -match '^\s*>') {
            if ($matched -and ($box -eq 1 -or $box -eq 2) -and $line -match '^\s*>\s*$') { $box = 2; continue }
            $hasHeader = $false
            $matched = $false
            $box = 0
            continue
        }
        if ($line -match '(?i)\bneeds approval(?:\s+for)?\b') {
            $hasHeader = $true
        }
        if ($line -match '(?i)\bctrl\+k\s+(?:to\s+)?approve\b' -and ($hasHeader -or $line -match '(?i)\balt\+j\s+manage\b' -or $line -match '^\s*[\u2503\u2502|]')) {
            $matched = $true
            $box = 0
            continue
        }
        if ($matched) {
            if ($line -match '^\s*$' -or $line -match '^\s*[\u2503\u2502|\u2514\u251c\u21b3\u25cf\u25cb\u273b\u2800-\u28ff]') { continue }
            if (($box -eq 0 -or $box -eq 1 -or $box -eq 3) -and $line -match '(?i)^\s*(?:\?\s+for\s+shortcuts|esc\s+to\s+cancel|\S.*(?:accept-edits|request-review|auto-approve|subagent\(s\)))') { continue }
            $matched = $false
            $box = 0
        }
    }
    return ($matched -and ($box -eq 0 -or $box -eq 1 -or $box -eq 3))
}
function Get-PaneAction([string]$Pane, [string]$KnownStatus = '') {
    try {
        $status = if ($KnownStatus) { $KnownStatus } else {
            [string](Invoke-Herdr @('agent','get',$Pane) | ConvertFrom-Json).result.agent.agent_status
        }
        if ($status -eq 'blocked') {
            if ($env:APPROVE_SCRAPE_FALLBACK -ne '0') {
                try {
                    $bScreen = Invoke-Herdr @('agent','read',$Pane,'--source','visible','--lines','40')
                    if ($bScreen) {
                        if (Test-CtrlKNeeded $bScreen) { return 'ctrl+k' }
                        if (Test-PromptVisible $bScreen) { return 'approve' }
                        if (Test-ContinueNeeded $bScreen) { return 'continue' }
                        if (Test-FalseBlockedScreen $bScreen) { return '' }
                    }
                } catch { }
            }
            return 'approve'
        }
        if ($env:APPROVE_SCRAPE_FALLBACK -eq '0') { return '' }
        $screen = Invoke-Herdr @('agent','read',$Pane,'--source','visible','--lines','40')
        if (Test-CtrlKNeeded $screen) { return 'ctrl+k' }
        if (Test-PromptVisible $screen) { return 'approve' }
        if (Test-ContinueNeeded $screen) { return 'continue' }
        return ''
    } catch { Write-Warning "Could not inspect pane ${Pane}: $_"; return '' }
}
function Needs-Approval([string]$Pane, [string]$KnownStatus = '') {
    return ((Get-PaneAction $Pane $KnownStatus) -ne '')
}
function Get-SortedAgents {
    $agents = @((Invoke-Herdr @('agent','list') | ConvertFrom-Json).result.agents)
    return @($agents | Sort-Object {
        $st = [string]$_.agent_status
        $foc = [bool]$_.focused
        if ($st -eq 'blocked') { 0 }
        elseif ($st -eq 'working' -and $foc) { 1 }
        elseif ($st -eq 'working') { 2 }
        elseif ($foc) { 3 }
        else { 4 }
    })
}
function Approve-Pane([string]$Pane, [string]$Agent, [string]$InitialStatus = '') {
    $mutex = New-PluginMutex "pane/$Pane"
    $locked = $false
    try {
        $locked = Lock-Mutex $mutex
        if (-not $locked) { return '-' }
        $keys = @('enter')
        $keyfile = Join-Path $config 'keys.conf'
        if (Test-Path -LiteralPath $keyfile) {
            foreach ($line in Get-Content -LiteralPath $keyfile) {
                if ($line.StartsWith("$Agent=")) { $keys = @($line.Substring($Agent.Length + 1).Trim() -split '\s+' | Where-Object { $_ }); break }
            }
        }
        $sent = 0
        $lastAction = ''
        $cleared = $false
        $max = [int](Number-Setting 'APPROVE_MAX_SENDS' 5)
        $settleMs = [int](1000 * (Number-Setting 'APPROVE_SETTLE_SEC' 0.12))
        while ($sent -lt $max -and $keys.Count -gt 0) {
            $hint = if ($sent -eq 0) { $InitialStatus } else { '' }
            $action = Get-PaneAction $Pane $hint
            if (-not $action) { $cleared = $true; break }
            if ($automatic -and -not (Test-Path -LiteralPath $flag)) { break }
            $timeout = [int](Number-Setting 'APPROVE_LEAVE_TIMEOUT_MS' 1200)
            if ($action -eq 'continue') {
                $cooldown = Number-Setting 'APPROVE_CONTINUE_COOLDOWN_SEC' 4
                if ($script:lastContinueAt.ContainsKey($Pane) -and (([DateTime]::UtcNow - $script:lastContinueAt[$Pane]).TotalSeconds -lt $cooldown)) {
                    break
                }
                try {
                    $null = Invoke-Herdr @('agent','prompt',$Pane,'continue')
                } catch {
                    try { $null = Invoke-Herdr @('agent','send-keys',$Pane,'c','o','n','t','i','n','u','e','enter') } catch { break }
                }
                $script:lastContinueAt[$Pane] = [DateTime]::UtcNow
                $sent++
                $lastAction = 'continue'
                try { $null = Invoke-Herdr @('agent','wait',$Pane,'--until','working','--timeout',"$timeout") ([Math]::Max(2000, $timeout + 1500)) } catch { }
                Start-Sleep -Milliseconds $settleMs
                $cleared = $true
                break
            }
            if ($action -eq 'ctrl+k') {
                try { $null = Invoke-Herdr @('agent','send-keys',$Pane,'ctrl+k') } catch { break }
                $sent++
                $lastAction = 'ctrl+k'
                if ($hint -eq 'blocked') {
                    try { $null = Invoke-Herdr @('agent','wait',$Pane,'--until','idle','--until','working','--until','done','--timeout',"$timeout") ([Math]::Max(2000, $timeout + 1500)) } catch { }
                }
                Start-Sleep -Milliseconds $settleMs
                if ($automatic -and $hint -and $hint -ne 'blocked') { $cleared = $true; break }
                continue
            }
            try { $null = Invoke-Herdr (@('agent','send-keys',$Pane) + $keys) } catch { break }
            $sent++
            $lastAction = 'approve'
            if (-not $hint -or $hint -eq 'blocked') {
                try { $null = Invoke-Herdr @('agent','wait',$Pane,'--until','idle','--until','working','--until','done','--timeout',"$timeout") ([Math]::Max(2000, $timeout + 1500)) } catch { }
            }
            Start-Sleep -Milliseconds $settleMs
            if ($automatic -and $hint -and $hint -ne 'blocked') { $cleared = $true; break }
        }
        if ($sent -eq 0) { return '-' }
        if ($cleared -or $lastAction -eq 'continue') { return '1' }
        $remaining = Get-PaneAction $Pane
        if ($remaining -eq 'approve' -or $remaining -eq 'ctrl+k') { return '0' }
        return '1'
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

switch ($Mode) {
    'on' {
        $null = New-Item -ItemType Directory -Path $config -Force
        $null = New-Item -ItemType File -Path $flag -Force
        Stop-Monitor
        Start-Monitor
        Notify 'Auto-approve ON'
    }
    'off' {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
        Stop-Monitor
        Notify 'Auto-approve OFF'
    }
    'event' {
        if (-not (Test-Path -LiteralPath $flag) -or -not $env:HERDR_PLUGIN_EVENT_JSON) { return }
        $monitorRunning = Test-MonitorRunning
        if (-not $monitorRunning) { Start-Monitor }
        $eventData = ($env:HERDR_PLUGIN_EVENT_JSON | ConvertFrom-Json).data
        if ($eventData.pane_id) {
            $paneId = [string]$eventData.pane_id
            $agentName = [string]$eventData.agent
            $statusHint = if ($eventData.agent_status -eq 'blocked') { 'blocked' } else { [string]$eventData.agent_status }
            if ($statusHint -eq 'blocked' -or -not $monitorRunning) {
                $res = Approve-Pane $paneId $agentName $statusHint
                if ($res -eq '-' -and $statusHint -ne 'blocked') {
                    Start-Sleep -Milliseconds 120
                    $null = Approve-Pane $paneId $agentName ''
                }
            }
        }
    }
    'startup' {
        if (Test-Path -LiteralPath $flag) { Start-Monitor }
    }
    'monitor' {
        $mutex = New-PluginMutex 'monitor'
        $locked = $false
        $pidFile = Join-Path $state 'monitor.pid'
        $logFile = Join-Path $state 'monitor.log'
        try {
            # Allow an exiting worker to release the lock after a rapid OFF/ON.
            $locked = Lock-Mutex $mutex 10000
            if (-not $locked) { return }
            $null = New-Item -ItemType Directory -Path $state -Force
            Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII -ErrorAction SilentlyContinue
            $idleCache = @{}
            $tick = 0
            while (Test-Path -LiteralPath $flag) {
                $tick++
                try {
                    # Status events are only hints: stacked or misdetected prompts
                    # may never produce another blocked transition. Prioritize red
                    # (blocked) panes first, then focused/working panes.
                    $agents = Get-SortedAgents
                    foreach ($agent in $agents) {
                        if (-not (Test-Path -LiteralPath $flag)) { break }
                        $paneId = [string]$agent.pane_id
                        $status = [string]$agent.agent_status
                        $isFocused = [bool]$agent.focused
                        if ($status -in @('idle', 'done') -and -not $isFocused) {
                            $stateKey = "${status}:$($agent.state_change_seq):$($agent.revision)"
                            if ($idleCache[$paneId] -eq $stateKey -and ($tick % 10) -ne 0) {
                                continue
                            }
                            $idleCache[$paneId] = $stateKey
                        } else {
                            $null = $idleCache.Remove($paneId)
                        }
                        $result = Approve-Pane $paneId ([string]$agent.agent) $status
                        if ($result -eq '1' -or $result -eq '0') {
                            $null = $idleCache.Remove($paneId)
                            try { Set-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) pane=$paneId result=$result" -ErrorAction SilentlyContinue } catch { }
                        }
                    }
                } catch {
                    # Herdr may be restarting. Keep the persisted toggle and retry.
                    try { Set-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $_" -ErrorAction SilentlyContinue } catch { }
                }
                Start-Sleep -Milliseconds ([Math]::Max(80, [int](1000 * (Number-Setting 'APPROVE_AUTO_POLL_SEC' 0.15))))
            }
        } finally {
            if ($locked) { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue; $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
    'sweep' {
        $mutex = New-PluginMutex 'sweep'
        $locked = $false
        try {
            try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
            if (-not $locked) { return }
            $agents = Get-SortedAgents
            $approved = 0; $stuck = 0
            foreach ($agent in $agents) {
                $result = Approve-Pane ([string]$agent.pane_id) ([string]$agent.agent) ([string]$agent.agent_status)
                if ($result -eq '1') { $approved++ } elseif ($result -eq '0') { $stuck++ }
            }
            if ($approved -or $stuck) { Notify "Approved $approved agents; $stuck still blocked" }
        } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    }
}
