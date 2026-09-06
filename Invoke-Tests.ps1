# 跑全部 Pester 測試。不需要 Docker、WSL 或網路。
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File Invoke-Tests.ps1
#
# 需要 Pester 5：Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
param([switch]$CI)

$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot 'tests'
$config.Run.Exit = $CI.IsPresent
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $CI.IsPresent
$config.TestResult.OutputPath = Join-Path $PSScriptRoot 'testResults.xml'

Invoke-Pester -Configuration $config
