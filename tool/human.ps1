# Sloppy-human touch driver: offset taps, wobbly drags, long presses, abandoned gestures.
#   human.ps1 tap X Y | hold X Y | swipe X1 Y1 X2 Y2 | wander [N]
# wander does N random gestures (default 10; mostly swipes and long presses) and logs them to tool/.gestures.txt.
# Exit 3 if the phone is not in portrait or the app lost focus (it never keeps driving another app).
param([string]$Cmd, [int]$a, [int]$b, [int]$c, [int]$d)
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$app = 'io.github.jacob_e_lee.taro_music'
$gl = "$PSScriptRoot\.gestures.txt"

function J($v, $r) { [int]($v + (Get-Random -Minimum (-$r) -Maximum ($r + 1))) }
function Sh($s) { & $adb shell $s | Out-Null }
function Ok {
    $t = (& $adb shell "dumpsys window | grep -E 'mCurrentFocus|mCurrentRotation'") -join ' '
    ($t -match $app) -and ($t -match 'mCurrentRotation=(ROTATION_)?0')
}

function Tap($x, $y) { $x = J $x 8; $y = J $y 8; Sh "input swipe $x $y $x $y $(Get-Random -Minimum 40 -Maximum 130)" }
function Hold($x, $y) { $x = J $x 6; $y = J $y 6; Sh "input swipe $x $y $x $y $(Get-Random -Minimum 450 -Maximum 950)" }
function Swipe($x1, $y1, $x2, $y2) {
    if ((Get-Random -Maximum 2) -eq 0) { Sh "input swipe $(J $x1 10) $(J $y1 10) $(J $x2 10) $(J $y2 10) $(Get-Random -Minimum 120 -Maximum 450)"; return }
    $cmd = "input motionevent DOWN $x1 $y1"   # slow drag with a wobble, uneven timing
    for ($i = 1; $i -le 6; $i++) {
        $f = $i / 6
        $cmd += "; sleep 0.0$(Get-Random -Minimum 1 -Maximum 5); input motionevent MOVE $(J ($x1 + ($x2 - $x1) * $f) 12) $([int]($y1 + ($y2 - $y1) * $f))"
    }
    Sh "$cmd; input motionevent UP $x2 $y2"
}
function Abandon($x, $y) { Sh "input motionevent DOWN $x $y; sleep 0.1; input motionevent MOVE $(J $x 25) $(J $y 40); sleep 0.1; input motionevent UP $(J $x 10) $(J $y 10)" }

if ($Cmd -ne 'wander') {
    switch ($Cmd) { 'tap' { Tap $a $b } 'hold' { Hold $a $b } 'swipe' { Swipe $a $b $c $d } default { Write-Host 'usage: human.ps1 tap|hold|swipe|wander ...'; exit 2 } }
    exit 0
}

if (-not (Ok)) { Write-Host 'ABORT: not portrait or app not focused'; exit 3 }
$size = ((& $adb shell wm size) -join ' ') -replace '.*?(\d+)x(\d+).*', '$1 $2' -split ' '
$W = [int]$size[0]; $H = [int]$size[1]
$n = if ($a) { $a } else { 10 }
Set-Content $gl ''
for ($i = 1; $i -le $n; $i++) {
    $x = Get-Random -Minimum ([int]($W * .05)) -Maximum ([int]($W * .95))
    $y = Get-Random -Minimum ([int]($H * .08)) -Maximum ([int]($H * .92))   # stay off the status and navigation bars
    $roll = Get-Random -Minimum 1 -Maximum 101
    if ($roll -le 35) { $dy = Get-Random -Minimum 250 -Maximum 900; $y2 = if ((Get-Random -Maximum 2)) { [Math]::Max(60, $y - $dy) } else { [Math]::Min($H - 60, $y + $dy) }; $g = "swipe $x,$y -> $x,$y2"; Swipe $x $y $x $y2 }
    elseif ($roll -le 60) { $g = "hold $x,$y"; Hold $x $y }
    elseif ($roll -le 80) { $g = "tap $x,$y"; Tap $x $y }
    elseif ($roll -le 90) { $g = "abandon $x,$y"; Abandon $x $y }
    else { $x2 = [Math]::Max(10, [Math]::Min($W - 10, $x + (Get-Random -Minimum -500 -Maximum 500))); $g = "swipe $x,$y -> $x2,$y"; Swipe $x $y $x2 $y }
    Add-Content $gl "$i $g"
    Start-Sleep -Milliseconds (Get-Random -Minimum 300 -Maximum 1500)
    if (-not (Ok)) { Write-Host "ABORT after gesture $i ($g): app lost focus or rotated"; exit 3 }
}
Write-Host "wander: $n gestures done, list in tool/.gestures.txt"
