# -Skip 在探索階段就被評估，所以「有沒有 WSL」要在檔案頂端算，不能放 BeforeAll。
Import-Module (Join-Path $PSScriptRoot '..\src\actci.psm1') -Force
$script:hasWsl = $false
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    $script:wslDistros = @(Get-WslDistros)
    $script:hasWsl = $script:wslDistros.Count -gt 0
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\actci.psm1') -Force
}

Describe 'ConvertTo-WslPath' {
    It 'C:\ -> /mnt/c' { ConvertTo-WslPath 'C:\Users\me\src' | Should -Be '/mnt/c/Users/me/src' }
    It 'D:\ 根目錄' { ConvertTo-WslPath 'D:\' | Should -Be '/mnt/d' }
    It '\\wsl.localhost\Ubuntu\home\me\src\ -> /home/me/src' { ConvertTo-WslPath '\\wsl.localhost\Ubuntu\home\me\src\' | Should -Be '/home/me/src' }
    It '\\wsl$\Ubuntu\home\me -> /home/me' { ConvertTo-WslPath '\\wsl$\Ubuntu\home\me' | Should -Be '/home/me' }
    It 'Linux 路徑原樣' { ConvertTo-WslPath '/home/me/src' | Should -Be '/home/me/src' }
    It '~ 原樣' { ConvertTo-WslPath '~/src' | Should -Be '~/src' }
    It '空字串回空' { ConvertTo-WslPath '' | Should -Be '' }
}

Describe '引號' {
    It 'bash 單引號跳脫' { ConvertTo-BashArg "it's" | Should -Be "'it'\''s'" }
    It 'bash 空字串也包引號' { ConvertTo-BashArg '' | Should -Be "''" }
    It 'Windows 參數：雙引號與結尾反斜線' { ConvertTo-WinArg 'a "b" c\' | Should -Be '"a \"b\" c\\"' }
    It 'Windows 參數：反斜線後接引號要加倍' { ConvertTo-WinArg 'x\"y' | Should -Be '"x\\\"y"' }
}

Describe 'ConvertFrom-WslBytes' {
    It 'UTF-8 位元組解成 UTF-8' {
        ConvertFrom-WslBytes ([System.Text.Encoding]::UTF8.GetBytes('中文OK')) | Should -Be '中文OK'
    }
    It 'UTF-16LE 位元組（wsl.exe 自己的訊息）也解得對' {
        ConvertFrom-WslBytes ([System.Text.Encoding]::Unicode.GetBytes('Wsl/Service/WSL_E_DISTRO_NOT_FOUND')) | Should -Be 'Wsl/Service/WSL_E_DISTRO_NOT_FOUND'
    }
    It '空陣列回空字串' { ConvertFrom-WslBytes @() | Should -Be '' }
}

Describe 'New-WslStartInfo' {
    It '發行版名稱不加引號，bash 指令用單引號包（外層 shell 才不會先展開 $VAR）' {
        $psi = New-WslStartInfo -BashCommand 'echo "$HOME" it''s' -Distro 'Ubuntu'
        $psi.FileName | Should -Be 'wsl.exe'
        $psi.Arguments | Should -Be "-d Ubuntu -- bash -lc 'echo `"`$HOME`" it'\''s'"
    }
    It '沒指定就用模組預設的發行版' {
        Set-WslDistro 'Debian'
        (New-WslStartInfo -BashCommand 'true').Arguments | Should -Match '^-d Debian '
        Set-WslDistro 'Ubuntu'
    }
}

Describe 'Invoke-Wsl 真的呼叫（沒有 WSL 就跳過）' {
    BeforeAll {
        if ($script:hasWsl) { Set-WslDistro $script:wslDistros[0] }
    }
    It 'UTF-8 中文往返' -Skip:(-not $script:hasWsl) {
        $r = Invoke-Wsl -BashCommand 'echo 中文OK' -TimeoutMs 60000
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Be '中文OK'
    }
    It '離開碼帶回來' -Skip:(-not $script:hasWsl) {
        (Invoke-Wsl -BashCommand 'exit 3' -TimeoutMs 60000).ExitCode | Should -Be 3
    }
    It '$PATH 裡有空白與括號也不會炸（就是 2026-09-06 那個 bug）' -Skip:(-not $script:hasWsl) {
        $r = Invoke-Wsl -BashCommand 'export PATH="$HOME/.local/bin:$PATH"; x=$(echo sub); echo "ok $x"' -TimeoutMs 60000
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Be 'ok sub'
    }
    It '找不到的發行版不丟例外，Error 可讀' -Skip:(-not $script:hasWsl) {
        $r = Invoke-Wsl -BashCommand 'true' -TimeoutMs 60000 -Distro 'no-such-distro-xyz'
        $r.ExitCode | Should -Not -Be 0
        ($r.Output + $r.Error) | Should -Not -Match "`0"
    }
}
