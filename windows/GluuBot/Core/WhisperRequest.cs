using System.Text;

namespace GluuBot.Core;

/// The multipart body for whisper-server's /inference, field for field what the Mac app sends.
/// Deliberately absent: no_timestamps and audio_ctx — both lost or garbled speech in the Mac measurements.
public static class WhisperRequest
{
    public static byte[] Body(byte[] wav, bool translate, string vocabulary, string boundary, string language = "th")
    {
        using var data = new MemoryStream();
        void Add(string s) { var b = Encoding.UTF8.GetBytes(s); data.Write(b, 0, b.Length); }
        string prompt = vocabulary.Length > 2000 ? vocabulary.Substring(0, 2000) : vocabulary;
        foreach (var (name, value) in new[] { ("language", language), ("translate", translate ? "true" : "false"), ("response_format", "json"), ("temperature", "0"), ("prompt", prompt) })
            Add($"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n");
        Add($"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n");
        data.Write(wav, 0, wav.Length);
        Add($"\r\n--{boundary}--\r\n");
        return data.ToArray();
    }
}
