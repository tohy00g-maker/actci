# actci watcher：看著一個 GitHub repo 開著的 PR，在本機用 act 跑，把判定推回去。
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File watcher.ps1 `
#         -Repo C:\Users\me\src\myrepo -Slug owner/repo
#
# 平常不直接跑這支，用 install_watcher.ps1 裝成排程工作。-Once 給安裝器試跑用。
#
# 日誌寫在 %LOCALAPPDATA%\actci\watcher.log，自己修剪，不靠 stdout 導向。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,          # Windows 或 Linux 路徑都可以
    [Parameter(Mandatory)][string]$Slug,          # owner/repo
    [string]$Event = 'pull_request',
    [string]$Job = '',                             # 只跑這個 job id；空字串 = 該事件下的所有 job
    [int]$IntervalSeconds = 60,
    [string]$Distro = '',
    [string]$State = '',                           # 判定與日誌放哪，預設 %LOCALAPPDATA%\actci
    [int]$TimeoutMinutes = 60,
    [int]$KeepLogLines = 3000,
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Import-Module (Join-Path $PSScriptRoot 'src\actci.psm1') -Force

if ($Distro) { Set-WslDistro $Distro }
$repoLinux = ConvertTo-WslPath $Repo
$store = Initialize-Store (New-Store -Path $State)
$logPath = Join-Path $store.Root 'watcher.log'

# 修剪：每分鐘至少一行，不修剪一年會長到五十萬行。
try {
    if (Test-Path -LiteralPath $logPath) {
        $existing = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
        if ($existing.Count -gt $KeepLogLines) {
            $existing | Select-Object -Last $KeepLogLines | Set-Content -LiteralPath $logPath -Encoding UTF8
        }
    }
} catch {}

function Write-Line([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    # Write-Host，不是 Write-Output：這支函式是被 watcher 迴圈當 -Log 呼叫的，Write-Output 會把
    # 日誌字串混進迴圈的回傳值，$result 就變成一個陣列，找不到 .Action（2026-09-06 第一次安裝踩到）。
    Write-Host $line
    try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch {}
}

$jobText = if ($Job) { "job $Job" } else { '全部 job' }
Write-Line "watcher 啟動：$Slug，repo $repoLinux，事件 $Event，$jobText，每 $IntervalSeconds 秒一圈，發行版 $(Get-WslDistro)，store $($store.Root)"

$result = Start-WatcherLoop -Store $store -Slug $Slug -RepoPath $repoLinux -Event $Event -Job $Job `
    -TimeoutMs ($TimeoutMinutes * 60000) -IntervalSeconds $IntervalSeconds -Once:$Once `
    -Log { param($m) Write-Line $m }

if ($Once) {
    # 給安裝器：這一圈至少要能問到 GitHub 而且沒掛。
    if ($result.Action -in @('ran', 'nothing-to-do')) { exit 0 }
    Write-Line "試跑結果：$($result.Action)"
    exit 1
}
