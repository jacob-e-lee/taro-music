# Pre-commit check for the agent. Run with the change still uncommitted.
#   exit 0  pass            exit 1  fail (last line says why: revert the change)
#   exit 2  code changed but no device attached: do not push code (docs-only changes are fine)
# Target an emulator with $env:ANDROID_SERIAL (adb honours it).
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
& "$PSScriptRoot\dev-js.ps1" -Reset   # a scratch override never stays on the phone

Write-Output $probe
if ($probeExit) { Fail 'inject.js did not run on the page (see probe line)' }
if ($err) { Fail "uncaught page error: $($err -join ' ')" }
Write-Output 'GATE OK'
