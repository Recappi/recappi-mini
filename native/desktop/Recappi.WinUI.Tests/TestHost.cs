using System.Net;
using System.Text;
using Recappi.Core;

namespace Recappi.WinUI.Tests;

internal sealed class TestHost : IDesktopHost, IAsyncDisposable
{
    public RecordingEngine Engine { get; }
    public LocalRecordingStore Store { get; }
    public AccountSession Account { get; }
    public CloudProcessing Processing { get; }
    public DesktopPreferences Preferences { get; private set; }
    public string ApplicationRoot { get; }
    public string Origin => "https://example.test";
    public bool RejectSave;
    public TestHost(string root, Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>>? handler = null)
    {
        ApplicationRoot = root; Directory.CreateDirectory(root);
        Store = new LocalRecordingStore(Path.Combine(root, "Recordings"));
        Preferences = new() { RecordingsRoot = Store.Root, AutoUpload = false, IncludeMicrophone = false, OnboardingCompleted = true, RecordingSuggestions = false };
        Engine = new RecordingEngine(Store, _ => [new SignalInput("system")], _ => new SignalInput("microphone"));
        Account = new AccountSession(new AccountStore(Path.Combine(root, "Account")), (origin, token) => new CloudClient(origin, token, new Handler(handler ?? DefaultResponse)));
        Processing = new CloudProcessing(Path.Combine(root, "Processing"), Account.Client);
    }
    public static HttpResponseMessage Json(string value) => new(HttpStatusCode.OK) { Content = new StringContent(value, Encoding.UTF8, "application/json") };
    public static Task<HttpResponseMessage> DefaultResponse(HttpRequestMessage request, CancellationToken _)
    {
        var path = request.RequestUri!.AbsolutePath;
        return Task.FromResult(Json(path.EndsWith("get-session") ? """{"session":{},"user":{"id":"a","email":"fixture@example.test"}}""" : path.EndsWith("ask-suggestions") ? """{"suggestions":[]}""" : path.EndsWith("ask-thread") ? """{"messages":[]}""" : path.EndsWith("transcript") ? """{"text":"Fixture transcript","summary":"Fixture summary","summaryStatus":"completed","segments":[{"text":"Fixture transcript","speaker":"Speaker 1","startMs":0,"endMs":1000}]}""" : """{"items":[],"nextCursor":null}"""));
    }
    public async Task SignIn(string? email = null)
    {
        new AccountStore(Path.Combine(ApplicationRoot, "Account")).Save(new CloudAccount(Origin, "a", email ?? "fixture@example.test", "test-only"));
        await Account.RestoreAsync();
        if (Account.Snapshot.State != AccountState.SignedIn) throw new Exception("Test account failed to initialize.");
    }
    public void ShowLibrary() { }
    public void ShowRecording(string id) { }
    public void ShowRecorder() { }
    public void ShowAccount() { }
    public void ShowSettings() { }
    public void ShowCaptions() { }
    public void ShowOnboarding(bool restart = false) { }
    public void SavePreferences(DesktopPreferences value) { if (RejectSave) throw new IOException("Controlled save failure"); new PreferencesStore(ApplicationRoot).Save(value); Preferences = value.Validate(); }
    public void SetRecordingLanguage(string language, string translation) => Preferences = Preferences with { CaptionLanguage = language, TranslationLanguage = translation };
    public Task StartRecording(RecordingOptions options, DesktopPreferences preferences) { Preferences = preferences; return Engine.StartAsync(options); }
    public async Task StopRecording() => await Engine.StopAsync();
    public Task StopCaptions(bool abort = false) => Task.CompletedTask;
    public Task StopCaptionsIfFinished() => Task.CompletedTask;
    public async Task Quit() => await Engine.DisposeAsync();
    public async ValueTask DisposeAsync() { await Engine.DisposeAsync(); await Processing.DisposeAsync(); }
    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> handler) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => handler(request, cancellationToken); }
    private sealed class SignalInput(string input) : IAudioInput
    {
        public string Input => input;
        public Exception? Error => null;
        private int sample;
        public void Start() { }
        public void Stop() { }
        public void Dispose() { }
        public void Read(float[] destination) { for (var i = 0; i < destination.Length; i++) destination[i] = (float)(Math.Sin(sample++ * 2 * Math.PI * 440 / 48000) * 0.2); }
    }
}
