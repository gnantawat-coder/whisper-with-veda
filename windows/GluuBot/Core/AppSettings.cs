using System.Text.Json;

namespace GluuBot.Core;

public sealed class AppSettings
{
    public int TalkKey { get; set; } = TalkKeys.Default;
    public string Mode { get; set; } = "TH";          // TH = Thai text, EN = translated to English
    public string Vocabulary { get; set; } = "";
    public string Model { get; set; } = "";
    public int MicDevice { get; set; } = -1;          // -1 = the Windows default input

    public static AppSettings Load(string path)
    {
        try { if (File.Exists(path)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new AppSettings(); }
        catch { /* a damaged settings file must never stop the app from starting */ }
        return new AppSettings();
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }
}
