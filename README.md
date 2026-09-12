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

## 給 AI agent 與腳本用：actci-cli.ps1

這套東西的主要使用者是機器，視窗只是給人看的。離開碼就是介面，不必解析文字；要細節加 `--json`。

```
powershell -NoProfile -ExecutionPolicy Bypass -File actci-cli.ps1 <command> [args] [--json]
```

| 指令 | 做什麼 | 離開碼 |
|---|---|---|
| `gate <sha>` | 這個 commit 有值得相信的通過嗎？合併門檻問這個 | 0 可以合併；1 有判定但不可信（0 支、測試紅了、CI 出錯）；2 還沒判定但 watcher 活著，該等；3 還沒判定而且 watcher 沒在動，等下去沒有意義 |
| `verdict <sha>` | 印判定，`--json` 是完整判定檔（含 `Jobs`：act 實際跑了哪幾支 workflow/job、各自狀態與測試數；`TestsRun` 是它們的加總） | 0；2 沒有 |
| `status [--limit N]` | 心跳幾秒前、watcher 設定、最近判定 | 永遠 0 |
| `run <repo> [--sha S] [--event E] [--job J] [--save] [--push owner/repo] [--context C]` | 用 act 跑一次；`--save` 存進 store，`--push` 推 status（預設 context `actci/manual`） | 0 值得相信的通過；1 其他 |
| `preflight` | WSL、act、docker、gh 就緒嗎 | 0 全就緒；1 有缺 |
| `prs <owner/repo>` | 開著的 PR 與各自的判定 | 0；1 問不到 |

共用選項：`--state <dir>`（store，預設 `~\.actci`）、`--distro <name>`。

一個 agent 典型的用法：`prs` 看哪個 PR 還沒判定 → 等 watcher 或自己 `run --sha … --save --push` → 合併前 `gate <sha>`，
只有離開碼 0 才合併。**不要**自己去讀 headline 判斷「看起來有過」，那正是 gate 存在的理由。

2 與 3 分開是刻意的。沒有判定有兩種原因，而它們對呼叫端的意思完全相反：還沒輪到就該等，CI 死了就該去修。
合成一個碼的話，一個 agent 面對停擺的 CI 只會一直等下去 —— 那正是 localci 誕生的那次事故的形狀。
`gate --json` 的 `watcher` 欄位會說是哪一種（never / idle / running / stale / stuck）。

## 需求

- Windows 10/11，WSL2 發行版（預設 Ubuntu）
- Docker Desktop，且在 Settings → Resources → WSL integration 勾選該發行版
- `gh` 已登入（推回 GitHub 與 watcher 需要）
- act 不用自己裝，視窗的環境分頁一鍵裝到 `~/.local/bin`，不需要 sudo
- Pester 5+（只有跑測試才需要）：`Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck`

## 快速開始

1. 雙擊 `actci.exe`（或 `actci.bat`，兩者做同一件事）。
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

**watcher 的事件要選 act 跑得動的那個 workflow 所接受的事件。** act 只跑 `runs-on: ubuntu-*` 的 job；
一個 repo 若 `pull_request` 只觸發 self-hosted 或 windows 的 workflow，act 會全部跳過，判定會是 CI 錯誤
（不是通過）。我自己用它守的那個 repo 就是這樣：PR 的 workflow 是 self-hosted Windows，watcher 得改用
`workflow_dispatch` 去跑那個 Ubuntu 上的檢查 workflow。安裝前用視窗的執行分頁「讀取 job 清單」，看每個 job 的事件欄。

**一個事件觸發多個 workflow 時，一定要指定 Job ID。** 例如同一個 repo 裡「每次檢查」與「每月全套」兩個 workflow
都收 `workflow_dispatch`，不指定的話 act 會兩個都跑，測試數變成兩倍、時間也兩倍。安裝對話框有 Job ID 欄，
命令列是 `-Job validate`。

分支保護可以要求 `actci` 這個 status（私有 repo 要 GitHub Pro 或組織方案；免費方案的私有 repo 沒有分支保護，
門檻只能靠 agent 合併前呼叫 `gate`）。手動執行推的是 `actci/manual`，兩者分開，
避免工作目錄未提交的狀態被當成正式判定。手動執行的判定不存進 store，否則 watcher 會把那個 commit 當成已判定而跳過。

watcher 是排程工作 `actci-watcher`，以 conhost --headless 啟動所以沒有視窗，每 10 分鐘的重複觸發是重啟保險。
安裝器最後會驗 NextRunTime 不為空，因為「它跑得動」跟「它會自己跑」是兩件事。

**改了 `src\` 底下的東西之後要重啟 watcher。** 它是一個長命的行程，模組在它啟動那一刻就載進記憶體了，
之後不管檔案怎麼改都不會重讀。2026-09-09 那次 Docker 自動重啟改完、測試全綠、也推上去了，watcher 卻還在
跑三天前載進去的舊程式。重啟法：

```powershell
Stop-ScheduledTask  -TaskName actci-watcher    # 這一步只是叫它停，重複觸發還是會把它叫回來
Start-ScheduledTask -TaskName actci-watcher
```

要真的暫停（例如手動量測期間）得用 `Disable-ScheduledTask`；只 `Stop-` 的話 10 分鐘後它又自己起來了。
重啟會放棄當下那一輪 act，被放棄的 commit 沒有判定檔，下一圈自然會重跑，不會漏判。

## 檔案

| 路徑 | 用途 |
|---|---|
| `actci.exe` | 帶圖示、無主控台的視窗程式。它把 PowerShell 引擎載進自己的行程來跑 `actci.ps1`，所以視窗屬於 actci.exe 本身，工作列圖示與釘選才會正確。由 `assets\build-exe.ps1` 用 Windows 內建的 csc.exe 編譯 |
| `actci.ps1` / `actci.bat` | 視窗本體，與不用 exe 時的啟動方式 |
| `actci-cli.ps1` | 給機器用的指令列：gate、verdict、status、run、preflight、prs |
| `assets\make-icon.ps1` | 用 GDI+ 畫出 `actci.ico` 與預覽 PNG |
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
| `runner/` | GitHub self-hosted runner 的重啟與看門狗（從 localci 搬來，參數預設值仍是我原本那台機器的） |
| `tests/` | Pester 測試，不需要 Docker 與網路 |

判定與日誌：`~\.actci\verdicts\<sha>.json`、`logs\<sha>.log`、`heartbeat.txt`、`watcher.log`、`watcher.json`。

為什麼在 `~\.actci` 不在 `AppData`：Claude 桌面版是 MSIX 打包的，從它啟動的程序（也就是 AI agent 跑的一切）
寫 `AppData\Local` 會被重導到 `AppData\Local\Packages\Claude_…\LocalCache`，排程 watcher 與使用者雙擊的
程式看不到。2026-09-06 實測同一個 PR 因此跑了兩次。使用者目錄根下的 `.actci` 不受重導。

## 測試

```
powershell -NoProfile -ExecutionPolicy Bypass -File Invoke-Tests.ps1
```

會碰外面的東西（wsl.exe、gh、act、docker）都用 Mock 替掉，因為要測的是**決策**，不是 docker 跑不跑得動。
WSL 相關有三個真的打 wsl.exe 的整合測試，機器上沒有 WSL 會自動跳過。

## 私有 repo：WSL 的 git 需要認證

watcher 每一圈會在 WSL 裡 `git fetch` PR 的 commit。私有 repo 要讓 WSL 的 git 借用 Windows 的
Git Credential Manager（安裝器的前置檢查連不上 origin 時也會印這一行）：

```
wsl -d Ubuntu -- git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"
```

## 已知的 wsl.exe 陷阱

- `-d` 後面的發行版名稱不能加引號，wsl.exe 不會去掉它。
- `--` 後面的字串原封不動交給 Linux 的 shell。用 Windows 雙引號包指令，`$HOME`、`$PATH`、`$(…)` 會被外層 shell 先展開，PATH 裡的 `Program Files (x86)` 一展開就是語法錯誤。要用 bash 單引號包。
- wsl.exe 自己的訊息是 UTF-16LE，Linux 程式的輸出是 UTF-8。

## 限制

- 只能跑 `runs-on: ubuntu-*` 的 job。Windows 與 macOS runner 會被跳過。
- OIDC、GitHub App token 無法模擬；`GITHUB_TOKEN` 由你的 PAT 代替。
- act 的 runner 映像是第三方近似品。本地通過不代表 GitHub 一定通過。
- 測試數解析認不得的框架會被當成 0 支，推 failure。用 `ACTCI_TESTS_RUN=N` 補。
