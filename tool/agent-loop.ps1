# Autonomous improvement loop. Started hidden by tool/agent.ps1. Never prompts a human.
# Stop: `agent off` (or create tool/STOP). Survives token limits (sleeps until reset), unplugging the phone, crashes.
$ErrorActionPreference = 'Continue'
$T = $PSScriptRoot
Set-Location (Split-Path $T)
$stop = "$T\STOP"; $stateFile = "$T\state.json"; $log = "$T\agent.log"
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$claude = if ($env:AGENT_CLAUDE) { $env:AGENT_CLAUDE } else { (Get-Command claude -ErrorAction SilentlyContinue).Source }
$IterTimeoutMin = 30
$MinGapSec = 20   # keeps an idle agent from spinning on tokens

# Stop Windows idle-sleeping while the loop runs; released automatically when this process ends.
Add-Type -Namespace W -Name P -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
[void][W.P]::SetThreadExecutionState(0x80000001)

# Real phone only (no emulators): every adb call in every child script targets it.
$env:ANDROID_SERIAL = "RFGL34ZRQ2H"

$S = [ordered]@{ loopPid = $PID; claudePid = 0; phase = 'starting'; iter = 0; item = ''; result = ''; fails = 0; cost = 0.0; until = ''; wip = $false; limitHits = 0 }
try {
    $old = Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($old.loopPid -ne $PID -and $old.phase -ne 'off' -and (Get-Process -Id $old.loopPid -ErrorAction SilentlyContinue)) { exit }  # already running
    $S.iter = [int]$old.iter; $S.cost = [double]$old.cost
} catch {}

function Save { try { [IO.File]::WriteAllText($stateFile, ($S | ConvertTo-Json)) } catch {} }
function Devices { @(& $adb devices | Select-String '\sdevice$') }
function Stopped { Test-Path $stop }
function Say($m) { Add-Content $log "$((Get-Date).ToString('s')) $m" }

function Wait-For($sec, $phase) {
    $end = (Get-Date).AddSeconds($sec)
    $S.phase = $phase; $S.until = $end.ToString('o'); Save
    while ((Get-Date) -lt $end -and -not (Stopped)) { Start-Sleep 3 }
    $S.until = ''; Save
}
function Wait-Phone {
    $S.phase = 'waiting-for-phone'; Save
    while (-not (Devices) -and -not (Stopped)) { Start-Sleep 10 }
}
function Kill-Tree($id) { cmd /c "taskkill /PID $id /T /F >nul 2>&1" }

function Run-Claude($text, $turns, $model) {
    $pf = "$T\.prompt.tmp"; $of = "$T\.out.json"; $ef = "$T\.err.txt"
    [IO.File]::WriteAllText($pf, $text)
    Remove-Item $of, $ef -ErrorAction SilentlyContinue
    $a = @('-p', '--output-format', 'json', '--dangerously-skip-permissions', '--max-turns', $turns)
    if ($model) { $a += @('--model', $model) }
    $file = $claude
    if ($claude -match '\.(cmd|bat)$') { $file = 'cmd.exe'; $a = @('/c', $claude) + $a }
    $p = Start-Process $file -ArgumentList $a -RedirectStandardInput $pf -RedirectStandardOutput $of -RedirectStandardError $ef -NoNewWindow -PassThru
    $null = $p.Handle   # without this, ExitCode comes back empty for a redirected Start-Process
    $S.claudePid = $p.Id; Save
    $deadline = (Get-Date).AddMinutes($IterTimeoutMin)
    $hadPhone = [bool](Devices); $lost = $null
    while (-not $p.HasExited) {
        Start-Sleep 3
        if (Stopped) { Kill-Tree $p.Id; return @{ stopped = $true } }
        if ((Get-Date) -gt $deadline) { Kill-Tree $p.Id; return @{ timeout = $true } }
        if ($hadPhone) {   # unplugged: give a 30 s grace, then abandon the iteration (work in progress stays on disk)
            if (Devices) { $lost = $null }
            elseif (-not $lost) { $lost = Get-Date }
            elseif (((Get-Date) - $lost).TotalSeconds -gt 30) { Kill-Tree $p.Id; return @{ unplugged = $true } }
        }
    }
    $S.claudePid = 0
    $raw = Get-Content $of -Raw -ErrorAction SilentlyContinue
    $err = Get-Content $ef -Raw -ErrorAction SilentlyContinue
    $j = $null; try { $j = $raw | ConvertFrom-Json } catch {}
    @{ exit = $p.ExitCode; json = $j; text = "$raw $err" }
}

function Classify($r) {
    $bad = ($r.exit -ne 0) -or (-not $r.json) -or $r.json.is_error
    if (-not $bad) { return 'ok' }
    $t = "$($r.json.result) $($r.text)"
    if ($t -match '(?i)usage limit|rate limit|limit reached|quota|resets? |\b429\b|\b529\b|overloaded') { return 'limit' }
    if ($t -match '(?i)ENOTFOUND|ECONN|ETIMEDOUT|network|fetch failed|getaddrinfo|socket') { return 'net' }
    'fail'
}

function Reset-At($t) {
    if ($t -match '\|(\d{10})\b') { return [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).LocalDateTime }
    if ($t -match '(?i)resets?\s*(?:at\s*)?(\d{1,2})(?::(\d\d))?\s*(am|pm)') {
        $h = [int]$Matches[1]; $m = if ($Matches[2]) { [int]$Matches[2] } else { 0 }; $ap = $Matches[3].ToLower()
        if ($ap -eq 'pm' -and $h -lt 12) { $h += 12 }
        if ($ap -eq 'am' -and $h -eq 12) { $h = 0 }
        $d = (Get-Date).Date.AddHours($h).AddMinutes($m)
        if ($d -le (Get-Date)) { $d = $d.AddDays(1) }
        return $d
    }
    $null
}

# Sleep until the token limit lifts. Zero tokens spent while waiting; one tiny probe call at the end.
function Wait-Limit($r) {
    while (-not (Stopped)) {
        $at = Reset-At "$($r.json.result) $($r.text)"
        $steps = 300, 600, 1200, 1800, 3600
        $sec = if ($at) { [int]([Math]::Max(60, ($at.AddSeconds(60) - (Get-Date)).TotalSeconds)) } else { $steps[[Math]::Min($S.limitHits, 4)] }
        $S.limitHits++
        Say "token limit; waiting ${sec}s"
        Wait-For $sec 'waiting-for-tokens'
        if (Stopped) { return }
        $r = Run-Claude 'Reply ok.' 1 'haiku'
        if ($r.stopped) { return }
        if ((Classify $r) -ne 'limit') { $S.limitHits = 0; return }
    }
}

Remove-Item $stop -ErrorAction SilentlyContinue
if (-not $claude) { $S.phase = 'off'; $S.result = 'claude not found'; Save; exit 1 }

while (-not (Stopped)) {
    $t0 = Get-Date
    $phone = [bool](Devices)
    $S.iter++; $S.phase = 'working'; $S.item = ''; Save
    $head = "PHONE: $(if ($phone) { 'attached' } else { 'absent' })`nITER: $($S.iter)`n"
    $r = Run-Claude ($head + (Get-Content "$T\agent-prompt.md" -Raw)) 80 $env:AGENT_MODEL
    if ($r.stopped) { break }
    $S.wip = [bool](git status --porcelain)
    if ($r.unplugged) { $S.result = 'phone unplugged mid-iteration'; Say $S.result; Wait-Phone; continue }
    if ($r.timeout) { $S.fails++; $S.result = 'iteration timed out'; Say $S.result; Wait-For 60 'backoff'; continue }
    $c = Classify $r
    switch ($c) {
        'ok' {
            $S.fails = 0
            if ($r.json.total_cost_usd) { $S.cost += [double]$r.json.total_cost_usd }
            $res = ([string]$r.json.result).Trim()
            $S.result = if ($res.Length -gt 140) { $res.Substring(0, 140) } else { $res }
            Say "iter $($S.iter) ok: $($S.result)"
            if ($res -match 'NOOP_NO_PHONE') { Wait-Phone }
        }
        'limit' { Say 'limit hit'; Save; Wait-Limit $r }
        'net' { $S.fails++; $S.result = 'network down'; Say $S.result; Wait-For ([Math]::Min(60 * $S.fails, 600)) 'waiting-for-network' }
        default { $S.fails++; $S.result = "claude failed (exit $($r.exit))"; Say "$($S.result): $(([string]$r.text).Substring(0, [Math]::Min(300, ([string]$r.text).Length)))"; Wait-For ([Math]::Min(30 * [Math]::Pow(2, $S.fails), 1800)) 'backoff' }
    }
    $gap = $MinGapSec - ((Get-Date) - $t0).TotalSeconds
    if ($gap -gt 0 -and $c -eq 'ok') { Start-Sleep ([int]$gap) }
}
$S.phase = 'off'; $S.claudePid = 0; Save
