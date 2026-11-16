<# :
@echo off
setlocal EnableExtensions
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Invoke-Expression ([IO.File]::ReadAllText('%~f0'))"
exit /b %errorlevel%
#>
# =====================================================================
#  图标弹弓 IconSlingshot v19 — 真桌面版（双模式 + 固定弹弓）
#  开局最小化所有窗口，游戏直接在真实桌面上玩。
#  普通模式：左边弹弓区（固定弹弓，右键可拖动）+ 右边堡垒区；
#  全屏乱打：弹弓随机出现，整个桌面都是战场。
#  弹丸打出去就消失；被打倒的图标也消失；打完自动结算。
#  建造阶段可框选多选，控制栏可拖动；ESC 随时退出。
#  游戏期间鼠标点击全部锁死，任何软件都开不了；游戏自动恢复。
#  全网排行榜+匿名留言板走云端；打赏码/二维码内嵌单文件。
#  关闭游戏后所有图标复位，复制的弹药图标自动删除。
# =====================================================================
$ErrorActionPreference = 'Stop'
$rootDir = Join-Path $env:LOCALAPPDATA 'IconSlingshot'
New-Item -ItemType Directory -Force -Path $rootDir | Out-Null
$logPath = Join-Path $rootDir 'game.log'
$snapPath = Join-Path $rootDir 'snapshot.txt'
$copyManifest = Join-Path $rootDir 'copies.txt'

function Write-Log([string]$msg) {
  try { Add-Content -Path $logPath -Value ("{0:HH:mm:ss.fff}  {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch { }
}
Write-Log '===== 启动 v19 ====='

# ---------------- 内置 C#：桌面图标操作 + 游戏引擎 ----------------
$cs = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Net;
using System.Text;
using System.Windows.Forms;

namespace IconSlingshot
{
    public class DesktopIcon { public string Name; public int X; public int Y; }

    public static class Native
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowW(string c, string w);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowExW(IntPtr p, IntPtr a, string c, string w);
        [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int k);
        [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
        [StructLayout(LayoutKind.Sequential)]
        public struct PT { public int X; public int Y; }
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out PT p);
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(PT p);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
        public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] public static extern IntPtr SetWindowsHookExW(int idHook, HookProc proc, IntPtr hMod, uint threadId);
        [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandleW(string n);
        [StructLayout(LayoutKind.Sequential)]
        public struct MSLLHOOKSTRUCT { public PT pt; public uint mouseData; public uint flags; public uint time; public UIntPtr dwExtraInfo; }
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint a, bool i, uint pid);
        [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr a, uint size, uint t, uint p);
        [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr h, IntPtr a, uint size, uint t);
        [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr h, IntPtr a, byte[] b, uint s, out IntPtr w);
        [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, uint s, out IntPtr r);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SHGetFileInfoW(string p, uint a, ref SHFILEINFOW i, uint cb, uint f);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct SHFILEINFOW
        {
            public IntPtr hIcon; public int iIcon; public uint dwAttributes;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szTypeName;
        }

        const uint LVM_FIRST = 0x1000;
        const uint LVM_GETITEMCOUNT = 0x1004;
        const uint LVM_GETITEMPOSITION = 0x1010;
        const uint LVM_SETITEMPOSITION32 = 0x1031;
        const uint LVM_GETITEMTEXTW = 0x1073;
        const uint PROC_ACCESS = 0x0008 | 0x0010 | 0x0020;
        const uint MEM_COMMIT = 0x1000, MEM_RELEASE = 0x8000, PAGE_RW = 4;

        static void PutI32(byte[] b, int off, int v) { b[off] = (byte)v; b[off + 1] = (byte)(v >> 8); b[off + 2] = (byte)(v >> 16); b[off + 3] = (byte)(v >> 24); }
        static void PutI64(byte[] b, int off, long v) { for (int i = 0; i < 8; i++) b[off + i] = (byte)(v >> (8 * i)); }
        static string ReadWStr(byte[] b) { int n = 0; while (n + 1 < b.Length && (b[n] != 0 || b[n + 1] != 0)) n += 2; return Encoding.Unicode.GetString(b, 0, n); }

        static IntPtr GetListView()
        {
            IntPtr progman = FindWindowW("Progman", null);
            IntPtr defView = progman != IntPtr.Zero ? FindWindowExW(progman, IntPtr.Zero, "SHELLDLL_DefView", null) : IntPtr.Zero;
            if (defView == IntPtr.Zero)
            {
                IntPtr worker = IntPtr.Zero;
                while ((worker = FindWindowExW(IntPtr.Zero, worker, "WorkerW", null)) != IntPtr.Zero)
                {
                    defView = FindWindowExW(worker, IntPtr.Zero, "SHELLDLL_DefView", null);
                    if (defView == IntPtr.Zero) break;
                }
            }
            if (defView == IntPtr.Zero) return IntPtr.Zero;
            return FindWindowExW(defView, IntPtr.Zero, "SysListView32", null);
        }

        static IntPtr OpenLv() { IntPtr lv = GetListView(); if (lv == IntPtr.Zero) return IntPtr.Zero; uint pid; GetWindowThreadProcessId(lv, out pid); return OpenProcess(PROC_ACCESS, false, pid); }

        // ---- 高速通道：缓存 listview 句柄 + 名字->序号映射，逐帧搬图标用 ----
        static IntPtr s_lv = IntPtr.Zero, s_h = IntPtr.Zero, s_pPt = IntPtr.Zero;
        static Dictionary<string, int> s_map;

        public static void ResetCache()
        {
            try { if (s_pPt != IntPtr.Zero) VirtualFreeEx(s_h, s_pPt, 8, MEM_RELEASE); } catch { }
            try { if (s_h != IntPtr.Zero) CloseHandle(s_h); } catch { }
            s_lv = IntPtr.Zero; s_h = IntPtr.Zero; s_pPt = IntPtr.Zero; s_map = null;
        }

        static void EnsureCache()
        {
            IntPtr lv = GetListView();
            if (lv == IntPtr.Zero) { ResetCache(); return; }
            if (s_lv != lv)
            {
                ResetCache();
                s_lv = lv;
                s_h = OpenLv();
                if (s_h == IntPtr.Zero) { ResetCache(); return; }
                s_pPt = VirtualAllocEx(s_h, IntPtr.Zero, 8, MEM_COMMIT, PAGE_RW);
                if (s_pPt == IntPtr.Zero) { ResetCache(); return; }
            }
            if (s_map != null) return;
            s_map = new Dictionary<string, int>();
            int count = (int)SendMessageW(s_lv, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero);
            IntPtr pLi = VirtualAllocEx(s_h, IntPtr.Zero, 512, MEM_COMMIT, PAGE_RW);
            IntPtr pTx = VirtualAllocEx(s_h, IntPtr.Zero, 1024, MEM_COMMIT, PAGE_RW);
            if (pLi == IntPtr.Zero || pTx == IntPtr.Zero) { ResetCache(); return; }
            try
            {
                var li = new byte[512];
                PutI32(li, 0, 1);        // mask = LVIF_TEXT
                PutI32(li, 8, 0);        // iSubItem
                PutI64(li, 24, pTx.ToInt64());
                PutI32(li, 32, 512);
                IntPtr wr, rd;
                WriteProcessMemory(s_h, pLi, li, 512, out wr);
                var tb = new byte[1024];
                for (int i = 0; i < count; i++)
                {
                    PutI32(li, 4, i);    // iItem (offset 4 on x64)
                    WriteProcessMemory(s_h, pLi, li, 512, out wr);
                    SendMessageW(s_lv, LVM_GETITEMTEXTW, (IntPtr)i, pLi);
                    ReadProcessMemory(s_h, pTx, tb, 1024, out rd);
                    string name = ReadWStr(tb);
                    if (!string.IsNullOrEmpty(name)) s_map[name] = i;
                }
            }
            finally
            {
                try { VirtualFreeEx(s_h, pLi, 512, MEM_RELEASE); } catch { }
                try { VirtualFreeEx(s_h, pTx, 1024, MEM_RELEASE); } catch { }
            }
        }

        public static bool MoveIcon(string name, int x, int y)
        {
            try
            {
                EnsureCache();
                if (s_h == IntPtr.Zero || s_map == null) return false;
                int idx;
                if (!s_map.TryGetValue(name, out idx))
                {
                    ResetCache(); EnsureCache();
                    if (s_map == null || !s_map.TryGetValue(name, out idx)) return false;
                }
                var pt = new byte[8]; PutI32(pt, 0, x); PutI32(pt, 4, y);
                IntPtr wr;
                WriteProcessMemory(s_h, s_pPt, pt, 8, out wr);
                SendMessageW(s_lv, LVM_SETITEMPOSITION32, (IntPtr)idx, s_pPt);
                return true;
            }
            catch { ResetCache(); return false; }
        }

        public static List<DesktopIcon> GetIcons()
        {
            var res = new List<DesktopIcon>();
            IntPtr lv = GetListView(); if (lv == IntPtr.Zero) return res;
            IntPtr h = OpenLv(); if (h == IntPtr.Zero) return res;
            try
            {
                int count = (int)SendMessageW(lv, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero);
                IntPtr pPt = VirtualAllocEx(h, IntPtr.Zero, 8, MEM_COMMIT, PAGE_RW);
                IntPtr pLi = VirtualAllocEx(h, IntPtr.Zero, 512, MEM_COMMIT, PAGE_RW);
                IntPtr pTx = VirtualAllocEx(h, IntPtr.Zero, 1024, MEM_COMMIT, PAGE_RW);
                if (pPt == IntPtr.Zero || pLi == IntPtr.Zero || pTx == IntPtr.Zero) return res;
                var li = new byte[512];
                PutI32(li, 0, 1);
                PutI32(li, 8, 0);
                PutI64(li, 24, pTx.ToInt64());
                PutI32(li, 32, 512);
                IntPtr wr, rd;
                WriteProcessMemory(h, pLi, li, 512, out wr);
                for (int i = 0; i < count; i++)
                {
                    SendMessageW(lv, LVM_GETITEMPOSITION, (IntPtr)i, pPt);
                    var ptBuf = new byte[8];
                    ReadProcessMemory(h, pPt, ptBuf, 8, out rd);
                    int x = BitConverter.ToInt32(ptBuf, 0), y = BitConverter.ToInt32(ptBuf, 4);
                    PutI32(li, 4, i);
                    WriteProcessMemory(h, pLi, li, 512, out wr);
                    SendMessageW(lv, LVM_GETITEMTEXTW, (IntPtr)i, pLi);
                    var tb = new byte[1024];
                    ReadProcessMemory(h, pTx, tb, 1024, out rd);
                    string name = ReadWStr(tb);
                    if (!string.IsNullOrEmpty(name)) res.Add(new DesktopIcon { Name = name, X = x, Y = y });
                }
                VirtualFreeEx(h, pPt, 8, MEM_RELEASE);
                VirtualFreeEx(h, pLi, 512, MEM_RELEASE);
                VirtualFreeEx(h, pTx, 1024, MEM_RELEASE);
            }
            finally { CloseHandle(h); }
            return res;
        }

        public static Bitmap LoadIcon(string path)
        {
            try
            {
                SHFILEINFOW fi = new SHFILEINFOW();
                uint cb = (uint)Marshal.SizeOf(typeof(SHFILEINFOW));
                SHGetFileInfoW(path, 0, ref fi, cb, 0x100);
                if (fi.hIcon == IntPtr.Zero) return null;
                Bitmap src = null;
                try { using (Icon ic = Icon.FromHandle(fi.hIcon)) src = ic.ToBitmap(); }
                finally { DestroyIcon(fi.hIcon); }
                if (src == null) return null;
                Bitmap b = new Bitmap(48, 48);
                using (Graphics g = Graphics.FromImage(b))
                {
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.Clear(Color.Transparent);
                    g.DrawImage(src, 0, 0, 48, 48);
                }
                src.Dispose();
                return b;
            }
            catch { return null; }
        }
    }

    public class Block
    {
        public string Name;
        public float X, Y;              // 实时位置（图标单元格左上角）
        public float VX, VY;
        public bool Static = true;      // 站着 / 已倒下
        public bool Knocked;            // 已被击倒（飞行中→落定即消失）
        public bool Gone;               // 已消失，停止同步
        public bool IsTarget = true;    // 是否计分靶子（普通模式下右边堡垒区才计分）
        public bool Sel;                // 建造阶段被框选/点选（多选一起拖）
    }

    public class Projectile
    {
        public string Name;
        public float X, Y, VX, VY;
        public float RestTimer;
        public bool Dead;
        public float DeadTimer;
    }

    public class Particle { public float X, Y, VX, VY, Life, Size; public Color C; }
    public class PopText { public float X, Y, Life; public string Text; }

    public class NameDialog : Form
    {
        public string PlayerName = "";
        TextBox tb;
        public NameDialog(int score, string last)
        {
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterScreen;
            Text = "图标弹弓";
            Size = new Size(360, 190);
            MaximizeBox = false; MinimizeBox = false; TopMost = true;
            Font = new Font("Microsoft YaHei UI", 10);
            var l1 = new Label { Text = "本局得分：" + score, Left = 24, Top = 16, Width = 300, Font = new Font("Microsoft YaHei UI", 13, FontStyle.Bold) };
            var l2 = new Label { Text = "留个名字，冲排行榜：", Left = 24, Top = 58, Width = 300 };
            tb = new TextBox { Left = 24, Top = 86, Width = 280, Font = new Font("Microsoft YaHei UI", 11) };
            tb.Text = string.IsNullOrEmpty(last) ? "无名氏" : last;
            var ok = new Button { Text = "记下这一分", Left = 24, Top = 118, Width = 280, Height = 34 };
            ok.Click += (s, e) => { PlayerName = tb.Text.Trim(); DialogResult = DialogResult.OK; Close(); };
            Controls.Add(l1); Controls.Add(l2); Controls.Add(tb); Controls.Add(ok);
            AcceptButton = ok;
        }
    }

    public class GameForm : Form
    {
        enum Mode { Menu, Build, CopyPick, Attack, Over }
        enum Kind { Normal, Full }
        Mode mode = Mode.Menu;
        Kind kind = Kind.Full;

        List<DesktopIcon> icons;
        Dictionary<string, string> paths;
        Dictionary<string, PointF> homes = new Dictionary<string, PointF>();
        List<Block> blocks = new List<Block>();
        List<string> ammoQueue = new List<string>();
        HashSet<string> copiedNames = new HashSet<string>();
        int ammoPos = -1;
        string armedName;
        Projectile proj;

        int splitX;                     // 普通模式分区线
        PointF slingPos;                // 弹弓皮兜中心（发射点）
        bool draggingSling;
        PointF slingGrabOff;
        bool prevRDown;

        // 鼠标钩子：游戏期间吞掉全部鼠标按键，任何软件都点不开（游戏自身用底层轮询，不受影响）
        IntPtr mouseHook;
        Native.HookProc mouseHookProc;
        Block dragBlock;
        PointF dragOff;

        int knocked = 0, score = 0, targetTotal = 0;
        List<Particle> parts = new List<Particle>();
        List<PopText> pops = new List<PopText>();

        float shake;
        float endWait;
        Random rnd = new Random();
        Stopwatch sw = Stopwatch.StartNew();
        double lastTick, lastPoll;
        Timer timer;

        RectangleF btnBoard, btnExit, btnFight, btnCopy, btnEnd, btnAgain, btnQuit, btnBoard2, btnNormal, btnFull, btnDonate, btnMsg;
        bool aiming;
        PointF pressPt, aimPt;
        bool prevDown, pressOnBtn, dialogOpen;
        PointF barPos;                  // 可拖动控制栏位置
        RectangleF barRect;             // 控制栏整体矩形（每帧更新）
        bool draggingBar;
        PointF barDragOff;
        bool prevEsc;
        bool hookLDown, hookRDown;      // 钩子吞掉点击前记录的按键状态（GetAsyncKeyState 读不到被吞的点击）
        PointF hookDownPt;

        // 建造阶段：框选多选 + 多选一起拖
        bool selBoxOn;                  // 正在拖框
        PointF selBoxA, selBoxB;        // 框的两个角
        bool groupDrag;                 // 拖的是整个选中组
        PointF lastDragPt;              // 上一帧光标（算组移动增量）

        // 顶部模式下拉
        bool modeListOn;
        RectangleF btnMode, lstNormal, lstFull;

        // 云端榜（WorkBuddy 云服务；endpoint/key 为公开标识，允许进源码）
        const string CloudEp = "https://wbapp-fly2w17y7s23cwjzpgtv86.app.workbuddy.host";
        const string CloudKey = "wbpk_FLY2w17Y7S23cwJZPgTV86_2ogOXimC822J4ShkRSRzNLLOhAwryRpO";
        long attackStartMs;   // 本局开始时间（算用时→得分率）
        PointF prevPt;
        int copyCount;
        string manifestPath, boardPath, lastName;

        Font fTitle, fBig, fMid, fSmall;
        int W, H;
        int GroundY;
        static readonly Color Key = Color.FromArgb(255, 1, 2, 3);

        // 窗口对系统完全点击穿透（WS_EX_TRANSPARENT），
        // 游戏运行期间任务栏/开始菜单/任何软件都照常可用；图标由鼠标钩子保护。
        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00080000;   // WS_EX_LAYERED
                cp.ExStyle |= 0x00000020;   // WS_EX_TRANSPARENT：鼠标全部穿透
                cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE：永不抢焦点
                cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW：不进 Alt+Tab
                return cp;
            }
        }

        public GameForm(List<DesktopIcon> ics, Dictionary<string, string> pths, int w, int h, string board, string last, string manifest)
        {
            icons = ics; paths = pths; W = w; H = h; boardPath = board; lastName = last; manifestPath = manifest;
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            Bounds = new Rectangle(0, 0, W, H);
            TopMost = true; ShowInTaskbar = false;
            BackColor = Key;
            TransparencyKey = Key;   // 键色区域=透明
            DoubleBuffered = true;
            Text = "IconSlingshot";

            GroundY = H - 56;
            splitX = W * 2 / 5;

            foreach (var ic in icons) homes[ic.Name] = new PointF(ic.X, ic.Y);
            RebuildBlocks();

            fTitle = new Font("Microsoft YaHei UI", 46, FontStyle.Bold);
            fBig = new Font("Microsoft YaHei UI", 24, FontStyle.Bold);
            fMid = new Font("Microsoft YaHei UI", 14, FontStyle.Bold);
            fSmall = new Font("Microsoft YaHei UI", 11);

            btnBoard = new RectangleF(W - 272, 26, 118, 42);
            btnExit = new RectangleF(W - 146, 26, 118, 42);
            btnDonate = new RectangleF(W - 398, 26, 118, 42);
            btnMsg = new RectangleF(W - 524, 26, 118, 42);
            barPos = new PointF(W / 2 - 312, 84);
            barRect = BarRect();

            // 截当前屏幕（此刻窗口未显示，看到的是壁纸）供文字自适应配色
            try
            {
                bgShot = new Bitmap(W, H);
                using (var gg = Graphics.FromImage(bgShot))
                    gg.CopyFromScreen(0, 0, 0, 0, new Size(W, H));
            }
            catch { bgShot = null; }

            timer = new Timer { Interval = 33 };
            timer.Tick += (s, e) => Tick();
            timer.Start();

            InstallMouseHook();

            FormClosing += (s, e) =>
            {
                try { timer.Stop(); } catch { }
                try { if (mouseHook != IntPtr.Zero) Native.UnhookWindowsHookEx(mouseHook); } catch { }
            };
        }

        // ---------- 鼠标钩子：点在桌面图标上的左/右键一律吞掉，图标只是图标 ----------
        void InstallMouseHook()
        {
            try
            {
                mouseHookProc = MouseHookProc;
                mouseHook = Native.SetWindowsHookExW(14, mouseHookProc, Native.GetModuleHandleW(null), 0);   // WH_MOUSE_LL
            }
            catch { mouseHook = IntPtr.Zero; }
        }

        IntPtr MouseHookProc(int code, IntPtr w, IntPtr l)
        {
            if (code >= 0 && mouseHook != IntPtr.Zero)
            {
                int msg = w.ToInt32();
                if (msg >= 0x0201 && msg <= 0x0209)          // 所有鼠标按键：游戏期间全部吞掉，什么软件都点不开
                {
                    if (!dialogOpen)
                    {
                        // 吞掉之前先记录左右键状态，游戏输入全靠这份记录
                        if (msg == 0x0201 || msg == 0x0204)      // 左/右键按下
                        {
                            var info = (Native.MSLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(Native.MSLLHOOKSTRUCT));
                            if (msg == 0x0201) { hookLDown = true; hookDownPt = new PointF(info.pt.X, info.pt.Y); }
                            else hookRDown = true;
                        }
                        else if (msg == 0x0202) hookLDown = false;   // 左键抬起
                        else if (msg == 0x0205) hookRDown = false;   // 右键抬起
                        return (IntPtr)1;
                    }
                }
            }
            return Native.CallNextHookEx(mouseHook, code, w, l);
        }

        void RebuildBlocks()
        {
            blocks.Clear();
            foreach (var ic in icons) blocks.Add(new Block { Name = ic.Name, X = ic.X, Y = ic.Y });
        }

        Block BlockByName(string n) { foreach (var b in blocks) if (b.Name == n) return b; return null; }

        Block PickBlock(PointF p)
        {
            Block best = null;
            float bd = float.MaxValue;
            foreach (var b in blocks)
            {
                float cx = b.X + 38, cy = b.Y + 38;
                if (Math.Abs(p.X - cx) > 62 || Math.Abs(p.Y - cy) > 62) continue;
                float dd = (p.X - cx) * (p.X - cx) + (p.Y - cy) * (p.Y - cy);
                if (dd < bd) { bd = dd; best = b; }
            }
            return best;
        }

        // ---------- 全局轮询输入（窗口本身完全穿透，收不到任何鼠标事件） ----------
        bool InR(RectangleF r, PointF p) { return p.X >= r.X && p.X <= r.Right && p.Y >= r.Y && p.Y <= r.Bottom; }
        RectangleF BarRect() { return new RectangleF(barPos.X, barPos.Y, 624, 94); }
        bool Clicked(RectangleF r, PointF d, PointF u) { return InR(r, d) && InR(r, u); }

        bool OverAnyBtn(PointF p)
        {
            if (mode == Mode.Menu)
                return InR(btnNormal, p) || InR(btnFull, p) || InR(btnBoard, p) || InR(btnExit, p) || InR(btnDonate, p) || InR(btnMsg, p);
            if (mode == Mode.Over)
                return InR(btnAgain, p) || InR(btnQuit, p) || InR(btnExit, p) || InR(btnBoard2, p) || InR(btnDonate, p) || InR(btnMsg, p);
            if (mode == Mode.Build || mode == Mode.CopyPick)
                return InR(barRect, p) || InR(btnFight, p) || InR(btnCopy, p) || InR(btnExit, p) || InR(btnBoard2, p) || InR(btnDonate, p) || InR(btnMsg, p)
                    || InR(btnMode, p) || (modeListOn && (InR(lstNormal, p) || InR(lstFull, p)));
            if (mode == Mode.Attack)
                return InR(btnEnd, p) || InR(btnExit, p) || InR(btnBoard2, p) || InR(btnDonate, p) || InR(btnMsg, p);
            return false;
        }

        void PollInput()
        {
            // ---- ESC：紧急出口，任何时候按下直接退出并复位（不需要确认） ----
            bool esc = (Native.GetAsyncKeyState(0x1B) & 0x8000) != 0;
            if (esc && !prevEsc && !dialogOpen) { prevEsc = esc; Close(); return; }
            prevEsc = esc;

            bool down = hookLDown;
            bool rDown = hookRDown;
            Native.PT cur;
            Native.GetCursorPos(out cur);
            var p = new PointF(cur.X, cur.Y);

            // ---- 右键：拖动弹弓（普通/全屏乱打通用） ----
            if (rDown && !prevRDown && mode == Mode.Attack && proj == null)
            {
                float ddx = cur.X - slingPos.X, ddy = cur.Y - slingPos.Y;
                if (ddx * ddx + ddy * ddy < 110 * 110)
                {
                    draggingSling = true;
                    slingGrabOff = new PointF(slingPos.X - cur.X, slingPos.Y - cur.Y);
                }
            }
            if (draggingSling)
            {
                if (!rDown)
                {
                    draggingSling = false;
                    // 钩子已吞掉全部右键消息，桌面不会再弹右键菜单，无需再发 Esc
                }
                else
                {
                    float nx = cur.X + slingGrabOff.X, ny = cur.Y + slingGrabOff.Y;
                    float minX = 70;
                    float maxX = kind == Kind.Normal ? splitX - 90 : W - 70;
                    slingPos = new PointF(
                        Math.Max(minX, Math.Min(maxX, nx)),
                        Math.Max(150, Math.Min(GroundY - 70, ny)));
                    if (armedName != null && proj == null)
                    {
                        var ab = BlockByName(armedName);
                        if (ab != null)
                        {
                            ab.X = slingPos.X - 38; ab.Y = slingPos.Y - 38;
                            Native.MoveIcon(armedName, (int)ab.X, (int)ab.Y);
                        }
                    }
                }
            }
            prevRDown = rDown;

            // ---- 左键：瞄准/发射/拖图标/点按钮 ----
            if (down && !prevDown)
            {
                prevPt = hookDownPt;   // 用钩子记录的按下坐标，避免轮询延迟
                pressOnBtn = dialogOpen || OverAnyBtn(prevPt) || draggingSling;
                dragBlock = null; groupDrag = false; selBoxOn = false;
                // 控制栏拖动：按在栏背景（非按钮）上
                bool overBarBtn = InR(btnMode, prevPt) || InR(btnFight, prevPt) || InR(btnCopy, prevPt)
                    || (modeListOn && (InR(lstNormal, prevPt) || InR(lstFull, prevPt)));
                if (!dialogOpen && (mode == Mode.Build || mode == Mode.CopyPick)
                    && InR(barRect, prevPt) && !overBarBtn)
                {
                    draggingBar = true;
                    barDragOff = new PointF(prevPt.X - barPos.X, prevPt.Y - barPos.Y);
                }
                if (!pressOnBtn && mode == Mode.Build)
                {
                    var db2 = PickBlock(prevPt);
                    if (db2 != null)
                    {
                        if (!db2.Sel)
                        {
                            // 点未选中的图标：只选它一个（清掉其他选中）
                            foreach (var b in blocks) if (b.Sel && b != db2) b.Sel = false;
                            db2.Sel = true;
                        }
                        else groupDrag = true;   // 点已选中的图标：整个选中组一起拖
                        dragBlock = db2;
                        dragOff = new PointF(prevPt.X - db2.X, prevPt.Y - db2.Y);
                        lastDragPt = prevPt;
                    }
                    else if (!modeListOn) { selBoxOn = true; selBoxA = prevPt; selBoxB = prevPt; }   // 空白处按下=开始框选（模式下拉开着时不启动）
                }
                if (!pressOnBtn && mode == Mode.Attack && armedName != null && proj == null)
                { aiming = true; pressPt = prevPt; aimPt = prevPt; }
            }
            if (aiming) aimPt = p;

            // 建造阶段：游戏自己拖图标（钩子吞掉了系统拖放，图标因此点不开）
            if (dragBlock != null && down)
            {
                float nx = Math.Max(0, Math.Min(W - 80, cur.X - dragOff.X));
                float ny = Math.Max(0, Math.Min(H - 90, cur.Y - dragOff.Y));
                if (groupDrag)
                {
                    // 组拖：其他选中图标跟随同样的位移
                    float dx = nx - dragBlock.X, dy = ny - dragBlock.Y;
                    foreach (var b in blocks)
                    {
                        if (!b.Sel || b == dragBlock || b.Gone) continue;
                        b.X = Math.Max(0, Math.Min(W - 80, b.X + dx));
                        b.Y = Math.Max(0, Math.Min(H - 90, b.Y + dy));
                        Native.MoveIcon(b.Name, (int)b.X, (int)b.Y);
                    }
                }
                dragBlock.X = nx; dragBlock.Y = ny;
                Native.MoveIcon(dragBlock.Name, (int)nx, (int)ny);
            }
            if (selBoxOn && down) selBoxB = p;
            if (draggingBar && down)
            {
                float bnx = Math.Max(10, Math.Min(W - barRect.Width - 10, cur.X - barDragOff.X));
                float bny = Math.Max(10, Math.Min(H - barRect.Height - 10, cur.Y - barDragOff.Y));
                barPos = new PointF(bnx, bny);
                barRect = BarRect();
            }

            if (!down && prevDown)
            {
                bool wasBarDrag = draggingBar;
                draggingBar = false;
                if (dragBlock != null)
                {
                    homes[dragBlock.Name] = new PointF(dragBlock.X, dragBlock.Y);
                    dragBlock = null;
                }
                if (groupDrag)
                {
                    foreach (var b in blocks) if (b.Sel) homes[b.Name] = new PointF(b.X, b.Y);
                    groupDrag = false;
                }
                if (selBoxOn)
                {
                    selBoxOn = false;
                    float bx = Math.Min(selBoxA.X, selBoxB.X), by = Math.Min(selBoxA.Y, selBoxB.Y);
                    float bw = Math.Abs(selBoxA.X - selBoxB.X), bh = Math.Abs(selBoxA.Y - selBoxB.Y);
                    if (bw < 10 && bh < 10)
                    { foreach (var b in blocks) b.Sel = false; }   // 原地单击空白=清除选择
                    else
                    {
                        foreach (var b in blocks)
                            b.Sel = !b.Gone && OverlapR(bx, by, bw, bh, b.X, b.Y, 76, 76);
                    }
                }
                bool used = false;
                if (!dialogOpen && !wasBarDrag) used = HandleClick(prevPt, p);   // 拖栏松手不算点击
                if (!used && !pressOnBtn && aiming && mode == Mode.Attack)
                {
                    aimPt = p;
                    FireFromPull();
                }
                aiming = false;
            }
            prevDown = down;
        }

        // 按钮判定：按下和抬起都落在同一个按钮上才算点击
        bool HandleClick(PointF d, PointF u)
        {
            if (mode == Mode.Menu)
            {
                if (Clicked(btnNormal, d, u)) { kind = Kind.Normal; ToBuild(); return true; }
                if (Clicked(btnFull, d, u)) { kind = Kind.Full; ToBuild(); return true; }
                if (Clicked(btnBoard, d, u)) { ShowBoard(); return true; }
                if (Clicked(btnDonate, d, u)) { ShowDonate(); return true; }
                if (Clicked(btnMsg, d, u)) { ShowFeedback(); return true; }
                if (Clicked(btnExit, d, u)) { ConfirmExit(); return true; }
                return false;
            }
            if (Clicked(btnExit, d, u)) { ConfirmExit(); return true; }
            if (Clicked(btnBoard2, d, u)) { ShowBoard(); return true; }
            if (Clicked(btnDonate, d, u)) { ShowDonate(); return true; }
            if (Clicked(btnMsg, d, u)) { ShowFeedback(); return true; }

            if (mode == Mode.Build)
            {
                if (Clicked(btnMode, d, u)) { modeListOn = !modeListOn; return true; }
                if (modeListOn)
                {
                    modeListOn = false;
                    if (Clicked(lstNormal, d, u)) { kind = Kind.Normal; return true; }   // 只改模式，图标位置不动
                    if (Clicked(lstFull, d, u)) { kind = Kind.Full; return true; }
                    return true;   // 点列表外面：只收起列表
                }
                if (Clicked(btnFight, d, u)) { StartAttack(); return true; }
                if (Clicked(btnCopy, d, u)) { mode = Mode.CopyPick; modeListOn = false; return true; }
                return false;
            }
            if (mode == Mode.CopyPick)
            {
                if (Clicked(btnCopy, d, u) || Clicked(btnFight, d, u)) { mode = Mode.Build; modeListOn = false; return true; }
                CopyPick(u);
                return true;
            }
            if (mode == Mode.Attack)
            {
                if (Clicked(btnEnd, d, u)) { EndRound(); return true; }
                return false;
            }
            if (mode == Mode.Over)
            {
                if (Clicked(btnAgain, d, u)) { ResetRound(); return true; }
                if (Clicked(btnQuit, d, u)) { Close(); return true; }
            }
            return false;
        }

        void FireFromPull()
        {
            if (armedName == null || proj != null) return;
            float dx = pressPt.X - aimPt.X, dy = pressPt.Y - aimPt.Y;
            float dist = (float)Math.Sqrt(dx * dx + dy * dy);
            if (dist < 30) return;
            float pow = Math.Min(dist, 220) * 9.0f;
            proj = new Projectile
            {
                Name = armedName,
                X = slingPos.X - 25, Y = slingPos.Y - 25,   // 从弹弓皮兜发射
                VX = dx / dist * pow, VY = dy / dist * pow
            };
            armedName = null;
            shake = 6;
        }

        // ---------- 模式切换 ----------
        void ToBuild()
        {
            mode = Mode.Build;
            modeListOn = false; selBoxOn = false; groupDrag = false;
            lastPoll = 0;
            Repoll();
        }

        void StartAttack()
        {
            Repoll();
            modeListOn = false; selBoxOn = false; groupDrag = false;
            foreach (var b in blocks) b.Sel = false;
            attackStartMs = sw.ElapsedMilliseconds;   // 计时起点（算得分率）
            var ammo = new List<string>();
            int targets = 0;
            foreach (var b in blocks)
            {
                // 普通模式：右半堡垒区=靶子，左半弹弓区=弹丸（复制的弹药永远是弹丸）；
                // 全屏乱打：全部都是靶子。
                b.IsTarget = (kind == Kind.Full) || (b.X >= splitX && !copiedNames.Contains(b.Name));
                if (b.IsTarget) targets++;
                else ammo.Add(b.Name);
            }
            if (targets == 0)
            {
                ShowMsg(kind == Kind.Normal
                    ? "右边（堡垒区）没有靶子：先回建造模式，把要打的目标拖到右边。"
                    : "桌面上没有图标，没法开打。");
                return;
            }
            if (kind == Kind.Normal && ammo.Count == 0)
            {
                ShowMsg("左边（弹弓区）一个图标都没有：先回建造模式，拖几个图标到左边当弹丸。");
                return;
            }
            ammoQueue = ammo.Count > 0 ? ammo : blocks.Select(x => x.Name).ToList();
            ammoPos = -1;
            targetTotal = targets;
            // 弹弓固定落位（普通=弹弓区中线；乱打=随机位置），右键可拖动微调
            slingPos = kind == Kind.Normal
                ? new PointF(splitX * 0.5f, GroundY - 110)
                : new PointF(120 + (float)rnd.NextDouble() * (W - 240),
                             220 + (float)rnd.NextDouble() * (GroundY - 330));
            draggingSling = false;
            mode = Mode.Attack;
            ArmNext();
        }

        void ArmNext()
        {
            if (mode != Mode.Attack) return;
            // 跳过已经消失/被打掉的，装下一发还活着的弹丸
            while (ammoPos + 1 < ammoQueue.Count)
            {
                ammoPos++;
                var b = BlockByName(ammoQueue[ammoPos]);
                if (b == null || b.Gone || b.Knocked) continue;
                armedName = ammoQueue[ammoPos];
                b.X = slingPos.X - 38; b.Y = slingPos.Y - 38;
                b.Static = true; b.Knocked = false; b.Gone = false; b.VX = 0; b.VY = 0;
                Native.MoveIcon(armedName, (int)b.X, (int)b.Y);
                return;
            }
            armedName = null;
            EndRound();   // 图标打完 / 弹丸用光，自动结算
        }

        // 图标消失：挪出屏幕 + 消散粒子（搬走失败自动重试，杜绝赖在原地）
        readonly List<string> vanishRetry = new List<string>();
        void Vanish(Block b)
        {
            if (b.Gone) return;
            b.Gone = true;
            Dust(b.X + 38, b.Y + 38, 10);
            b.X = -170; b.Y = -170;
            vanishRetry.Add(b.Name);   // 每帧重试 MoveIcon 直到成功
        }

        void ResetRound()
        {
            foreach (var b in blocks)
            {
                PointF hp;
                if (homes.TryGetValue(b.Name, out hp))
                {
                    Native.MoveIcon(b.Name, (int)hp.X, (int)hp.Y);
                    b.X = hp.X; b.Y = hp.Y;
                }
                b.Knocked = false; b.Static = true; b.Gone = false; b.VX = 0; b.VY = 0;
            }
            knocked = 0; score = 0; proj = null; armedName = null; aiming = false; endWait = 0;
            draggingSling = false;
            mode = Mode.Build;
        }

        void EndRound()
        {
            aiming = false;
            score = knocked * 100;
            int dur = RoundSeconds();   // 进入结算瞬间记录用时
            mode = Mode.Over;
            dialogOpen = true;
            using (var d = new NameDialog(score, lastName))
            {
                d.ShowDialog(this);
                if (!string.IsNullOrEmpty(d.PlayerName))
                {
                    lastName = d.PlayerName;
                    SaveScore(d.PlayerName, score, dur);
                }
            }
            dialogOpen = false;
            btnAgain = new RectangleF(W / 2 - 260, H / 2 + 150, 240, 54);
            btnQuit = new RectangleF(W / 2 + 20, H / 2 + 150, 240, 54);
        }

        // 本局用时（秒，最少记 5 秒，服务端 CHECK 要求）
        int RoundSeconds()
        {
            int dur = (int)((sw.ElapsedMilliseconds - attackStartMs) / 1000);
            return Math.Max(5, Math.Min(dur, 86400));
        }

        void ConfirmExit()
        {
            dialogOpen = true;
            var r = MessageBox.Show(this, "退出游戏并复位桌面？", "图标弹弓", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            dialogOpen = false;
            if (r == DialogResult.Yes) Close();
        }

        void ShowMsg(string txt)
        {
            dialogOpen = true;
            MessageBox.Show(this, txt, "图标弹弓", MessageBoxButtons.OK, MessageBoxIcon.Information);
            dialogOpen = false;
        }

        // ---------- 复制弹丸：选哪个图标就复制哪个 ----------
        void CopyPick(PointF p)
        {
            Block best = PickBlock(p);
            mode = Mode.Build;
            if (best == null) return;   // 点空白处 = 取消
            CopyFive(best.Name);
        }

        void CopyFive(string srcName)
        {
            string src;
            if (paths == null || !paths.TryGetValue(srcName, out src)
                || string.IsNullOrEmpty(src) || src.StartsWith("::")
                || !(src.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase)
                     || src.EndsWith(".url", StringComparison.OrdinalIgnoreCase)
                     || src.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                || !File.Exists(src))
            {
                ShowMsg("「" + srcName + "」没法复制（系统图标或找不到原文件），换一个图标试试。");
                return;
            }
            try
            {
                string dir = Environment.GetFolderPath(Environment.SpecialFolder.Desktop);
                string ext = Path.GetExtension(src);
                string baseName = Path.GetFileNameWithoutExtension(src);
                int made = 0;
                for (int i = 1; i <= 5; i++)
                {
                    copyCount++;
                    string dst = Path.Combine(dir, baseName + " 弹" + copyCount + ext);
                    if (!File.Exists(dst))
                    {
                        File.Copy(src, dst, false);
                        try { File.AppendAllText(manifestPath, dst + Environment.NewLine, Encoding.UTF8); } catch { }
                        copiedNames.Add(Path.GetFileNameWithoutExtension(dst));
                        made++;
                    }
                }
                Application.DoEvents();
                System.Threading.Thread.Sleep(1100);   // 等桌面刷新出新图标
                Repoll();
                ShowMsg("已复制 " + made + " 个「" + baseName + "」弹丸，桌面上直接可见。\n退出游戏时会自动删除这些副本。");
            }
            catch (Exception ex)
            {
                ShowMsg("复制失败：" + ex.Message);
            }
        }

        // 建造阶段轮询真实图标位置：同步堡垒、发现新复制的图标
        void Repoll()
        {
            var fresh = Native.GetIcons();
            var seen = new HashSet<string>();
            foreach (var f in fresh)
            {
                seen.Add(f.Name);
                var b = BlockByName(f.Name);
                if (b == null)
                {
                    blocks.Add(new Block { Name = f.Name, X = f.X, Y = f.Y });
                    homes[f.Name] = new PointF(f.X, f.Y);
                    icons.Add(f);
                }
                else if (!b.Knocked)
                {
                    b.X = f.X; b.Y = f.Y; b.Static = true; b.Gone = false;
                    if (mode == Mode.Build || mode == Mode.CopyPick) homes[f.Name] = new PointF(f.X, f.Y);
                }
            }
            for (int i = blocks.Count - 1; i >= 0; i--)
                if (!seen.Contains(blocks[i].Name)) blocks.RemoveAt(i);
        }

        // ---------- 排行榜 ----------
        void SaveScore(string name, int sc, int dur)
        {
            // 本地：分数|名字|时间（追加式，每局都留底）
            try
            {
                File.AppendAllText(boardPath,
                    sc + "|" + name.Replace('|', '_') + "|" + DateTime.Now.ToString("yyyy-MM-dd HH:mm") + Environment.NewLine,
                    Encoding.UTF8);
            }
            catch { }
            // 云端：追加到全网榜（失败不打扰，本地已留底）
            try { CloudPost(name, sc, kind == Kind.Full ? "full" : "normal", dur); } catch { }
        }

        static string JsonEsc(string s)
        {
            var sb = new StringBuilder();
            foreach (char c in s)
            {
                switch (c)
                {
                    case '\\': sb.Append("\\\\"); break;
                    case '"': sb.Append("\\\""); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 32) sb.Append("\\u" + ((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            return sb.ToString();
        }

        // 云端提交一条成绩
        bool CloudPost(string name, int sc, string gameMode, int dur)
        {
            var req = (HttpWebRequest)WebRequest.Create(CloudEp + "/.cloud/database/rest/scores?select=*");
            req.Method = "POST";
            req.ContentType = "application/json";
            req.Timeout = 6000;
            req.Headers.Add("x-wb-webapp-access-key", CloudKey);
            req.Headers.Add("prefer", "return=representation");
            string body = "{\"owner_name\":\"" + JsonEsc(name) + "\",\"score\":" + sc +
                          ",\"mode\":\"" + gameMode + "\",\"duration\":" + dur + "}";
            var buf = Encoding.UTF8.GetBytes(body);
            req.ContentLength = buf.Length;
            using (var st = req.GetRequestStream()) st.Write(buf, 0, buf.Length);
            using (var resp = (HttpWebResponse)req.GetResponse())
                return (int)resp.StatusCode >= 200 && (int)resp.StatusCode < 300;
        }

        // 拉全网 Top 30（得分率 desc，同率按提交时间先后）；连不上返回 null
        List<string> CloudTop()
        {
            string url = CloudEp + "/.cloud/database/rest/scores?select=owner_name,score,rate,created_at" +
                         "&order=rate.desc%2Ccreated_at.asc&limit=30";
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = "GET";
            req.Timeout = 6000;
            req.Headers.Add("x-wb-webapp-access-key", CloudKey);
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var sr = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                return ParseRows(sr.ReadToEnd());
        }

        // 极简 JSON 数组解析（字段固定，够用即可）
        List<string> ParseRows(string json)
        {
            var list = new List<string>();
            int depth = 0, objStart = -1;
            for (int i = 0; i < json.Length; i++)
            {
                if (json[i] == '{') { if (depth == 0) objStart = i; depth++; }
                else if (json[i] == '}')
                {
                    depth--;
                    if (depth == 0 && objStart >= 0)
                    {
                        string obj = json.Substring(objStart, i - objStart + 1);
                        string n = JsonStr(obj, "owner_name");
                        if (n != null)
                        {
                            int sc = (int)JsonNum(obj, "score");
                            double rt = JsonNum(obj, "rate");
                            string t = JsonStr(obj, "created_at");
                            string when = t != null && t.Length >= 16 ? t.Substring(5, 11).Replace('T', ' ') : "";
                            list.Add(n + " — " + sc + " 分（" + rt.ToString("0.0") + " 分/秒）" + (when != "" ? "  " + when : ""));
                        }
                        objStart = -1;
                    }
                }
            }
            return list;
        }

        static string JsonStr(string obj, string key)
        {
            string pat = "\"" + key + "\":\"";
            int a = obj.IndexOf(pat);
            if (a < 0) return null;
            a += pat.Length;
            var sb = new StringBuilder();
            while (a < obj.Length)
            {
                char c = obj[a];
                if (c == '\\') { a += 2; continue; }
                if (c == '"') break;
                sb.Append(c); a++;
            }
            return sb.ToString();
        }

        static double JsonNum(string obj, string key)
        {
            string pat = "\"" + key + "\":";
            int a = obj.IndexOf(pat);
            if (a < 0) return 0;
            a += pat.Length;
            int b = a;
            while (b < obj.Length && (char.IsDigit(obj[b]) || obj[b] == '-' || obj[b] == '.' || obj[b] == 'e' || obj[b] == 'E' || obj[b] == '+')) b++;
            double v;
            return double.TryParse(obj.Substring(a, b - a), out v) ? v : 0;
        }
        List<string> LoadBoard()
        {
            var rows = new List<string>();
            try
            {
                if (File.Exists(boardPath))
                    rows = File.ReadAllLines(boardPath, Encoding.UTF8)
                        .Where(l => !string.IsNullOrWhiteSpace(l)).ToList();
            }
            catch { }
            return rows;
        }

        // ---------- 打赏 ----------
        // 微信收款码 PNG 的 base64（构建时注入）
        static readonly string QR_B64 = "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ABivuqigD4u8Df8ABJ34KfD/AMbeH/FOl3fiptT0PUbfU7UXGpRNGZYZVkTcBCMruUZGRx3r7PyaXFGKADAowKWigBMUYpaKAEwKMClooAKKKKAGsM189ftL/sO/Dv8Aar13RtV8az61Fc6Vbva2/wDZV2kK7GbcdwaNsnNfQ9JigD5u/Zs/YG+Gv7LXjS/8U+DLrXZdSvdPbTJRql4k0flNLHIcBY1w26Jec9M19I4paKAKmo2KahYXFrISI542jYj0IINfD/8Aw5t+An/P54w/8GkP/wAYr7rpMUAfCv8Aw5t+An/P54x/8GkP/wAYo/4c2/AT/n88Y/8Ag0h/+MV91YoxQB8K/wDDm34Cf8/njH/waQ//ABivUv2cf+Cf3wx/Zf8AHlz4u8GXGvS6pcWEmnSLql4k0flO8bnAWNcHMS96+mMUYoAWiiigBK+N/iN/wSt+DXxR8eeIPF+t3nigarrd7Lf3S2uoRRxCSRizbVMJwMn1r7JpMCrA8n/Zw/Zt8Kfsv+BLrwj4Ol1CXS7i/k1F21OZZZfNdI0blUUYxEvGPWvVQMU/ApaAE2ilooqACvhm+/4I+fAvUb24uprzxb5k0jSPt1OIDJJJ/wCWFfc1JgVZZwvwb+Emi/BH4baJ4H8OvdyaNo8bxWzXrh5cNI0h3MAoPLnoK8k/aP8A2B/hp+1H41sfFHjS412LUrLT002IaXeJCnlLJJIMho2yd0rd6+lcUYFAHwoP+CNnwFP/AC+eMP8AwaRf/GKX/hzX8Bf+fzxh/wCDSH/4xX3XRUEHwp/w5r+Av/P54w/8GkP/AMYo/wCHNfwF/wCfzxh/4NIf/jFfddFAGJ4R8M2ngvwtovh3TzKdP0myhsLczNufy4kCJuIAycKMnFbQ4FGKWgAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAP/Z";

        void ShowDonate()
        {
            dialogOpen = true;
            try
            {
                Image qr;
                using (var ms = new MemoryStream(Convert.FromBase64String(QR_B64)))
                    qr = new Bitmap(Image.FromStream(ms));
                using (var dlg = new Form
                {
                    FormBorderStyle = FormBorderStyle.FixedDialog,
                    StartPosition = FormStartPosition.CenterScreen,
                    TopMost = true,
                    ShowInTaskbar = false,
                    MaximizeBox = false,
                    MinimizeBox = false,
                    BackColor = Color.White,
                    Text = "打赏作者",
                    ClientSize = new Size(380, 470)
                })
                {
                    var pic = new PictureBox
                    {
                        Image = qr,
                        SizeMode = PictureBoxSizeMode.Zoom,
                        Location = new Point(48, 18),
                        Size = new Size(284, 284)
                    };
                    var lbl = new Label
                    {
                        Text = "小游戏仅供小娱乐，\n如果你感觉有趣，可以打赏作者，嘻嘻",
                        Font = new Font("Microsoft YaHei UI", 11.5f),
                        ForeColor = Color.FromArgb(80, 80, 80),
                        TextAlign = ContentAlignment.MiddleCenter,
                        Location = new Point(10, 310),
                        Size = new Size(360, 90)
                    };
                    var tip = new Label
                    {
                        Text = "（微信扫一扫）",
                        Font = new Font("Microsoft YaHei UI", 9f),
                        ForeColor = Color.FromArgb(150, 150, 150),
                        TextAlign = ContentAlignment.MiddleCenter,
                        Location = new Point(10, 405),
                        Size = new Size(360, 30)
                    };
                    dlg.Controls.Add(pic);
                    dlg.Controls.Add(lbl);
                    dlg.Controls.Add(tip);
                    dlg.ShowDialog(this);
                }
            }
            catch { }
            dialogOpen = false;
        }

        // ---------- 留言板 ----------
        bool CloudPostMsg(string content)
        {
            var req = (HttpWebRequest)WebRequest.Create(CloudEp + "/.cloud/database/rest/messages?select=*");
            req.Method = "POST";
            req.ContentType = "application/json";
            req.Timeout = 6000;
            req.Headers.Add("x-wb-webapp-access-key", CloudKey);
            string body = "{\"content\":\"" + JsonEsc(content) + "\"}";
            var buf = Encoding.UTF8.GetBytes(body);
            req.ContentLength = buf.Length;
            using (var st = req.GetRequestStream()) st.Write(buf, 0, buf.Length);
            using (var resp = (HttpWebResponse)req.GetResponse())
                return (int)resp.StatusCode >= 200 && (int)resp.StatusCode < 300;
        }

        void ShowFeedback()
        {
            dialogOpen = true;
            try
            {
                using (var dlg = new Form
                {
                    FormBorderStyle = FormBorderStyle.FixedDialog,
                    StartPosition = FormStartPosition.CenterScreen,
                    TopMost = true,
                    ShowInTaskbar = false,
                    MaximizeBox = false,
                    MinimizeBox = false,
                    BackColor = Color.White,
                    Text = "留言板",
                    ClientSize = new Size(440, 330)
                })
                {
                    var lbl = new Label
                    {
                        Text = "匿名留下你的意见或新的小游戏想法（如果有的话）",
                        Font = new Font("Microsoft YaHei UI", 10f),
                        ForeColor = Color.FromArgb(110, 110, 110),
                        Location = new Point(18, 16),
                        Size = new Size(404, 28)
                    };
                    var box = new TextBox
                    {
                        Multiline = true,
                        MaxLength = 200,
                        Font = new Font("Microsoft YaHei UI", 11f),
                        Location = new Point(18, 48),
                        Size = new Size(404, 180)
                    };
                    var cnt = new Label
                    {
                        Text = "0 / 200",
                        Font = new Font("Microsoft YaHei UI", 8.5f),
                        ForeColor = Color.FromArgb(160, 160, 160),
                        Location = new Point(330, 232),
                        Size = new Size(92, 22),
                        TextAlign = ContentAlignment.MiddleRight
                    };
                    box.TextChanged += (s, e) => cnt.Text = box.TextLength + " / 200";
                    var send = new Button
                    {
                        Text = "发 送",
                        Font = new Font("Microsoft YaHei UI", 11f, FontStyle.Bold),
                        BackColor = Color.FromArgb(70, 130, 220),
                        ForeColor = Color.White,
                        FlatStyle = FlatStyle.Flat,
                        Location = new Point(18, 262),
                        Size = new Size(404, 46)
                    };
                    send.FlatAppearance.BorderSize = 0;
                    send.Click += (s, e) =>
                    {
                        string txt = box.Text.Trim();
                        if (txt.Length == 0) return;
                        send.Enabled = false; send.Text = "发送中…";
                        dlg.Cursor = Cursors.WaitCursor;
                        System.Threading.ThreadPool.QueueUserWorkItem(_ =>
                        {
                            bool ok = false;
                            try { ok = CloudPostMsg(txt); } catch { }
                            try
                            {
                                dlg.BeginInvoke((Action)(() =>
                                {
                                    dlg.Cursor = Cursors.Default;
                                    if (ok)
                                    {
                                        dlg.Close();
                                        MessageBox.Show("已送达，谢谢你的留言！", "留言板", MessageBoxButtons.OK, MessageBoxIcon.Information);
                                    }
                                    else
                                    {
                                        send.Enabled = true; send.Text = "重试发送";
                                        MessageBox.Show(dlg, "发送失败（可能没联网），稍后再试。", "留言板", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                                    }
                                }));
                            }
                            catch { }
                        });
                    };
                    dlg.Controls.Add(lbl);
                    dlg.Controls.Add(box);
                    dlg.Controls.Add(cnt);
                    dlg.Controls.Add(send);
                    dlg.AcceptButton = send;
                    dlg.ShowDialog(this);
                }
            }
            catch { }
            dialogOpen = false;
        }

        void ShowBoard()
        {
            var all = LoadBoard()
                .Select(l => l.Split('|'))
                .Where(a => a.Length >= 2)
                .Select(a => new { S = ParseI(a[0]), N = a[1], T = a.Length >= 3 ? a[2] : "" })
                .ToList();
            var sb = new StringBuilder();

            // 全网榜：得分率（分/秒）排行，同率先打先排；连不上回退本机 Top 30
            List<string> cloud = null;
            try { cloud = CloudTop(); } catch { }
            sb.AppendLine("== 全网 Top 30（按得分率：分/秒）==");
            if (cloud != null && cloud.Count > 0)
                sb.AppendLine(string.Join(Environment.NewLine, cloud.Select((t, i) => (i + 1) + ".  " + t).ToList()));
            else if (cloud != null)
                sb.AppendLine("全网榜还空着，来开个张。");
            else
            {
                sb.AppendLine("（云端连不上，显示本机 Top 30）");
                var localTop = all.OrderByDescending(x => x.S).Take(30)
                    .Select((r, i) => (i + 1) + ".  " + r.N + " — " + r.S).ToList();
                sb.AppendLine(localTop.Count == 0 ? "本机还没有记录。" : string.Join(Environment.NewLine, localTop));
            }

            sb.AppendLine();
            sb.AppendLine("== 本机最近 30 局 ==");
            var recent = Enumerable.Reverse(all).Take(30)
                .Select(r => (string.IsNullOrEmpty(r.T) ? "（旧记录）" : r.T) + "  " + r.N + " — " + r.S).ToList();
            sb.AppendLine(recent.Count == 0 ? "还没有记录。" : string.Join(Environment.NewLine, recent));
            ShowBoardMsg(sb.ToString());
        }
        void ShowBoardMsg(string msg)
        {
            dialogOpen = true;
            MessageBox.Show(this, msg, "排行榜", MessageBoxButtons.OK, MessageBoxIcon.Information);
            dialogOpen = false;
        }
        long ParseI(string s) { long v; return long.TryParse(s, out v) ? v : 0; }

        // ---------- 物理 ----------
        void Tick()
        {
            double now = sw.ElapsedMilliseconds;
            float dt = (float)Math.Min((now - lastTick) / 1000.0, 0.06);
            lastTick = now;
            if (dt <= 0) dt = 0.033f;

            PollInput();

            if (mode == Mode.Attack) StepPhysics(dt);
            if ((mode == Mode.Build || mode == Mode.CopyPick) && now - lastPoll > 600)
            {
                lastPoll = now;
                Repoll();
            }
            StepFx(dt);
            Invalidate();
        }

        bool OverlapR(float ax, float ay, float aw, float ah, float bx, float by, float bw, float bh)
        {
            return ax < bx + bw && ax + aw > bx && ay < by + bh && ay + ah > by;
        }

        void Knock(Block b, float ix, float iy)
        {
            b.Knocked = true; b.Static = false;
            // 有力量感：被打的图标继承入射速度的大头，再加上扬
            b.VX = ix * 0.55f + (float)(rnd.NextDouble() - 0.5) * 160;
            b.VY = Math.Min(iy * 0.45f, 320) - 150 - (float)rnd.NextDouble() * 190;
            if (b.IsTarget)
            {
                knocked++;
                pops.Add(new PopText { X = b.X + 38, Y = b.Y, Life = 1.0f, Text = "+100" });
            }
            Hit(b.X + 38, b.Y + 38, 420);
            shake = Math.Min(14, shake + 5);
        }

        void SyncIcon(string name, float x, float y)
        {
            Native.MoveIcon(name, (int)x, (int)y);
        }

        void StepPhysics(float dt)
        {
            const float G = 1500f;

            // 消失重试：缓存失效导致搬走失败的图标，每帧重试直到成功
            for (int i = vanishRetry.Count - 1; i >= 0; i--)
                if (Native.MoveIcon(vanishRetry[i], -170, -170)) vanishRetry.RemoveAt(i);

            // 弹丸：真图标从弹弓皮兜飞出
            if (proj != null && !proj.Dead)
            {
                proj.VY += G * dt;
                proj.X += proj.VX * dt; proj.Y += proj.VY * dt;
                SyncIcon(proj.Name, proj.X, proj.Y);

                foreach (var b in blocks)
                {
                    if (b.Knocked || b.Gone || b.Name == proj.Name || b.Name == armedName) continue;
                    if (OverlapR(proj.X, proj.Y, 50, 50, b.X + 10, b.Y + 8, 56, 56))
                    {
                        Knock(b, proj.VX, proj.VY);
                        proj.VX *= 0.92f; proj.VY *= 0.92f;   // 穿透继续飞，只轻微减速，保持力量感
                    }
                }

                if (proj.Y + 50 > GroundY)
                {
                    proj.Y = GroundY - 50;
                    proj.VY = -proj.VY * 0.3f;
                    proj.VX *= 0.85f;
                    if (Math.Abs(proj.VY) < 70) proj.VY = 0;
                    Dust(proj.X + 25, GroundY, 3);
                }
                if (proj.X < -90 || proj.X > W + 90 || proj.Y > H + 90) proj.Dead = true;
                // 落地趋于静止 → 死亡（速度阈值判定，VX 精确比较永远到不了 0）
                if (proj.VY == 0 && Math.Abs(proj.VX) < 25 && proj.Y + 50 >= GroundY - 1)
                {
                    proj.RestTimer += dt;
                    if (proj.RestTimer > 0.15f) proj.Dead = true;
                }
                else proj.RestTimer = 0;
            }
            if (proj != null && proj.Dead)
            {
                proj.DeadTimer += dt;
                if (proj.DeadTimer > 0.15f)
                {
                    // 弹丸打出去就消失（两种模式都是），自动装下一发
                    var b = BlockByName(proj.Name);
                    if (b != null) Vanish(b); else Native.MoveIcon(proj.Name, -170, -170);
                    proj = null;
                    ArmNext();
                }
            }

            // 被击倒的图标：真图标跟着物理飞，落定即消失
            foreach (var b in blocks)
            {
                if (b.Static || b.Gone) continue;
                b.VY += G * dt;
                b.X += b.VX * dt; b.Y += b.VY * dt;

                // 连锁：撞到还没倒的图标
                foreach (var o in blocks)
                {
                    if (o == b || o.Knocked || o.Gone || !o.Static || o.Name == armedName) continue;
                    if (OverlapR(b.X, b.Y, 76, 76, o.X + 10, o.Y + 8, 56, 56))
                        Knock(o, b.VX, b.VY);
                }

                if (b.Y + 76 > GroundY)
                {
                    b.Y = GroundY - 76;
                    b.VY = -b.VY * 0.25f;
                    b.VX *= 0.7f;
                    if (Math.Abs(b.VY) < 60) b.VY = 0;
                }
                if (b.X < 2) { b.X = 2; b.VX = Math.Abs(b.VX) * 0.4f; }
                if (b.X + 76 > W - 2) { b.X = W - 2 - 76; b.VX = -Math.Abs(b.VX) * 0.4f; }
                SyncIcon(b.Name, b.X, b.Y);

                // 飞出屏幕 / 落定 → 消失
                if (b.Y > H + 140 || (b.VY == 0 && Math.Abs(b.VX) < 30 && b.Y + 76 >= GroundY - 1))
                    Vanish(b);
            }

            if (shake > 0) shake = Math.Max(0, shake - dt * 26);

            // 靶子全灭 → 自动结算（普通模式=堡垒区没图标；乱打=图标全打完）
            bool anyTarget = false, allDone = true;
            foreach (var b in blocks)
            {
                if (!b.IsTarget) continue;
                anyTarget = true;
                if (!b.Knocked && !b.Gone) allDone = false;
            }
            if (anyTarget && allDone) endWait += dt; else endWait = 0;
            if (anyTarget && allDone && endWait > 1.0f) EndRound();
        }

        void StepFx(float dt)
        {
            for (int i = parts.Count - 1; i >= 0; i--)
            {
                var p = parts[i];
                p.VY += 900 * dt; p.X += p.VX * dt; p.Y += p.VY * dt;
                p.Life -= dt;
                if (p.Life <= 0) parts.RemoveAt(i);
            }
            for (int i = pops.Count - 1; i >= 0; i--) { pops[i].Y -= 40 * dt; pops[i].Life -= dt; if (pops[i].Life <= 0) pops.RemoveAt(i); }
        }

        void Dust(float x, float y, int n)
        {
            for (int i = 0; i < n; i++)
                parts.Add(new Particle { X = x, Y = y, VX = (float)(rnd.NextDouble() - 0.5) * 200, VY = -rnd.Next(30, 160), Life = 0.5f, Size = 4, C = Color.FromArgb(180, 230, 225, 205) });
        }
        void Hit(float x, float y, float speed)
        {
            int n = Math.Min(20, 6 + (int)(speed / 90));
            for (int i = 0; i < n; i++)
            {
                bool spark = rnd.NextDouble() < 0.4;
                parts.Add(new Particle
                {
                    X = x, Y = y,
                    VX = (float)(rnd.NextDouble() - 0.5) * 520,
                    VY = (float)(rnd.NextDouble() - 0.8) * 460,
                    Life = 0.6f,
                    Size = spark ? 3 : 5,
                    C = spark ? Color.FromArgb(220, 255, 250, 210) : Color.FromArgb(200, 255, 210, 110)
                });
            }
        }

        // ---------- 绘制 ----------
        void DrawBtn(Graphics g, RectangleF r, string txt, bool hot)
        {
            using (var pth = Round(r, 10))
            using (var br = new SolidBrush(hot ? Color.FromArgb(230, 70, 130, 220) : Color.FromArgb(220, 25, 32, 45)))
            {
                g.FillPath(br, pth);
            }
            using (var pen = new Pen(Color.FromArgb(160, 255, 255, 255), 1.4f)) g.DrawPath(pen, Round(r, 10));
            TextRenderer.DrawText(g, txt, fMid, new Rectangle((int)r.X, (int)r.Y, (int)r.Width, (int)r.Height), Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
        void DrawListItem(Graphics g, RectangleF r, string txt, bool cur)
        {
            using (var br = new SolidBrush(cur ? Color.FromArgb(240, 70, 130, 220) : Color.FromArgb(235, 25, 32, 45)))
                g.FillRectangle(br, r.X, r.Y, r.Width, r.Height);
            using (var pen = new Pen(Color.FromArgb(160, 255, 255, 255), 1.2f))
                g.DrawRectangle(pen, r.X, r.Y, r.Width, r.Height);
            TextRenderer.DrawText(g, (cur ? "● " : "　 ") + txt, fMid,
                new Rectangle((int)r.X, (int)r.Y, (int)r.Width, (int)r.Height), Color.White,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        }
        GraphicsPath Round(RectangleF r, float rad)
        {
            var p = new GraphicsPath();
            p.AddArc(r.X, r.Y, rad * 2, rad * 2, 180, 90);
            p.AddArc(r.Right - rad * 2, r.Y, rad * 2, rad * 2, 270, 90);
            p.AddArc(r.Right - rad * 2, r.Bottom - rad * 2, rad * 2, rad * 2, 0, 90);
            p.AddArc(r.X, r.Bottom - rad * 2, rad * 2, rad * 2, 90, 90);
            p.CloseFigure();
            return p;
        }

        // 开局桌面截图（窗口未显示时壁纸可见）——用于文字自适应配色
        Bitmap bgShot;
        float RegionLum(Rectangle r)
        {
            try
            {
                if (bgShot == null) return 80f;
                int x0 = Math.Max(0, r.X), y0 = Math.Max(0, r.Y);
                int x1 = Math.Min(bgShot.Width - 1, r.Right), y1 = Math.Min(bgShot.Height - 1, r.Bottom);
                if (x1 - x0 < 4 || y1 - y0 < 4) return 80f;
                int step = Math.Max(12, Math.Min(40, (x1 - x0) / 20));
                double sum = 0; int n = 0;
                for (int y = y0; y < y1; y += step)
                    for (int x = x0; x < x1; x += step)
                    {
                        var c = bgShot.GetPixel(x, y);
                        sum += 0.299 * c.R + 0.587 * c.G + 0.114 * c.B; n++;
                    }
                return n == 0 ? 80f : (float)(sum / n);
            }
            catch { return 80f; }
        }

        // 自适应文字：按背后壁纸亮度选 亮字/暗字 + 反色描边，任何壁纸都可读
        // 描边粗细随字号自适应（小字 1px 防糊，大字 2px）；noEdge=true 用于自带底板的文字
        void ShadowText(Graphics g, string txt, Font f, Rectangle r, Color light, Color dark, TextFormatFlags flg)
        {
            bool brightBg = RegionLum(r) > 138;   // 背景偏亮 → 用暗字+白描边
            Color c = brightBg ? dark : light;
            Color edge = brightBg ? Color.FromArgb(220, 255, 255, 255) : Color.FromArgb(220, 0, 0, 0);
            int o = f.Size <= 12f ? 1 : 2;        // 小字描边细一圈，避免糊
            TextRenderer.DrawText(g, txt, f, new Rectangle(r.X + o, r.Y, r.Width, r.Height), edge, flg);
            TextRenderer.DrawText(g, txt, f, new Rectangle(r.X - o, r.Y, r.Width, r.Height), edge, flg);
            TextRenderer.DrawText(g, txt, f, new Rectangle(r.X, r.Y + o, r.Width, r.Height), edge, flg);
            TextRenderer.DrawText(g, txt, f, new Rectangle(r.X, r.Y - o, r.Width, r.Height), edge, flg);
            TextRenderer.DrawText(g, txt, f, r, c, flg);
        }

        // 普通模式：分区虚线（不带文字）
        void DrawSplit(Graphics g)
        {
            if (kind != Kind.Normal || mode == Mode.Menu || mode == Mode.Over) return;
            using (var pen = new Pen(Color.FromArgb(110, 255, 255, 255), 2f) { DashStyle = DashStyle.Dash })
                g.DrawLine(pen, splitX, 118, splitX, GroundY);
        }

        // 固定弹弓：木架 + 皮筋；右键可拖动
        void DrawSling(Graphics g)
        {
            if (mode != Mode.Attack) return;
            float bx = slingPos.X;
            float fy = slingPos.Y + 40;

            if (kind == Kind.Full)
            {
                // 乱打模式：弹弓就是一个发射圈（开局随机位置，右键可拖）
                using (var pen = new Pen(Color.FromArgb(255, 70, 150, 255), 5f))
                    g.DrawEllipse(pen, bx - 34, slingPos.Y - 34, 68, 68);
                using (var pen = new Pen(Color.FromArgb(170, 255, 255, 255), 2f))
                    g.DrawEllipse(pen, bx - 42, slingPos.Y - 42, 84, 84);
                if (aiming)
                {
                    using (var pen = new Pen(Color.FromArgb(230, 255, 230, 150), 2f))
                        g.DrawLine(pen, bx, slingPos.Y, aimPt.X, aimPt.Y);
                }
                ShadowText(g, draggingSling ? "松开右键放下" : "右键拖我搬家", fSmall,
                    new Rectangle((int)bx - 70, (int)slingPos.Y + 46, 140, 22), Color.FromArgb(180, 255, 255, 255), Color.FromArgb(35, 35, 42), TextFormatFlags.HorizontalCenter);
                return;
            }

            using (var pen = new Pen(Color.FromArgb(235, 110, 70, 40), 8f))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                g.DrawLine(pen, bx, GroundY, bx, fy);
                g.DrawLine(pen, bx, fy, bx - 26, slingPos.Y - 4);
                g.DrawLine(pen, bx, fy, bx + 26, slingPos.Y - 4);
            }
            // 皮筋
            if (armedName != null && proj == null)
            {
                using (var pen = new Pen(Color.FromArgb(225, 60, 50, 45), 3f))
                {
                    if (aiming)
                    {
                        g.DrawLine(pen, bx - 26, slingPos.Y - 4, aimPt.X, aimPt.Y);
                        g.DrawLine(pen, bx + 26, slingPos.Y - 4, aimPt.X, aimPt.Y);
                    }
                    else
                    {
                        g.DrawLine(pen, bx - 26, slingPos.Y - 4, bx, slingPos.Y);
                        g.DrawLine(pen, bx + 26, slingPos.Y - 4, bx, slingPos.Y);
                    }
                }
            }
            // 底座阴影 + 可拖动提示
            using (var b = new SolidBrush(Color.FromArgb(120, 0, 0, 0))) g.FillEllipse(b, bx - 22, GroundY - 8, 44, 12);
            ShadowText(g, draggingSling ? "松开右键放下弹弓" : "右键拖我搬家", fSmall,
                new Rectangle((int)bx - 70, GroundY + 8, 140, 22), Color.FromArgb(180, 255, 255, 255), Color.FromArgb(35, 35, 42), TextFormatFlags.HorizontalCenter);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            DrawSplit(g);
            DrawSling(g);
            DrawHud(g);
            if (mode == Mode.Menu) DrawMenu(g);
            if (mode == Mode.Over) DrawOver(g);
            foreach (var p in parts)
                using (var b = new SolidBrush(Color.FromArgb(Math.Min(255, (int)(p.Life * 255 * 1.6)), p.C))) g.FillRectangle(b, p.X, p.Y, p.Size, p.Size);
            foreach (var t in pops)
                using (var b = new SolidBrush(Color.FromArgb((int)(Math.Min(1, t.Life) * 255), 255, 240, 140)))
                    g.DrawString(t.Text, fMid, b, t.X - 30, t.Y - 34);
        }

        void DrawHud(Graphics g)
        {
            if (mode == Mode.Menu) return;
            btnExit = new RectangleF(W - 146, 26, 118, 42);
            btnBoard2 = new RectangleF(W - 272, 26, 118, 42);
            btnDonate = new RectangleF(W - 398, 26, 118, 42);
            btnMsg = new RectangleF(W - 524, 26, 118, 42);
            DrawBtn(g, btnExit, "退出", false);
            DrawBtn(g, btnBoard2, "排行榜", false);
            DrawBtn(g, btnDonate, "打赏 ☕", false);
            DrawBtn(g, btnMsg, "留言板", false);

            if (mode == Mode.Build || mode == Mode.CopyPick)
            {
                // 可拖动控制栏：模式切换 / 开始进攻 / 复制弹丸 / 说明文字
                barRect = BarRect();
                float cbx = barRect.X, cby = barRect.Y;
                using (var pth = Round(barRect, 12))
                using (var br = new SolidBrush(Color.FromArgb(235, 20, 28, 44)))
                    g.FillPath(br, pth);
                using (var pen = new Pen(Color.FromArgb(220, 90, 150, 230), 1.6f))
                    g.DrawPath(pen, Round(barRect, 12));
                // 左侧拖动把手（三道横线）
                using (var pen = new Pen(Color.FromArgb(230, 150, 190, 240), 2f))
                    for (int i = 0; i < 3; i++)
                        g.DrawLine(pen, cbx + 14, cby + 34 + i * 9, cbx + 32, cby + 34 + i * 9);
                btnMode = new RectangleF(cbx + 42, cby + 12, 176, 44);
                btnFight = new RectangleF(cbx + 230, cby + 12, 176, 44);
                btnCopy = new RectangleF(cbx + 418, cby + 12, 192, 44);
                DrawBtn(g, btnMode, "模式：" + (kind == Kind.Normal ? "普通" : "乱打") + " ▾", false);
                DrawBtn(g, btnFight, mode == Mode.CopyPick ? "返回建造 ◀" : "开始进攻 ▶", true);
                DrawBtn(g, btnCopy, mode == Mode.CopyPick ? "取消复制 ✕" : "复制弹丸 ×5", false);
                string barHint = mode == Mode.CopyPick
                    ? "点哪个图标就复制它 ×5，点空白处取消"
                    : (kind == Kind.Full ? "拖框可一次选中多个图标，一起拖动摆放"
                                          : "弹丸放左边，靶子摆右边，拖框可多选一起摆");
                // 深色底板上直接画白字（不描边，避免小字糊成一团）
                TextRenderer.DrawText(g, barHint, fSmall,
                    new Rectangle((int)(cbx + 10), (int)(cby + 64), 604, 24), Color.FromArgb(235, 255, 255, 255), TextFormatFlags.HorizontalCenter);
                if (modeListOn && mode == Mode.Build)
                {
                    lstNormal = new RectangleF(btnMode.X, btnMode.Bottom + 4, 220, 44);
                    lstFull = new RectangleF(btnMode.X, btnMode.Bottom + 52, 220, 44);
                    DrawListItem(g, lstNormal, "普通模式（左右分区）", kind == Kind.Normal);
                    DrawListItem(g, lstFull, "全屏乱打", kind == Kind.Full);
                }

                // 选中图标高亮（色键窗口不支持半透明混色，只用不透明亮蓝描边）
                using (var pen = new Pen(Color.FromArgb(255, 60, 140, 255), 2f))
                    foreach (var b in blocks)
                    {
                        if (b.Gone || !b.Sel) continue;
                        g.DrawRectangle(pen, b.X, b.Y, 76, 76);
                    }
                if (selBoxOn)
                {
                    float bx = Math.Min(selBoxA.X, selBoxB.X), by = Math.Min(selBoxA.Y, selBoxB.Y);
                    float bw = Math.Abs(selBoxA.X - selBoxB.X), bh = Math.Abs(selBoxA.Y - selBoxB.Y);
                    using (var pen = new Pen(Color.FromArgb(255, 70, 150, 255), 2f))
                        g.DrawRectangle(pen, bx, by, bw, bh);
                }
            }
            if (mode == Mode.Attack)
            {
                btnEnd = new RectangleF(28, H - 72, 150, 44);
                DrawBtn(g, btnEnd, "结束结算 ■", true);
                int remain = 0;
                for (int i = ammoPos + 1; i < ammoQueue.Count; i++)
                {
                    var bb = BlockByName(ammoQueue[i]);
                    if (bb != null && !bb.Gone && !bb.Knocked) remain++;
                }
                ShadowText(g, "击倒 " + knocked + " / " + targetTotal + " 靶   剩 " + remain + " 发", fBig,
                    new Rectangle(W / 2 - 320, 22, 640, 44), Color.FromArgb(245, 255, 235, 160), Color.FromArgb(70, 45, 12), TextFormatFlags.HorizontalCenter);
                ShadowText(g, "左键按住拖动瞄准（拉得越远越猛），松手发射！右键拖动弹弓可以搬家", fSmall,
                    new Rectangle(W / 2 - 320, 72, 640, 26), Color.FromArgb(225, 255, 255, 255), Color.FromArgb(32, 34, 40), TextFormatFlags.HorizontalCenter);

                // 当前弹丸高亮（在弹弓皮兜上）
                if (armedName != null && proj == null)
                    using (var pen = new Pen(Color.FromArgb(230, 255, 220, 90), 2.5f) { DashStyle = DashStyle.Dash })
                        g.DrawEllipse(pen, slingPos.X - 44, slingPos.Y - 44, 88, 88);

                // 弹道预览（从弹弓皮兜出发）
                if (aiming && armedName != null)
                {
                    float dx = pressPt.X - aimPt.X, dy = pressPt.Y - aimPt.Y;
                    float dist = (float)Math.Sqrt(dx * dx + dy * dy);
                    if (dist > 30)
                    {
                        float pow = Math.Min(dist, 220) * 9.0f;
                        float vx = dx / dist * pow, vy = dy / dist * pow;
                        float x = slingPos.X, y = slingPos.Y;
                        for (int i = 0; i < 26; i++)
                        {
                            vy += 1500f * 0.05f; x += vx * 0.05f; y += vy * 0.05f;
                            if (i % 2 == 0 && y < H && x > 0 && x < W)
                                using (var db = new SolidBrush(Color.FromArgb(Math.Max(40, 190 - i * 7), 255, 240, 150)))
                                    g.FillEllipse(db, x - 3, y - 3, 6, 6);
                        }
                    }
                }
            }
        }

        void DrawMenu(Graphics g)
        {
            ShadowText(g, "图 标 弹 弓", fTitle, new Rectangle(0, H / 2 - 260, W, 120), Color.FromArgb(245, 255, 235, 150), Color.FromArgb(70, 45, 12), TextFormatFlags.HorizontalCenter);
            ShadowText(g, "真图标乱斗 · 桌面就是战场 · 关闭自动复位", fMid, new Rectangle(0, H / 2 - 130, W, 40), Color.FromArgb(230, 235, 245, 255), Color.FromArgb(35, 38, 48), TextFormatFlags.HorizontalCenter);

            btnNormal = new RectangleF(W / 2 - 190, H / 2 - 50, 380, 60);
            btnFull = new RectangleF(W / 2 - 190, H / 2 + 26, 380, 60);
            DrawBtn(g, btnNormal, "普通模式 · 左弹弓 右堡垒", true);
            DrawBtn(g, btnFull, "全屏乱打 · 整个桌面都是战场", false);

            DrawBtn(g, btnBoard, "排行榜", false);
            DrawBtn(g, btnExit, "退出", false);
            DrawBtn(g, btnDonate, "打赏 ☕", false);
        }

        void DrawOver(Graphics g)
        {
            ShadowText(g, "本局结束", fTitle, new Rectangle(0, H / 2 - 220, W, 100), Color.FromArgb(245, 255, 235, 150), Color.FromArgb(70, 45, 12), TextFormatFlags.HorizontalCenter);
            ShadowText(g, "击倒靶子 " + knocked + " / " + targetTotal + "  × 100", fMid, new Rectangle(0, H / 2 - 90, W, 40), Color.FromArgb(230, 235, 245, 255), Color.FromArgb(35, 38, 48), TextFormatFlags.HorizontalCenter);
            ShadowText(g, "总分 " + score, fBig, new Rectangle(0, H / 2 - 30, W, 70), Color.FromArgb(250, 255, 245, 200), Color.FromArgb(75, 48, 14), TextFormatFlags.HorizontalCenter);
            DrawBtn(g, btnAgain, "再来一局", true);
            DrawBtn(g, btnQuit, "退出复位", false);
        }
    }
}
'@

try {
  Add-Type -TypeDefinition $cs -ReferencedAssemblies 'System.Drawing', 'System.Windows.Forms' -ErrorAction Stop
  Write-Log 'C# 编译 OK'
} catch {
  Write-Log ("编译失败: " + $_.Exception.Message)
  [System.Windows.Forms.MessageBox]::Show("游戏引擎初始化失败，详见日志：`n$logPath", '图标弹弓', 'OK', 'Error') | Out-Null
  exit 1
}

# ---------------- 残局恢复：上次异常退出留下的快照/副本 ----------------
if (Test-Path $snapPath) {
  Write-Log '发现残局快照，先复位上次桌面'
  Get-Content $snapPath -Encoding UTF8 | ForEach-Object {
    $p = $_ -split '\|', 3
    if ($p.Count -ge 3) { [void][IconSlingshot.Native]::MoveIcon($p[0], [int]$p[1], [int]$p[2]) }
  }
  Remove-Item $snapPath -Force -ErrorAction SilentlyContinue
}
if (Test-Path $copyManifest) {
  Get-Content $copyManifest -Encoding UTF8 | ForEach-Object {
    if ($_ -and (Test-Path -LiteralPath $_)) { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }
  }
  Remove-Item $copyManifest -Force -ErrorAction SilentlyContinue
  Write-Log '已清理上次残留的弹药副本'
}

# ---------------- 采集桌面图标 ----------------
[void][IconSlingshot.Native]::SetProcessDPIAware()
$icons = [IconSlingshot.Native]::GetIcons()
Write-Log ("图标数: " + $icons.Count)
if ($icons.Count -eq 0) {
  [System.Windows.Forms.MessageBox]::Show('没找到桌面图标（或被系统策略拦截），游戏无法开始。', '图标弹弓', 'OK', 'Warning') | Out-Null
  exit 1
}

# 解析每个图标到真实路径（复制弹丸用；用户桌面 + 公共桌面都查）
$desktop = [Environment]::GetFolderPath('Desktop')
$publicDesk = 'C:\Users\Public\Desktop'
$clsids = @{
  '此电脑' = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}'; '此计算机' = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
  'This PC' = '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
  '回收站' = '::{645FF040-5081-101B-9F08-00AA002F954E}'; 'Recycle Bin' = '::{645FF040-5081-101B-9F08-00AA002F954E}'
  '网络' = '::{F02C1A0D-BD21-4750-86F0-D240EDA803B3}'; 'Network' = '::{F02C1A0D-BD21-4750-86F0-D240EDA803B3}'
  '控制面板' = '::{26EE0668-A00A-44D7-9371-BEB064C98683}'
}
$paths = New-Object 'System.Collections.Generic.Dictionary[string,string]'
foreach ($ic in $icons) {
  $path = $null
  foreach ($dir in @($desktop, $publicDesk)) {
    foreach ($ext in @('', '.lnk', '.url', '.exe')) {
      $cand = Join-Path $dir ($ic.Name + $ext)
      if (Test-Path -LiteralPath $cand) { $path = $cand; break }
    }
    if ($path) { break }
  }
  if (-not $path -and $clsids.ContainsKey($ic.Name)) { $path = $clsids[$ic.Name] }
  if ($path) { $paths[$ic.Name] = $path }
}
Write-Log ("可复制图标: " + @($paths.Values | Where-Object { $_ -notlike '::*' }).Count)

# 快照：记录全部图标原位，退出时统一复位
Set-Content -Path $snapPath -Encoding UTF8 -Value ($icons | ForEach-Object { "{0}|{1}|{2}" -f $_.Name, $_.X, $_.Y })

# ---------------- 最小化所有窗口：只留壁纸和真图标 ----------------
try {
  $shell = New-Object -ComObject Shell.Application
  $shell.MinimizeAll()
  Write-Log '已最小化所有窗口'
} catch { Write-Log ('MinimizeAll 失败: ' + $_.Exception.Message) }
Start-Sleep -Milliseconds 600

# ---------------- 启动游戏 ----------------
$sw2 = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width
$sh2 = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height
$boardFile = Join-Path $rootDir 'leaderboard.txt'
$lastFile = Join-Path $rootDir 'lastname.txt'
$lastName = ''
if (Test-Path $lastFile) { $lastName = (Get-Content $lastFile -Encoding UTF8 -Raw).Trim() }

try {
  $form = New-Object IconSlingshot.GameForm($icons, $paths, $sw2, $sh2, $boardFile, $lastName, $copyManifest)
  Write-Log '游戏窗口启动'
  [void]$form.ShowDialog()
  Write-Log '游戏结束'
  # 复位：全部图标按快照搬回原位
  $restored = 0
  foreach ($ic in $icons) {
    if ([IconSlingshot.Native]::MoveIcon($ic.Name, $ic.X, $ic.Y)) { $restored++ }
  }
  Write-Log ("复位完成: $restored/" + $icons.Count)
  # 删除复制出来的弹药副本
  if (Test-Path $copyManifest) {
    $deleted = 0
    Get-Content $copyManifest -Encoding UTF8 | ForEach-Object {
      if ($_ -and (Test-Path -LiteralPath $_)) { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue; $deleted++ }
    }
    Remove-Item $copyManifest -Force -ErrorAction SilentlyContinue
    Write-Log ("弹药副本清理: $deleted")
  }
} finally {
  Remove-Item $snapPath -Force -ErrorAction SilentlyContinue
  Write-Log '===== 退出，桌面已复位 ====='
}
