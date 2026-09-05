# ActRunner

在本地 WSL 裡用 [act](https://github.com/nektos/act) 執行任何 repo 的 GitHub Actions workflow，
Windows 視窗介面，不用開終端機。

## 需求

- Windows 10/11，已安裝 WSL2 發行版（預設 Ubuntu）
- Docker Desktop，且在 Settings → Resources → WSL integration 勾選該發行版
- 不需要額外安裝 Python、Node 或其他東西；程式本身是 PowerShell + WinForms

## 使用

1. 雙擊 `ActRunner.bat`。
2. 按「檢查環境」。四個燈都綠才算就緒：WSL、Docker、act、.actrc。
   - Docker 紅燈：按「啟動 Docker Desktop」，等一分鐘再檢查。
   - act 紅燈：按「安裝 / 更新 act」，裝到 `~/.local/bin`，不需要 sudo。
   - .actrc 橘燈：按「建立 ~/.actrc」，選 full（20 GB，最像 GitHub）或 medium（500 MB）。
3. 按「編輯 secrets」，在 `~/.act-secrets` 填入 `GITHUB_TOKEN=你的PAT`，一行一個 KEY=value。
4. 「瀏覽…」選 repo 資料夾，或直接貼 Linux 路徑（例如 `/home/me/src/myrepo`）。
   建議 repo 放在 Linux 檔案系統，放 `C:\` 底下會慢很多倍。
5. 「讀取 job 清單」，選事件與 job，按「執行」或直接雙擊 job。
6. 輸出即時顯示在下方，可「儲存 log…」。

## 額外參數範例

| 目的 | 填入 |
|---|---|
| 指定 workflow 檔 | `-W .github/workflows/ci.yml` |
| 帶入事件 payload | `-e event.json` |
| 覆寫矩陣 | `--matrix os:ubuntu-latest` |
| 傳環境變數 | `--env FOO=bar` |
| 換 runner 映像 | `-P ubuntu-latest=catthehacker/ubuntu:full-latest` |

## 限制

- 只能跑 `runs-on: ubuntu-*` 的 job。Windows 與 macOS runner 會被跳過。
- OIDC、GitHub App token 無法模擬；`GITHUB_TOKEN` 由你的 PAT 代替。
- 本地通過不代表 GitHub 一定通過，把它當推送前的快速把關。

設定（上次的發行版、repo 路徑、事件）存在 `%APPDATA%\ActRunner\settings.json`。
