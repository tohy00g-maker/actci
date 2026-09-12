# CI runner 的排程工作共用的一點東西。
#
# 2026-09-02 這幾支從原本那個專案搬過來時，它們 dot-source 的是那邊的
# `scripts/_deployment_common.ps1` —— 而那份沒有一起搬。**我搬了腳本卻沒搬
# 它依賴的東西**，而那件事是真的跑一次才抓到的（語法檢查過得了）。
#
# 只拄需要的那一個函式，不把整份包抬過來 —— 那份裡其餘的都是
# 那個專案的部署邏輯，跟 runner 無關。


function New-QuietScheduledTaskAction([string]$Execute, [string]$Argument,
                                      [string]$WorkingDirectory) {
    <#
    排程工作的動作，但不彈主控台視窗。

    ## 為什麼需要

    2026-09-01：使用者說「我在專注全螢幕時 cmd 會打斷全螢幕」。

    查下去七個排程工作全部是 `Interactive` 登入類型，而其中三個每 10
    分鐘一次 —— 平均每三四分鐘彈一次。而那天才加的伺服器看門狗是最後
    一根稻草。

    ## 為什麼是 conhost --headless，不是別的

    - `-WindowStyle Hidden`：PowerShell 自己起來之後才藏，**會閃一下**。
      全螢幕下那一閃跟一個視窗一樣打斷人。
    - `LogonType S4U`（不管使用者登入與否都執行）：根本不會有視窗，但
      **改它要提權**（實測：Set-ScheduledTask 回 HRESULT 0x80070005），而且
      權限不夠的帳號會變成**工作根本跑不起來** —— 把一個煩人的視窗
      換成一個死掉的看門狗，那是更糟的交換。
    - `conhost.exe --headless`：Windows 10 1903 之後內建。不必提權，完全沒有
      視窗，而且只改 Action —— 工作本身的觸發器、身分、設定都不動。

    ## 不要拿它藏你想看的東西

    `localci 的 runner/install_ci_runner_banner.ps1` 那一個視窗是**故意的** —— runner 自己的主控台，
    人要看的。這支只給背景工作用。
    #>

    $inner = if ($Argument) { "$Execute $Argument" } else { $Execute }
    return New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument "--headless $inner" -WorkingDirectory $WorkingDirectory
}
