# One entry point for the improvement agent. Normally run through agent.cmd.
#   agent            start (opens a status window)   agent off     stop now, safe to unplug the phone
#   agent toggle     on if off, off if on            agent status  print status once
param([string]$Cmd = 'on')
$T = $PSScriptRoot
$stateFile = "$T\state.json"; $stop = "$T\STOP"
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$app = 'io.github.jacob_e_lee.taro_music'

function Get-State { try { Get-Content $stateFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null } }
function Test-Running {
    $s = Get-State
    [bool]($s -and $s.loopPid -and $s.phase -ne 'off' -and (Get-Process -Id $s.loopPid -ErrorAction SilentlyContinue))
}

function Stop-Agent {
    $s = Get-State
    New-Item $stop -Force | Out-Null
    if ($s) { foreach ($id in $s.loopPid, $s.claudePid) { if ($id) { cmd /c "taskkill /PID $id /T /F >nul 2>&1" } } }
    if (& $adb devices | Select-String '\sdevice$') {   # drop the scratch inject.js so the phone is left clean
        & $adb shell rm -f "/sdcard/Android/data/$app/files/inject.js" | Out-Null
        & $adb forward --remove-all | Out-Null
    }
    if ($s) {
        $s.phase = 'off'; $s.claudePid = 0; $s.until = ''
        $s.wip = [bool](git -C (Split-Path $T) status --porcelain)
        [IO.File]::WriteAllText($stateFile, ($s | ConvertTo-Json))
    }
    Write-Host 'Agent stopped. SAFE TO UNPLUG.' -ForegroundColor Green
}

function Start-Agent {
    if (-not (Test-Running)) {
        Remove-Item $stop -ErrorAction SilentlyContinue
        Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$T\agent-loop.ps1`""
        Start-Sleep 2
    }
    Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", 'view'
}

function Get-Frame {   # about 10 lines, no model calls
    $s = Get-State
    $running = Test-Running
    $phase = if (-not $s) { 'never started' } elseif ($running) { $s.phase } elseif ($s.phase -eq 'off') { 'off' } else { 'STOPPED (loop died)' }
    $n = @(& $adb devices | Select-String '\sdevice$').Count
    $todo = if (Test-Path docs\BACKLOG.md) { @(Select-String -Path docs\BACKLOG.md -Pattern '^- \[ \]').Count } else { 0 }
    $l = @("taro agent: $phase")
    if ($s) {
        if ($s.until) { $left = [DateTime]::Parse($s.until) - (Get-Date); if ($left.TotalSeconds -gt 0) { $l[0] += ('  (resumes in {0:hh\:mm\:ss}, at {1:HH:mm})' -f $left, [DateTime]::Parse($s.until)) } }
        $l += "iteration $($s.iter)   failures in a row $($s.fails)   cost `$$([Math]::Round([double]$s.cost, 2))   unfinished edits: $(if ($s.wip) { 'yes' } else { 'no' })"
        $l += "last: $($s.result)"
    }
    $l += "devices attached: $n   backlog open: $todo"
    $l += (git log -3 --format='  %h %s' | ForEach-Object { $_ })
    $l
}

function Show-View {
    $Host.UI.RawUI.WindowTitle = 'taro agent'
    while ($true) {
        $f = Get-Frame
        Clear-Host
        $f | Write-Host
        Write-Host "`n[q] close view   [x] stop agent   [s] start agent" -ForegroundColor DarkGray
        for ($i = 0; $i -lt 10; $i++) {
            try {
                if ([Console]::KeyAvailable) {
                    switch ([Console]::ReadKey($true).KeyChar) {
                        'q' { return }
                        'x' { Stop-Agent; Start-Sleep 2 }
                        's' { if (-not (Test-Running)) { Remove-Item $stop -ErrorAction SilentlyContinue; Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$T\agent-loop.ps1`"" } }
                    }
                }
            } catch {}
            Start-Sleep -Milliseconds 300
        }
    }
}

Set-Location (Split-Path $T)
switch ($Cmd) {
    'on' { Start-Agent }
    'off' { Stop-Agent }
    'toggle' { if (Test-Running) { Stop-Agent } else { Start-Agent } }
    'status' { Get-Frame }
    'view' { Show-View }
    default { Write-Host 'usage: agent [on|off|toggle|status]' }
}
