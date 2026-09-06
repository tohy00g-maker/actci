# 把 actci 做成一個真正的 Windows 程式：actci.exe
#
# 用 Windows 內建的 csc.exe 編一個 winexe，不需要安裝任何東西。
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File assets\build-exe.ps1
#     powershell -NoProfile -ExecutionPolicy Bypass -File assets\build-exe.ps1 -StartMenuShortcut
#
# ## 為什麼是在自己的行程裡跑 PowerShell，而不是去啟動 powershell.exe
#
# 第一版是啟動器：actci.exe 開一個隱藏的 powershell.exe 去跑 actci.ps1。功能沒問題，但
# **視窗屬於 powershell.exe**，而工作列的按鈕是按「哪個程序持有這個視窗」取圖示與分組的，
# 所以工作列上顯示的是 PowerShell 的圖示，跟 exe 自己的圖示對不起來（2026-09-06 使用者提出）。
#
# 試過 SetCurrentProcessExplicitAppUserModelID：回傳 S_OK、值也讀得回來，圖示照舊。原因是
# powershell.exe 在我們的腳本執行之前就已經建立了一個隱藏的主控台視窗，AppUserModelID 那時
# 已經定了。
#
# 所以改成把 PowerShell 引擎**載進 actci.exe 自己的行程**：開一個 STA runspace，用目前這條
# 執行緒跑 actci.ps1。視窗就是 actci.exe 開的，工作列圖示、分組、釘選全部自然正確，而且少一
# 個行程。
#
# 圖示不存在會先跑 make-icon.ps1。

param(
    [string]$Version = '0.2.0',
    [switch]$StartMenuShortcut
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ico = Join-Path $PSScriptRoot 'actci.ico'
if (-not (Test-Path $ico)) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'make-icon.ps1') }

$csc = Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path $csc)) { throw "找不到 csc.exe：$csc" }

# PowerShell 引擎的位置從目前這個行程問出來，不要猜 GAC 路徑。
$smaPath = [psobject].Assembly.Location
if (-not (Test-Path $smaPath)) { throw "找不到 System.Management.Automation.dll" }

$source = @"
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("actci")]
[assembly: AssemblyDescription("Local GitHub Actions CI: act in WSL, verdicts pushed back as commit statuses")]
[assembly: AssemblyProduct("actci")]
[assembly: AssemblyCompany("actci")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("$Version.0")]
[assembly: AssemblyFileVersion("$Version.0")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(dir, "actci.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("找不到 actci.ps1，它要和 actci.exe 放在同一個資料夾。\n\n" + script,
                "actci", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }

        // UseCurrentThread：讓腳本跑在這條 STA 主執行緒上，WinForms 的訊息迴圈才會是這個行程的。
        InitialSessionState iss = InitialSessionState.CreateDefault();
        iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
        iss.ApartmentState = ApartmentState.STA;
        iss.ThreadOptions = PSThreadOptions.UseCurrentThread;

        try
        {
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.Open();
                using (System.Management.Automation.PowerShell ps = System.Management.Automation.PowerShell.Create())
                {
                    ps.Runspace = rs;
                    StringBuilder cmd = new StringBuilder();
                    cmd.Append("& '").Append(script.Replace("'", "''")).Append("'");
                    foreach (string a in args) { cmd.Append(' ').Append(Quote(a)); }
                    ps.AddScript(cmd.ToString());

                    var results = ps.Invoke();

                    // 從主控台啟動時（煙霧測試）把輸出帶出去；沒有主控台就安靜地算了。
                    try
                    {
                        foreach (var r in results) { if (r != null) Console.Out.WriteLine(r.ToString()); }
                        foreach (var e in ps.Streams.Error) { Console.Error.WriteLine(e.ToString()); }
                    }
                    catch (IOException) { }

                    if (ps.Streams.Error.Count > 0)
                    {
                        // 視窗開不起來的時候要有人講話，否則雙擊之後什麼都不會發生。
                        var first = ps.Streams.Error[0];
                        if (results.Count == 0)
                        {
                            MessageBox.Show("actci 沒能啟動：\n\n" + first.ToString(), "actci",
                                MessageBoxButtons.OK, MessageBoxIcon.Error);
                            return 1;
                        }
                    }
                }
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show("actci 啟動失敗：\n\n" + ex.Message, "actci", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 3;
        }
        return 0;
    }

    static string Quote(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\t', '"', '\'' }) < 0) return s;
        return "'" + s.Replace("'", "''") + "'";
    }
}
"@

$work = Join-Path $env:TEMP 'actci-build'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$cs = Join-Path $work 'Launcher.cs'
[System.IO.File]::WriteAllText($cs, $source, (New-Object System.Text.UTF8Encoding $true))
$exe = Join-Path $root 'actci.exe'

& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$exe" "/win32icon:$ico" `
    /reference:System.Windows.Forms.dll "/reference:$smaPath" $cs
if ($LASTEXITCODE -ne 0) { throw "csc 失敗（$LASTEXITCODE）" }
"已建置 $exe（$((Get-Item $exe).Length) bytes，版本 $((Get-Item $exe).VersionInfo.FileVersion)）"

if ($StartMenuShortcut) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'actci.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = $exe; $sc.WorkingDirectory = $root; $sc.IconLocation = "$exe,0"
    $sc.Description = 'actci — 本地 GitHub Actions CI'
    $sc.Save()
    "已建立開始功能表捷徑 $lnk"
}
