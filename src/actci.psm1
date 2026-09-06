# actci 核心模組：判定、儲存、輸出解析、GitHub status 對應。
# 不碰視窗、不碰 WSL、不碰網路。那些在別的檔案。

Set-StrictMode -Version Latest

foreach ($file in @('Verdict.ps1', 'Parse.ps1', 'Store.ps1', 'Status.ps1', 'Wsl.ps1', 'Engine.ps1', 'GitHub.ps1', 'Watcher.ps1')) {
    . (Join-Path $PSScriptRoot $file)
}

Export-ModuleMember -Function @(
    # Verdict
    'New-Verdict', 'New-VerdictStep', 'Get-IsoNow',
    'Test-VerdictPassed', 'Test-VerdictTrustworthy', 'Get-VerdictHeadline',
    'ConvertTo-VerdictJson', 'ConvertFrom-VerdictJson',
    # Parse
    'Remove-AnsiCodes', 'ConvertFrom-ActOutput', 'Get-TestsRun',
    # Store
    'New-Store', 'Initialize-Store', 'Save-Verdict', 'Get-StoredVerdict',
    'Get-RecentVerdicts', 'Write-Heartbeat', 'Get-HeartbeatAge',
    # Status
    'Get-StatusState', 'New-StatusPayload',
    # Wsl
    'Get-WslDistro', 'Set-WslDistro', 'ConvertTo-BashArg', 'ConvertTo-WinArg', 'ConvertTo-WslPath',
    'ConvertFrom-WslBytes', 'New-WslStartInfo', 'Invoke-Wsl', 'Get-WslDistros',
    # Engine
    'Get-RepoHeadSha', 'Test-ActPreflight', 'New-ActCommand', 'Invoke-ActRun', 'Complete-ActVerdict',
    # GitHub
    'Invoke-Gh', 'Test-GhAuth', 'Send-CommitStatus', 'Send-PendingStatus', 'Get-OpenPullRequests',
    # Watcher
    'Get-WatcherConfigPath', 'Save-WatcherConfig', 'Get-WatcherConfig', 'Update-PullRequestRef',
    'Invoke-WatcherRun', 'Invoke-WatcherTick', 'Start-WatcherLoop'
)
