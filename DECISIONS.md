# actci 融合決議

2026-09-06 逐題確認。actci 是 ActRunner（PowerShell + WinForms，用 act 跑 GitHub Actions）
與 localci（Python，自架 CI 服務，判定推回 GitHub）的融合。兩個來源 repo 都保留不刪。

每一條都寫「決定」與「為什麼」。改動任何一條前先讀完那一條的理由。

---

## 1. 主體：ActRunner 為主，localci 的功能用 PowerShell 重寫搬進來

**為什麼：** 單一語言，不需要 Python 環境；視窗與 WSL 呼叫層已經在 ActRunner 裡。
**代價：** localci 的 7 個 Python 測試檔全部失效，見第 11 條。

## 2. 執行引擎：只用 act，不保留寫死的 Django 腳本

所有專案一律跑自己的 `.github/workflows`，example-app 也是。

**為什麼：** 與 GitHub 上的行為一致，換專案不必改程式碼。
**代價：** 失去 localci 依 requirements 雜湊自建映像的快取，首次執行較慢。act 的
`--action-offline-mode` 與 `--reuse` 部分補回。

## 3. 觸發：watcher 是獨立背景腳本裝成排程工作，視窗只是面板

`watcher.ps1` 每圈：寫心跳 → 用 gh 列開著的 PR → 挑最舊且未判定的 → git archive 該 sha →
act 跑 → 存判定 → 推 commit status。一圈只跑一個 commit。視窗關掉 watcher 照跑。

**為什麼：** 視窗開著才有 CI 是把 CI 綁在一個人的桌面上。localci 的看法一致。

## 4. 判定語意：內建常見框架解析，認不出就標為未驗證

保留 localci 的核心規則：`passed` 與 `is_trustworthy` 分開，`is_trustworthy = passed 且 tests_run > 0`。

tests_run 從 act 的輸出解析，支援的結尾統計行：

| 框架 | 樣式 |
|---|---|
| Django / unittest | `Ran N tests in` |
| pytest | `N passed`（含 `N passed, M failed` 等變形） |
| jest / vitest | `Tests: ... N total` |
| go test | `ok ` 行數，或 `-v` 下的 `--- PASS` 計數 |
| cargo test | `test result: ok. N passed` |
| dotnet test | `Passed! - Failed: 0, Passed: N` |

一個都抓不到的通過：`tests_run = 0`，不算 trustworthy，headline 寫「沒抓到測試數」，
推回 GitHub 是 `failure`。

**為什麼：** localci README 記錄了三次「0 支測試的通過看起來與真的通過一樣」的事故。
只看 exit code 就是重犯。

## 5. 推回 GitHub：保留，手動執行也可勾選推回

- watcher 推的 context 是 `actci`。
- 視窗手動執行有「推回 GitHub」勾選，預設關，推的 context 是 `actci/manual`。
- 分支保護只要求 `actci`。
- state 對應沿用 localci：errored → `error`；passed 且 tests_run = 0 → `failure`；
  passed → `success`；failed → `failure`。開跑先推 `pending`。
- 用 gh，不自己管 token。不自動合併。

**為什麼：** 手動與自動分 context，避免工作目錄未 commit 的狀態被當成正式判定。

## 6. 範圍縮減：拿掉，交給 workflow 自己

localci 的 scope.py 不搬。專案想省時間就在 workflow 用 `paths:`、`paths-ignore:` 與 job 層的 `if:`。

**為什麼：** 那是在重做 GitHub Actions 已有的功能，而且 localci 自己已經實測發現
「只改文件就不跑」這條規則在 example-app 上是錯的。

## 7. 圖形介面：同一個 WinForms 視窗，三個分頁

- **執行**：現在的手動面板（選 repo、讀 job、選事件、執行、串流 log），加「推回 GitHub」勾選。
- **監看**：watcher 心跳幾秒前（每秒重算，超過門檻變色）、最近判定列表、排程工作啟停、
  監看哪個 repo 與 slug 的設定。
- **環境**：WSL / Docker / act / .actrc 檢查與一鍵安裝，secrets 編輯。

心跳顯示邏輯沿用 localci ui.py：不顯示「上次幾點」，顯示「幾秒前」，停了會自己爬上去變色。

## 8. Docker 位置：全部走 WSL

act、docker、git archive 都在 WSL 內執行。watcher 排程工作是 Windows 的 PowerShell，
透過 wsl.exe 下指令。repo 建議放 Linux 檔案系統。

已知的 wsl.exe 陷阱（ActRunner 踩過）：`-d` 後的發行版名稱不能加引號；wsl.exe 自身訊息
是 UTF-16LE 而 Linux 程式輸出是 UTF-8，要依零位元組比例判斷。

## 9. 環境建置：放在「環境」分頁

由第 7 條決定。

## 10. 排程、心跳、看門狗：全部搬，含 self-hosted runner 的重啟與看門狗

- `install_watcher.ps1`：裝排程工作，含 localci 的第 5 步驗證「NextRunTime 不為空」，
  防「裝了但永遠不會自己醒來」。
- 心跳寫在 watcher 迴圈頂端。
- `runner/` 下的 `restart_runner.ps1`、`runner_watchdog.ps1`、`install_runner_watchdog.ps1`
  等一起搬，但 `C:\actions-runner`、`Example-CI-Runner` 這些寫死的值改成參數預設值。

**為什麼：** 使用者要一個地方放所有本地 CI 工具。runner 看門狗雖然服務的是這套工具
想取代的東西，但過渡期兩者並存。

## 11. 測試：Pester 重寫，對應 localci 每一個測試檔

| localci | actci |
|---|---|
| test_verdict.py | Verdict.Tests.ps1（trustworthy、headline、JSON 往返、忽略未知欄位） |
| test_scope_and_status.py | Status.Tests.ps1（state 對應；scope 不搬） |
| test_store_and_cli.py | Store.Tests.ps1（存取、心跳、recent） |
| test_watcher.py | Watcher.Tests.ps1（一圈的決策，wsl.exe 與 gh 用 Mock） |
| test_ui.py | Dashboard.Tests.ps1（幾秒前的計算與變色門檻，不開視窗） |
| test_runner_watchdog_script.py | RunnerWatchdog.Tests.ps1 |
| test_restart_runner_script.py | RestartRunner.Tests.ps1 |
| （新）| Parse.Tests.ps1（各框架 tests_run 解析、act -l 解析、路徑轉換） |

不需要 Docker 與網路。現有的 `-SelfTest` 保留為快速煙霧測試。

## 12. 儲存庫：新開 actci，ActRunner 與 localci 都留著

- actci 以 ActRunner 的 git 歷史為起點。
- localci 完成交接後在 README 標註已被 actci 取代並指向新 repo，不刪。
- ActRunner 保留為單純的 act 前端。

## 13. 名稱：actci

排程工作名 `actci-watcher`，commit status context `actci`，狀態目錄 `%USERPROFILE%\.actci`。

第一版寫的是 `%LOCALAPPDATA%\actci`，2026-09-06 當天改掉：Claude 桌面版是 MSIX 打包，從它啟動的程序寫
AppData 會被重導到套件快取，排程 watcher 看不到 AI 存的判定，同一個 PR 跑了兩次。

## 14. 主要使用者是 AI，視窗是給人看的（2026-09-06 補）

使用者原話：「這套軟體主要是給 AI 用的、只是我私心希望他可視化，也可支援手動。」所以：
`actci-cli.ps1` 是主要介面，離開碼就是 API（gate 0/1/2），一切輸出可 `--json`；視窗與手動執行沿用但不是設計中心。
任何新功能先問「agent 怎麼呼叫它、怎麼讀結果」，再問視窗要不要有按鈕。

---

## 15. Docker 沒開就自己開回來，不要把它寫成 commit 的判定（2026-09-09 補）

2026-09-09 凌晨 Docker Desktop 自己關了。watcher 06:46 拿到 PR #715，前置檢查回 `nointegration`，
那個 commit 就被推成 `error`。畫面上它跟「CI 自己出問題」一模一樣，但它其實只是「請把 Docker 打開」——
而且它會佔住那個 sha 的判定檔，接下來 30 分鐘 watcher 都不會再看它一眼。

「Docker 沒開」不是那個 commit 的判定。跟第 12 條「有人在跑不是判定」是同一個道理。

所以 `Invoke-ActRun` 在前置檢查回 `nodocker` / `nodaemon` / `nointegration` 時，先 `Restore-DockerEngine`：
啟動 Docker Desktop，然後每 5 秒重跑一次前置檢查，最多等 180 秒。等到了就照常跑，那個 commit 一樣拿得到
真正的判定，只在註記裡留一句「Docker 原本沒開，已自動重啟」。等不到才認賠成 errored，而且註記要說出
已經試過重啟 —— 不然下一個人看到 error 又得從頭查一次同一件事。

三個界線：

- **只在 docker 那三種前置檢查碼下重啟。** 測試真的失敗時去重啟 Docker 只會白等三分鐘，還會讓人以為
  問題出在環境。有一支測試就是盯著這件事。
- **等待用輪詢前置檢查，不看「程序在不在」。** Docker Desktop 的視窗程序起來之後，daemon 還要一段時間
  才接受連線，WSL integration 又更晚。程序在，不代表 act 跑得動。
- **啟動之前不先探一次。** 呼叫端是在前置檢查剛失敗之後才叫它的，開頭再探一次只是白白多等一輪。

`Start-DockerDesktop` / `Restore-DockerEngine` 的 Starter / Prober / Sleeper 都可注入，測試不碰真的 Docker、
也不真的睡。`-NoDockerRestart` 關掉整段。

同一天的另一半：`run <repo>` 收到不存在的相對路徑會直接擋掉。當天有人把 GitHub slug 打成 repo 路徑，
`git archive` 在 WSL 裡失敗，而那條路徑會產出一份 `outcome=errored` 的判定 —— 存下去就蓋掉同一個 sha 上
真正的判定。打錯字不該變成一個 commit 的判決。

（附帶一提：Pester 6 拿掉了 `Assert-MockCalled`。寫成那樣時 PowerShell 會為了找它自動載入系統內建的
Pester 3.4.0，然後 3.4.0 的 `BeforeAll` 會蓋掉之後每一個測試檔的探索。一律用 `Should -Invoke`。）

---

## 實作順序

1. **判定與儲存**：Verdict 型別、Store（JSON 一 commit 一檔、心跳、recent）、tests_run 解析器，附 Pester。
2. **執行核心抽出**：把 ActRunner 的 act 呼叫抽成可被視窗與 watcher 共用的模組，加 git archive 該 sha 到暫存目錄再跑。
3. **推回 GitHub**：state 對應、pending、gh 呼叫，附 Pester。
4. **watcher 與排程安裝器**：一圈的決策、迴圈不因單一 PR 出事而停、NextRunTime 驗證。
5. **視窗三分頁**：執行頁加勾選、監看頁、環境頁搬現有內容。
6. **runner/ 腳本搬入並參數化**。
7. **README 與 localci 交接標註**。
