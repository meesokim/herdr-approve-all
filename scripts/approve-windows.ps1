param([Parameter(Mandatory=$true)][ValidateSet('sweep','on','off','event','startup','monitor')][string]$Mode)
$ErrorActionPreference = 'Stop'
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
function Start-Monitor {
    # Probe the same mutex as the worker, rather than trusting a reusable PID.
    $mutex = New-PluginMutex 'monitor'
    $locked = $false
    try {
        $locked = Lock-Mutex $mutex
        if (-not $locked) { return }
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    $null = New-Item -ItemType Directory -Path $state -Force
    $workerArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" monitor'
    # A detached worker is independent of Herdr's short-lived action/event jobs.
    # It inherits HERDR_BIN_PATH and the socket/named-pipe invocation context.
    $null = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $workerArguments -WindowStyle Hidden
}
function Test-PromptVisible([string]$Screen) {
    if (-not $Screen) { return $false }
    $rule = [string][char]0x2500
    $cursor = [string][char]0x276f
    # Strip conversation history above an active composer box so markdown lists
    # or user-pasted prompt text in scrollback never false-trigger while working.
    $composerPattern = '(?s)^.*' + $rule + '{20,}\r?\n(?:\s*>[^\r\n]*\r?\n)+' + $rule + '{20,}\r?\n'
    $active = $Screen -replace $composerPattern, ''
    $selectedYesPattern = '(?im)^\s*[' + $cursor + '>]\s*1\.\s+(?:Yes|Allow)\b'
    $secondOptionPattern = '(?im)^\s*2\.\s+(?:Yes|No|Allow|Deny)\b'
    $dialogCuePattern = '(?i)esc to cancel|Navigate|enter to (?:confirm|select)|Requesting permission for:|Run this command\?|Allow (?:sandbox bypass|access)\b|Reason:\s*outside workspace|Do you want to'
    if ($active -match $selectedYesPattern -and ($active -match $secondOptionPattern -or $active -match $dialogCuePattern)) {
        return $true
    }
    $classicChoicePattern = '(?im)^\s*(?:[' + $cursor + '>]\s*\d+\.\s+|1\.\s+(?:Yes|Allow)\b)|enter to (?:confirm|select)'
    return ($active -match '(?i)esc to cancel' -and $active -match $classicChoicePattern)
}
function Test-ContinueNeeded([string]$Screen) {
    if (-not $Screen) { return $false }
    $rule = [string][char]0x2500
    # Match transient network errors at the bottom of the transcript right above
    # an empty composer box (or end of screen), ignoring user-quoted (> ...) lines.
    $pattern = '(?is)(?:^|\r?\n)\s*(?!>)[^\r\n>]*?There was a network issue connecting to the server,\s*please try again\.\s*(?:\r?\n\s*Error ID:\s*[^\r\n]+)?\s*(?:$|\r?\n' + $rule + '{20,}\r?\n\s*>\s*\r?\n' + $rule + '{20,})'
    return ($Screen -match $pattern)
}
function Test-CtrlKNeeded([string]$Screen) {
    if (-not $Screen) { return $false }
    $rule = [string][char]0x2500
    $hasHeader = $false
    $inUser = $false
    $matched = $false
    $box = 0
    foreach ($line in ($Screen -split "\r?\n")) {
        if ($line -match ('^\s*' + $rule + '{20,}\s*$') -and $line -notmatch '^\s*[\u2503\u2502|]') {
            if ($matched) {
                if ($box -eq 0) { $box = 1; continue }
                if ($box -eq 2) { $box = 3; continue }
            }
            $inUser = $false
            continue
        }
        if ($line -match '^\s*>') {
            if ($matched -and ($box -eq 1 -or $box -eq 2)) { $box = 2; continue }
            $inUser = $true
            $hasHeader = $false
            $matched = $false
            $box = 0
            continue
        }
        if ($line -notmatch '^\s*[\u2503\u2502|]') {
            $inUser = $false
        }
        if (-not $inUser -and $line -match '(?i)\bneeds approval(?:\s+for)?\b') {
            $hasHeader = $true
        }
        if (-not $inUser -and $line -match '(?i)\bctrl\+k\s+(?:to\s+)?approve\b' -and ($hasHeader -or $line -match '(?i)\balt\+j\s+manage\b' -or $line -match '^\s*[\u2503\u2502|]')) {
            $matched = $true
            $box = 0
            continue
        }
        if ($matched) {
            if ($line -match '^\s*$' -or $line -match '^\s*[\u2503\u2502|\u2514\u251c\u25cf\u273b\u2800-\u28ff]') { continue }
            if (($box -eq 0 -or $box -eq 3) -and $line -match '(?i)^\s*(?:\?\s+for\s+shortcuts|esc\s+to\s+cancel|\S.*(?:accept-edits|request-review|auto-approve))') { continue }
            $matched = $false
            $box = 0
        }
    }
    return ($matched -and ($box -eq 0 -or $box -eq 3))
}
function Get-PaneAction([string]$Pane, [string]$KnownStatus = '') {
    try {
        $status = if ($KnownStatus) { $KnownStatus } else {
            [string](Invoke-Herdr @('agent','get',$Pane) | ConvertFrom-Json).result.agent.agent_status
        }
        if ($status -eq 'blocked') { return 'approve' }
        if ($env:APPROVE_SCRAPE_FALLBACK -eq '0') { return '' }
        $screen = Invoke-Herdr @('agent','read',$Pane,'--source','visible','--lines','28')
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
        switch ([string]$_.agent_status) {
            'blocked' { 0 }
            'working' { 1 }
            default   { 2 }
        }
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
        $max = [int](Number-Setting 'APPROVE_MAX_SENDS' 5)
        while ($sent -lt $max -and $keys.Count -gt 0) {
            $hint = if ($sent -eq 0) { $InitialStatus } else { '' }
            $action = Get-PaneAction $Pane $hint
            if (-not $action) { break }
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
                Start-Sleep -Milliseconds ([int](1000 * (Number-Setting 'APPROVE_SETTLE_SEC' 0.25)))
                break
            }
            if ($action -eq 'ctrl+k') {
                try { $null = Invoke-Herdr @('agent','send-keys',$Pane,'ctrl+k') } catch { break }
                $sent++
                $lastAction = 'ctrl+k'
                if ($hint -eq 'blocked') {
                    try { $null = Invoke-Herdr @('agent','wait',$Pane,'--until','idle','--until','working','--until','done','--timeout',"$timeout") ([Math]::Max(2000, $timeout + 1500)) } catch { }
                }
                Start-Sleep -Milliseconds ([int](1000 * (Number-Setting 'APPROVE_SETTLE_SEC' 0.25)))
                continue
            }
            try { $null = Invoke-Herdr (@('agent','send-keys',$Pane) + $keys) } catch { break }
            $sent++
            $lastAction = 'approve'
            if (-not $hint -or $hint -eq 'blocked') {
                try { $null = Invoke-Herdr @('agent','wait',$Pane,'--until','idle','--until','working','--until','done','--timeout',"$timeout") ([Math]::Max(2000, $timeout + 1500)) } catch { }
            }
            Start-Sleep -Milliseconds ([int](1000 * (Number-Setting 'APPROVE_SETTLE_SEC' 0.25)))
        }
        if ($sent -eq 0) { return '-' }
        if ($lastAction -eq 'continue') { return '1' }
        $remaining = Get-PaneAction $Pane
        if ($remaining -eq 'approve' -or $remaining -eq 'ctrl+k') { return '0' }
        return '1'
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

switch ($Mode) {
    'on' {
        $null = New-Item -ItemType Directory -Path $config -Force
        $null = New-Item -ItemType File -Path $flag -Force
        Start-Monitor
        Notify 'Auto-approve ON'
    }
    'off' {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
        Notify 'Auto-approve OFF'
    }
    'event' {
        if (-not (Test-Path -LiteralPath $flag) -or -not $env:HERDR_PLUGIN_EVENT_JSON) { return }
        Start-Monitor
        $eventData = ($env:HERDR_PLUGIN_EVENT_JSON | ConvertFrom-Json).data
        if ($eventData.agent_status -eq 'blocked' -and $eventData.pane_id) {
            $null = Approve-Pane ([string]$eventData.pane_id) ([string]$eventData.agent) 'blocked'
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
            Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII
            while (Test-Path -LiteralPath $flag) {
                try {
                    # Status events are only hints: stacked or misdetected prompts
                    # may never produce another blocked transition. Prioritize red
                    # (blocked) panes first, then green (working) panes.
                    $agents = Get-SortedAgents
                    foreach ($agent in $agents) {
                        if (-not (Test-Path -LiteralPath $flag)) { break }
                        $result = Approve-Pane ([string]$agent.pane_id) ([string]$agent.agent) ([string]$agent.agent_status)
                        if ($result -eq '1' -or $result -eq '0') {
                            Set-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) pane=$($agent.pane_id) result=$result"
                        }
                    }
                } catch {
                    # Herdr may be restarting. Keep the persisted toggle and retry.
                    Set-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) $_"
                }
                Start-Sleep -Milliseconds ([Math]::Max(100, [int](1000 * (Number-Setting 'APPROVE_AUTO_POLL_SEC' 0.3))))
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
