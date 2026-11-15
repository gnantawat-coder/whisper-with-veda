using GluuBot.Core;

namespace GluuBot;

/// One window for everything: readiness, talk key, language, model download, microphone, vocabulary, recent text.
public sealed class SettingsForm : Form
{
    private readonly TrayApp app;
    private readonly Label status = new() { AutoSize = true, MaximumSize = new Size(500, 0) };
    private readonly Label keyLabel = new() { AutoSize = true, Font = new Font("Segoe UI", 10f, FontStyle.Bold), Padding = new Padding(0, 6, 8, 0) };
    private readonly Button keyButton = new() { Text = "เปลี่ยนปุ่ม", AutoSize = true };
    private readonly RadioButton thRadio = new() { Text = "TH · ข้อความไทย", AutoSize = true }, enRadio = new() { Text = "EN · แปลเป็นอังกฤษ", AutoSize = true };
    private readonly ComboBox modelBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 480 };
    private readonly Label modelState = new() { AutoSize = true, MaximumSize = new Size(480, 0) };
    private readonly Button downloadButton = new() { Text = "ดาวน์โหลด", AutoSize = true }, useButton = new() { Text = "ใช้โมเดลนี้", AutoSize = true };
    private readonly ProgressBar progress = new() { Width = 300, Maximum = 1000, Visible = false };
    private readonly ComboBox micBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 480 };
    private readonly TextBox vocabulary = new() { Multiline = true, Width = 480, Height = 60, ScrollBars = ScrollBars.Vertical };
    private readonly ListBox history = new() { Width = 480, Height = 96, HorizontalScrollbar = true };
    private readonly Button copyButton = new() { Text = "คัดลอกข้อความที่เลือก", AutoSize = true };
    private readonly Button testButton = new() { Text = "ทดสอบความเร็วด้วยไฟล์ตัวอย่าง", AutoSize = true }, diagButton = new() { Text = "คัดลอกข้อมูลเครื่อง (ส่งให้ผู้พัฒนา)", AutoSize = true };
    private readonly Label testLabel = new() { AutoSize = true, MaximumSize = new Size(480, 0) };
    private CancellationTokenSource? download;
    private bool loading;

    public SettingsForm(TrayApp app)
    {
        this.app = app;
        SuspendLayout();
        AutoScaleDimensions = new SizeF(96F, 96F); AutoScaleMode = AutoScaleMode.Dpi;
        Text = "gluu bot for Windows (lite) " + TrayApp.Version; Font = new Font("Segoe UI", 9f);
        ClientSize = new Size(560, 760); MinimumSize = new Size(480, 400); StartPosition = FormStartPosition.CenterScreen; MaximizeBox = false;
        var root = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(12) };
        Controls.Add(root);

        root.Controls.Add(Group("สถานะ", status));
        root.Controls.Add(Group("ปุ่มพูด · กดค้างเพื่อพูด ปล่อยเพื่อพิมพ์", keyLabel, keyButton,
            Note("ปุ่มพูด + Space สลับ TH/EN · Esc ยกเลิก · Windows มองไม่เห็นปุ่ม Fn จึงต้องใช้ปุ่มอื่น · ปุ่มธรรมดา (เช่น F9) จะถูกยึดไว้ใช้กับ gluu bot อย่างเดียว")));
        root.Controls.Add(Group("ภาษาผลลัพธ์", thRadio, enRadio));
        root.Controls.Add(Group("โมเดลถอดเสียง", modelBox, modelState, downloadButton, useButton, progress,
            Note("ดาวน์โหลดจาก huggingface.co ครั้งเดียว ตรวจ checksum ก่อนใช้ · เสียงและข้อความไม่ถูกส่งออกจากเครื่อง")));
        root.Controls.Add(Group("ไมโครโฟน", micBox));
        root.Controls.Add(Group("คำศัพท์ของคุณ · ชื่อคน ชื่อโปรเจกต์ ศัพท์เทคนิค คั่นด้วยจุลภาค", vocabulary));
        root.Controls.Add(Group("ข้อความล่าสุด · อยู่ในหน่วยความจำเท่านั้น หายเมื่อปิดโปรแกรม", history, copyButton));
        root.Controls.Add(Group("ตรวจเครื่อง", testButton, diagButton, testLabel));

        foreach (var m in ModelCatalog.All) modelBox.Items.Add(m.Id + " — " + m.Label);
        foreach (var (_, name) in Recorder.Devices()) micBox.Items.Add(name);

        keyButton.Click += (_, _) => CaptureKey();
        thRadio.CheckedChanged += (_, _) => { if (!loading && thRadio.Checked) app.SetMode("TH"); };
        enRadio.CheckedChanged += (_, _) => { if (!loading && enRadio.Checked) app.SetMode("EN"); };
        modelBox.SelectedIndexChanged += (_, _) => { if (!loading) UpdateModelRow(); };
        downloadButton.Click += async (_, _) => await DownloadOrCancelAsync();
        useButton.Click += async (_, _) => { app.Settings.Model = Selected().Id; app.Save(); await app.RestartEngineAsync(); };
        micBox.SelectedIndexChanged += (_, _) => { if (!loading) { app.Settings.MicDevice = micBox.SelectedIndex - 1; app.Save(); } };
        vocabulary.Leave += (_, _) => { app.Settings.Vocabulary = vocabulary.Text; app.Save(); };
        copyButton.Click += (_, _) => { if (history.SelectedItem is string s && s.Length > 0) { try { Clipboard.SetText(s); } catch { } } };
        testButton.Click += async (_, _) => { testButton.Enabled = false; testLabel.Text = "กำลังทดสอบ…"; testLabel.Text = await app.TestEngineAsync(); testButton.Enabled = true; };
        diagButton.Click += (_, _) => { try { Clipboard.SetText(app.Diagnostics()); testLabel.Text = "คัดลอกแล้ว — วางส่งให้ผู้พัฒนาได้ (ไม่มีข้อความที่คุณพูด)"; } catch { } };

        app.Changed += OnAppChanged;
        FormClosing += (_, e) =>
        {
            app.Settings.Vocabulary = vocabulary.Text; app.Save(); app.CancelKeyCapture();
            if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }   // closing the window keeps gluu bot running in the tray
        };
        Disposed += (_, _) => { app.Changed -= OnAppChanged; download?.Cancel(); };
        ResumeLayout(false); PerformLayout();
        LoadFromApp();
    }

    private static Label Note(string text) => new() { Text = text, AutoSize = true, MaximumSize = new Size(480, 0), ForeColor = SystemColors.GrayText };

    private static GroupBox Group(string title, params Control[] controls)
    {
        var flow = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Location = new Point(10, 22), MaximumSize = new Size(500, 0), WrapContents = true };
        foreach (var c in controls) { c.Margin = new Padding(3, 3, 6, 6); flow.Controls.Add(c); }
        var box = new GroupBox { Text = title, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, MinimumSize = new Size(520, 0), Margin = new Padding(0, 0, 0, 10), Padding = new Padding(8) };
        box.Controls.Add(flow);
        return box;
    }

    private ModelInfo Selected() => ModelCatalog.All[Math.Max(0, modelBox.SelectedIndex)];

    private void OnAppChanged() { if (!IsDisposed && IsHandleCreated) LoadFromApp(); }

    private void LoadFromApp()
    {
        loading = true;
        status.Text = app.EngineState + (app.LastError.Length > 0 ? "\n" + app.LastError : "")
            + (app.EngineReady ? "\nกด " + TalkKeys.Name(app.Settings.TalkKey) + " ค้างแล้วพูด ปล่อยเพื่อพิมพ์ลงช่องที่เคอร์เซอร์อยู่" : "");
        keyLabel.Text = TalkKeys.Name(app.Settings.TalkKey);
        thRadio.Checked = app.Settings.Mode == "TH"; enRadio.Checked = app.Settings.Mode == "EN";
        if (modelBox.SelectedIndex < 0)
        {
            var current = app.InstalledModel() ?? ModelCatalog.Find(app.Settings.Model) ?? ModelCatalog.All[app.Engine.HasGpuBuild ? 0 : 1];
            modelBox.SelectedIndex = Array.IndexOf(ModelCatalog.All, current);
        }
        if (micBox.SelectedIndex < 0 && micBox.Items.Count > 0) micBox.SelectedIndex = Math.Clamp(app.Settings.MicDevice + 1, 0, micBox.Items.Count - 1);
        if (!vocabulary.Focused) vocabulary.Text = app.Settings.Vocabulary;
        var selected = history.SelectedIndex;
        history.BeginUpdate(); history.Items.Clear(); foreach (var h in app.History) history.Items.Add(h); history.EndUpdate();
        if (selected >= 0 && selected < history.Items.Count) history.SelectedIndex = selected; else if (history.Items.Count > 0) history.SelectedIndex = 0;
        testLabel.Text = app.LastTest;
        loading = false;
        UpdateModelRow();
    }

    private void UpdateModelRow()
    {
        var m = Selected();
        bool installed = TrayApp.IsInstalled(m), busy = download != null;
        modelState.Text = installed ? (app.ActiveModel == m.Id ? "กำลังใช้อยู่" : "ดาวน์โหลดแล้ว") : $"ยังไม่ได้ดาวน์โหลด · {m.Bytes / 1048576.0:0} MB";
        downloadButton.Text = busy ? "ยกเลิก" : "ดาวน์โหลด";
        downloadButton.Visible = busy || !installed;
        useButton.Visible = installed && app.ActiveModel != m.Id && !busy;
        modelBox.Enabled = !busy;
    }

    private async Task DownloadOrCancelAsync()
    {
        if (download != null) { download.Cancel(); return; }
        var m = Selected();
        var cts = new CancellationTokenSource(); download = cts;
        progress.Value = 0; progress.Visible = true; UpdateModelRow();
        try
        {
            var report = new Progress<double>(v => { if (!IsDisposed) { progress.Value = (int)(v * 1000); modelState.Text = $"กำลังดาวน์โหลด {v * 100:0}% ของ {m.Bytes / 1048576.0:0} MB"; } });
            await ModelDownloader.DownloadAsync(m, TrayApp.ModelPath(m), report, cts.Token);
            download = null; progress.Visible = false;
            app.Settings.Model = m.Id; app.Save();
            await app.RestartEngineAsync();
        }
        catch (OperationCanceledException) { modelState.Text = "ยกเลิกแล้ว"; }
        catch (Exception ex) { modelState.Text = "ดาวน์โหลดไม่สำเร็จ: " + ex.Message; }
        finally
        {
            if (ReferenceEquals(download, cts)) download = null;
            cts.Dispose();
            if (!IsDisposed) { progress.Visible = false; var keep = modelState.Text; UpdateModelRow(); if (keep.StartsWith("ดาวน์โหลดไม่สำเร็จ") || keep == "ยกเลิกแล้ว") modelState.Text = keep; }
        }
    }

    private void CaptureKey()
    {
        keyButton.Enabled = false; keyLabel.Text = "กดปุ่มที่ต้องการ… (Esc ยกเลิก)";
        app.BeginKeyCapture(vk =>
        {
            if (vk >= 0) { app.Settings.TalkKey = vk; app.Save(); }
            if (!IsDisposed) keyButton.Enabled = true;
            app.Refresh();
        });
    }
}
