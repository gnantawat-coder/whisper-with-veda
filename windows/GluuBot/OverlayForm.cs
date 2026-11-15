using System.Drawing.Drawing2D;

namespace GluuBot;

/// The small status pill at the bottom of the screen. It never takes focus and clicks pass through it,
/// so the field the user is typing into stays the target.
public sealed class OverlayForm : Form
{
    private const int WS_EX_TOPMOST = 0x8, WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;
    private static readonly Color Ink = Color.FromArgb(17, 17, 17), Cyan = Color.FromArgb(95, 225, 255);
    private readonly System.Windows.Forms.Timer hideTimer = new();
    private string text = "", mode = "TH";
    private float level;
    private bool listening;

    public OverlayForm()
    {
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; StartPosition = FormStartPosition.Manual; TopMost = true;
        BackColor = Ink; Opacity = 0.94; DoubleBuffered = true;
        Font = new Font("Segoe UI", 10.5f, FontStyle.Bold);
        hideTimer.Tick += (_, _) => { hideTimer.Stop(); Hide(); };
    }

    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE; return cp; }
    }

    public void ShowListening(string modeLabel) { listening = true; level = 0; Present("กำลังฟัง", modeLabel, 0); }
    public void ShowThinking(string modeLabel) { listening = false; Present("กำลังถอดเสียง…", modeLabel, 0); }
    public void Flash(string message, string modeLabel, int milliseconds = 1600) { listening = false; Present(message, modeLabel, milliseconds); }
    public void HideNow() { hideTimer.Stop(); Hide(); }
    public void SetLevel(float value) { if (!listening || !Visible) return; level = level * 0.6f + value * 0.4f; Invalidate(); }

    private void Present(string message, string modeLabel, int hideAfter)
    {
        text = message; mode = modeLabel;
        hideTimer.Stop();
        float scale = DeviceDpi / 96f;
        using (var g = CreateGraphics())
        {
            int width = (int)(g.MeasureString(text, Font).Width + 118 * scale);
            Size = new Size(Math.Max((int)(230 * scale), width), (int)(44 * scale));
        }
        var area = Screen.FromPoint(Cursor.Position).WorkingArea;
        Location = new Point(area.Left + (area.Width - Width) / 2, area.Bottom - Height - (int)(28 * scale));
        using (var path = Rounded(new Rectangle(0, 0, Width, Height), Height / 2)) Region = new Region(path);
        if (!Visible) Show();
        Invalidate();
        if (hideAfter > 0) { hideTimer.Interval = hideAfter; hideTimer.Start(); }
    }

    private static GraphicsPath Rounded(Rectangle r, int radius)
    {
        int d = radius * 2;
        var p = new GraphicsPath();
        p.AddArc(r.Left, r.Top, d, d, 90, 180); p.AddArc(r.Right - d, r.Top, d, d, 270, 180); p.CloseFigure();
        return p;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        float s = DeviceDpi / 96f, h = Height;
        // Two cyan eyes on the left: the same face as the Mac character, in miniature. They grow with the voice.
        float eyeH = (14 + (listening ? level * 10 : 0)) * s, eyeW = 5 * s, cx = 26 * s;
        using (var eye = new Pen(Cyan, eyeW) { StartCap = LineCap.Round, EndCap = LineCap.Round })
            foreach (float dx in new[] { -5f, 5f })
                g.DrawLine(eye, cx + dx * s, h / 2 - eyeH / 2 + eyeW / 2, cx + dx * s, h / 2 + eyeH / 2 - eyeW / 2);
        using var white = new SolidBrush(Color.White);
        var size = g.MeasureString(text, Font);
        g.DrawString(text, Font, white, 46 * s, (h - size.Height) / 2);
        // Language pill on the right.
        using var small = new Font("Segoe UI", 8.5f, FontStyle.Bold);
        var ms = g.MeasureString(mode, small);
        var pill = new RectangleF(Width - ms.Width - 30 * s, (h - 22 * s) / 2, ms.Width + 16 * s, 22 * s);
        using (var pillPath = Rounded(Rectangle.Round(pill), (int)(11 * s))) using (var dim = new SolidBrush(Color.FromArgb(60, 60, 60))) g.FillPath(dim, pillPath);
        g.DrawString(mode, small, white, pill.Left + 8 * s, pill.Top + (pill.Height - ms.Height) / 2);
    }
}
