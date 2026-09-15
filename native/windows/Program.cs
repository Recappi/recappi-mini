using System.Diagnostics;
using System.Text.Json;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

Console.CancelKeyPress += (_, e) => e.Cancel = true;
if (args.SequenceEqual(["--version"]))
{
    Console.WriteLine("recappi-windows-capture/1");
    return 0;
}
// Internal PCM transport for windows-sidecar.js. No account data enters this process.
// stdout is JSON only; closing stdin stops capture and flushes the final audio frame.
return await RunAsync(args);

static async Task<int> RunAsync(string[] args)
{
    bool system = !args.Contains("--no-system-audio");
    bool microphone = !args.Contains("--no-microphone");
    if (!system && !microphone) return 2;
    var inputs = new List<CaptureInput>();
    try
    {
        if (args.SequenceEqual(["--list-sources"])) { Send(InputCatalog.Sources()); return 0; }
        if (args.SequenceEqual(["--list-microphones"])) { Send(InputCatalog.Microphones()); return 0; }
        var processArgument = OptionValue(args, "--process-id");
        var microphoneId = OptionValue(args, "--microphone-device");
        if (system) inputs.Add(new CaptureInput(processArgument is null
            ? new WasapiLoopbackCapture()
            : new ProcessLoopbackCapture(uint.Parse(processArgument)), "system"));
        if (microphone)
        {
            using var enumerator = new MMDeviceEnumerator();
            using var device = microphoneId is null or "default"
                ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console)
                : enumerator.GetDevice(microphoneId);
            if (device.DataFlow != DataFlow.Capture || device.State != DeviceState.Active)
                throw new ArgumentException("The selected microphone is not an active input device.");
            inputs.Add(new CaptureInput(new WasapiCapture(device), "microphone"));
        }
        foreach (var input in inputs) input.Start();
        Send(new { type = "ready", sampleRate = 48000, channels = 1 });
        var stopped = Task.Run(() => { while (Console.ReadLine() is not null) { } });
        var clock = Stopwatch.StartNew();
        long written = 0;
        // A clock, rather than either capture callback, drives the output. WASAPI
        // loopback stops delivering packets when nothing plays; that means silence,
        // not a reason to stall the microphone or shorten the recording timeline.
        while (!stopped.IsCompleted)
        {
            await Task.WhenAny(stopped, Task.Delay(50));
            double elapsed = clock.Elapsed.TotalSeconds;
            bool finishing = stopped.IsCompleted;
            if (finishing) foreach (var input in inputs) input.Stop();
            // Keep a small, fixed read latency so callback jitter doesn't insert
            // silence ahead of incoming samples. Drain that latency on stop.
            var target = (long)(Math.Max(0, elapsed - (finishing ? 0 : 0.15)) * 48000);
            while (written < target)
            {
                int count = (int)Math.Min(4800, target - written);
                var mixed = new float[count];
                foreach (var input in inputs)
                {
                    if (input.Error is { } error) throw error;
                    var samples = new float[count];
                    input.Read(samples);
                    double sum = 0;
                    foreach (float sample in samples) sum += (double)sample * sample;
                    Send(new { type = "level", input = input.Input, rmsDb = sum > 0 ? Math.Max(-120, 10 * Math.Log10(sum / count)) : -120 });
                    for (int i = 0; i < count; i++) mixed[i] += samples[i];
                }
                for (int i = 0; i < count; i++)
                    mixed[i] = float.IsFinite(mixed[i]) ? Math.Clamp(mixed[i] / inputs.Count, -1f, 1f) : 0;
                byte[] bytes = new byte[count * sizeof(float)];
                Buffer.BlockCopy(mixed, 0, bytes, 0, bytes.Length);
                Send(new { type = "audio", samples = Convert.ToBase64String(bytes) });
                written += count;
            }
        }
        return 0;
    }
    catch (Exception error)
    {
        Send(new { type = "error", message = error.Message });
        return 1;
    }
    finally
    {
        foreach (var input in inputs) input.Dispose();
    }
}

static string? OptionValue(string[] args, string option)
{
    int index = Array.IndexOf(args, option);
    if (index < 0) return null;
    if (index + 1 >= args.Length || args[index + 1].StartsWith("--")) throw new ArgumentException($"Missing value for {option}.");
    return args[index + 1];
}

static void Send(object value)
{
    Console.WriteLine(JsonSerializer.Serialize(value));
    Console.Out.Flush();
}
