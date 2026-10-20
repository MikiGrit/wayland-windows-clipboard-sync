# Self-elevation check for Administrator rights
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting Administrator privileges..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

Write-Host "==========================================" -ForegroundColor Green
Write-Host " Seamless Clipboard Sync - Windows Setup " -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

$userName = $env:USERNAME
$userProfile = $env:USERPROFILE
$clipDir = Join-Path -Path $userProfile -ChildPath ".clip"

Write-Host "Active User: $userName" -ForegroundColor Cyan
Write-Host "Target Directory: $clipDir" -ForegroundColor Cyan

# Create .clip directory in user profile
New-Item -ItemType Directory -Force -Path $clipDir | Out-Null

# SetClip C# Source (Reads to_win.txt dynamically using Environment User Profile)
$setClipSrc = @"
using System;
using System.IO;
using System.Windows.Forms;

class SetClip {
    [STAThread]
    static void Main() {
        try {
            string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string path = Path.Combine(userProfile, @".clip\to_win.txt");
            if (File.Exists(path)) {
                string text = File.ReadAllText(path);
                if (!string.IsNullOrEmpty(text)) {
                    Clipboard.SetText(text);
                }
            }
        } catch {}
    }
}
"@

# WatchWin C# Source (Listens for Win32 clipboard updates and sends over 127.0.0.1:9999)
$watchWinSrc = @"
using System;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class ClipWatcher : Form {
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool AddClipboardFormatListener(IntPtr hwnd);

    private string lastText = "";

    public ClipWatcher() {
        this.ShowInTaskbar = false;
        this.WindowState = FormWindowState.Minimized;
        this.FormBorderStyle = FormBorderStyle.None;
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        AddClipboardFormatListener(this.Handle);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x031D) {
            try {
                if (Clipboard.ContainsText()) {
                    string text = Clipboard.GetText();
                    if (!string.IsNullOrEmpty(text) && text != lastText) {
                        lastText = text;
                        using (var client = new TcpClient("127.0.0.1", 9999))
                        using (var writer = new StreamWriter(client.GetStream(), Encoding.UTF8)) {
                            writer.Write(text);
                        }
                    }
                }
            } catch {}
        }
        base.WndProc(ref m);
    }

    [STAThread]
    static void Main() {
        Application.Run(new ClipWatcher());
    }
}
"@

Write-Host "[1/3] Compiling windowless C# binaries..." -ForegroundColor Yellow
Add-Type -TypeDefinition $setClipSrc -OutputAssembly "$clipDir\SetClip.exe" -OutputType WindowsApplication -ReferencedAssemblies "System.Windows.Forms.dll", "System.dll"
Add-Type -TypeDefinition $watchWinSrc -OutputAssembly "$clipDir\WatchWin.exe" -OutputType WindowsApplication -ReferencedAssemblies "System.Windows.Forms.dll", "System.dll"

Write-Host "[2/3] Registering Scheduled Tasks..." -ForegroundColor Yellow

# Task 1: Paste Execution Task
$actPaste = New-ScheduledTaskAction -Execute "$clipDir\SetClip.exe"
Register-ScheduledTask -TaskName "PasteWinClip" -Action $actPaste -Force | Out-Null

# Task 2: Background Watcher Execution Task (Triggered at User Logon)
$actWatch = New-ScheduledTaskAction -Execute "$clipDir\WatchWin.exe"
$trigLogon = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName "WatchWinClip" -Action $actWatch -Trigger $trigLogon -Force | Out-Null

Write-Host "[3/3] Verifying output executables..." -ForegroundColor Yellow
if ((Test-Path "$clipDir\SetClip.exe") -and (Test-Path "$clipDir\WatchWin.exe")) {
    Write-Host "Success: Executables compiled to $clipDir" -ForegroundColor Green
} else {
    Write-Host "Error: Binary compilation failed." -ForegroundColor Red
}

Write-Host ""
Write-Host "=== Windows Setup Completed Successfully ===" -ForegroundColor Green
