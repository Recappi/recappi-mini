using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Recappi.Core;

public sealed record SpeakerProfile(string Name, string Emoji, string? Note);

/// <summary>Per-account, per-recording local display metadata, never sent to the API.</summary>
public sealed class SpeakerProfileStore(string root)
{
    public static string DefaultRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Recappi Mini", "Speakers");
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Recappi Mini speaker profiles v1");
    private string FilePath(string partition, string recordingId)
    {
        if (partition.Length != 64 || !partition.All(Uri.IsHexDigit) || string.IsNullOrWhiteSpace(recordingId)) throw new ArgumentException("Invalid speaker profile scope.");
        var id = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(recordingId)));
        return Path.Combine(Path.GetFullPath(root), partition, id + ".dpapi");
    }
    public IReadOnlyDictionary<string, SpeakerProfile> Load(string partition, string recordingId)
    {
        var path = FilePath(partition, recordingId);
        if (!File.Exists(path)) return new Dictionary<string, SpeakerProfile>();
        var bytes = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
        try { return JsonSerializer.Deserialize<Dictionary<string, SpeakerProfile>>(bytes) ?? throw new InvalidDataException("Invalid speaker profiles."); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    public void Save(string partition, string recordingId, string speaker, SpeakerProfile profile)
    {
        if (string.IsNullOrWhiteSpace(speaker)) throw new ArgumentException("Choose a speaker.");
        profile = profile with { Name = profile.Name.Trim(), Emoji = profile.Emoji.Trim(), Note = profile.Note?.Trim() };
        if (profile.Name.Length is < 1 or > 100 || profile.Emoji.Length > 16 || profile.Note?.Length > 1000) throw new ArgumentException("姓名最多 100 字，图标最多 16 字，备注最多 1000 字。");
        var entries = new Dictionary<string, SpeakerProfile>(Load(partition, recordingId)) { [speaker] = profile };
        var path = FilePath(partition, recordingId);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(entries);
        try
        {
            File.WriteAllBytes(temporary, ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.CurrentUser));
            File.Move(temporary, path, true);
        }
        finally { CryptographicOperations.ZeroMemory(plaintext); if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public void Delete(string partition, string recordingId) => File.Delete(FilePath(partition, recordingId));
}
