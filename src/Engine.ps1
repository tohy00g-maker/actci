# 執行核心：用 act 跑一個 repo 的 workflow，回傳一份判定。視窗與 watcher 共用。
#
# ## 為什麼有 sha 就 git archive，不直接在工作目錄跑
#
# localci 量過：直接掛工作目錄進容器，74,856 個檔案（media/、.venv/ 全在）跑 15 支
# 測試 285 秒；`git archive <sha>` 只給那個 commit 追蹤的檔案，4.5 秒。
# 更重要的是語意：有 sha 就是在判定**那個 commit**，未提交的改動、別的分支留下的
# 檔案都不該混進來。沒給 sha（視窗手動執行）才跑工作目錄現況，判定會註明。
#
# ## 三種結果怎麼分
#
#   exit 0                                  -> passed（TestsRun 由 Get-TestsRun 決定可不可信）
#   exit != 0 且輸出裡有 step 失敗的痕跡     -> failed（被測程式碼的問題）
#   exit != 0 但 act 根本沒跑到任何 step     -> errored（CI 自己的問題：docker 沒開、映像拉不下來）
#   逾時、wsl 叫不動、前置檢查失敗           -> errored
#
# ## 這一支不丟例外
#
# 呼叫端是排程與視窗。丟例外只會讓判定消失，而消失的判定跟通過長得一樣。
# 所有失敗都變成 Outcome。

$script:ActStepFailedRegex = [regex]'(❌\s+Failure|Job failed|🏁\s+Job failed)'
$script:ActInfraRegex = [regex]'(Cannot connect to the Docker daemon|docker\.sock|permission denied while trying to connect|failed to start container|unable to find image|Error: failed to pull|no such file or directory: .*act)'

function Get-RepoHeadSha {
    # 回傳完整 sha；不是 git repo 或叫不動就回 ''。
    param([Parameter(Mandatory)][string]$RepoPath, [string]$Distro = '')
    $r = Invoke-Wsl -BashCommand ('git -C ' + (ConvertTo-BashArg $RepoPath) + ' rev-parse HEAD 2>/dev/null') -TimeoutMs 30000 -Distro $Distro
    if ($r.ExitCode -eq 0 -and $r.Output -match '^[0-9a-f]{40}$') { return $r.Output.Trim() }
    return ''
}

function Test-ActPreflight {
    # act 與 docker 都要在 WSL 裡叫得動。回傳 @{ Ok; Detail }。
    param([string]$Distro = '')
    $cmd = $script:BashPrefix +
        'if ! command -v act >/dev/null 2>&1; then echo __NOACT__; exit 0; fi; ' +
        'if ! command -v docker >/dev/null 2>&1; then echo __NODOCKER__; exit 0; fi; ' +
        'v=$(docker info --format {{.ServerVersion}} 2>/dev/null); ' +
        'if [ -z "$v" ]; then echo __NODAEMON__; exit 0; fi; ' +
        'echo __OK__ $(act --version 2>&1 | head -1) docker $v'
    $r = Invoke-Wsl -BashCommand $cmd -TimeoutMs 60000 -Distro $Distro
    if ($r.ExitCode -ne 0 -or -not $r.Output) {
        return [pscustomobject]@{ Ok = $false; Detail = "WSL 叫不動：$($r.Error) $($r.Output)".Trim() }
    }
    switch -Wildcard ($r.Output) {
        '*__NOACT__*'    { return [pscustomobject]@{ Ok = $false; Detail = 'act 未安裝（WSL 內找不到 act）' } }
        '*__NODOCKER__*' { return [pscustomobject]@{ Ok = $false; Detail = 'WSL 內找不到 docker，Docker Desktop 沒開或沒啟用 WSL integration' } }
        '*__NODAEMON__*' { return [pscustomobject]@{ Ok = $false; Detail = 'docker 有指令但 daemon 沒回應，Docker Desktop 還在啟動或已停止' } }
        '*__OK__*'       { return [pscustomobject]@{ Ok = $true; Detail = ($r.Output -replace '__OK__\s*', '').Trim() } }
    }
    return [pscustomobject]@{ Ok = $false; Detail = "前置檢查回了看不懂的東西：$($r.Output)" }
}

function New-ActCommand {
    # 組出要交給 bash -lc 的那一串。獨立出來讓測試能盯住引號與順序。
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string]$Sha = '',
        [string]$Event = 'push',
        [string]$Job = '',
        [string[]]$ExtraArgs = @(),
        [string]$RawArgs = ''
    )
    $actArgs = New-Object System.Collections.Generic.List[string]
    if ($Event) { $actArgs.Add((ConvertTo-BashArg $Event)) }
    if ($Job) { $actArgs.Add('-j'); $actArgs.Add((ConvertTo-BashArg $Job)) }
    foreach ($a in $ExtraArgs) { if ($null -ne $a -and $a -ne '') { $actArgs.Add((ConvertTo-BashArg $a)) } }
    $act = 'NO_COLOR=1 TERM=dumb act ' + ($actArgs -join ' ')
    if ($RawArgs) { $act += ' ' + $RawArgs.Trim() }
    $act += ' 2>&1'

    $repo = ConvertTo-BashArg $RepoPath
    if ($Sha) {
        # 暫存目錄一定清掉，不論 act 結果如何；act 的離開碼要留下來。
        return $script:BashPrefix +
            'tmp=$(mktemp -d /tmp/actci-XXXXXX) || exit 97; ' +
            "git -C $repo archive --format=tar " + (ConvertTo-BashArg $Sha) + ' | tar -x -C "$tmp" || { rm -rf "$tmp"; echo __ARCHIVE_FAILED__; exit 98; }; ' +
            'cd "$tmp" && ' + $act + '; rc=$?; cd /; rm -rf "$tmp"; exit $rc'
    }
    return $script:BashPrefix + "cd $repo && " + $act
}

function Get-LastMeaningfulLine {
    param([string[]]$Lines)
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $l = $Lines[$i].Trim()
        if ($l) { if ($l.Length -gt 300) { return $l.Substring(0, 300) }; return $l }
    }
    return ''
}

function Invoke-ActRun {
    param(
        [Parameter(Mandatory)][string]$RepoPath,   # Linux 路徑；Windows 路徑請先 ConvertTo-WslPath
        [string]$Sha = '',                          # 空字串 = 跑工作目錄現況（只給視窗手動用）
        [string]$Event = 'push',
        [string]$Job = '',
        [string[]]$ExtraArgs = @(),
        [string]$RawArgs = '',
        [string]$LogDir = '',
        [int]$TimeoutMs = 3600000,
        [string]$Distro = '',
        [switch]$SkipPreflight
    )
    $started = [Diagnostics.Stopwatch]::StartNew()

    # 判定一定要有 sha 才能存。沒給就用 HEAD 標記，並註明跑的是工作目錄。
    $worktree = -not $Sha
    $labelSha = $Sha
    $note = ''
    if ($worktree) {
        $labelSha = Get-RepoHeadSha -RepoPath $RepoPath -Distro $Distro
        if (-not $labelSha) { $labelSha = '0000000' }
        $note = '跑的是工作目錄現況，不是 commit'
    }
    $verdict = New-Verdict -Sha $labelSha -Repo $RepoPath -Event $Event -Job $Job -Note $note

    if (-not $SkipPreflight) {
        $pre = Test-ActPreflight -Distro $Distro
        if (-not $pre.Ok) {
            $verdict.Outcome = 'errored'
            $verdict.Note = $pre.Detail
            $verdict.FinishedAt = Get-IsoNow
            $verdict.Seconds = $started.Elapsed.TotalSeconds
            return $verdict
        }
    }

    $cmd = New-ActCommand -RepoPath $RepoPath -Sha $Sha -Event $Event -Job $Job -ExtraArgs $ExtraArgs -RawArgs $RawArgs
    $r = Invoke-Wsl -BashCommand $cmd -TimeoutMs $TimeoutMs -Distro $Distro

    $verdict.Seconds = $started.Elapsed.TotalSeconds
    $verdict.FinishedAt = Get-IsoNow
    $output = ($r.Output + "`n" + $r.Error).Trim()
    $lines = ConvertFrom-ActOutput $output
    $verdict.Steps = @((New-VerdictStep -Name 'act' -ExitCode $r.ExitCode -Seconds $verdict.Seconds))

    if ($LogDir) {
        try {
            if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
            $logPath = Join-Path $LogDir ($labelSha.Substring(0, [Math]::Min(12, $labelSha.Length)) + '.log')
            [System.IO.File]::WriteAllText($logPath, $output + "`n", (New-Object System.Text.UTF8Encoding $false))
            $verdict.LogPath = $logPath
        } catch {
            $note = "日誌寫不進去：$($_.Exception.Message)"
            $verdict.Note = ($verdict.Note + ' ' + $note).Trim()
        }
    }

    $tests = Get-TestsRun $output
    $verdict.TestsRun = $tests.Count
    $verdict.TestsSource = $tests.Sources

    if ($r.ExitCode -eq -1 -and $r.Error -like '逾時*') {
        $verdict.Outcome = 'errored'
        $verdict.Note = ('超過 {0} 秒還沒跑完' -f [int]($TimeoutMs / 1000))
        return $verdict
    }
    if ($r.ExitCode -eq 98 -or $output -like '*__ARCHIVE_FAILED__*') {
        $verdict.Outcome = 'errored'
        $verdict.Note = "git archive $Sha 失敗：" + (Get-LastMeaningfulLine ($lines | Where-Object { $_ -notlike '*__ARCHIVE_FAILED__*' }))
        return $verdict
    }
    if ($r.ExitCode -eq 0) {
        $verdict.Outcome = 'passed'
        return $verdict
    }
    if ($script:ActInfraRegex.IsMatch($output)) {
        $verdict.Outcome = 'errored'
        $verdict.Note = Get-LastMeaningfulLine @($lines | Where-Object { $script:ActInfraRegex.IsMatch($_) })
        return $verdict
    }
    if ($script:ActStepFailedRegex.IsMatch($output) -or $tests.Count -gt 0) {
        # 有 step 失敗的痕跡、或測試真的跑了 —— 那是被測程式碼的問題。
        $verdict.Outcome = 'failed'
        return $verdict
    }
    $verdict.Outcome = 'errored'
    $last = Get-LastMeaningfulLine $lines
    $verdict.Note = if ($last) { $last } else { "離開碼 $($r.ExitCode)" }
    return $verdict
}
