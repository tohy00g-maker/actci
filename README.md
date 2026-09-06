# actci

在本地 WSL 裡用 [act](https://github.com/nektos/act) 執行任何 repo 的 GitHub Actions workflow，
並把判定推回 GitHub 變成 commit status。Windows 視窗介面加背景 watcher。

這是兩個專案的融合：

- **ActRunner**：PowerShell + WinForms 前端，用 act 跑 workflow，環境一鍵建置。
- **localci**：自架 CI 服務的判定語意（通過與值得相信是兩回事）、輪詢 PR、推回 commit status、心跳與看門狗。

融合的每一條決定與理由見 [DECISIONS.md](DECISIONS.md)。目前程式碼仍是 ActRunner 的原貌，
依 DECISIONS.md 最後一節的順序逐步實作。

## 現階段可用的部分（ActRunner 原有功能）

### 需求

- Windows 10/11，已安裝 WSL2 發行版（預設 Ubuntu）
- Docker Desktop，且在 Settings → Resources → WSL integration 勾選該發行版
- 不需要額外安裝 Python、Node 或其他東西

### 使用

1. 雙擊 `ActRunner.bat`。
2. 按「檢查環境」。四個燈都綠才算就緒：WSL、Docker、act、.actrc。
3. 按「編輯 secrets」，在 `~/.act-secrets` 填入 `GITHUB_TOKEN=你的PAT`。
4. 「瀏覽…」選 repo 資料夾，或直接貼 Linux 路徑。建議 repo 放在 Linux 檔案系統。
5. 「讀取 job 清單」，選事件與 job，按「執行」或直接雙擊 job。

### 限制

- 只能跑 `runs-on: ubuntu-*` 的 job。
- OIDC、GitHub App token 無法模擬；`GITHUB_TOKEN` 由你的 PAT 代替。
- 本地通過不代表 GitHub 一定通過。