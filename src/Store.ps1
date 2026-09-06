# 判定與心跳的存放。一個 commit 一個 JSON，心跳一個檔。
#
# 預設放 %LOCALAPPDATA%\actci：
#   verdicts\<sha>.json
#   logs\<sha>.log
#   heartbeat.txt
#
# 寫檔一律先寫暫存再改名，讓讀的那一邊永遠不會看到寫到一半的檔案。
# 視窗每五秒重讀這個目錄，watcher 隨時可能在寫。

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function New-Store {
    param([string]$Path = '')
    if (-not $Path) { $Path = Join-Path $env:LOCALAPPDATA 'actci' }
    [pscustomobject]@{
        PSTypeName = 'actci.Store'
        Root       = $Path
        Verdicts   = (Join-Path $Path 'verdicts')
        Logs       = (Join-Path $Path 'logs')
        Heartbeat  = (Join-Path $Path 'heartbeat.txt')
    }
}

function Initialize-Store {
    param([Parameter(Mandatory)]$Store)
    foreach ($dir in @($Store.Root, $Store.Verdicts, $Store.Logs)) {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    return $Store
}

function Write-AtomicText {
    param([string]$Path, [string]$Text)
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Text, $script:Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-VerdictFilePath {
    param($Store, [string]$Sha)
    if ($Sha -notmatch '^[0-9a-fA-F]{7,64}$') { throw "sha 格式不對：'$Sha'" }
    return Join-Path $Store.Verdicts ($Sha.ToLower() + '.json')
}

function Save-Verdict {
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Verdict)
    Initialize-Store $Store | Out-Null
    $path = Get-VerdictFilePath $Store $Verdict.Sha
    Write-AtomicText -Path $path -Text (ConvertTo-VerdictJson $Verdict)
    return $path
}

function Get-StoredVerdict {
    # 沒有就回 $null。壞掉的檔案也回 $null 並警告 —— 呼叫端會把它當成「還沒判定」
    # 重跑一次，那比「把壞檔當成已判定」安全。
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Sha)
    $path = Get-VerdictFilePath $Store $Sha
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return ConvertFrom-VerdictJson ([System.IO.File]::ReadAllText($path, $script:Utf8NoBom))
    } catch {
        Write-Warning "判定檔讀不出來，當成沒有：$path（$($_.Exception.Message)）"
        return $null
    }
}

function Get-RecentVerdicts {
    # 最近完成的在前。壞檔跳過。
    param([Parameter(Mandatory)]$Store, [int]$Limit = 10)
    if (-not (Test-Path -LiteralPath $Store.Verdicts)) { return @() }
    $all = foreach ($file in Get-ChildItem -LiteralPath $Store.Verdicts -Filter '*.json' -File) {
        try {
            ConvertFrom-VerdictJson ([System.IO.File]::ReadAllText($file.FullName, $script:Utf8NoBom))
        } catch {
            Write-Warning "判定檔讀不出來，跳過：$($file.FullName)"
        }
    }
    $sorted = @($all) | Sort-Object -Property @{ Expression = { if ($_.FinishedAt) { $_.FinishedAt } else { $_.StartedAt } }; Descending = $true }
    return @($sorted | Select-Object -First $Limit)
}

function Write-Heartbeat {
    # 呼叫端要在迴圈**頂端**呼叫。寫在底端的話，一個卡在跑測試中間的 watcher
    # 會停止心跳 —— 而那正是它最該報告的時刻。
    param([Parameter(Mandatory)]$Store, [string]$Note = '')
    Initialize-Store $Store | Out-Null
    $stamp = [DateTime]::UtcNow.ToString('o')
    Write-AtomicText -Path $Store.Heartbeat -Text ("{0}`n{1}`n" -f $stamp, ($Note -replace "[`r`n]", ' '))
}

function Get-HeartbeatAge {
    # 從來沒跳過回 $null；否則回 @{ Seconds; Note; At }。
    # 「從來沒跳過」跟「跳過但很久以前」是兩件事，不要合成一個數字。
    param([Parameter(Mandatory)]$Store, [DateTime]$Now = [DateTime]::UtcNow)
    if (-not (Test-Path -LiteralPath $Store.Heartbeat)) { return $null }
    $lines = [System.IO.File]::ReadAllText($Store.Heartbeat, $script:Utf8NoBom) -split "`n"
    if ($lines.Count -eq 0 -or -not $lines[0].Trim()) { return $null }
    try {
        $at = [DateTime]::Parse($lines[0].Trim(), [Globalization.CultureInfo]::InvariantCulture,
                                [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    } catch {
        return $null
    }
    $note = if ($lines.Count -gt 1) { $lines[1].Trim() } else { '' }
    return [pscustomobject]@{
        Seconds = [Math]::Max(0, ($Now.ToUniversalTime() - $at).TotalSeconds)
        Note    = $note
        At      = $at
    }
}
