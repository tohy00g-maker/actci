BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\actci.psm1') -Force
    function script:Fake([int]$code, [string]$out, [string]$err = '') {
        [pscustomobject]@{ ExitCode = $code; Output = $out; Error = $err }
    }
}

Describe 'Send-CommitStatus' {
    BeforeEach {
        $script:seen = @()
        Mock -ModuleName actci Invoke-Gh {
            param([string[]]$Arguments, [string]$InputText, [int]$TimeoutMs)
            $script:seen += ,@{ Args = $Arguments; Input = $InputText }
            & $script:ghScript $Arguments $InputText
        }
    }

    It '打對端點、payload 是 New-StatusPayload 的內容' {
        $script:ghScript = { Fake 0 '{"id":1}' }
        $v = New-Verdict -Sha ('a' * 40) -Repo '/r' -Outcome 'passed' -TestsRun 5 -TestsSource @('jest')
        $r = Send-CommitStatus -Slug 'me/repo' -Verdict $v
        $r.Posted | Should -BeTrue
        $r.State | Should -Be 'success'
        $script:seen.Count | Should -Be 1
        $script:seen[0].Args | Should -Be @('api', '--method', 'POST', "repos/me/repo/statuses/$('a' * 40)", '--input', '-')
        $body = $script:seen[0].Input | ConvertFrom-Json
        $body.state | Should -Be 'success'
        $body.context | Should -Be 'actci'
        $body.description | Should -Be (Get-VerdictHeadline $v)
    }
    It '0 支的通過推的是 failure' {
        $script:ghScript = { Fake 0 '{}' }
        $v = New-Verdict -Sha ('b' * 40) -Repo '/r' -Outcome 'passed' -TestsRun 0
        (Send-CommitStatus -Slug 'me/repo' -Verdict $v).State | Should -Be 'failure'
    }
    It 'errored 推的是 error' {
        $script:ghScript = { Fake 0 '{}' }
        $v = New-Verdict -Sha ('c' * 40) -Repo '/r' -Outcome 'errored' -Note 'docker down'
        (Send-CommitStatus -Slug 'me/repo' -Verdict $v).State | Should -Be 'error'
    }
    It 'context 與 target_url 帶進 payload' {
        $script:ghScript = { Fake 0 '{}' }
        $v = New-Verdict -Sha ('d' * 40) -Repo '/r' -Outcome 'passed' -TestsRun 1
        Send-CommitStatus -Slug 'me/repo' -Verdict $v -Context 'actci/manual' -TargetUrl 'https://x/log' | Out-Null
        $body = $script:seen[0].Input | ConvertFrom-Json
        $body.context | Should -Be 'actci/manual'
        $body.target_url | Should -Be 'https://x/log'
    }
    It 'gh 失敗：Posted false，Detail 是 stderr 尾巴，不丟例外' {
        $script:ghScript = { Fake 1 '' "gh: Not Found (HTTP 404)`n{`"message`": `"Not Found`"}" }
        $v = New-Verdict -Sha ('e' * 40) -Repo '/r' -Outcome 'passed' -TestsRun 1
        $r = Send-CommitStatus -Slug 'me/repo' -Verdict $v
        $r.Posted | Should -BeFalse
        $r.Detail | Should -Match '404'
    }
    It 'gh 叫不動：Posted false' {
        $script:ghScript = { Fake -1 '' '叫不動 gh：not found' }
        $v = New-Verdict -Sha ('f' * 40) -Repo '/r' -Outcome 'passed' -TestsRun 1
        (Send-CommitStatus -Slug 'me/repo' -Verdict $v).Posted | Should -BeFalse
    }
}

Describe 'Send-PendingStatus' {
    BeforeEach {
        $script:seen = @()
        Mock -ModuleName actci Invoke-Gh {
            param([string[]]$Arguments, [string]$InputText, [int]$TimeoutMs)
            $script:seen += ,@{ Args = $Arguments; Input = $InputText }
            Fake 0 '{}'
        }
    }
    It 'state 是 pending，Note 進 description，超過 140 字截掉' {
        $r = Send-PendingStatus -Slug 'me/repo' -Sha ('1' * 40) -Note ('x' * 200)
        $r.Posted | Should -BeTrue
        $body = $script:seen[0].Input | ConvertFrom-Json
        $body.state | Should -Be 'pending'
        $body.context | Should -Be 'actci'
        $body.description.Length | Should -Be 140
    }
}

Describe 'Get-OpenPullRequests' {
    BeforeEach {
        Mock -ModuleName actci Invoke-Gh {
            param([string[]]$Arguments, [string]$InputText, [int]$TimeoutMs)
            $script:lastArgs = $Arguments
            & $script:ghScript $Arguments
        }
    }
    It '解析成 Number/Sha/Branch/Title' {
        $script:ghScript = { Fake 0 '[{"number":12,"headRefOid":"abc","headRefName":"feat","title":"T 中文"},{"number":3,"headRefOid":"def","headRefName":"fix","title":"x"}]' }
        $r = Get-OpenPullRequests -Slug 'me/repo'
        $r.Problem | Should -Be ''
        @($r.Pulls).Count | Should -Be 2
        $r.Pulls[0].Number | Should -Be 12
        $r.Pulls[0].Sha | Should -Be 'abc'
        $r.Pulls[0].Branch | Should -Be 'feat'
        $r.Pulls[0].Title | Should -Be 'T 中文'
        $script:lastArgs | Should -Contain '--repo'
        $script:lastArgs | Should -Contain 'me/repo'
        $script:lastArgs | Should -Contain 'number,headRefOid,headRefName,title'
    }
    It '沒有 PR：空清單且 Problem 是空字串' {
        $script:ghScript = { Fake 0 '[]' }
        $r = Get-OpenPullRequests -Slug 'me/repo'
        @($r.Pulls).Count | Should -Be 0
        $r.Problem | Should -Be ''
    }
    It '只有一個 PR 也是陣列' {
        $script:ghScript = { Fake 0 '[{"number":1,"headRefOid":"a","headRefName":"b","title":"c"}]' }
        @((Get-OpenPullRequests -Slug 'me/repo').Pulls).Count | Should -Be 1
    }
    It 'gh 失敗：空清單但 Problem 有字，分得出「沒有」跟「問不到」' {
        $script:ghScript = { Fake 1 '' 'error connecting to api.github.com' }
        $r = Get-OpenPullRequests -Slug 'me/repo'
        @($r.Pulls).Count | Should -Be 0
        $r.Problem | Should -Match 'api.github.com'
    }
    It 'gh 回的不是 JSON：Problem 說明' {
        $script:ghScript = { Fake 0 'not json at all' }
        (Get-OpenPullRequests -Slug 'me/repo').Problem | Should -Match 'JSON'
    }
}

Describe 'Test-GhAuth' {
    It '登入了：Ok 與那一行' {
        Mock -ModuleName actci Invoke-Gh { Fake 0 '' "github.com`n  ✓ Logged in to github.com account someone (keyring)" }
        $r = Test-GhAuth
        $r.Ok | Should -BeTrue
        $r.Detail | Should -Match 'Logged in to github.com account someone'
    }
    It '沒登入：Ok false' {
        Mock -ModuleName actci Invoke-Gh { Fake 1 '' 'You are not logged into any GitHub hosts.' }
        (Test-GhAuth).Ok | Should -BeFalse
    }
}

Describe 'body 怎麼送到 gh 手上' {
    # 2026-09-09：判定都算對了、也存進 store 了，PR 上的檢查卻一直停在舊的那一份
    # —— `gh: Problems parsing JSON (HTTP 400)`。JSON 本身沒問題，同一份內容改用
    # `--input <檔案>` GitHub 就收下。
    #
    # 差別在 stdin 的第一個位元組：只要 .NET 碰過 Process.StandardInput，它就會用
    # Console.InputEncoding 建一個 AutoFlush 的 StreamWriter，而設 AutoFlush 會立刻
    # flush 一次 —— 那一下把 UTF-8 的 BOM 寫在我們的 JSON 前面。
    #
    # 這件事最貴的不是少一個綠勾：`gh pr checks` 會回「no checks reported」而且
    # 離開碼 0，看起來跟「等過了、沒問題」一模一樣。

    It '暫存檔沒有 BOM，內容一個位元組都不差' {
        $path = New-GhInputFile -Text '{"state":"success"}'
        try {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $bytes[0] | Should -Be 0x7b
            [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Be '{"state":"success"}'
        } finally {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        }
    }
    It '中文的 description 也是 UTF-8，而且還是沒有 BOM' {
        $text = '{"description":"' + ([char]0x901A + [char]0x904E) + '"}'
        $path = New-GhInputFile -Text $text
        try {
            $bytes = [System.IO.File]::ReadAllBytes($path)
            $bytes[0] | Should -Be 0x7b
            [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Be $text
        } finally {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
        }
    }
    It '只換緊接在 --input 後面的那一格' {
        $out = Resolve-GhInputArgument -Arguments @('api', '--method', 'POST', 'repos/x/y/statuses/z', '--input', '-') -Path 'C:\tmp\b.json'
        $out | Should -Be @('api', '--method', 'POST', 'repos/x/y/statuses/z', '--input', 'C:\tmp\b.json')
    }
    It '別的地方的 - 不要動它' {
        # 譬如將來有人送 `--jq -`，或某個 flag 的值剛好是一個減號。
        $out = Resolve-GhInputArgument -Arguments @('api', '--jq', '-', '--input', '-') -Path 'C:\tmp\b.json'
        $out | Should -Be @('api', '--jq', '-', '--input', 'C:\tmp\b.json')
    }
}
