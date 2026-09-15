using Recappi.Core;

namespace Recappi.Desktop;

public sealed record AccountHeaderText(string Identity, string Status)
{
    public static AccountHeaderText From(AccountSnapshot snapshot) => new(
        snapshot.State == AccountState.SignedOut ? "尚未登录" : snapshot.Account?.Email ?? snapshot.Account?.UserId ?? "Recappi Cloud",
        snapshot.State switch
        {
            AccountState.SignedIn => "已连接 · 管理账号",
            AccountState.Offline => "离线 · 可查看已缓存内容",
            AccountState.Expired => "登录已过期 · 重新登录",
            AccountState.Checking => "正在检查连接…",
            AccountState.SigningIn => "等待浏览器登录确认…",
            AccountState.Failed => "账号读取失败 · 查看详情",
            _ => "本机录音可用 · 登录云端"
        });
}
