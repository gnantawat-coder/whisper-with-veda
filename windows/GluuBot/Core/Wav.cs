using System.Text;

namespace GluuBot.Core;

public static class Wav
{
    public const int Rate = 16000;
    public static double Seconds(int pcmBytes) => pcmBytes / (double)(Rate * 2);

    /// 16-bit mono PCM at 16 kHz → a minimal WAV file.
    public static byte[] FromPcm16(byte[] pcm, int rate = Rate)
    {
        using var s = new MemoryStream(44 + pcm.Length);
        using var w = new BinaryWriter(s, Encoding.ASCII, leaveOpen: true);
        w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + pcm.Length); w.Write(Encoding.ASCII.GetBytes("WAVE"));
        w.Write(Encoding.ASCII.GetBytes("fmt ")); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(rate); w.Write(rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write(Encoding.ASCII.GetBytes("data")); w.Write(pcm.Length); w.Write(pcm);
        w.Flush();
        return s.ToArray();
    }

    /// The first `seconds` of a PCM WAV, re-wrapped; null when the file is not plain PCM. Used for the warm-up clip.
    public static byte[]? Prefix(byte[] wav, double seconds)
    {
        if (wav.Length < 44 || Encoding.ASCII.GetString(wav, 0, 4) != "RIFF" || Encoding.ASCII.GetString(wav, 8, 4) != "WAVE") return null;
        int pos = 12, rate = 0, blockAlign = 0, channels = 0, bits = 0;
        while (pos + 8 <= wav.Length)
        {
            string id = Encoding.ASCII.GetString(wav, pos, 4);
            int size = BitConverter.ToInt32(wav, pos + 4), body = pos + 8;
            if (size < 0 || body + Math.Min(size, wav.Length - body) > wav.Length) return null;
            if (id == "fmt " && size >= 16)
            {
                if (BitConverter.ToInt16(wav, body) != 1) return null;
                channels = BitConverter.ToInt16(wav, body + 2); rate = BitConverter.ToInt32(wav, body + 4);
                blockAlign = BitConverter.ToInt16(wav, body + 12); bits = BitConverter.ToInt16(wav, body + 14);
            }
            else if (id == "data")
            {
                if (rate != Rate || channels != 1 || bits != 16 || blockAlign != 2) return null;
                int available = Math.Min(size, wav.Length - body);
                int take = Math.Min(available, (int)(seconds * rate) * blockAlign);
                var pcm = new byte[take];
                Array.Copy(wav, body, pcm, 0, take);
                return FromPcm16(pcm, rate);
            }
            pos = body + size + (size & 1);
        }
        return null;
    }
}
