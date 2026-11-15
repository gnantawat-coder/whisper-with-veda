using System.Diagnostics;
using System.Text.Json;
using GluuBot.Core;

namespace GluuBot;

/// Runs whisper.cpp's whisper-server next to the app and talks to it on localhost only. Nothing leaves the machine.
public sealed class WhisperEngine : IDisposable
{
    public const int Port = 18766;
    private readonly string engineDir;
    private readonly HttpClient http = new() { Timeout = TimeSpan.FromMinutes(5) };
    private readonly Queue<string> startupLog = new();
    private Process? process;
    private volatile bool ready;
    private IntPtr job;

    public WhisperEngine(string engineDir) { this.engineDir = engineDir; }
    public DateTime LastUse { get; private set; } = DateTime.MinValue;
    public bool IsRunning { get { try { return process is { HasExited: false }; } catch { return false; } } }
    public string ServerPath => Path.Combine(engineDir, "whisper-server.exe");
    /// The NVIDIA package ships cuBLAS next to the server; the CPU package does not.
    public bool HasGpuBuild { get { try { return Directory.Exists(engineDir) && (File.Exists(Path.Combine(engineDir, "ggml-cuda.dll")) || Directory.EnumerateFiles(engineDir, "cublas*.dll").Any()); } catch { return false; } } }

    public async Task StartAsync(string modelPath, CancellationToken ct = default)
    {
        Stop();
        if (!File.Exists(ServerPath)) throw new FileNotFoundException("ไม่พบ engine\\whisper-server.exe ข้างไฟล์โปรแกรม — แตกไฟล์ zip ให้ครบทั้งโฟลเดอร์");
        if (!File.Exists(modelPath)) throw new FileNotFoundException("ไม่พบไฟล์โมเดล");
        int threads = Math.Clamp(Environment.ProcessorCount / 2, 4, 8);
        var psi = new ProcessStartInfo(ServerPath)
        {
            WorkingDirectory = engineDir, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
        };
        // No "-nt": without timestamp tokens whisper.cpp drops speech just before each 30 s window boundary.
        foreach (var a in new[] { "--host", "127.0.0.1", "--port", Port.ToString(), "-m", modelPath, "-l", "th", "-t", threads.ToString() }) psi.ArgumentList.Add(a);
        var p = new Process { StartInfo = psi };
        ready = false;
        lock (startupLog) startupLog.Clear();
        // Engine output can contain transcripts once it is serving. Lines are kept only until it is ready,
        // only in memory, only to explain a failed start; after that everything is read and dropped.
        void Keep(object? _, DataReceivedEventArgs e)
        {
            if (e.Data == null || ready) return;
            lock (startupLog) { startupLog.Enqueue(e.Data); while (startupLog.Count > 12) startupLog.Dequeue(); }
        }
        p.OutputDataReceived += Keep; p.ErrorDataReceived += Keep;
        p.Start();
        p.BeginOutputReadLine(); p.BeginErrorReadLine();
        JobObject.Attach(ref job, p);
        process = p;
        var deadline = DateTime.UtcNow.AddMinutes(4);
        while (DateTime.UtcNow < deadline)
        {
            ct.ThrowIfCancellationRequested();
            if (p.HasExited) throw new InvalidOperationException("เอนจินปิดตัวเองตอนเริ่ม (exit " + p.ExitCode + "): " + Tail());
            if (await HealthAsync(ct)) { ready = true; LastUse = DateTime.UtcNow; lock (startupLog) startupLog.Clear(); return; }
            await Task.Delay(400, ct);
        }
        Stop();
        throw new TimeoutException("เอนจินโหลดโมเดลไม่เสร็จใน 4 นาที");
    }

    private string Tail() { lock (startupLog) return string.Join(" | ", startupLog.TakeLast(4)); }

    private async Task<bool> HealthAsync(CancellationToken ct)
    {
        try
        {
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
            limit.CancelAfter(TimeSpan.FromSeconds(2));
            using var response = await http.GetAsync($"http://127.0.0.1:{Port}/health", limit.Token);
            if (!response.IsSuccessStatusCode) return false;
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(limit.Token));
            return doc.RootElement.TryGetProperty("status", out var s) && s.GetString() == "ok";
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch { return false; }
    }

    public async Task<string> TranscribeAsync(byte[] wav, bool translate, string vocabulary, string language = "th", CancellationToken ct = default)
    {
        if (!IsRunning) throw new InvalidOperationException("เอนจินยังไม่ทำงาน");
        string boundary = "GluuBot-" + Guid.NewGuid().ToString("N");
        using var content = new ByteArrayContent(WhisperRequest.Body(wav, translate, vocabulary, boundary, language));
        content.Headers.TryAddWithoutValidation("Content-Type", "multipart/form-data; boundary=" + boundary);
        using var response = await http.PostAsync($"http://127.0.0.1:{Port}/inference", content, ct);
        response.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(ct));
        LastUse = DateTime.UtcNow;
        return doc.RootElement.TryGetProperty("text", out var text) ? text.GetString() ?? "" : "";
    }

    /// After a long idle the first inference is slow (the weights get paged out). One second of real speech pulls
    /// them back; silence is useless for this — whisper loops on it.
    public async Task WarmUpAsync(byte[] oneSecondOfSpeech)
    {
        try { await TranscribeAsync(oneSecondOfSpeech, false, "", "en"); } catch { /* warm-up is best effort */ }
    }

    public void Stop()
    {
        var p = process; process = null; ready = false;
        if (p == null) return;
        try { if (!p.HasExited) { p.Kill(true); p.WaitForExit(3000); } } catch { }
        p.Dispose();
    }

    public void Dispose() { Stop(); http.Dispose(); }
}
