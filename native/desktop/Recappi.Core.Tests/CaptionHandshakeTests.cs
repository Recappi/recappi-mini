using System.Net;
using System.Net.Sockets;
using System.Text;
using Recappi.Core;

internal static class CaptionHandshakeTests
{
    public static async Task RunAsync()
    {
        foreach (var status in new[] { 401, 403, 503 })
        {
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            using var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var server = Task.Run(async () =>
            {
                using var peer = await listener.AcceptTcpClientAsync(deadline.Token);
                await using var stream = peer.GetStream();
                using var reader = new StreamReader(stream, Encoding.ASCII, leaveOpen: true);
                while (await reader.ReadLineAsync(deadline.Token) is { Length: > 0 }) { }
                await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Rejected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"), deadline.Token);
            });
            try
            {
                await using var connection = await CaptionConnection.ConnectAsync(new($"ws://127.0.0.1:{port}/caption", "Bearer", "fixture"), "https://example.test", deadline.Token);
                throw new Exception("Rejected WebSocket handshake unexpectedly connected.");
            }
            catch (CloudException error) when ((int)error.Status == status) { }
            await server;
        }
        foreach (var status in new[] { HttpStatusCode.Unauthorized, HttpStatusCode.Forbidden })
        {
            var attempts = 0;
            await using var captions = new LiveCaptions(new(), _ =>
            {
                Interlocked.Increment(ref attempts);
                throw new CloudException(status);
            }, [TimeSpan.Zero, TimeSpan.Zero]);
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            while (captions.Status.State != "failed") await Task.Delay(10, deadline.Token);
            await Task.Delay(50, deadline.Token);
            if (attempts != 1 || captions.Status.Message?.Contains("授权失败") != true) throw new Exception("Caption authorization failure retried or lost its explicit message.");
        }
    }
}
