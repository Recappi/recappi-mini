using System.Text.Json;
using NAudio.Wave;
using Recappi.Core;

internal static class CloudPipelineSmoke
{
    public static async Task RunAsync(string audioPath, string root)
    {
        using var config = JsonDocument.Parse(File.ReadAllText(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "recappi", "config.json")));
        var origin = config.RootElement.GetProperty("origin").GetString()!; var token = config.RootElement.GetProperty("authToken").GetString()!;
        using var client = new CloudClient(origin, token);
        var session = await client.SessionAsync();
        var account = new CloudAccount(origin, session.GetProperty("user").GetProperty("id").GetString()!, null, token);
        var store = new LocalRecordingStore(Path.Combine(root, "recordings"));
        using var source = new WaveFileReader(audioPath);
        var recording = store.Create("Recappi native validation · synthetic speech") with { State = RecordingState.Done, DurationMs = (long)source.TotalTime.TotalMilliseconds };
        File.Copy(audioPath, recording.AudioPath); store.Save(recording);
        var second = store.Create("Recappi native validation · concurrent synthetic upload") with { State = RecordingState.Done, DurationMs = recording.DurationMs };
        File.Copy(audioPath, second.AudioPath); store.Save(second);
        await using var processing = new CloudProcessing(Path.Combine(root, "processing"));
        ProcessingStage? last = null;
        processing.Changed += entry => { if (entry.Stage != last) { last = entry.Stage; Console.WriteLine("Cloud test stage: " + entry.Stage); } };
        string? remoteId = null; var deleted = false; var completed = false; var secondUploaded = false; var suggestionsCount = 0; var downloaded = false; var askDone = false; var transcriptCharacters = 0; var answerCharacters = 0; int? failureStatus = null;
        var cleanedIds = new List<string>();
        try
        {
            var results = await Task.WhenAll(
                processing.StartAsync(recording, account, new("en", "This recording contains synthetic speech for native client validation.")),
                processing.StartAsync(second, account, new(Transcribe: false)));
            var result = results[0];
            secondUploaded = results[1].Stage == ProcessingStage.Synced && results[1].UploadCompleted;
            if (!secondUploaded) throw new Exception("Concurrent synthetic upload did not complete.");
            Console.WriteLine("PASS two concurrent local processing requests completed their real uploads.");
            remoteId = result.Ticket?.Id;
            if (result.Stage != ProcessingStage.Completed || remoteId is null) throw new Exception("Synthetic recording processing did not complete.");
            completed = true;
            var transcript = CloudTranscript.Parse(await client.TranscriptAsync(remoteId, result.JobId)); transcriptCharacters = transcript.Text.Length;
            if (transcriptCharacters == 0) throw new Exception("Synthetic speech transcript was empty.");
            Console.WriteLine("PASS real multipart upload, processing job and non-empty transcript.");
            var audio = await client.DownloadAudioAsync(remoteId, Path.Combine(root, "cloud-copy.audio")); downloaded = new FileInfo(audio).Length > 44;
            if (!downloaded) throw new Exception("Downloaded audio was empty.");
            Console.WriteLine("PASS real authenticated cloud audio download.");
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
            await foreach (var update in client.AskAsync(remoteId, "What will the team do tomorrow?", cancellation: timeout.Token))
            {
                if (update.Name == "answer_delta") answerCharacters += update.Text?.Length ?? 0;
                if (update.Name == "done") { askDone = true; if (update.Text is not null) answerCharacters = update.Text.Length; }
            }
            if (!askDone || answerCharacters == 0) throw new Exception("Real Ask response did not complete.");
            Console.WriteLine("PASS real native Ask stream completed.");
            var suggestions = await client.AskSuggestionsAsync(remoteId, timeout.Token);
            suggestionsCount = suggestions.Length;
            if (suggestionsCount == 0 || suggestions.Any(string.IsNullOrWhiteSpace)) throw new Exception("Real Ask suggestions were empty.");
            Console.WriteLine("PASS real Ask suggestions decoded into non-empty questions.");
        }
        catch (CloudException error) { failureStatus = (int)error.Status; throw; }
        finally
        {
            var owned = processing.List(account.Partition).Where(entry => entry.LocalId == recording.Id || entry.LocalId == second.Id).ToArray();
            remoteId ??= owned.FirstOrDefault(entry => entry.LocalId == recording.Id)?.Ticket?.Id;
            var ownedIds = owned.Select(entry => entry.Ticket?.Id).OfType<string>().Distinct().ToArray();
            foreach (var ownedId in ownedIds)
            {
                try { await client.DeleteAsync(ownedId); cleanedIds.Add(ownedId); await processing.ForgetRemoteAsync(account.Partition, ownedId); Console.WriteLine("PASS synthetic cloud test recording cleaned up."); }
                catch (Exception) { Console.WriteLine("Synthetic cloud test recording cleanup requires follow-up."); }
            }
            deleted = ownedIds.Length == 2 && cleanedIds.Count == ownedIds.Length;
            File.WriteAllText(Path.Combine(root, "cloud-pipeline-smoke.json"), JsonSerializer.Serialize(new { remoteId, completed, secondUploaded, suggestionsCount, transcriptCharacters, downloaded, askDone, answerCharacters, failureStatus, deleted, cleanedIds }, new JsonSerializerOptions { WriteIndented = true }));
        }
        if (!deleted) throw new Exception("Synthetic cloud test cleanup incomplete.");
    }
}
