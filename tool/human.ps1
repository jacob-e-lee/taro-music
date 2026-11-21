# Sloppy-human touch driver: offset taps, wobbly drags, long presses, abandoned gestures.
#   human.ps1 tap X Y | hold X Y | swipe X1 Y1 X2 Y2   (system-level touches via adb; random wandering lives in oracle.mjs)
param([string]$Cmd, [int]$a, [int]$b, [int]$c, [int]$d)
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"

function J($v, $r) { [int]($v + (Get-Random -Minimum (-$r) -Maximum ($r + 1))) }
function Sh($s) { & $adb shell $s | Out-Null }

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

switch ($Cmd) { 'tap' { Tap $a $b } 'hold' { Hold $a $b } 'swipe' { Swipe $a $b $c $d } default { Write-Host 'usage: human.ps1 tap|hold|swipe X Y [X2 Y2]'; exit 2 } }
