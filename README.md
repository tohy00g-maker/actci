# actci

在本地 WSL 裡用 [act](https://github.com/nektos/act) 跑任何 repo 的 GitHub Actions workflow，
把判定推回 GitHub 變成 commit status。Windows 視窗、背景 watcher、看門狗，全部 PowerShell，
不需要 Python 或 Node。

這是兩個專案的融合：**ActRunner**（act 的 WinForms 前端）與 **localci**（自架 CI 服務的判定語意、
輪詢 PR、推回 status、心跳）。每一條融合決定與理由見 [DECISIONS.md](DECISIONS.md)。

---

## 核心想法：通過與值得相信是兩回事

一次執行的判定一定帶著「跑了幾支測試」。`passed` 而 `TestsRun = 0` 不是通過，是**沒有驗證**：
範圍算錯、測試檔沒被收集到、指令拼錯，這些看起來都跟真的通過一模一樣。

| 結果 | 推到 GitHub 的 state |
|---|---|
| passed 且 TestsRun > 0 | `success` |
| passed 但 TestsRun = 0 | `failure`（不是 success） |
| failed（測試跑了，有紅的） | `failure` |
| errored（CI 自己的問題：Docker 沒開、映像拉不下來、act 掛了） | `error` |

測試數從 act 的輸出解析，認得 Django/unittest、pytest、jest、mocha、go test、cargo、dotnet 的統計行。
專案也可以在 workflow 最後 `echo ACTCI_TESTS_RUN=N` 直接指定。一個都認不出來就是 0。

「測試失敗」與「CI 跑不起來」是兩種紅字。前者是被測程式碼的問題，後者是這套 CI 自己的問題，
混成一種會讓人去翻程式碼找一個不存在的 bug。

---

## 需求

- Windows 10/11，WSL2 發行版（預設 Ubuntu）
- Docker Desktop，且在 Settings → Resources → WSL integration 勾選該發行版
- `gh` 已登入（推回 GitHub 與 watcher 需要）
- act 不用自己裝，視窗的環境分頁一鍵裝到 `~/.local/bin`，不需要 sudo
- Pester 5+（只有跑測試才需要）：`Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck`

## 快速開始

1. 雙擊 `actci.bat`。
2. **環境**分頁：按「檢查環境」。依序處理：啟動 Docker Desktop → 安裝 act → 建立 ~/.actrc（選 medium 或 full 映像）→ 編輯 secrets 填入 `GITHUB_TOKEN=你的PAT`。五個燈都綠才算就緒。
3. **執行**分頁：選 repo（建議放在 Linux 檔案系統，`/mnt/c` 下 Docker 掛載很慢）→ 讀取 job 清單 → 選事件與 job → 執行。輸出即時串流。
   勾「跑完推回 GitHub」會以 HEAD 的 sha 推 `actci/manual` context，推之前會再確認一次。
4. **監看**分頁：「安裝 / 更新 watcher…」填 repo 與 owner/repo，安裝器會開一個主控台跑五個步驟。裝好之後這頁顯示心跳幾秒前、排程工作狀態、最近判定。

## watcher 做什麼

```
每 60 秒
  ├─ 寫心跳（在迴圈頂端，不是底端）
  ├─ 用 gh 問開著的 PR
  ├─ 挑一個還沒判定過的（最舊的優先）
  ├─ git fetch refs/pull/N/head（fork 來的 PR 本地沒有那個 commit）
  ├─ git archive 那個 sha 到暫存目錄 → act 跑 → 清掉
  ├─ 存判定（一個 commit 一個 JSON）
  └─ 推 commit status，context `actci`
```

分支保護可以要求 `actci` 這個 status。手動執行推的是 `actci/manual`，兩者分開，
避免工作目錄未提交的狀態被當成正式判定。手動執行的判定不存進 store，否則 watcher 會把那個 commit 當成已判定而跳過。

watcher 是排程工作 `actci-watcher`，以 conhost --headless 啟動所以沒有視窗，每 10 分鐘的重複觸發是重啟保險。
安裝器最後會驗 NextRunTime 不為空，因為「它跑得動」跟「它會自己跑」是兩件事。

## 檔案

| 路徑 | 用途 |
|---|---|
| `actci.ps1` / `actci.bat` | 視窗 |
| `watcher.ps1` | watcher 入口，平常由排程工作啟動 |
| `install_watcher.ps1` | 裝排程工作，五步驗證 |
| `src/actci.psm1` | 模組，載入下面幾支 |
| `src/Verdict.ps1` | 判定型別、trustworthy、headline、JSON |
| `src/Parse.ps1` | 剝 act 前綴與色碼、各框架測試數 |
| `src/Store.ps1` | `%LOCALAPPDATA%\actci` 的判定、日誌、心跳 |
| `src/Status.ps1` | 判定 → GitHub state |
| `src/Wsl.ps1` | wsl.exe 呼叫、引號、路徑轉換 |
| `src/Engine.ps1` | act 執行核心，含前置檢查與 git archive |
| `src/GitHub.ps1` | 透過 gh 推 status、列 PR |
| `src/Watcher.ps1` | 一圈的決策與迴圈 |
| `runner/` | GitHub self-hosted runner 的重啟與看門狗（從 localci 搬來，參數預設值仍是 example-app 的） |
| `tests/` | Pester 測試，不需要 Docker 與網路 |

判定與日誌：`%LOCALAPPDATA%\actci\verdicts\<sha>.json`、`logs\<sha>.log`、`heartbeat.txt`、`watcher.log`、`watcher.json`。

## 測試

```
powershell -NoProfile -ExecutionPolicy Bypass -File Invoke-Tests.ps1
```

會碰外面的東西（wsl.exe、gh、act、docker）都用 Mock 替掉，因為要測的是**決策**，不是 docker 跑不跑得動。
WSL 相關有三個真的打 wsl.exe 的整合測試，機器上沒有 WSL 會自動跳過。

## 已知的 wsl.exe 陷阱

- `-d` 後面的發行版名稱不能加引號，wsl.exe 不會去掉它。
- `--` 後面的字串原封不動交給 Linux 的 shell。用 Windows 雙引號包指令，`$HOME`、`$PATH`、`$(…)` 會被外層 shell 先展開，PATH 裡的 `Program Files (x86)` 一展開就是語法錯誤。要用 bash 單引號包。
- wsl.exe 自己的訊息是 UTF-16LE，Linux 程式的輸出是 UTF-8。

## 限制

- 只能跑 `runs-on: ubuntu-*` 的 job。Windows 與 macOS runner 會被跳過。
- OIDC、GitHub App token 無法模擬；`GITHUB_TOKEN` 由你的 PAT 代替。
- act 的 runner 映像是第三方近似品。本地通過不代表 GitHub 一定通過。
- 測試數解析認不得的框架會被當成 0 支，推 failure。用 `ACTCI_TESTS_RUN=N` 補。
