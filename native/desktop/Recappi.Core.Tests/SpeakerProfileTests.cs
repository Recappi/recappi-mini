using System.Text;
using Recappi.Core;

internal static class SpeakerProfileTests
{
    public static Task RunAsync(string root)
    {
        var directory = Path.Combine(root, "speakers");
        var store = new SpeakerProfileStore(directory);
        var a = new CloudAccount("https://recappi.test", "a", null, "fixture").Partition;
        var b = new CloudAccount("https://recappi.test", "b", null, "fixture").Partition;
        var profile = new SpeakerProfile("Ada", "🎤", "Project owner");
        store.Save(a, "recording", "speaker_1", profile);
        if (new SpeakerProfileStore(directory).Load(a, "recording")["speaker_1"] != profile) throw new Exception("Speaker profile did not survive reload.");
        if (store.Load(b, "recording").Count != 0 || store.Load(a, "other-recording").Count != 0) throw new Exception("Speaker profiles crossed account or recording scope.");
        if (Encoding.UTF8.GetString(File.ReadAllBytes(Directory.GetFiles(Path.Combine(directory, a)).Single())).Contains("Project owner")) throw new Exception("Speaker notes were not protected.");
        try { store.Save(a, "recording", "speaker_1", profile with { Name = " " }); throw new Exception("Invalid profile accepted."); } catch (ArgumentException) { }
        if (store.Load(a, "recording")["speaker_1"] != profile) throw new Exception("Failed save changed existing profile.");
        store.Delete(a, "recording");
        if (store.Load(a, "recording").Count != 0) throw new Exception("Deleted recording retained speaker profiles.");
        return Task.CompletedTask;
    }
}
