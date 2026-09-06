# 透過 wsl.exe 在 Linux 發行版裡執行 bash 指令。視窗與 watcher 共用。
#
# 兩個 ActRunner 踩過的 wsl.exe 陷阱，別再踩：
# 1. `-d` 後面的發行版名稱**不能加引號**。wsl.exe 不會去掉引號，會直接說找不到發行版。
# 2. wsl.exe 自己的訊息（找不到發行版之類）是 UTF-16LE，而 Linux 程式的輸出是 UTF-8。
#    這裡讀原始位元組，依零位元組比例判斷。

$script:WslDistro = 'Ubuntu'
# ~/.local/bin 是不用 sudo 安裝 act 的位置；bash -lc 會讀 .profile 但那要目錄先存在。
$script:BashPrefix = 'export PATH=$HOME/.local/bin:$PATH; '

function Get-WslDistro { return $script:WslDistro }
function Set-WslDistro { param([Parameter(Mandatory)][string]$Name); $script:WslDistro = $Name }

function ConvertTo-BashArg {
    # 單引號包住，內部單引號改成 '\''
    param([AllowEmptyString()][string]$Text)
    return "'" + ($Text -replace "'", "'\''") + "'"
}

function ConvertTo-WinArg {
    # 依 Windows CommandLineToArgvW 規則加雙引號並跳脫
    param([AllowEmptyString()][string]$Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq '\') { $bs++ }
        elseif ($ch -eq '"') { [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0 }
        else { if ($bs) { [void]$sb.Append('\' * $bs); $bs = 0 }; [void]$sb.Append($ch) }
    }
    if ($bs) { [void]$sb.Append('\' * ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-WslPath {
    # C:\a\b -> /mnt/c/a/b；\\wsl.localhost\Ubuntu\home\me -> /home/me；Linux 路徑原樣。
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim().TrimEnd('\')
    if ($p -match '^\\\\wsl(\$|\.localhost)\\[^\\]+(\\.*)?$') {
        $rest = $Matches[2]
        if (-not $rest) { return '/' }
        return ($rest -replace '\\', '/')
    }
    if ($p -match '^([A-Za-z]):(\\.*)?$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2]
        if (-not $rest) { return "/mnt/$drive" }
        return "/mnt/$drive" + ($rest -replace '\\', '/')
    }
    return $p
}

function ConvertFrom-WslBytes {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return '' }
    $zeros = 0
    $i = 1
    while ($i -lt $Bytes.Length) { if ($Bytes[$i] -eq 0) { $zeros++ }; $i += 2 }
    $half = [Math]::Max(1, [int]($Bytes.Length / 2))
    if ($zeros * 100 / $half -gt 30) { return ([System.Text.Encoding]::Unicode.GetString($Bytes) -replace "`0", '') }
    return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function New-WslStartInfo {
    param([Parameter(Mandatory)][string]$BashCommand, [string]$Distro = '')
    if (-not $Distro) { $Distro = $script:WslDistro }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = '-d ' + $Distro + ' -- bash -lc ' + (ConvertTo-WinArg $BashCommand)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $env:SystemRoot   # 避免 WSL 對目前目錄 chdir 失敗的警告
    return $psi
}

function Invoke-Wsl {
    # 同步執行，回傳 @{ ExitCode; Output; Error }。逾時回 ExitCode -1 與 Error '逾時…'。
    # 從不丟例外 —— 呼叫端是 watcher 迴圈，例外只會讓判定消失。
    param(
        [Parameter(Mandatory)][string]$BashCommand,
        [int]$TimeoutMs = 60000,
        [string]$Distro = ''
    )
    try {
        $psi = New-WslStartInfo -BashCommand $BashCommand -Distro $Distro
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $msOut = New-Object System.IO.MemoryStream
        $msErr = New-Object System.IO.MemoryStream
        $tOut = $p.StandardOutput.BaseStream.CopyToAsync($msOut)
        $tErr = $p.StandardError.BaseStream.CopyToAsync($msErr)
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch {}
            return [pscustomobject]@{ ExitCode = -1; Output = (ConvertFrom-WslBytes $msOut.ToArray()); Error = "逾時（${TimeoutMs} ms）" }
        }
        [System.Threading.Tasks.Task]::WaitAll(@($tOut, $tErr))
        return [pscustomobject]@{
            ExitCode = $p.ExitCode
            Output   = (ConvertFrom-WslBytes $msOut.ToArray()).TrimEnd()
            Error    = (ConvertFrom-WslBytes $msErr.ToArray()).TrimEnd()
        }
    } catch {
        return [pscustomobject]@{ ExitCode = -1; Output = ''; Error = $_.Exception.Message }
    }
}

function Get-WslDistros {
    $result = @()
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'wsl.exe'
        $psi.Arguments = '-l -q'
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit(10000) | Out-Null
        foreach ($line in ($out -split "`r?`n")) {
            $n = ($line -replace "`0", '').Trim()
            if ($n -and $n -notlike 'docker-desktop*') { $result += $n }
        }
    } catch {}
    return ,$result
}
