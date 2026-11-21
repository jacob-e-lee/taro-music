# Pre-commit check for the agent. Run with the change still uncommitted.
#   exit 0  pass            exit 1  fail (last line says why: revert the change)
#   exit 2  code changed but no device attached: do not push code (docs-only changes are fine)
# Always the real phone: adb honours $env:ANDROID_SERIAL (set by agent-loop.ps1).
# -Full also runs the background / screen-off journey (the loop passes it on every 3rd build).
param([switch]$Full)
$root = Split-Path $PSScriptRoot
Set-Location $root
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$flutter = 'C:\Users\jelee\develop\flutter\bin\flutter.bat'
$app = 'io.github.jacob_e_lee.taro_music'
function Fail($m) { Write-Output "GATE FAIL: $m"; exit 1 }

node --check assets/ytm/inject.js
if ($LASTEXITCODE) { Fail 'inject.js syntax error' }

$paths = git status --porcelain | ForEach-Object { $_.Substring(3) -replace '^"|"$', '' }
$code = @($paths | Where-Object { $_ -notmatch '\.md$|^docs/|^tool/' })
if (-not $code) { Write-Output 'GATE OK (no app code changed)'; exit 0 }
if (-not (& $adb devices | Select-String '\sdevice$')) { Write-Output 'GATE NO DEVICE: code changed, do not push it'; exit 2 }

$build = @($code | Where-Object { $_ -ne 'assets/ytm/inject.js' }).Count -gt 0
if ($build) {
    & $flutter build apk --debug | Select-Object -Last 3
    if ($LASTEXITCODE) { Fail 'flutter build' }
    & $adb install -r build/app/outputs/flutter-apk/app-debug.apk | Out-Null
    if ($LASTEXITCODE) { Fail 'adb install' }
}

& $adb logcat -c
& "$PSScriptRoot\dev-js.ps1"
$appPid = ''
for ($i = 0; $i -lt 15 -and -not $appPid; $i++) { Start-Sleep 1; $appPid = (& $adb shell pidof $app) -join '' }
if (-not $appPid) { & "$PSScriptRoot\dev-js.ps1" -Reset; Fail 'app did not start' }
& $adb forward tcp:9222 "localabstract:webview_devtools_remote_$appPid" | Out-Null
$probe = node "$PSScriptRoot\probe.mjs"
$probeExit = $LASTEXITCODE
$err = & $adb logcat -d -s TaroMusic | Select-String 'Uncaught' | Where-Object { $_ -notmatch 'doubleclick|LegacyDataMixin' } | Select-Object -First 2
& $adb forward --remove-all | Out-Null

# Journeys, selector canary, layout and frame baselines run on the live page, with the override still installed.
$bad = ''; $notReady = $false
if (-not $probeExit -and -not $err) {
    $checks = @(@('journeys'), @('selectors'), @('layout'), @('perf'))
    if ($Full) { $checks[0] = @('journeys', '--full') }
    foreach ($c in $checks) {
        $out = node "$PSScriptRoot\journey.mjs" @c
        $code = $LASTEXITCODE
        Write-Output ($out | Select-Object -Last 6)
        if ($code -eq 3) { $notReady = $true; break }
        if ($code) { $bad = "$($c -join ' '): $(($out | Where-Object { $_ -match '^FAIL|^ERROR' } | Select-Object -First 2) -join ' ')"; break }
    }
}
& "$PSScriptRoot\dev-js.ps1" -Reset   # a scratch override never stays on the phone

Write-Output $probe
if ($probeExit) { Fail 'inject.js did not run on the page (see probe line)' }
if ($err) { Fail "uncaught page error: $($err -join ' ')" }
if ($bad) { Fail $bad }
if ($notReady) { Write-Output 'GATE NO DEVICE: phone not on the app in portrait, journeys not run; do not push code'; exit 2 }
Write-Output 'GATE OK'
