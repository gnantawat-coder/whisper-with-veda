namespace GluuBot.Core;

public static class Vocabulary
{
    /// A plain list of terms is the only prompt shape that helped on the Mac measurements; sentences made the model invent names.
    public static string Hint(string words)
    {
        var seen = new HashSet<string>();
        var terms = words.Split(new[] { ',', '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(w => w.Trim()).Where(w => w.Length > 0 && seen.Add(w));
        return string.Join(", ", terms);
    }
}
