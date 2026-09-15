using System.Text.Json;

namespace Recappi.Core;

public sealed record LoginPrompt(string Code, Uri VerificationUri, DateTimeOffset ExpiresAt);

public sealed class DeviceLogin(CloudClient client, Func<TimeSpan, CancellationToken, Task>? delay = null)
{
    public async Task<CloudAccount> SignInAsync(Action<LoginPrompt> showPrompt, CancellationToken cancellation = default)
    {
        var begin = await client.BeginDeviceLoginAsync(cancellation);
        var deviceCode = Required(begin, "device_code");
        var userCode = Required(begin, "user_code");
        var verify = new Uri(Required(begin, "verification_uri_complete"), UriKind.Absolute);
        if (verify.GetLeftPart(UriPartial.Authority) != client.Origin.GetLeftPart(UriPartial.Authority) || !string.IsNullOrEmpty(verify.UserInfo))
            throw new InvalidDataException("Unexpected sign-in verification origin.");
        var expires = PositiveNumber(begin, "expires_in", 3600);
        var interval = PositiveNumber(begin, "interval", 60);
        var deadline = DateTimeOffset.UtcNow.AddSeconds(expires);
        showPrompt(new(userCode, verify, deadline));
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellation.ThrowIfCancellationRequested();
            var wait = TimeSpan.FromSeconds(Math.Min(interval, Math.Max(0, (deadline - DateTimeOffset.UtcNow).TotalSeconds)));
            await (delay?.Invoke(wait, cancellation) ?? Task.Delay(wait, cancellation));
            if (DateTimeOffset.UtcNow >= deadline) break;
            var poll = await client.PollDeviceLoginAsync(deviceCode, cancellation);
            switch (Required(poll, "status"))
            {
                case "pending":
                    if (poll.TryGetProperty("interval", out _)) interval = PositiveNumber(poll, "interval", 60);
                    break;
                case "slow_down":
                    interval = poll.TryGetProperty("interval", out _) ? PositiveNumber(poll, "interval", 60) : Math.Min(60, interval + 5);
                    break;
                case "denied": throw new InvalidOperationException("Sign-in was declined.");
                case "expired": throw new TimeoutException("Sign-in code expired. Try again.");
                case "authorized":
                    var user = poll.GetProperty("user");
                    return new CloudAccount(client.Origin.GetLeftPart(UriPartial.Authority), Required(user, "id"), user.TryGetProperty("email", out var email) ? email.GetString() : null, Required(poll, "token"));
                default: throw new InvalidDataException("Unknown sign-in status.");
            }
        }
        throw new TimeoutException("Sign-in code expired. Try again.");
    }

    private static string Required(JsonElement json, string name) => json.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(property.GetString()) ? property.GetString()! : throw new InvalidDataException("Incomplete sign-in response.");
    private static double PositiveNumber(JsonElement json, string name, double maximum)
    {
        if (!json.TryGetProperty(name, out var property) || !property.TryGetDouble(out var value) || !double.IsFinite(value) || value <= 0 || value > maximum) throw new InvalidDataException("Invalid sign-in timing.");
        return value;
    }
}
