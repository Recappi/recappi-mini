using System.Net;

namespace Recappi.Core;

public enum AccountState { SignedOut, Checking, SigningIn, SignedIn, Expired, Offline, Failed }
public sealed record AccountSnapshot(AccountState State, CloudAccount? Account = null, string? Message = null);

public sealed class AccountSession(AccountStore store, Func<string, string?, CloudClient>? createClient = null)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private CancellationTokenSource? login;
    private AccountSnapshot snapshot = new(AccountState.SignedOut);
    public AccountSnapshot Snapshot => Volatile.Read(ref snapshot);
    public event Action<AccountSnapshot>? Changed;
    public CloudClient Client(CloudAccount account)
    {
        var client = createClient?.Invoke(account.Origin, account.Token) ?? new CloudClient(account.Origin, account.Token);
        client.AuthenticationRejected += () => RejectAuthentication(account);
        return client;
    }
    private void RejectAuthentication(CloudAccount account)
    {
        var current = Snapshot;
        if (current.State is not (AccountState.SignedIn or AccountState.Offline) || current.Account is not { } active || active.Partition != account.Partition || active.Token != account.Token) return;
        var expired = new AccountSnapshot(AccountState.Expired, active, "登录已过期，请重新连接。");
        if (ReferenceEquals(Interlocked.CompareExchange(ref snapshot, expired, current), current)) Notify(expired);
    }

    public async Task RestoreAsync(CancellationToken cancellation = default)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            var account = store.Load();
            if (account is null) { Publish(new(AccountState.SignedOut)); return; }
            Publish(new(AccountState.Checking, account));
            await ValidateAsync(account, cancellation);
        }
        catch (OperationCanceledException) { throw; }
        catch { Publish(new(AccountState.Failed, Message: "无法读取保存的账号，请重新登录。")); }
        finally { gate.Release(); }
    }

    public async Task RefreshAsync(CancellationToken cancellation = default)
    {
        await gate.WaitAsync(cancellation);
        try
        {
            if (Snapshot.Account is not { } account) return;
            Publish(new(AccountState.Checking, account));
            await ValidateAsync(account, cancellation);
        }
        finally { gate.Release(); }
    }

    private async Task ValidateAsync(CloudAccount account, CancellationToken cancellation)
    {
        try
        {
            using var client = Client(account);
            var verified = await client.ValidateAccountAsync(account, cancellation);
            store.Save(verified);
            Publish(new(AccountState.SignedIn, verified));
        }
        catch (CloudException failure) when (failure.Status == HttpStatusCode.Unauthorized)
        { Publish(new(AccountState.Expired, account, "登录已过期，请重新连接。")); }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { Publish(new(AccountState.Offline, account, "连接检查已取消。")); throw; }
        catch { Publish(new(AccountState.Offline, account, "暂时无法连接云端，本地录音仍可使用。")); }
    }

    public async Task SignInAsync(string origin, Action<LoginPrompt> prompt, CancellationToken cancellation = default)
    {
        await gate.WaitAsync(cancellation);
        var previous = Snapshot;
        using var pending = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        Interlocked.Exchange(ref login, pending);
        try
        {
            Publish(new(AccountState.SigningIn, previous.Account));
            using var client = createClient?.Invoke(origin, null) ?? new CloudClient(origin);
            var account = await new DeviceLogin(client).SignInAsync(prompt, pending.Token);
            store.Save(account);
            Publish(new(AccountState.SignedIn, account));
        }
        catch (OperationCanceledException) { Publish(previous with { Message = "登录已取消。" }); }
        catch (Exception failure) { Publish(previous with { Message = failure is CloudException ? failure.Message : "登录未完成，请重试。" }); }
        finally { Interlocked.CompareExchange(ref login, null, pending); gate.Release(); }
    }

    public void CancelLogin()
    {
        try { Volatile.Read(ref login)?.Cancel(); } catch (ObjectDisposedException) { }
    }

    public async Task SignOutAsync(CancellationToken cancellation = default)
    {
        CancelLogin();
        await gate.WaitAsync(cancellation);
        try
        {
            var account = Snapshot.Account;
            store.Clear();
            Publish(new(AccountState.SignedOut));
            if (account is not null)
            {
                try { using var client = Client(account); await client.SignOutAsync(cancellation); }
                catch { Publish(new(AccountState.SignedOut, Message: "本机已退出；服务器会话未能撤销。")); }
            }
        }
        finally { gate.Release(); }
    }

    private void Publish(AccountSnapshot value)
    {
        Interlocked.Exchange(ref snapshot, value);
        Notify(value);
    }
    private void Notify(AccountSnapshot value)
    {
        if (Changed is null) return;
        foreach (Action<AccountSnapshot> observer in Changed.GetInvocationList())
            try { observer(value); } catch { }
    }
}
