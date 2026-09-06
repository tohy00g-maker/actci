# 把 actci 做成一個真正的 Windows 程式：actci.exe
#
# 這支 exe 是一個很小的啟動器（C#，用 Windows 內建的 csc.exe 編譯，不需要安裝任何東西）：
# 帶圖示、沒有主控台、有檔案屬性裡的名稱與版本，雙擊就用隱藏的 PowerShell 開 actci.ps1。
# 命令列參數原樣轉給 actci.ps1（例如 -AutoCloseSeconds 10 給煙霧測試）。
#
#     powershell -NoProfile -ExecutionPolicy Bypass -File assets\build-exe.ps1
#     powershell -NoProfile -ExecutionPolicy Bypass -File assets\build-exe.ps1 -StartMenuShortcut
#
# 圖示不存在會先跑 make-icon.ps1。

param(
    [string]$Version = '0.1.0',
    [switch]$StartMenuShortcut
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$ico = Join-Path $PSScriptRoot 'actci.ico'
if (-not (Test-Path $ico)) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'make-icon.ps1') }

$csc = Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path $csc)) { throw "找不到 csc.exe：$csc" }

$source = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("actci")]
[assembly: AssemblyDescription("Local GitHub Actions CI: act in WSL, verdicts pushed back as commit statuses")]
[assembly: AssemblyProduct("actci")]
[assembly: AssemblyCompany("actci")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("$Version.0")]
[assembly: AssemblyFileVersion("$Version.0")]

static class Launcher
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(dir, "actci.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("找不到 actci.ps1，它要和 actci.exe 放在同一個資料夾。\n\n" + script, "actci",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
        string psArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"";
        foreach (string a in args) psArgs += " " + Quote(a);
        var psi = new ProcessStartInfo("powershell.exe", psArgs)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = dir,
        };
        try
        {
            using (var p = Process.Start(psi))
            {
                // 等它結束，離開碼帶回來：這樣 actci.exe -AutoCloseSeconds 10 可以拿來做煙霧測試。
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show("啟動 PowerShell 失敗：" + ex.Message, "actci", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 3;
        }
    }

    static string Quote(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return s;
        return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }
}
"@

$work = Join-Path $env:TEMP 'actci-build'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$cs = Join-Path $work 'Launcher.cs'
[System.IO.File]::WriteAllText($cs, $source, (New-Object System.Text.UTF8Encoding $true))
$exe = Join-Path $root 'actci.exe'

& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$exe" "/win32icon:$ico" /reference:System.Windows.Forms.dll $cs
if ($LASTEXITCODE -ne 0) { throw "csc 失敗（$LASTEXITCODE）" }
$info = Get-Item $exe
"已建置 $exe（$($info.Length) bytes，版本 $((Get-Item $exe).VersionInfo.FileVersion)）"

if ($StartMenuShortcut) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'actci.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = $exe; $sc.WorkingDirectory = $root; $sc.IconLocation = "$exe,0"
    $sc.Description = 'actci — 本地 GitHub Actions CI'
    $sc.Save()
    "已建立開始功能表捷徑 $lnk"
}
