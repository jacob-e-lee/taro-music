# Push assets/ytm/inject.js to a debug build on a USB-connected phone and restart the app.
#   tool/dev-js.ps1          push and restart
#   tool/dev-js.ps1 -Reset   remove the override (back to the bundled asset) and restart
param([switch]$Reset)
$ErrorActionPreference = 'Stop'

$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) { $adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" }
$app = 'com.example.taro_music'
$dest = "/sdcard/Android/data/$app/files/inject.js"

if ($Reset) {
    & $adb shell rm -f $dest
} else {
    & $adb push "$PSScriptRoot\..\assets\ytm\inject.js" $dest
}
if ($LASTEXITCODE) { exit $LASTEXITCODE }
& $adb shell am force-stop $app
& $adb shell am start -n "$app/.MainActivity" | Out-Null
