#requires -Version 5
<#
  build_apk.ps1 — 构建 K酱 的 Android 安装包

  ## 为什么单独写脚本

  与 Windows 版（build_win_kernel.ps1）对齐：两边都必须注入同一组
  弹弹play 凭证，否则「弹幕」这项功能在安卓上是哑的。

  `DANDAN_APPID` / `DANDAN_APPSECRET` 通过 `--dart-define` 编进
  libapp.so（Dart 的 String.fromEnvironment 是编译期常量）。
  不传这两个参数，APK 里搜不到凭证字符串，弹幕接口会 400。

  ## 用法

      .\build_apk.ps1 -DandanAppId '3a7sz6a867' -DandanAppSecret 'xxx'
      .\build_apk.ps1                 # 不注入凭证（弹幕需在设置页手填）

  ## 前置

  - JAVA_HOME  / ANDROID_HOME 需指向 D:\dev\jdk-17.0.20.1+1 与 D:\dev\android-sdk
  - android/gradle.properties 里已配好构建期代理与 UTF-8（见该文件注释）
#>
[CmdletBinding()]
param(
  [string]$DandanAppId     = '',
  [string]$DandanAppSecret = '',
  [string]$TargetPlatform  = '',   # 留空=arm64+armeabi；'android-x64' 用于模拟器验证
  [switch]$SplitPerAbi
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$env:JAVA_HOME     = 'D:\dev\jdk-17.0.20.1+1'
$env:ANDROID_HOME  = 'D:\dev\android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:PATH = "$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:PATH"

$flutter = 'D:\dev\flutter\bin\flutter.bat'

$args_ = @('build', 'apk', '--release')
if ($DandanAppId -and $DandanAppSecret) {
  $args_ += "--dart-define=DANDAN_APPID=$DandanAppId"
  $args_ += "--dart-define=DANDAN_APPSECRET=$DandanAppSecret"
  Write-Host "  注入弹弹play 凭证: $DandanAppId" -ForegroundColor Green
} else {
  Write-Host "  未注入弹弹play 凭证（弹幕需在设置页手填）" -ForegroundColor Yellow
}
if ($TargetPlatform) { $args_ += "--target-platform=$TargetPlatform" }
if ($SplitPerAbi)    { $args_ += '--split-per-abi' }

Write-Host ""
Write-Host "  flutter $($args_ -join ' ')" -ForegroundColor DarkGray
Write-Host ""

& $flutter @args_
if ($LASTEXITCODE -ne 0) {
  Write-Host "  构建失败（exit $LASTEXITCODE）" -ForegroundColor Red
  exit $LASTEXITCODE
}

# ── 校验：凭证确实编进去了 ──
$apk = 'build\app\outputs\flutter-apk\app-release.apk'
if (Test-Path $apk) {
  $size = (Get-Item $apk).Length
  Write-Host ""
  Write-Host "  产物: $apk  $([math]::Round($size/1MB,2))MB" -ForegroundColor Green
  if ($DandanAppId) {
    $bytes = [System.IO.File]::ReadAllBytes($apk)
    $needle = [System.Text.Encoding]::UTF8.GetBytes($DandanAppId)
    $found = $false
    for ($i = 0; $i -le $bytes.Length - $needle.Length; $i++) {
      if ($bytes[$i] -eq $needle[0]) {
        $ok = $true
        for ($j = 1; $j -lt $needle.Length; $j++) {
          if ($bytes[$i + $j] -ne $needle[$j]) { $ok = $false; break }
        }
        if ($ok) { $found = $true; break }
      }
    }
    if ($found) { Write-Host "  ✓ 弹幕凭证已编入 APK" -ForegroundColor Green }
    else        { Write-Host "  ✗ 弹幕凭证未找到 —— 弹幕会失效" -ForegroundColor Red }
  }
}
