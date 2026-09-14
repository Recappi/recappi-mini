using System.Diagnostics;
using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

// Process loopback captures a process AND its children, independent of output
// endpoint. Never fall back to device loopback when activation fails.
// https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/
public sealed class ProcessLoopbackCapture(uint processId) : IWaveIn
{
    private AudioClient? client;
    private Thread? worker;
    private readonly EventWaitHandle samplesReady = new(false, EventResetMode.AutoReset);
    private volatile bool stopping;
    public event EventHandler<WaveInEventArgs>? DataAvailable;
    public event EventHandler<StoppedEventArgs>? RecordingStopped;
    public WaveFormat WaveFormat { get; set; } = new(48000, 16, 2);

    public void StartRecording()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348))
            throw new PlatformNotSupportedException("App recording requires Windows build 20348 or later (Windows 11 / Server 2022).");
        if (worker is not null) throw new InvalidOperationException("Capture has already started.");
        using (var process = Process.GetProcessById(checked((int)processId)))
            if (process.HasExited) throw new IOException("The selected app has exited. Select it again.");
        client = ActivateAsync(processId).GetAwaiter().GetResult();
        try
        {
            client.Initialize(AudioClientShareMode.Shared,
                AudioClientStreamFlags.Loopback | AudioClientStreamFlags.EventCallback | AudioClientStreamFlags.AutoConvertPcm,
                0, 0, WaveFormat, Guid.Empty);
            client.SetEventHandle(samplesReady.SafeWaitHandle.DangerousGetHandle());
            client.Start();
            worker = new Thread(Capture) { IsBackground = true, Name = "Recappi process loopback" };
            worker.Start();
        }
        catch { client.Dispose(); client = null; throw; }
    }

    private void Capture()
    {
        Exception? failure = null;
        try
        {
            var capture = client!.AudioCaptureClient;
            while (!stopping)
            {
                samplesReady.WaitOne(100);
                Drain(capture);
            }
            client.Stop();
            Drain(capture);
        }
        catch (Exception error) { failure = error; }
        finally
        {
            try { client?.Stop(); } catch (Exception error) { failure ??= error; }
            RecordingStopped?.Invoke(this, new StoppedEventArgs(failure));
        }
    }

    private void Drain(AudioCaptureClient capture)
    {
        while (capture.GetNextPacketSize() > 0)
        {
            var pointer = capture.GetBuffer(out int frames, out AudioClientBufferFlags flags);
            try
            {
                var bytes = new byte[checked(frames * WaveFormat.BlockAlign)];
                if (!flags.HasFlag(AudioClientBufferFlags.Silent)) Marshal.Copy(pointer, bytes, 0, bytes.Length);
                DataAvailable?.Invoke(this, new WaveInEventArgs(bytes, bytes.Length));
            }
            finally { capture.ReleaseBuffer(frames); }
        }
    }

    public void StopRecording()
    {
        stopping = true;
        samplesReady.Set();
        if (worker != Thread.CurrentThread) worker?.Join();
    }

    public void Dispose()
    {
        StopRecording();
        client?.Dispose();
        client = null;
        samplesReady.Dispose();
    }

    private static async Task<AudioClient> ActivateAsync(uint processId)
    {
        // AUDIOCLIENT_ACTIVATION_PARAMS: PROCESS_LOOPBACK, PID, INCLUDE_TARGET_PROCESS_TREE.
        var parameters = Marshal.AllocHGlobal(12);
        IActivateAudioInterfaceAsyncOperation? operation = null;
        var completion = new ActivationCompletion();
        try
        {
            if (!Marshal.IsTypeVisibleFromCom(typeof(ActivationCompletion)))
                throw new InvalidOperationException("The process-capture callback must be COM-visible.");
            Marshal.WriteInt32(parameters, 0, 1);
            Marshal.WriteInt32(parameters, 4, unchecked((int)processId));
            Marshal.WriteInt32(parameters, 8, 0);
            var variant = new PropVariant { Type = 65, Blob = new Blob { Size = 12, Data = parameters } }; // VT_BLOB
            var iid = typeof(IAudioClient).GUID;
            int activationResult = ActivateAudioInterfaceAsync(
                "VAD\\Process_Loopback", ref iid, ref variant, completion, out operation);
            if (activationResult < 0) throw new COMException("Process audio activation failed.", activationResult);
            // The parent process bounds activation time and kills a stuck helper.
            // Keep the callback and activation storage alive until COM completes.
            return new AudioClient(await completion.Result.Task.ConfigureAwait(false));
        }
        finally
        {
            GC.KeepAlive(completion);
            if (operation is not null) Marshal.ReleaseComObject(operation);
            Marshal.FreeHGlobal(parameters);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Blob { public int Size; public IntPtr Data; }
    [StructLayout(LayoutKind.Sequential)]
    private struct PropVariant { public ushort Type, Reserved1, Reserved2, Reserved3; public Blob Blob; }

    [DllImport("Mmdevapi.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern int ActivateAudioInterfaceAsync(string deviceInterfacePath, ref Guid riid,
        ref PropVariant activationParams, IActivateAudioInterfaceCompletionHandler completionHandler,
        out IActivateAudioInterfaceAsyncOperation activationOperation);

    [ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IActivateAudioInterfaceAsyncOperation
    {
        [PreserveSig] int GetActivateResult(out int activateResult, [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
    }

    [ComVisible(true), Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IActivateAudioInterfaceCompletionHandler
    {
        [PreserveSig] int ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation);
    }

    [ComVisible(true), Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAgileObject { }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class ActivationCompletion : IActivateAudioInterfaceCompletionHandler, IAgileObject
    {
        public readonly TaskCompletionSource<IAudioClient> Result = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation)
        {
            try
            {
                Marshal.ThrowExceptionForHR(operation.GetActivateResult(out int result, out var value));
                Marshal.ThrowExceptionForHR(result);
                Result.TrySetResult((IAudioClient)value);
            }
            catch (Exception error) { Result.TrySetException(error); }
            return 0;
        }
    }
}
