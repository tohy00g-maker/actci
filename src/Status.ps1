# 判定 → GitHub commit status 的 state。純對應，不打網路；真正呼叫 gh 的在 GitHub.ps1。
#
# GitHub 的 state 只有 pending / success / failure / error。三種 Outcome 對過去：
#   passed 且 TestsRun > 0   -> success
#   passed 但 TestsRun = 0   -> failure（不是 success，見下）
#   failed                   -> failure
#   errored                  -> error（CI 自己的問題，跟程式碼無關）
#
# 「passed 而 TestsRun = 0 推成 failure」是整個設計最重要的一行。一個沒驗到任何
# 東西的通過，在 PR 上長得跟真的通過一模一樣。既然那個綠勾的用途是讓人不必再想，
# 它就不能在那種情況下是綠的。

$script:DefaultContext = 'actci'

function Get-StatusState {
    param([Parameter(Mandatory)]$Verdict)
    if ($Verdict.Outcome -eq 'errored') { return 'error' }
    if (Test-VerdictTrustworthy $Verdict) { return 'success' }
    return 'failure'
}

function New-StatusPayload {
    # 給 gh api POST repos/{slug}/statuses/{sha} 用的內容。description 上限 140 字。
    param(
        [Parameter(Mandatory)]$Verdict,
        [string]$Context = $script:DefaultContext,
        [string]$TargetUrl = ''
    )
    $description = Get-VerdictHeadline $Verdict
    if ($description.Length -gt 140) { $description = $description.Substring(0, 140) }
    $payload = [ordered]@{
        state       = Get-StatusState $Verdict
        context     = $Context
        description = $description
    }
    if ($TargetUrl) { $payload.target_url = $TargetUrl }
    return $payload
}
