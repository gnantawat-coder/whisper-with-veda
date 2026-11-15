using NAudio.Wave;

namespace GluuBot;

/// Microphone → 16 kHz mono 16-bit PCM in memory. Audio is never written to disk.
public sealed class Recorder : IDisposable
{
    private const int MaxBytes = 16000 * 2 * 120;   // two minutes, like the Mac app's limit
    private readonly MemoryStream buffer = new();
    private readonly object gate = new();
    private WaveInEvent? waveIn;
    public event Action<float>? Level;
    public bool IsRecording => waveIn != null;

    public static List<(int Id, string Name)> Devices()
    {
        var list = new List<(int, string)> { (-1, "ค่าเริ่มต้นของ Windows") };
        try { for (int i = 0; i < WaveInEvent.DeviceCount; i++) list.Add((i, WaveInEvent.GetCapabilities(i).ProductName)); } catch { }
        return list;
    }

    public void Start(int device)
    {
        Stop();
        lock (gate) buffer.SetLength(0);
        WaveInEvent Open(int id)
        {
            var w = new WaveInEvent { DeviceNumber = id, WaveFormat = new WaveFormat(16000, 16, 1), BufferMilliseconds = 50 };
            w.DataAvailable += (_, e) =>
            {
                lock (gate) { if (buffer.Length < MaxBytes) buffer.Write(e.Buffer, 0, e.BytesRecorded); }
                Level?.Invoke(Rms(e.Buffer, e.BytesRecorded));
            };
            try { w.StartRecording(); } catch { w.Dispose(); throw; }
            return w;
        }
        try { waveIn = Open(device); }
        catch when (device != 0 && WaveInEvent.DeviceCount > 0) { waveIn = Open(0); }   // the chosen device is gone: fall back to the first one
    }

    public byte[] Stop()
    {
        var w = waveIn; waveIn = null;
        if (w != null) { try { w.StopRecording(); } catch { } w.Dispose(); }
        lock (gate) return buffer.ToArray();
    }

    private static float Rms(byte[] data, int count)
    {
        int samples = count / 2;
        if (samples == 0) return 0;
        double sum = 0;
        for (int i = 0; i < samples; i++) { double v = BitConverter.ToInt16(data, i * 2) / 32768.0; sum += v * v; }
        return (float)Math.Min(1.0, Math.Sqrt(sum / samples) * 6);
    }

    public void Dispose() { Stop(); buffer.Dispose(); }
}
