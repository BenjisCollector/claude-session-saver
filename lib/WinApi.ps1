# WinApi.ps1 — Win32 interop for window enumeration, positioning, and process inspection.
# Uses P/Invoke to call user32.dll, kernel32.dll, and ntdll.dll directly.

if (-not ([System.Management.Automation.PSTypeName]'WinApi').Type) {
    Add-Type -IgnoreWarnings -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public struct WindowInfo {
    public IntPtr Handle;
    public int Left;
    public int Top;
    public int Width;
    public int Height;
    public string Title;
}

public static class WinApi {

    // ── Window enumeration ──

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after,
        int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    private static List<IntPtr> _found;
    private static uint _targetPid;

    /// <summary>Returns all visible titled windows belonging to a process.</summary>
    public static WindowInfo[] GetWindows(uint pid) {
        _found = new List<IntPtr>();
        _targetPid = pid;
        EnumWindows((h, _) => {
            uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp == _targetPid && IsWindowVisible(h) && GetWindowTextLength(h) > 0)
                _found.Add(h);
            return true;
        }, IntPtr.Zero);

        var result = new WindowInfo[_found.Count];
        for (int i = 0; i < _found.Count; i++) {
            RECT r; GetWindowRect(_found[i], out r);
            int len = GetWindowTextLength(_found[i]);
            var sb = new StringBuilder(len + 1);
            GetWindowText(_found[i], sb, sb.Capacity);
            result[i] = new WindowInfo {
                Handle = _found[i], Left = r.Left, Top = r.Top,
                Width = r.Right - r.Left, Height = r.Bottom - r.Top,
                Title = sb.ToString()
            };
        }
        return result;
    }

    /// <summary>Moves and resizes a window.</summary>
    public static void MoveWindow(IntPtr hWnd, int x, int y, int w, int h) {
        SetWindowPos(hWnd, IntPtr.Zero, x, y, w, h, 0x0004 | 0x0010);
    }

    // ── Process CWD reading via PEB ──

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr hProc, IntPtr addr,
        byte[] buf, int size, out int read);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr hProc,
        int infoClass, byte[] info, int len, out int retLen);

    /// <summary>Reads the current working directory of a process via its PEB (x64 only).</summary>
    public static string GetProcessCwd(int pid) {
        IntPtr h = IntPtr.Zero;
        try {
            h = OpenProcess(0x0410, false, pid); // QUERY_INFORMATION | VM_READ
            if (h == IntPtr.Zero) return null;

            byte[] pbi = new byte[48]; int rl;
            if (NtQueryInformationProcess(h, 0, pbi, 48, out rl) != 0) return null;

            IntPtr peb = (IntPtr)BitConverter.ToInt64(pbi, 8);
            byte[] buf = new byte[0x30]; int br;
            if (!ReadProcessMemory(h, peb, buf, buf.Length, out br)) return null;

            IntPtr pp = (IntPtr)BitConverter.ToInt64(buf, 0x20); // ProcessParameters
            byte[] pp_buf = new byte[0x50];
            if (!ReadProcessMemory(h, pp, pp_buf, pp_buf.Length, out br)) return null;

            ushort len = BitConverter.ToUInt16(pp_buf, 0x38);
            IntPtr ptr = (IntPtr)BitConverter.ToInt64(pp_buf, 0x40);
            if (len == 0 || ptr == IntPtr.Zero) return null;

            byte[] cwd = new byte[len];
            if (!ReadProcessMemory(h, ptr, cwd, len, out br)) return null;

            string s = Encoding.Unicode.GetString(cwd);
            return (s.Length > 3 && s.EndsWith("\\")) ? s.TrimEnd('\\') : s;
        }
        catch { return null; }
        finally { if (h != IntPtr.Zero) CloseHandle(h); }
    }
}
'@
}
