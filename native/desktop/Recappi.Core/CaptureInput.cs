using NAudio.Wave;
using NAudio.Wave.SampleProviders;

sealed class CaptureInput : IDisposable
{
    private readonly IWaveIn capture;
    private readonly BufferedWaveProvider buffer;
    private readonly ISampleProvider samples;
    private Exception? error;
    private bool stopping;
    private bool started;
    private readonly ManualResetEventSlim stopped = new(false);
    public Exception? Error => Volatile.Read(ref error);

    public string Input { get; }

    public CaptureInput(IWaveIn capture, string input)
    {
        this.capture = capture;
        Input = input;
        // A bounded buffer handles callback jitter. On overflow we fail explicitly
        // rather than silently dropping meeting audio or accumulating memory.
        buffer = new BufferedWaveProvider(capture.WaveFormat)
        {
            BufferDuration = TimeSpan.FromSeconds(2),
            ReadFully = true,
            DiscardOnBufferOverflow = false,
        };
        ISampleProvider provider = new MonoProvider(buffer.ToSampleProvider());
        samples = provider.WaveFormat.SampleRate == 48000
            ? provider : new WdlResamplingSampleProvider(provider, 48000);
        capture.DataAvailable += (_, data) =>
        {
            try { buffer.AddSamples(data.Buffer, 0, data.BytesRecorded); }
            catch (Exception failure) { Interlocked.CompareExchange(ref error, failure, null); }
        };
        capture.RecordingStopped += (_, data) =>
        {
            if (!stopping)
                Interlocked.CompareExchange(ref error, data.Exception ?? new IOException("Audio device stopped unexpectedly."), null);
            else if (data.Exception is not null)
                Interlocked.CompareExchange(ref error, data.Exception, null);
            stopped.Set();
        };
    }

    public void Start() { capture.StartRecording(); started = true; }
    public void Read(float[] destination) => samples.Read(destination, 0, destination.Length);
    public void Stop()
    {
        if (stopping || !started) return;
        stopping = true;
        capture.StopRecording();
        if (!stopped.Wait(TimeSpan.FromSeconds(2))) throw new IOException("Audio device did not stop in time.");
    }
    public void Dispose() { try { Stop(); } finally { capture.Dispose(); stopped.Dispose(); } }
}

sealed class MonoProvider(ISampleProvider source) : ISampleProvider
{
    public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 1);
    private float[] buffer = [];

    public int Read(float[] destination, int offset, int count)
    {
        int channels = source.WaveFormat.Channels;
        if (channels == 1) return source.Read(destination, offset, count);
        int needed = count * channels;
        if (buffer.Length < needed) buffer = new float[needed];
        int read = source.Read(buffer, 0, needed) / channels;
        for (int frame = 0; frame < read; frame++)
        {
            float sum = 0;
            for (int channel = 0; channel < channels; channel++) sum += buffer[frame * channels + channel];
            destination[offset + frame] = sum / channels;
        }
        return read;
    }
}
