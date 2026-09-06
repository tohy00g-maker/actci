# 一次執行的判定 —— 這套系統裡最重要的資料形狀。
#
# 沿用 localci 的規則：判定一定帶著 TestsRun。一個 Outcome = passed 而
# TestsRun = 0 的結果不是通過，是「沒有驗證」。Test-VerdictTrustworthy 講的
# 就是這件事，而它跟 Test-VerdictPassed 是分開的兩個問題。
#
# 三種 Outcome：
#   passed   通過
#   failed   測試跑了，有紅的 —— 被測程式碼的問題
#   errored  跑不起來 —— CI 自己的問題（Docker 沒開、映像拉不下來、act 掛了）
# 後兩者分開，是為了讓人不要在錯的地方找原因。

$script:VerdictSchema = 1
$script:Outcomes = @('passed', 'failed', 'errored')

function Get-IsoNow {
    [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function New-VerdictStep {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ExitCode,
        [double]$Seconds = 0
    )
    [pscustomobject]@{ Name = $Name; ExitCode = $ExitCode; Seconds = $Seconds }
}

function New-Verdict {
    param(
        [Parameter(Mandatory)][string]$Sha,
        [Parameter(Mandatory)][string]$Repo,
        [string]$Outcome = 'errored',
        [int]$TestsRun = 0,
        [string[]]$TestsSource = @(),
        [string]$Event = '',
        [string]$Job = '',
        [string]$Engine = 'act',
        [string]$Note = ''
    )
    if ($script:Outcomes -notcontains $Outcome) {
        throw "Outcome 必須是 $($script:Outcomes -join ' / ')，收到 '$Outcome'"
    }
    [pscustomobject]@{
        PSTypeName  = 'actci.Verdict'
        Schema      = $script:VerdictSchema
        Sha         = $Sha
        Repo        = $Repo
        Event       = $Event
        Job         = $Job
        Engine      = $Engine
        Outcome     = $Outcome
        TestsRun    = $TestsRun
        TestsSource = [string[]]$TestsSource
        StartedAt   = (Get-IsoNow)
        FinishedAt  = ''
        Seconds     = [double]0
        Steps       = @()
        LogPath     = ''
        Note        = $Note
    }
}

function Test-VerdictPassed {
    param([Parameter(Mandatory)]$Verdict)
    return $Verdict.Outcome -eq 'passed'
}

function Test-VerdictTrustworthy {
    # 通過**而且真的驗過東西**。合併門檻要問這一個，不是問 Test-VerdictPassed。
    param([Parameter(Mandatory)]$Verdict)
    return ($Verdict.Outcome -eq 'passed') -and ($Verdict.TestsRun -gt 0)
}

function Get-VerdictHeadline {
    # 一行話。一定要帶跑了幾支，否則就是在重複 localci 記錄過的那個錯。
    param([Parameter(Mandatory)]$Verdict)
    switch ($Verdict.Outcome) {
        'errored' {
            $note = if ($Verdict.Note) { $Verdict.Note } else { '沒有說明' }
            return "CI 自己出問題：$note"
        }
        'failed' {
            return ('失敗（跑了 {0} 支，{1:0} 秒）' -f $Verdict.TestsRun, $Verdict.Seconds)
        }
    }
    if ($Verdict.TestsRun -le 0) {
        return '沒有抓到任何測試數 —— 這不是通過，是沒有驗證'
    }
    $source = if (@($Verdict.TestsSource).Count -gt 0) { @($Verdict.TestsSource) -join '+' } else { '?' }
    return ('通過（{0} 支，{1:0} 秒，{2}）' -f $Verdict.TestsRun, $Verdict.Seconds, $source)
}

function ConvertTo-VerdictJson {
    param([Parameter(Mandatory)]$Verdict)
    return ($Verdict | ConvertTo-Json -Depth 6)
}

function ConvertFrom-VerdictJson {
    # 不認得的欄位直接丟掉，不要炸。舊的判定檔案在改版之後還要讀得出來。
    param([Parameter(Mandatory)][string]$Json)
    $data = $Json | ConvertFrom-Json
    foreach ($required in 'Sha', 'Repo') {
        if (-not $data.PSObject.Properties[$required]) { throw "判定 JSON 缺少 $required" }
    }
    $v = New-Verdict -Sha ([string]$data.Sha) -Repo ([string]$data.Repo)
    $known = 'Schema', 'Event', 'Job', 'Engine', 'Outcome', 'TestsRun', 'TestsSource',
             'StartedAt', 'FinishedAt', 'Seconds', 'Steps', 'LogPath', 'Note'
    foreach ($name in $known) {
        $prop = $data.PSObject.Properties[$name]
        if (-not $prop) { continue }
        $value = $prop.Value
        switch ($name) {
            'Steps' {
                $v.Steps = @(foreach ($s in @($value)) {
                    if ($null -ne $s) {
                        New-VerdictStep -Name ([string]$s.Name) -ExitCode ([int]$s.ExitCode) -Seconds ([double]$s.Seconds)
                    }
                })
            }
            'TestsSource' { $v.TestsSource = [string[]]@(@($value) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) }
            'TestsRun'    { $v.TestsRun = [int]$value }
            'Seconds'     { $v.Seconds = [double]$value }
            'Schema'      { $v.Schema = [int]$value }
            default       { $v.$name = [string]$value }
        }
    }
    if ($script:Outcomes -notcontains $v.Outcome) {
        # 認不得的結果當成 CI 自己的問題，而不是當成通過。
        $v.Note = "判定檔的 Outcome '$($v.Outcome)' 認不得。$($v.Note)".Trim()
        $v.Outcome = 'errored'
    }
    return $v
}
