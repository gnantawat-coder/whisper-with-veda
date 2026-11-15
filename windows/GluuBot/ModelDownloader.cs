using System.Security.Cryptography;
using GluuBot.Core;

namespace GluuBot;

public static class ModelDownloader
{
    /// Downloads to "<file>.part", checks the SHA-256 against the catalogue, and only then gives the file its real name.
    public static async Task DownloadAsync(ModelInfo model, string destination, IProgress<double> progress, CancellationToken ct)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        string part = destination + ".part";
        using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        try
        {
            using var response = await http.GetAsync(model.Url, HttpCompletionOption.ResponseHeadersRead, ct);
            response.EnsureSuccessStatusCode();
            long total = response.Content.Headers.ContentLength ?? model.Bytes, done = 0;
            await using (var input = await response.Content.ReadAsStreamAsync(ct))
            await using (var output = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
            {
                var chunk = new byte[1 << 20];
                int n;
                while ((n = await input.ReadAsync(chunk, ct)) > 0)
                {
                    await output.WriteAsync(chunk.AsMemory(0, n), ct);
                    hash.AppendData(chunk, 0, n);
                    done += n;
                    progress.Report(Math.Min(1.0, done / (double)total));
                }
            }
            string actual = Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
            if (actual != model.Sha256) throw new InvalidDataException("ไฟล์ที่ดาวน์โหลดไม่ตรงกับ checksum — ลองใหม่อีกครั้ง");
            File.Move(part, destination, true);
        }
        catch
        {
            try { File.Delete(part); } catch { }
            throw;
        }
    }
}
