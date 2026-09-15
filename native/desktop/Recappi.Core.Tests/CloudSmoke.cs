using System.Collections.Concurrent;
using System.Text.Json;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Recappi.Core;

internal static class CloudSmoke
{
    public static async Task RunAsync(string audioPath, string output, bool translate = false)
    {
        var configPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "recappi", "config.json");
        using var config = JsonDocument.Parse(File.ReadAllText(configPath));
        var token = config.RootElement.GetProperty("authToken").GetString() ?? throw new Exception("Test account missing.");
        var origin = config.RootElement.GetProperty("origin").GetString() ?? throw new Exception("Test origin missing.");
        using var client = new CloudClient(origin, token);
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(50));
        var session = await client.SessionAsync(limit.Token);
        if (!session.TryGetProperty("user", out var user) || user.ValueKind != JsonValueKind.Object) throw new Exception("Existing account session is invalid.");
        Console.WriteLine("PASS existing account session validated (identity omitted).");
        var options = new CaptionOptions("en", translate ? "zh" : null);
        var claim = await client.CaptionSessionAsync(options, limit.Token);
        Console.WriteLine("PASS real caption session claim (credentials omitted).");
        var results = new ConcurrentQueue<CaptionDelta>();
        var states = new ConcurrentQueue<string>();
        await using var captions = new LiveCaptions(options, cancellation => CaptionConnection.ConnectAsync(claim, origin, cancellation), []);
        captions.Delta += results.Enqueue;
        captions.Changed += value => states.Enqueue(value.State);
        while (captions.Status.State is "connecting" or "reconnecting") await Task.Delay(25, limit.Token);
        if (captions.Status.State != "live") throw new Exception("Real caption socket did not connect.");
        using var reader = new WaveFileReader(audioPath);
        ISampleProvider samples = reader.ToSampleProvider();
        if (samples.WaveFormat.Channels == 2) samples = new StereoToMonoSampleProvider(samples);
        if (samples.WaveFormat.Channels != 1) throw new Exception("Test audio must be mono or stereo.");
        if (samples.WaveFormat.SampleRate != 48000) samples = new WdlResamplingSampleProvider(samples, 48000);
        var buffer = new float[4800]; int count;
        while ((count = samples.Read(buffer, 0, buffer.Length)) != 0)
        {
            captions.Append(buffer.AsSpan(0, count).ToArray()); await Task.Delay(100, limit.Token);
        }
        await Task.Delay(1000, limit.Token);
        await captions.StopAsync();
        var finals = results.Where(x => x.IsFinal).ToArray();
        Directory.CreateDirectory(output);
        var sourceCount = finals.Count(x => x.Stream == "source"); var translationCount = finals.Count(x => x.Stream == "translation");
        File.WriteAllText(Path.Combine(output, "cloud-caption-smoke.json"), JsonSerializer.Serialize(new { mode = translate ? "translation" : "transcription", socketStates = states.ToArray(), sourceFinalCount = sourceCount, translationFinalCount = translationCount, gotText = finals.Any(x => !string.IsNullOrWhiteSpace(x.Text)), finalState = captions.Status.State }, new JsonSerializerOptions { WriteIndented = true }));
        if (sourceCount == 0 || translate && translationCount == 0) throw new Exception("Connected, but required final caption streams were not received for synthetic speech.");
        Console.WriteLine($"PASS real native caption socket and synthetic speech: {finals.Length} final segments.");
    }
}
