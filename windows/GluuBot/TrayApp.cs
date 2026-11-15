using System.Runtime.InteropServices;
using System.Text;
using GluuBot.Core;

namespace GluuBot;

public enum Phase { Idle, Recording, Processing }

/// The whole app: a tray icon, a keyboard hook, the recorder and the engine. No main window.
public sealed class TrayApp : ApplicationContext
{
    public const string Version = "0.1.0";
    public static readonly string AppDir = AppContext.BaseDirectory;
    /// Models live under C:\ProgramData: whisper.cpp opens files through narrow-character APIs, so a Thai user name
    /// in the path would stop it from finding the model. ProgramData is always plain ASCII.
    public static readonly string ModelsDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "gluu bot", "models");
    private static readonly string SettingsPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "gluu bot", "settings.json");

    public readonly AppSettings Settings = AppSettings.Load(SettingsPath);
    public readonly WhisperEngine Engine = new(Path.Combine(AppDir, "engine"));
    public readonly List<string> History = new();   // the last transcripts, in memory only — never written anywhere
    public Phase Phase { get; private set; } = Phase.Idle;
    public bool EngineReady { get; private set; }
    public string EngineState { get; private set; } = "ยังไม่เริ่ม";
    public string ActiveModel { get; private set; } = "";
    public string LastError { get; private set; } = "";
    public string LastTest { get; private set; } = "ยังไม่ได้ทดสอบ";
    public event Action? Changed;

    private readonly Recorder recorder = new();
    private readonly OverlayForm overlay = new();
    private readonly NotifyIcon tray = new();
    private readonly ToolStripMenuItem thItem = new("TH · ข้อความไทย"), enItem = new("EN · แปลเป็นอังกฤษ");
    private KeyboardHook? hook;
    private TalkShortcut shortcut;
    private Action<int>? keyCapture;
    private bool spaceDown;
    private CancellationTokenSource? work;
    private SettingsForm? settingsForm;
    private byte[]? warmUpClip;
    private int engineGeneration;

    public TrayApp()
    {
        _ = overlay.Handle;   // create the window handle now so background threads can post to the UI thread
        recorder.Level += value => Post(() => overlay.SetLevel(value));
        var menu = new ContextMenuStrip();
        thItem.Click += (_, _) => SetMode("TH"); enItem.Click += (_, _) => SetMode("EN");
        menu.Items.Add(thItem); menu.Items.Add(enItem); menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("คัดลอกข้อความล่าสุด", null, (_, _) => CopyLatest());
        menu.Items.Add("ตั้งค่า…", null, (_, _) => ShowSettings());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("ออกจาก gluu bot", null, (_, _) => ExitThread());
        tray.Icon = MakeIcon(); tray.ContextMenuStrip = menu; tray.Visible = true;
        tray.DoubleClick += (_, _) => ShowSettings();
        try { hook = new KeyboardHook(OnKey); }
        catch (Exception ex) { LastError = "ติดตั้งตัวดักปุ่มไม่ได้: " + ex.Message; }
        try { var jfk = Path.Combine(AppDir, "test-jfk.wav"); if (File.Exists(jfk)) warmUpClip = Wav.Prefix(File.ReadAllBytes(jfk), 1.0); } catch { }
        Refresh();
        if (InstalledModel() == null) { EngineState = "ยังไม่มีโมเดล — เปิดตั้งค่าแล้วกดดาวน์โหลด"; ShowSettings(); }
        else _ = RestartEngineAsync();
    }

    // MARK: models and engine
    public static string ModelPath(ModelInfo m) => Path.Combine(ModelsDir, m.File);
    public static bool IsInstalled(ModelInfo m) { try { return File.Exists(ModelPath(m)) && new FileInfo(ModelPath(m)).Length == m.Bytes; } catch { return false; } }
    /// The model the user picked if it is on disk, otherwise the most accurate one that is.
    public ModelInfo? InstalledModel()
    {
        var chosen = ModelCatalog.Find(Settings.Model);
        if (chosen != null && IsInstalled(chosen)) return chosen;
        return ModelCatalog.All.FirstOrDefault(IsInstalled);
    }

    public async Task RestartEngineAsync()
    {
        int generation = ++engineGeneration;
        var model = InstalledModel();
        EngineReady = false;
        if (model == null) { Engine.Stop(); EngineState = "ยังไม่มีโมเดล — กดดาวน์โหลดในหน้านี้"; ActiveModel = ""; Refresh(); return; }
        EngineState = "กำลังโหลดโมเดล " + model.Id + "…"; ActiveModel = model.Id; Refresh();
        try
        {
            await Engine.StartAsync(ModelPath(model));
            if (generation != engineGeneration) return;
            EngineReady = true; EngineState = "พร้อม · " + model.Id + (Engine.HasGpuBuild ? " · NVIDIA" : " · CPU"); LastError = "";
        }
        catch (Exception ex)
        {
            if (generation != engineGeneration) return;
            EngineState = "เอนจินเริ่มไม่ได้"; LastError = ex.Message;
        }
        Refresh();
    }

    /// Transcribes the bundled English sample, so a tester can report how fast this machine is without speaking.
    public async Task<string> TestEngineAsync()
    {
        var path = Path.Combine(AppDir, "test-jfk.wav");
        if (!EngineReady) return LastTest = "เอนจินยังไม่พร้อม";
        if (!File.Exists(path)) return LastTest = "ไม่พบ test-jfk.wav";
        try
        {
            var watch = System.Diagnostics.Stopwatch.StartNew();
            var text = await Engine.TranscribeAsync(File.ReadAllBytes(path), false, "", "en");
            watch.Stop();
            LastTest = $"{watch.Elapsed.TotalSeconds:0.0} วินาที สำหรับเสียง 11 วินาที ({ActiveModel}) — \"{ThaiText.Cleaned(text)}\"";
        }
        catch (Exception ex) { LastTest = "ทดสอบไม่สำเร็จ: " + ex.Message; }
        Refresh();
        return LastTest;
    }

    // MARK: keyboard
    public void BeginKeyCapture(Action<int> onKey) { keyCapture = onKey; }
    public void CancelKeyCapture() { keyCapture = null; }

    /// Runs inside the keyboard hook: decide, post the work, return. True swallows the key.
    private bool OnKey(int vk, bool down, bool injected)
    {
        if (keyCapture != null)
        {
            if (!down) return false;
            var capture = keyCapture; keyCapture = null;
            Post(() => capture(vk == 0x1B || !TalkKeys.Allowed(vk) ? -1 : vk));
            return true;
        }
        if (vk == Settings.TalkKey)
        {
            var action = shortcut.Key(down);
            if (action != null) Post(() => Dispatch(action.Value));
            return !TalkKeys.IsModifier(vk);   // a plain key is ours alone; Ctrl/Alt/Shift still reach other apps
        }
        if (vk == 0x20)
        {
            bool repeat = down && spaceDown; spaceDown = down;
            var (consume, action) = shortcut.Space(down, repeat);
            if (action != null) Post(() => Dispatch(action.Value));
            return consume;
        }
        if (vk == 0x1B && down && Phase != Phase.Idle) { Post(Cancel); return true; }
        return false;
    }

    private void Dispatch(TalkAction action)
    {
        switch (action)
        {
            case TalkAction.Begin: Begin(); break;
            case TalkAction.End: End(); break;
            case TalkAction.Toggle: StopQuietly(); SetMode(Settings.Mode == "TH" ? "EN" : "TH"); break;
        }
    }

    // MARK: dictation
    private void Begin()
    {
        if (Phase != Phase.Idle) return;
        if (!EngineReady) { overlay.Flash(EngineState, Settings.Mode, 2200); return; }
        try { recorder.Start(Settings.MicDevice); }
        catch (Exception ex)
        {
            LastError = "เปิดไมโครโฟนไม่ได้: " + ex.Message;
            overlay.Flash("เปิดไมโครโฟนไม่ได้ · ตรวจ Settings › Privacy › Microphone", Settings.Mode, 3200); Refresh(); return;
        }
        Phase = Phase.Recording;
        overlay.ShowListening(Settings.Mode);
        if (warmUpClip != null && (DateTime.UtcNow - Engine.LastUse).TotalSeconds >= 90) _ = Engine.WarmUpAsync(warmUpClip);
        Refresh();
    }

    private async void End()
    {
        if (Phase != Phase.Recording) return;
        Phase = Phase.Processing;
        overlay.ShowThinking(Settings.Mode);
        var cts = new CancellationTokenSource(); work = cts;
        try
        {
            await Task.Delay(150);   // the last syllable is still in the sound card's buffer when the key comes up
            var pcm = recorder.Stop();
            if (cts.IsCancellationRequested) return;
            if (Wav.Seconds(pcm.Length) < 0.35) { overlay.HideNow(); return; }
            var raw = await Engine.TranscribeAsync(Wav.FromPcm16(pcm), Settings.Mode == "EN", Vocabulary.Hint(Settings.Vocabulary), "th", cts.Token);
            if (cts.IsCancellationRequested) return;
            var text = ThaiText.Cleaned(raw);
            if (text.Length == 0) { overlay.Flash("ไม่พบเสียงพูด", Settings.Mode); return; }
            History.Insert(0, text); if (History.Count > 20) History.RemoveAt(20);
            bool typed = await Task.Run(() => Typer.Type(text));
            overlay.Flash(typed ? "พิมพ์แล้ว" : "พิมพ์ลงช่องนี้ไม่ได้ · คัดลอกจากเมนูได้", Settings.Mode, typed ? 1200 : 3200);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { LastError = "ถอดเสียงไม่สำเร็จ: " + ex.Message; overlay.Flash("ถอดเสียงไม่สำเร็จ", Settings.Mode, 2600); }
        finally
        {
            if (ReferenceEquals(work, cts)) { work = null; Phase = Phase.Idle; }
            cts.Dispose();
            Refresh();
        }
    }

    private void StopQuietly()
    {
        work?.Cancel(); work = null;
        if (recorder.IsRecording) recorder.Stop();
        Phase = Phase.Idle;
    }

    private void Cancel() { StopQuietly(); overlay.Flash("ยกเลิก", Settings.Mode, 900); Refresh(); }

    public void SetMode(string mode)
    {
        Settings.Mode = mode == "EN" ? "EN" : "TH"; Save();
        overlay.Flash(Settings.Mode == "TH" ? "ข้อความไทย" : "แปลเป็นอังกฤษ", Settings.Mode, 1300);
        Refresh();
    }

    public void CopyLatest()
    {
        if (History.Count == 0) { overlay.Flash("ยังไม่มีข้อความ", Settings.Mode); return; }
        try { Clipboard.SetText(History[0]); overlay.Flash("คัดลอกแล้ว", Settings.Mode); } catch { overlay.Flash("คัดลอกไม่ได้", Settings.Mode); }
    }

    // MARK: plumbing
    public void Save() { try { Settings.Save(SettingsPath); } catch (Exception ex) { LastError = "บันทึกการตั้งค่าไม่ได้: " + ex.Message; } }
    public void Post(Action action) { try { if (overlay.IsHandleCreated && !overlay.IsDisposed) overlay.BeginInvoke(action); } catch { } }

    public void Refresh()
    {
        thItem.Checked = Settings.Mode == "TH"; enItem.Checked = Settings.Mode == "EN";
        var tip = "gluu bot · " + Settings.Mode + " · " + (EngineReady ? "กด " + TalkKeys.Name(Settings.TalkKey) + " ค้างเพื่อพูด" : EngineState);
        tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
        Changed?.Invoke();
    }

    public void ShowSettings()
    {
        if (settingsForm == null || settingsForm.IsDisposed) settingsForm = new SettingsForm(this);
        settingsForm.Show();
        if (settingsForm.WindowState == FormWindowState.Minimized) settingsForm.WindowState = FormWindowState.Normal;
        settingsForm.Activate();
    }

    /// What a tester pastes back: versions and timings only. No transcripts, no audio, no file names from the user's folders.
    public string Diagnostics()
    {
        var b = new StringBuilder();
        b.AppendLine("gluu bot for Windows (lite) " + Version);
        b.AppendLine("Windows: " + Environment.OSVersion.Version + (Environment.Is64BitOperatingSystem ? " x64" : " x86"));
        b.AppendLine("CPU threads: " + Environment.ProcessorCount);
        b.AppendLine("Engine: " + (Engine.HasGpuBuild ? "NVIDIA (CUDA)" : "CPU") + " · " + EngineState);
        b.AppendLine("Model: " + (ActiveModel.Length > 0 ? ActiveModel : "none"));
        b.AppendLine("Talk key: " + TalkKeys.Name(Settings.TalkKey) + " · mode " + Settings.Mode);
        b.AppendLine("Keyboard hook: " + (hook != null ? "installed" : "failed"));
        b.AppendLine("Microphones: " + (Recorder.Devices().Count - 1));
        b.AppendLine("Sample test: " + (LastTest.Contains(" — ") ? LastTest.Substring(0, LastTest.IndexOf(" — ")) : LastTest));
        b.AppendLine("Last error: " + (LastError.Length > 0 ? LastError : "none"));
        return b.ToString();
    }

    /// The tray icon is the character itself: a dark disc with two cyan eyes.
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr handle);
    private static Icon MakeIcon()
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias; g.Clear(Color.Transparent);
            using var ink = new SolidBrush(Color.FromArgb(17, 17, 17)); using var rim = new Pen(Color.FromArgb(120, 255, 255, 255), 1.2f); using var cyan = new SolidBrush(Color.FromArgb(95, 225, 255));
            g.FillEllipse(ink, 1, 1, 30, 30); g.DrawEllipse(rim, 1, 1, 30, 30);
            g.FillRectangle(cyan, 10, 9, 4, 12); g.FillRectangle(cyan, 18, 9, 4, 12);
        }
        IntPtr handle = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(handle).Clone();
        DestroyIcon(handle);
        return icon;
    }

    public static void ReportCrash(Exception ex)
    {
        try { MessageBox.Show("gluu bot เจอข้อผิดพลาด:\n" + ex.GetType().Name + ": " + ex.Message, "gluu bot", MessageBoxButtons.OK, MessageBoxIcon.Warning); } catch { }
    }

    protected override void ExitThreadCore()
    {
        StopQuietly();
        hook?.Dispose(); hook = null;
        tray.Visible = false; tray.Dispose();
        Engine.Dispose(); recorder.Dispose();
        base.ExitThreadCore();
    }
}
