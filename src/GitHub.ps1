# 跟 GitHub 講話：推 commit status、列開著的 PR。全部透過 gh。
#
# ## 為什麼用 gh 而不是自己打 API
#
# gh 已經裝好、已經認證。自己處理 token 就多一個要保管的秘密，而這套東西的價值
# 不值得多一個秘密。
#
# ## 這裡不做的事
#
# 不自動合併。這支只負責回報事實，決定權留在人手上 —— 一個既判定又執行的東西，
# 出錯時沒有第二道關。
#
# ## 這裡的函式不丟例外
#
# 呼叫端是 watcher 迴圈；在那裡丟例外會讓整圈停掉，而「沒能回報」不該讓
# 「已經跑完的測試」跟著消失。

function Invoke-Gh {
    # 同步呼叫 gh.exe。回傳 @{ ExitCode; Output; Error }。測試會把這支 Mock 掉。
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$InputText = '',
        [int]$TimeoutMs = 60000
    )
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'gh.exe'
        $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-WinArg $_ }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $p = [System.Diagnostics.Process]::Start($psi)
        if ($InputText) {
            $writer = New-Object System.IO.StreamWriter($p.StandardInput.BaseStream, (New-Object System.Text.UTF8Encoding $false))
            $writer.Write($InputText)
            $writer.Flush()
            $writer.Close()
        } else {
            $p.StandardInput.Close()
        }
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            return [pscustomobject]@{ ExitCode = -1; Output = ''; Error = "gh 逾時（${TimeoutMs} ms）" }
        }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $so.Result.TrimEnd(); Error = $se.Result.TrimEnd() }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = ''; Error = "叫不動 gh：$($_.Exception.Message)" }
    }
}

function Get-GhFailureDetail {
    param($Result)
    $text = if ($Result.Error) { $Result.Error } else { $Result.Output }
    $text = ($text -replace '\s+', ' ').Trim()
    if ($text.Length -gt 300) { $text = $text.Substring($text.Length - 300) }
    if (-not $text) { $text = "gh 離開碼 $($Result.ExitCode)" }
    return $text
}

function Test-GhAuth {
    # 回傳 @{ Ok; Detail }。
    $r = Invoke-Gh -Arguments @('auth', 'status') -TimeoutMs 30000
    if ($r.ExitCode -eq 0) {
        $line = ($r.Output + "`n" + $r.Error) -split "`n" | Where-Object { $_ -match 'Logged in to' } | Select-Object -First 1
        return [pscustomobject]@{ Ok = $true; Detail = ([string]$line).Trim() }
    }
    return [pscustomobject]@{ Ok = $false; Detail = (Get-GhFailureDetail $r) }
}

function Send-CommitStatus {
    # 在那個 commit 上放一個狀態。回傳 @{ Posted; State; Detail }。
    param(
        [Parameter(Mandatory)][string]$Slug,      # owner/repo
        [Parameter(Mandatory)]$Verdict,
        [string]$Context = 'actci',
        [string]$TargetUrl = ''
    )
    $payload = New-StatusPayload -Verdict $Verdict -Context $Context -TargetUrl $TargetUrl
    $json = $payload | ConvertTo-Json -Compress
    $r = Invoke-Gh -Arguments @('api', '--method', 'POST', "repos/$Slug/statuses/$($Verdict.Sha)", '--input', '-') -InputText $json
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ Posted = $false; State = $payload.state; Detail = (Get-GhFailureDetail $r) }
    }
    return [pscustomobject]@{ Posted = $true; State = $payload.state; Detail = $payload.state }
}

function Send-PendingStatus {
    # 開跑時先放一個 pending。沒有這一步，PR 上在測試跑完前是空的 —— 而空的看起來
    # 跟「還沒有人管」一樣。
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Sha,
        [string]$Context = 'actci',
        [string]$Note = 'actci 開始跑了'
    )
    if ($Note.Length -gt 140) { $Note = $Note.Substring(0, 140) }
    $json = ([ordered]@{ state = 'pending'; context = $Context; description = $Note }) | ConvertTo-Json -Compress
    $r = Invoke-Gh -Arguments @('api', '--method', 'POST', "repos/$Slug/statuses/$Sha", '--input', '-') -InputText $json
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ Posted = $false; State = 'pending'; Detail = (Get-GhFailureDetail $r) }
    }
    return [pscustomobject]@{ Posted = $true; State = 'pending'; Detail = 'pending' }
}

function Get-OpenPullRequests {
    # 回傳 @{ Pulls = [{Number, Sha, Branch, Title}]; Problem = '' }。
    # 失敗時 Pulls 是空的而 Problem 有字 —— 呼叫端要分得出「沒有 PR」跟「問不到」。
    param([Parameter(Mandatory)][string]$Slug)
    $r = Invoke-Gh -Arguments @('pr', 'list', '--repo', $Slug, '--state', 'open', '--limit', '100',
                                '--json', 'number,headRefOid,headRefName,title')
    if ($r.ExitCode -ne 0) {
        return [pscustomobject]@{ Pulls = @(); Problem = (Get-GhFailureDetail $r) }
    }
    try {
        # PS 5.1 的 ConvertFrom-Json 把整個 JSON 陣列當成一個物件送進管線，
        # 用 -InputObject 收成變數再 @() 才會得到「一個 PR 一個元素」。
        $text = if ($r.Output) { $r.Output } else { '[]' }
        $rows = ConvertFrom-Json -InputObject $text
        $rows = @($rows)
    } catch {
        return [pscustomobject]@{ Pulls = @(); Problem = "gh 回的不是 JSON：$($_.Exception.Message)" }
    }
    $pulls = @(foreach ($row in $rows) {
        if ($null -eq $row) { continue }
        [pscustomobject]@{
            Number = [int]$row.number
            Sha    = [string]$row.headRefOid
            Branch = [string]$row.headRefName
            Title  = [string]$row.title
        }
    })
    return [pscustomobject]@{ Pulls = $pulls; Problem = '' }
}
