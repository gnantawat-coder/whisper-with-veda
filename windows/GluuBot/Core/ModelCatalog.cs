namespace GluuBot.Core;

public sealed record ModelInfo(string Id, string File, string Url, long Bytes, string Sha256, string Label);

/// whisper.cpp GGML models from the project's Hugging Face repository; sizes and SHA-256 are the repository's own LFS records.
/// large-v3-turbo is deliberately not offered: it cannot translate to English.
public static class ModelCatalog
{
    private const string Base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";
    public static readonly ModelInfo[] All =
    {
        new("large-v3-q5_0", "ggml-large-v3-q5_0.bin", Base + "ggml-large-v3-q5_0.bin", 1081140203, "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1", "แม่นที่สุด · 1.08 GB · รุ่นเดียวกับ Mac · ช้าถ้าไม่มีการ์ดจอ NVIDIA"),
        new("medium-q5_0", "ggml-medium-q5_0.bin", Base + "ggml-medium-q5_0.bin", 539212467, "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f", "กลาง · 539 MB"),
        new("small-q5_1", "ggml-small-q5_1.bin", Base + "ggml-small-q5_1.bin", 190085487, "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb", "เร็วที่สุด · 190 MB · ภาษาไทยผิดเยอะกว่า"),
    };
    public static ModelInfo? Find(string id) => All.FirstOrDefault(m => m.Id == id);
}
