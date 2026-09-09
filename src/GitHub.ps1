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

function New-GhInputFile {
    # 把 body 落成一個暫存檔，回傳路徑。**不可以有 BOM。**
    #
    # ## 為什麼不從 stdin 餵
    #
    # 2026-09-09：每一份判定都算對了、也存進 store 了，但 PR 上的檢查一直停在
    # 舊的那一份 —— `gh: Problems parsing JSON (HTTP 400)`。JSON 本身是好的，
    # 同一份內容用 `--input <檔案>` 送，GitHub 就收下。
    #
    # 差別在 stdin 的**第一個位元組**。只要 .NET 碰過 `Process.StandardInput`，
    # 它就會用 `Console.InputEncoding` 建一個 AutoFlush 的 StreamWriter，而設
    # AutoFlush 會立刻 flush 一次 —— 那一下把 UTF-8 的 BOM（EF BB BF）寫進了
    # 子行程的 stdin，寫在我們自己的 JSON 前面。GitHub 的解析器看到那三個位元組
    # 就回 400。（同一條指令在 bash 裡管用，因為那條路上沒有 .NET。）
    #
    # 這件事最貴的地方不是漏一個綠勾：`gh pr checks` 會回「no checks reported」
    # 而且離開碼 0 —— 看起來跟「等過了、沒問題」一模一樣。
    param([Parameter(Mandatory)][string]$Text)
    $path = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        "actci-gh-$([guid]::NewGuid().ToString('n')).json")
    [System.IO.File]::WriteAllBytes(
        $path,
        (New-Object System.Text.UTF8Encoding $false).GetBytes($Text))
    return $path
}

function Resolve-GhInputArgument {
    # 把 `--input -` 換成 `--input <暫存檔>`。只換緊接在 --input 後面的那一格，
    # 不是每一個長得像 `-` 的參數。
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Path
    )
    $out = @()
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($i -gt 0 -and $Arguments[$i] -eq '-' -and $Arguments[$i - 1] -eq '--input') {
            $out += $Path
        } else {
            $out += $Arguments[$i]
        }
    }
    return , $out
}

function Invoke-Gh {
    # 同步呼叫 gh.exe。回傳 @{ ExitCode; Output; Error }。測試會把這支 Mock 掉。
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$InputText = '',
        [int]$TimeoutMs = 60000
    )
    $inputFile = ''
    try {
        if ($InputText) {
            $inputFile = New-GhInputFile -Text $InputText
            $Arguments = Resolve-GhInputArgument -Arguments $Arguments -Path $inputFile
        }
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
        # body 走檔案，所以這裡永遠只是把 stdin 關掉。不要再往裡面寫東西 ——
        # 那條路上 .NET 會先塞一個 BOM 進去，見 New-GhInputFile。
        $p.StandardInput.Close()
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            return [pscustomobject]@{ ExitCode = -1; Output = ''; Error = "gh 逾時（${TimeoutMs} ms）" }
        }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = $so.Result.TrimEnd(); Error = $se.Result.TrimEnd() }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = ''; Error = "叫不動 gh：$($_.Exception.Message)" }
    } finally {
        if ($inputFile -and (Test-Path $inputFile)) {
            Remove-Item $inputFile -Force -ErrorAction SilentlyContinue
        }
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
