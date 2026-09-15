using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Recappi.Core;

public sealed record CloudAccount(string Origin, string UserId, string? Email, string Token)
{
    public override string ToString() => "Recappi account (credentials redacted)";
    public string Partition => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Origin + "\n" + UserId))).ToLowerInvariant();
}

/// <summary>Only the current Windows user can decrypt the stored account.</summary>
public sealed class AccountStore(string directory)
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Recappi Mini native desktop account v1");
    private readonly string path = Path.Combine(Path.GetFullPath(directory), "account.dpapi");
    public void Save(CloudAccount account)
    {
        _ = CloudClient.ValidateOrigin(account.Origin);
        if (string.IsNullOrWhiteSpace(account.UserId) || string.IsNullOrWhiteSpace(account.Token)) throw new ArgumentException("Incomplete account.");
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(account);
        byte[] encrypted;
        try { encrypted = ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.CurrentUser); }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllBytes(temporary, encrypted); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public CloudAccount? Load()
    {
        if (!File.Exists(path)) return null;
        var plaintext = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
        try
        {
            var account = JsonSerializer.Deserialize<CloudAccount>(plaintext) ?? throw new InvalidDataException("Saved account is empty.");
            _ = CloudClient.ValidateOrigin(account.Origin);
            if (string.IsNullOrWhiteSpace(account.UserId) || string.IsNullOrWhiteSpace(account.Token)) throw new InvalidDataException("Saved account is incomplete.");
            return account;
        }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
    }
    public void Clear() => File.Delete(path);
}
