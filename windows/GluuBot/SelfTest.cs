using System.Diagnostics;
using GluuBot.Core;

namespace GluuBot;

/// Checks that only make sense on a real Windows machine; the build server runs them on every change.
/// They exercise the same classes the app uses, not copies of them.
internal static class SelfTest
{
    /// --selftest-engine <model> <wav> <result file>: start whisper-server, transcribe, report timings.
    public static int Engine(string[] args)
    {
        string model = args[1], wavPath = args[2], outFile = args[3];
        var lines = new List<string>();
        int code = 1;
        try
        {
            using var engine = new WhisperEngine(Path.Combine(TrayApp.AppDir, "engine"));
            var load = Stopwatch.StartNew();
            Task.Run(() => engine.StartAsync(model)).GetAwaiter().GetResult();
            load.Stop();
            var wav = File.ReadAllBytes(wavPath);
            var first = Stopwatch.StartNew();
            string text = ThaiText.Cleaned(Task.Run(() => engine.TranscribeAsync(wav, false, "", "en")).GetAwaiter().GetResult());
            first.Stop();
            var second = Stopwatch.StartNew();
            Task.Run(() => engine.TranscribeAsync(wav, false, "", "en")).GetAwaiter().GetResult();
            second.Stop();
            var clip = Wav.Prefix(wav, 1.0);
            lines.Add($"load_seconds={load.Elapsed.TotalSeconds:0.00}");
            lines.Add($"first_inference_seconds={first.Elapsed.TotalSeconds:0.00}");
            lines.Add($"second_inference_seconds={second.Elapsed.TotalSeconds:0.00}");
            lines.Add("warmup_clip=" + (clip != null));
            lines.Add("gpu_build=" + engine.HasGpuBuild);
            lines.Add("text=" + text);
            code = text.Contains("country", StringComparison.OrdinalIgnoreCase) ? 0 : 2;
        }
        catch (Exception ex) { lines.Add("error=" + ex.GetType().Name + ": " + ex.Message); }
        File.WriteAllLines(outFile, lines);
        return code;
    }

    /// --selftest-ui <result file>: type Thai into a real text box with SendInput, then press a talk key through the real hook.
    public static int Ui(string[] args)
    {
        string outFile = args[1];
        const string sample = "สวัสดีครับ น้ำ ก็ ที่นี่ gluu bot 123";
        var lines = new List<string>();
        bool ok = true;
        using var form = new Form { Text = "gluu bot selftest", TopMost = true, Width = 640, Height = 200, StartPosition = FormStartPosition.CenterScreen };
        var box = new TextBox { Dock = DockStyle.Fill, Multiline = true, Font = new Font("Segoe UI", 12f) };
        form.Controls.Add(box);
        var events = new List<string>();
        var shortcut = new TalkShortcut();
        KeyboardHook? hook = null;
        int step = 0;
        var timer = new System.Windows.Forms.Timer { Interval = 900 };
        timer.Tick += (_, _) =>
        {
            step++;
            try
            {
                if (step == 1) { form.Activate(); Win32.SetForegroundWindow(form.Handle); box.Focus(); }
                else if (step == 2)
                {
                    lines.Add("foreground=" + (Win32.GetForegroundWindow() == form.Handle));
                    lines.Add("sendinput_accepted=" + Typer.Type(sample));
                }
                else if (step == 3)
                {
                    bool match = box.Text == sample;
                    lines.Add("typed_matches=" + match);
                    if (!match) lines.Add("typed_got=[" + box.Text + "]");
                    ok &= match;
                    box.Clear();
                    hook = new KeyboardHook((vk, down, _) =>
                    {
                        if (vk != 0x78) return false;   // F9 stands in for the talk key
                        events.Add((down ? "down" : "up") + ":" + shortcut.Key(down));
                        return true;
                    }) { AcceptInjected = true };
                    Typer.TapVirtualKey(0x78);
                }
                else if (step == 4)
                {
                    string got = string.Join(",", events);
                    lines.Add("hook_events=" + got);
                    ok &= got == "down:Begin,up:End";
                    hook?.Dispose();
                    timer.Stop();
                    File.WriteAllLines(outFile, lines);
                    form.Close();
                }
            }
            catch (Exception ex)
            {
                lines.Add("error=" + ex.GetType().Name + ": " + ex.Message); ok = false;
                timer.Stop(); File.WriteAllLines(outFile, lines); form.Close();
            }
        };
        form.Shown += (_, _) => timer.Start();
        Application.Run(form);
        return ok ? 0 : 1;
    }
}
