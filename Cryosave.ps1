<#
.SYNOPSIS
    System tray application for Cryosave.
.DESCRIPTION
    Runs in the notification area (system tray).
    Left-click or right-click the icon to open the menu.
    Features: Save, Save+Close, Restore, auto-save toggle, self-restart.
#>

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:CryosaveVersion = '1.4.0'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# DPI awareness — ensures GetWindowRect and Screen.Bounds use the same coordinate space
if (-not ([System.Management.Automation.PSTypeName]'DpiHelper').Type) {
    Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class DpiHelper { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
}
[DpiHelper]::SetProcessDPIAware() | Out-Null

. "$root\lib\WinApi.ps1"

# ── Single-instance guard ──

$script:mutex = New-Object System.Threading.Mutex($false, 'CryosaveTray')
if (-not $script:mutex.WaitOne(0)) {
    exit 0
}

# ── Load config ──

$configPath = Join-Path $root 'config.json'
$config = @{ maxSaves = 10; restoreDelayMs = 1500; enableToastNotifications = $true; autoSaveMinutes = 5 }
if (Test-Path $configPath) {
    try { $config = Get-Content $configPath -Raw | ConvertFrom-Json } catch { }
}

# ── Add C# helper classes: CryoColors + CryoIcons ──

if (-not ([System.Management.Automation.PSTypeName]'CryoColors').Type) {
    Add-Type -IgnoreWarnings -ReferencedAssemblies @(
        'System.Windows.Forms'
        'System.Drawing'
    ) -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class CryoColors : ProfessionalColorTable {
    public override Color MenuItemSelected { get { return Color.FromArgb(224, 244, 255); } }
    public override Color MenuItemBorder { get { return Color.FromArgb(0, 168, 232); } }
    public override Color MenuItemSelectedGradientBegin { get { return Color.FromArgb(224, 244, 255); } }
    public override Color MenuItemSelectedGradientEnd { get { return Color.FromArgb(200, 235, 255); } }
    public override Color MenuItemPressedGradientBegin { get { return Color.FromArgb(180, 225, 245); } }
    public override Color MenuItemPressedGradientEnd { get { return Color.FromArgb(160, 215, 240); } }
    public override Color ToolStripDropDownBackground { get { return Color.White; } }
    public override Color ImageMarginGradientBegin { get { return Color.FromArgb(240, 248, 255); } }
    public override Color ImageMarginGradientMiddle { get { return Color.FromArgb(240, 248, 255); } }
    public override Color ImageMarginGradientEnd { get { return Color.FromArgb(240, 248, 255); } }
    public override Color SeparatorDark { get { return Color.FromArgb(190, 220, 240); } }
    public override Color SeparatorLight { get { return Color.FromArgb(230, 242, 250); } }
    public override Color CheckBackground { get { return Color.FromArgb(200, 235, 255); } }
    public override Color CheckSelectedBackground { get { return Color.FromArgb(180, 225, 245); } }
    public override Color CheckPressedBackground { get { return Color.FromArgb(160, 215, 240); } }
}

public static class CryoIcons {
    private static Color IceBlue = Color.FromArgb(0, 180, 235);
    private static Color IceLight = Color.FromArgb(100, 210, 255);
    private const int S = 20;

    public static Image Snowflake() {
        var bmp = new Bitmap(S, S);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            var pen = new Pen(IceBlue, 1.6f);
            float cx = S/2f, cy = S/2f, r = 7f;
            for (int i = 0; i < 6; i++) {
                double a = Math.PI / 3 * i;
                float x2 = cx + (float)(Math.Cos(a) * r);
                float y2 = cy + (float)(Math.Sin(a) * r);
                g.DrawLine(pen, cx, cy, x2, y2);
                float bx = cx + (float)(Math.Cos(a) * r * 0.55);
                float by = cy + (float)(Math.Sin(a) * r * 0.55);
                float bl = r * 0.35f;
                g.DrawLine(pen, bx, by, bx + (float)(Math.Cos(a + 0.7) * bl), by + (float)(Math.Sin(a + 0.7) * bl));
                g.DrawLine(pen, bx, by, bx + (float)(Math.Cos(a - 0.7) * bl), by + (float)(Math.Sin(a - 0.7) * bl));
            }
            pen.Dispose();
        }
        return bmp;
    }

    public static Image SnowflakeClose() {
        var bmp = new Bitmap(S, S);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            var pen = new Pen(IceBlue, 1.4f);
            float cx = 7, cy = 8.5f, r = 5.5f;
            for (int i = 0; i < 6; i++) {
                double a = Math.PI / 3 * i;
                g.DrawLine(pen, cx, cy, cx + (float)(Math.Cos(a) * r), cy + (float)(Math.Sin(a) * r));
            }
            pen.Dispose();
            var xpen = new Pen(Color.FromArgb(220, 50, 50), 2.0f);
            g.DrawLine(xpen, 12, 12, 18, 18);
            g.DrawLine(xpen, 18, 12, 12, 18);
            xpen.Dispose();
        }
        return bmp;
    }

    public static Image Thaw() {
        var bmp = new Bitmap(S, S);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            var brush = new SolidBrush(Color.FromArgb(255, 180, 30));
            g.FillEllipse(brush, 5, 5, 10, 10);
            brush.Dispose();
            var pen = new Pen(Color.FromArgb(255, 200, 60), 1.4f);
            float cx = S/2f, cy = S/2f;
            for (int i = 0; i < 8; i++) {
                double a = Math.PI / 4 * i;
                g.DrawLine(pen, cx + (float)(Math.Cos(a) * 6.5), cy + (float)(Math.Sin(a) * 6.5),
                               cx + (float)(Math.Cos(a) * 8.5), cy + (float)(Math.Sin(a) * 8.5));
            }
            pen.Dispose();
        }
        return bmp;
    }

    public static Image Info() {
        var bmp = new Bitmap(S, S);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            var brush = new SolidBrush(Color.FromArgb(100, 160, 220));
            g.FillEllipse(brush, 2, 2, 16, 16);
            brush.Dispose();
            var font = new Font("Segoe UI", 9f, FontStyle.Bold);
            var white = new SolidBrush(Color.White);
            var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString("i", font, white, new RectangleF(2, 2, 16, 16), sf);
            font.Dispose(); white.Dispose(); sf.Dispose();
        }
        return bmp;
    }

    public static Image FolderOpen() {
        var bmp = new Bitmap(S, S);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            var back = new SolidBrush(Color.FromArgb(220, 180, 60));
            g.FillRectangle(back, 1, 5, 18, 12);
            back.Dispose();
            var tab = new SolidBrush(Color.FromArgb(240, 200, 80));
            g.FillRectangle(tab, 1, 3, 8, 3);
            tab.Dispose();
            var front = new SolidBrush(Color.FromArgb(245, 210, 90));
            PointF[] pts = { new PointF(0,9), new PointF(3,18), new PointF(19,18), new PointF(17,9) };
            g.FillPolygon(front, pts);
            front.Dispose();
        }
        return bmp;
    }

    public static Image ListIcon() {
        var bmp = new Bitmap(S, S);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            var pen = new Pen(Color.FromArgb(80, 130, 180), 1.6f);
            var dot = new SolidBrush(Color.FromArgb(0, 168, 232));
            for (int i = 0; i < 3; i++) {
                int y = 4 + i * 5;
                g.FillEllipse(dot, 2, y, 4, 4);
                g.DrawLine(pen, 8, y + 2f, 17, y + 2f);
            }
            pen.Dispose(); dot.Dispose();
        }
        return bmp;
    }

    public static Image Timer() {
        var bmp = new Bitmap(S, S);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            var pen = new Pen(Color.FromArgb(80, 150, 80), 1.6f);
            g.DrawEllipse(pen, 2, 2, 16, 16);
            g.DrawLine(pen, S/2f, S/2f, S/2f, 5);
            g.DrawLine(pen, S/2f, S/2f, 14, 11);
            pen.Dispose();
        }
        return bmp;
    }

    public static Image Restart() {
        var bmp = new Bitmap(S, S);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            var pen = new Pen(Color.FromArgb(80, 140, 200), 1.8f);
            g.DrawArc(pen, 3, 3, 14, 14, -60, 300);
            var brush = new SolidBrush(Color.FromArgb(80, 140, 200));
            PointF[] arrow = { new PointF(14, 3), new PointF(17, 6), new PointF(13, 7) };
            g.FillPolygon(brush, arrow);
            pen.Dispose(); brush.Dispose();
        }
        return bmp;
    }

    public static Image Exit() {
        var bmp = new Bitmap(S, S);
        using (var g = Graphics.FromImage(bmp)) {
            g.SmoothingMode = SmoothingMode.HighQuality;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            var pen = new Pen(Color.FromArgb(140, 140, 140), 1.5f);
            g.DrawRectangle(pen, 2, 2, 10, 16);
            pen.Dispose();
            var apen = new Pen(Color.FromArgb(200, 60, 60), 1.8f);
            g.DrawLine(apen, 10, S/2f, 18, S/2f);
            g.DrawLine(apen, 15, 7, 18, S/2f);
            g.DrawLine(apen, 15, 13, 18, S/2f);
            apen.Dispose();
        }
        return bmp;
    }
}
'@
}

# ── UIA tab counter (counts actual tabs per WT window via UI Automation) ──

if (-not ([System.Management.Automation.PSTypeName]'UiaTabCounter').Type) {
    Add-Type -IgnoreWarnings -ReferencedAssemblies @('UIAutomationClient','UIAutomationTypes') -TypeDefinition @'
using System;
using System.Threading;
using System.Windows.Automation;

public static class UiaTabCounter {
    public static int CountTabs(IntPtr hWnd, int timeoutMs) {
        int result = -1;
        var thread = new Thread(() => {
            try {
                var root = AutomationElement.FromHandle(hWnd);
                var tabItems = root.FindAll(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.TabItem));
                result = tabItems.Count > 0 ? tabItems.Count : 1;
            } catch {
                result = 1;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!thread.Join(timeoutMs)) {
            thread.Abort();
            return 1;
        }
        return result;
    }
}
'@
}

# ── Generate tray icon (ice-blue snowflake on transparent bg) ──

function New-CryoIcon {
    $bmp = New-Object System.Drawing.Bitmap(16, 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $ice = [System.Drawing.Color]::FromArgb(0, 212, 255)
    $pen = New-Object System.Drawing.Pen($ice, 1.6)

    $cx = 8; $cy = 8; $r = 6
    for ($i = 0; $i -lt 6; $i++) {
        $angle = [Math]::PI / 3 * $i
        $x2 = $cx + [Math]::Cos($angle) * $r
        $y2 = $cy + [Math]::Sin($angle) * $r
        $g.DrawLine($pen, $cx, $cy, [float]$x2, [float]$y2)
        $bx = $cx + [Math]::Cos($angle) * ($r * 0.6)
        $by = $cy + [Math]::Sin($angle) * ($r * 0.6)
        $ba1 = $angle + [Math]::PI / 4
        $ba2 = $angle - [Math]::PI / 4
        $bl = $r * 0.3
        $g.DrawLine($pen, [float]$bx, [float]$by, [float]($bx + [Math]::Cos($ba1) * $bl), [float]($by + [Math]::Sin($ba1) * $bl))
        $g.DrawLine($pen, [float]$bx, [float]$by, [float]($bx + [Math]::Cos($ba2) * $bl), [float]($by + [Math]::Sin($ba2) * $bl))
    }

    $pen.Dispose()
    $g.Dispose()

    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    return $icon
}

# ── Create tray icon ──

$tray = New-Object System.Windows.Forms.NotifyIcon
try { $tray.Icon = New-CryoIcon } catch { $tray.Icon = [System.Drawing.SystemIcons]::Application }
$tray.Text = 'Cryosave'
$tray.Visible = $true

# ── Helpers ──

function Invoke-Save {
    try {
        $saveScript = Join-Path $root 'Freeze.ps1'
        Start-Process powershell.exe -ArgumentList @(
            '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', $saveScript, '-Silent'
        ) -WindowStyle Hidden
    } catch {
        $tray.ShowBalloonTip(3000, 'Error', "Save failed: $_", [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

function Invoke-SaveAndClose {
    try {
        $saveScript = Join-Path $root 'Freeze.ps1'
        Start-Process powershell.exe -ArgumentList @(
            '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', $saveScript, '-Silent', '-Close'
        ) -WindowStyle Hidden
    } catch {
        $tray.ShowBalloonTip(3000, 'Error', "Save failed: $_", [System.Windows.Forms.ToolTipIcon]::Error)
    }
}

# ── HUD: Live window detection ──

function Get-LiveWindowInfo {
    $handles = [WinApi]::FindWindowsByClass("CASCADIA_HOSTING_WINDOW_CLASS")
    if (-not $handles -or $handles.Count -eq 0) { return @() }

    # Get window info for each handle
    $windows = @()
    $wtPids = @()
    foreach ($h in $handles) {
        $info = [WinApi]::GetWindowInfoFromHandle($h)
        $windows += $info
        if ($info.Pid -notin $wtPids) { $wtPids += $info.Pid }
    }

    # Walk process tree (same as Freeze.ps1 lines 62-87)
    $allProcs = Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction SilentlyContinue

    # Direct children of WT that are shells
    $shells = $allProcs | Where-Object {
        $_.ParentProcessId -in $wtPids -and
        $_.Name -ne "OpenConsole.exe" -and
        $_.Name -match "powershell|pwsh|cmd|bash|ssh|conhost|wsl|nu"
    }

    # Also find shells under OpenConsole
    $openConsoles = $allProcs | Where-Object { $_.Name -eq "OpenConsole.exe" -and $_.ParentProcessId -in $wtPids }
    $ocPids = $openConsoles | ForEach-Object { $_.ProcessId }
    $ocShells = $allProcs | Where-Object {
        $_.ParentProcessId -in $ocPids -and $_.Name -ne "OpenConsole.exe"
    }
    if ($ocShells) { $shells = @($shells) + @($ocShells) }

    # Find Claude node.exe descendants (up to 3 levels deep)
    $shellPids = $shells | ForEach-Object { $_.ProcessId }
    $level1 = $allProcs | Where-Object { $_.ParentProcessId -in $shellPids }
    $level1Pids = $level1 | ForEach-Object { $_.ProcessId }
    $level2 = $allProcs | Where-Object { $_.ParentProcessId -in $level1Pids }
    $level2Pids = $level2 | ForEach-Object { $_.ProcessId }
    $level3 = $allProcs | Where-Object { $_.ParentProcessId -in $level2Pids }
    $allChildren = @($shells) + @($level1) + @($level2) + @($level3)

    $claudeByPid = @{}
    foreach ($proc in $allChildren) {
        if ($proc.Name -eq 'node.exe' -and $proc.CommandLine -match 'claude') {
            # Find which WT PID this belongs to by tracing up
            $parentShell = $shells | Where-Object { $_.ProcessId -eq $proc.ParentProcessId }
            if (-not $parentShell) {
                $parentShell = $allChildren | Where-Object { $_.ProcessId -eq $proc.ParentProcessId }
            }
            foreach ($wtPid in $wtPids) {
                $pidShells = $shells | Where-Object {
                    $p = $_.ParentProcessId
                    if ($p -in $ocPids) {
                        $oc = $openConsoles | Where-Object { $_.ProcessId -eq $p }
                        if ($oc) { $p = $oc.ParentProcessId }
                    }
                    $p -eq $wtPid
                }
                $pidShellIds = $pidShells | ForEach-Object { $_.ProcessId }
                # Check if this node.exe descends from a shell in this WT
                $ancestor = $proc
                for ($i = 0; $i -lt 4; $i++) {
                    if ($ancestor.ParentProcessId -in $pidShellIds) {
                        if (-not $claudeByPid.ContainsKey($wtPid)) { $claudeByPid[$wtPid] = 0 }
                        $claudeByPid[$wtPid]++
                        break
                    }
                    $ancestor = $allProcs | Where-Object { $_.ProcessId -eq $ancestor.ParentProcessId } | Select-Object -First 1
                    if (-not $ancestor) { break }
                }
            }
        }
    }

    # Build result — use UIA for accurate per-window tab counts
    $result = @()
    foreach ($w in $windows) {
        $wpid = [uint32]$w.Pid
        $claudeTabs = if ($claudeByPid.ContainsKey($wpid)) { $claudeByPid[$wpid] } else { 0 }
        $totalTabs = [UiaTabCounter]::CountTabs($w.Handle, 1500)
        $result += @{
            Handle    = $w.Handle
            Left      = $w.Left
            Top       = $w.Top
            Width     = $w.Width
            Height    = $w.Height
            Title     = $w.Title
            TotalTabs = $totalTabs
            ClaudeTabs = $claudeTabs
            HasClaude = ($claudeTabs -gt 0)
        }
    }
    return $result
}

# ── HUD: Creates a custom-painted panel for the context menu ──

function New-HudPanel {
    $panelW = 280
    $panelH = 160
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Size = New-Object System.Drawing.Size($panelW, $panelH)
    $panel.BackColor = [System.Drawing.Color]::FromArgb(18, 24, 40)

    $panel.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

        $screens = [System.Windows.Forms.Screen]::AllScreens
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen

        # Scaling — uniform to preserve aspect ratio, centered in panel
        $pad = 10
        $pw = $s.ClientSize.Width
        $ph = $s.ClientSize.Height
        $drawW = $pw - 2 * $pad
        $drawH = $ph - 2 * $pad
        $scale = [Math]::Min($drawW / $vs.Width, $drawH / $vs.Height)
        $offX = $pad + ($drawW - $vs.Width * $scale) / 2
        $offY = $pad + ($drawH - $vs.Height * $scale) / 2

        # Monitor outlines
        $monPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(120, 255, 255, 255), 1.0)
        $monFont = New-Object System.Drawing.Font('Segoe UI', 6.5)
        $monBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(100, 200, 200, 200))
        $idx = 0
        foreach ($scr in $screens) {
            $idx++
            $b = $scr.Bounds
            $sx = $offX + ($b.X - $vs.X) * $scale
            $sy = $offY + ($b.Y - $vs.Y) * $scale
            $sw = $b.Width * $scale
            $sh = $b.Height * $scale
            $g.DrawRectangle($monPen, [float]$sx, [float]$sy, [float]$sw, [float]$sh)
            $g.DrawString("$idx", $monFont, $monBrush, [float]($sx + 3), [float]($sy + 2))
        }
        $monPen.Dispose(); $monFont.Dispose(); $monBrush.Dispose()

        # WT windows
        $faintPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 150, 150, 150), 0.8)
        $faintPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dot
        $cornerPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(220, 0, 180, 235), 2.5)
        $cornerPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $cornerPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $fillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(45, 0, 180, 235))
        $countFont = New-Object System.Drawing.Font('Segoe UI', 7, [System.Drawing.FontStyle]::Bold)
        $countBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $countSf = New-Object System.Drawing.StringFormat
        $countSf.Alignment = [System.Drawing.StringAlignment]::Center
        $countSf.LineAlignment = [System.Drawing.StringAlignment]::Center

        foreach ($w in $script:hudData) {
            $wx = $offX + ($w.Left - $vs.X) * $scale
            $wy = $offY + ($w.Top - $vs.Y) * $scale
            $ww = $w.Width * $scale
            $wh = $w.Height * $scale

            if ($w.HasClaude) {
                $g.FillRectangle($fillBrush, [float]$wx, [float]$wy, [float]$ww, [float]$wh)

                # Cornerless rectangle (4 L-shaped corners)
                $L = [Math]::Max(6, [Math]::Min(20, [Math]::Min($ww, $wh) * 0.2))

                # Top-left
                $g.DrawLine($cornerPen, [float]$wx, [float]$wy, [float]($wx + $L), [float]$wy)
                $g.DrawLine($cornerPen, [float]$wx, [float]$wy, [float]$wx, [float]($wy + $L))
                # Top-right
                $g.DrawLine($cornerPen, [float]($wx + $ww), [float]$wy, [float]($wx + $ww - $L), [float]$wy)
                $g.DrawLine($cornerPen, [float]($wx + $ww), [float]$wy, [float]($wx + $ww), [float]($wy + $L))
                # Bottom-left
                $g.DrawLine($cornerPen, [float]$wx, [float]($wy + $wh), [float]($wx + $L), [float]($wy + $wh))
                $g.DrawLine($cornerPen, [float]$wx, [float]($wy + $wh), [float]$wx, [float]($wy + $wh - $L))
                # Bottom-right
                $g.DrawLine($cornerPen, [float]($wx + $ww), [float]($wy + $wh), [float]($wx + $ww - $L), [float]($wy + $wh))
                $g.DrawLine($cornerPen, [float]($wx + $ww), [float]($wy + $wh), [float]($wx + $ww), [float]($wy + $wh - $L))
            } else {
                $g.DrawRectangle($faintPen, [float]$wx, [float]$wy, [float]$ww, [float]$wh)
            }

            # Tab count — only show when window has 2+ tabs
            if ($w.TotalTabs -gt 1) {
                $rect = New-Object System.Drawing.RectangleF([float]$wx, [float]$wy, [float]$ww, [float]$wh)
                $g.DrawString($w.TotalTabs.ToString(), $countFont, $countBrush, $rect, $countSf)
            }
        }

        $faintPen.Dispose(); $cornerPen.Dispose(); $fillBrush.Dispose()
        $countFont.Dispose(); $countBrush.Dispose(); $countSf.Dispose()
    })

    return $panel
}

# ── Styled context menu ──

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowItemToolTips = $true
$menu.ShowImageMargin = $true
$menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer(
    (New-Object CryoColors)
)
$menu.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

# ── Header: App name with snowflake icon ──

$header = New-Object System.Windows.Forms.ToolStripLabel
$header.Text = 'Cryosave -- Session Manager'
$header.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$header.ForeColor = [System.Drawing.Color]::FromArgb(0, 168, 232)
$header.Image = [CryoIcons]::Snowflake()
$header.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$header.AutoSize = $false
$header.Width = 280
$header.Padding = New-Object System.Windows.Forms.Padding(20, 4, 0, 0)
$menu.Items.Add($header) | Out-Null

$hint = New-Object System.Windows.Forms.ToolStripLabel
$hint.Text = 'Hover items for details'
$hint.Font = New-Object System.Drawing.Font('Segoe UI', 7.5, [System.Drawing.FontStyle]::Italic)
$hint.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
$hint.AutoSize = $false
$hint.Width = 280
$hint.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$hint.Padding = New-Object System.Windows.Forms.Padding(20, 0, 0, 2)
$menu.Items.Add($hint) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# ── HUD panel embedded in menu ──

$script:hudData = @()
$script:hudPanel = New-HudPanel
$hudHost = New-Object System.Windows.Forms.ToolStripControlHost($script:hudPanel)
$hudHost.AutoSize = $false
$hudHost.Size = $script:hudPanel.Size
$hudHost.Margin = New-Object System.Windows.Forms.Padding(0)
$hudHost.Padding = New-Object System.Windows.Forms.Padding(0)
$hudHost.BackColor = [System.Drawing.Color]::FromArgb(18, 24, 40)
$menu.Items.Add($hudHost) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# ── Last save info (at the top, before action items) ──

$infoItem = New-Object System.Windows.Forms.ToolStripMenuItem('Last save: (none)')
$infoItem.Image = [CryoIcons]::Info()
$infoItem.Enabled = $false
$infoItem.ToolTipText = 'Shows when you last saved your workspace and how many windows/tabs were captured'
$menu.Items.Add($infoItem) | Out-Null

# Update info label + HUD when menu opens
$menu.Add_Opening({
    $latestPath = Join-Path $root 'saves\latest.json'
    if (Test-Path $latestPath) {
        try {
            $data = Get-Content $latestPath -Raw | ConvertFrom-Json
            $tabs = ($data.windows | ForEach-Object { $_.tabs.Count } | Measure-Object -Sum).Sum
            $infoItem.Text = "Last save: $($data.savedAt)  ($($data.windows.Count) win, $tabs tabs)"
        } catch {
            $infoItem.Text = 'Last save: (error reading)'
        }
    } else {
        $infoItem.Text = 'Last save: (none)'
    }
    # Refresh HUD data and repaint
    $script:hudData = Get-LiveWindowInfo
    $script:hudPanel.Invalidate()
})

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# ── Save Workspace ──

$saveItem = New-Object System.Windows.Forms.ToolStripMenuItem('Save Workspace')
$saveItem.Image = [CryoIcons]::Snowflake()
$saveItem.ToolTipText = 'Save all terminal windows, tabs, and Claude Code sessions to a snapshot file'
$saveItem.Add_Click({ Invoke-Save })
$menu.Items.Add($saveItem) | Out-Null

# ── Save & Close ──

$saveCloseItem = New-Object System.Windows.Forms.ToolStripMenuItem('Save && Close')
$saveCloseItem.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$saveCloseItem.Image = [CryoIcons]::SnowflakeClose()
$saveCloseItem.ToolTipText = 'Save everything, then close all Windows Terminal windows running Claude Code'
$saveCloseItem.Add_Click({ Invoke-SaveAndClose })
$menu.Items.Add($saveCloseItem) | Out-Null

# ── Restore Workspace ──

$restoreItem = New-Object System.Windows.Forms.ToolStripMenuItem('Restore Workspace')
$restoreItem.Image = [CryoIcons]::Thaw()
$restoreItem.ToolTipText = 'Re-open terminal windows and Claude Code sessions from your last save'
$restoreItem.Add_Click({
    $latestPath = Join-Path $root 'saves\latest.json'
    if (-not (Test-Path $latestPath)) {
        $tray.ShowBalloonTip(3000, 'No Saves', 'No saved workspace found. Save first.', [System.Windows.Forms.ToolTipIcon]::Warning)
        return
    }
    $restoreScript = Join-Path $root 'Thaw.ps1'
    Start-Process powershell.exe -ArgumentList @(
        '-ExecutionPolicy', 'Bypass', '-File', $restoreScript
    )
})
$menu.Items.Add($restoreItem) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# ── List Saves ──

$listItem = New-Object System.Windows.Forms.ToolStripMenuItem('List Saves')
$listItem.Image = [CryoIcons]::ListIcon()
$listItem.ToolTipText = 'Show your recent workspace snapshots'
$listItem.Add_Click({
    $savesDir = Join-Path $root 'saves'
    if (-not (Test-Path $savesDir)) {
        $tray.ShowBalloonTip(3000, 'No Saves', 'No saves directory found.', [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }
    $files = Get-ChildItem -Path $savesDir -Filter '20*.json' | Sort-Object Name -Descending
    if ($files.Count -eq 0) {
        $tray.ShowBalloonTip(3000, 'No Saves', 'No snapshots found.', [System.Windows.Forms.ToolTipIcon]::Info)
        return
    }
    $list = ($files | Select-Object -First 8 | ForEach-Object {
        $data = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $tabs = ($data.windows | ForEach-Object { $_.tabs.Count } | Measure-Object -Sum).Sum
        "$($_.BaseName) - $($data.windows.Count) win, $tabs tabs"
    }) -join "`n"
    $tray.ShowBalloonTip(10000, "Saved Workspaces ($($files.Count))", $list, [System.Windows.Forms.ToolTipIcon]::Info)
})
$menu.Items.Add($listItem) | Out-Null

# ── Open Saves Folder ──

$folderItem = New-Object System.Windows.Forms.ToolStripMenuItem('Open Saves Folder')
$folderItem.Image = [CryoIcons]::FolderOpen()
$folderItem.ToolTipText = 'Open the saves folder in File Explorer'
$folderItem.Add_Click({
    $savesDir = Join-Path $root 'saves'
    if (-not (Test-Path $savesDir)) { New-Item -ItemType Directory -Path $savesDir -Force | Out-Null }
    Start-Process explorer.exe -ArgumentList $savesDir
})
$menu.Items.Add($folderItem) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# ── Auto-save toggle ──

$autoSaveMinutes = if ($config.autoSaveMinutes) { $config.autoSaveMinutes } else { 5 }
$autoSaveItem = New-Object System.Windows.Forms.ToolStripMenuItem("Auto-save every ${autoSaveMinutes}min")
$autoSaveItem.Image = [CryoIcons]::Timer()
$autoSaveItem.ToolTipText = "When checked, automatically saves your workspace every $autoSaveMinutes minutes while Windows Terminal is running"
$autoSaveItem.Checked = $false
$autoSaveItem.CheckOnClick = $true
$menu.Items.Add($autoSaveItem) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

# ── Restart ──

$restartItem = New-Object System.Windows.Forms.ToolStripMenuItem('Restart')
$restartItem.Image = [CryoIcons]::Restart()
$restartItem.ToolTipText = 'Restart the tray app (use after updating scripts)'
$restartItem.Add_Click({
    try { $script:mutex.ReleaseMutex() } catch { }
    $trayScript = Join-Path $root 'Cryosave.ps1'
    Start-Process powershell.exe -ArgumentList @(
        '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', $trayScript
    ) -WindowStyle Hidden
    $timer.Stop()
    $timer.Dispose()
    $tray.Visible = $false
    $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$menu.Items.Add($restartItem) | Out-Null

# ── Exit ──

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Exit')
$exitItem.Image = [CryoIcons]::Exit()
$exitItem.ToolTipText = 'Save your workspace and exit the tray app'
$exitItem.Add_Click({
    Invoke-Save
    $timer.Stop()
    $timer.Dispose()
    $tray.Visible = $false
    $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$menu.Items.Add($exitItem) | Out-Null

# ── Version label at bottom ──

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$versionLabel = New-Object System.Windows.Forms.ToolStripLabel
$versionLabel.Text = "v$($script:CryosaveVersion)"
$versionLabel.Font = New-Object System.Drawing.Font('Segoe UI', 7.5)
$versionLabel.ForeColor = [System.Drawing.Color]::FromArgb(170, 170, 170)
$versionLabel.Alignment = [System.Windows.Forms.ToolStripItemAlignment]::Right
$versionLabel.AutoSize = $true
$versionLabel.Padding = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
$menu.Items.Add($versionLabel) | Out-Null

$tray.ContextMenuStrip = $menu

# ── Left-click shows tooltip; right-click shows menu (via ContextMenuStrip) ──

$tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $tray.ShowBalloonTip(2000, 'Cryosave', 'Right-click for menu', [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

# ── Auto-save timer ──

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $autoSaveMinutes * 60 * 1000
$timer.Add_Tick({
    if ($autoSaveItem.Checked) {
        $wt = Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue
        if ($wt) { Invoke-Save }
    }
})
$timer.Start()

# ── FileSystemWatcher: notify when script changes ──

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $root
$watcher.Filter = 'Cryosave.ps1'
$watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite
$watcher.EnableRaisingEvents = $true

$script:lastNotify = [DateTime]::MinValue
Register-ObjectEvent -InputObject $watcher -EventName Changed -Action {
    $now = [DateTime]::Now
    if (($now - $script:lastNotify).TotalSeconds -gt 3) {
        $script:lastNotify = $now
        $tray.ShowBalloonTip(5000, 'Cryosave Updated',
            'Script changed. Click Restart in the menu to apply.',
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
} | Out-Null

# ── Cleanup on unexpected exit ──

[System.Windows.Forms.Application]::add_ApplicationExit({
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
    $tray.Visible = $false
    $tray.Dispose()
    if ($script:mutex) { $script:mutex.ReleaseMutex(); $script:mutex.Dispose() }
})

# ── Run message loop ──

[System.Windows.Forms.Application]::Run()
