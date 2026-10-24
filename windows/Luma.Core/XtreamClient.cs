using System.Net;
using System.Text;
using System.Text.Json;
namespace Luma.Core;
public sealed class XtreamClient : IDisposable
{
    public Credentials Credentials { get; }
    private readonly HttpClient http;
    private readonly SemaphoreSlim detailsGate = new(1);
    private readonly Dictionary<string, (DateTimeOffset Time, SeriesDetails Details)> details = [];
    private DateTimeOffset nextRequest = DateTimeOffset.MinValue;
    public XtreamClient(Credentials credentials, HttpMessageHandler? handler = null)
    {
        Credentials = credentials;
        http = handler == null ? new(new HttpClientHandler { UseCookies = false, AutomaticDecompression = DecompressionMethods.All }) : new(handler);
        http.Timeout = TimeSpan.FromSeconds(25); http.DefaultRequestHeaders.UserAgent.ParseAdd("Luma/0.3");
        http.MaxResponseContentBufferSize = 64 * 1024 * 1024;
    }
    private async Task<JsonElement> Request(string? action, CancellationToken ct, params (string, string)[] args)
    {
        try {
            using var response = await http.GetAsync(Credentials.Api(action, args), ct);
            if (!response.IsSuccessStatusCode) {
                if (response.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.TooManyRequests) nextRequest = DateTimeOffset.UtcNow.AddSeconds(30);
                throw new ProviderException($"Your provider returned HTTP {(int)response.StatusCode}. Please try again later.");
            }
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct)); return json.RootElement.Clone();
        } catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (ProviderException) { throw; }
        catch { throw new ProviderException("Could not read your provider's response. Check the address and connection, then try again."); }
    }
    public async Task Authenticate(CancellationToken ct)
    {
        var json = await Request(null, ct); var info = json.At("user_info");
        if (info.At("auth").Text() != "1") throw new ProviderException("Your provider did not accept these credentials.");
        if (info.At("status").Text() is { } status && !status.Equals("Active", StringComparison.OrdinalIgnoreCase)) throw new ProviderException("Your provider reports that this account is not active.");
    }
    public async Task<(List<Category> Categories, List<MediaItem> Items)> Library(LibraryKind kind, CancellationToken ct)
    {
        var prefix = kind == LibraryKind.Movie ? "vod" : kind == LibraryKind.Live ? "live" : "series";
        var cats = Request($"get_{prefix}_categories", ct);
        var items = Request(kind == LibraryKind.Series ? "get_series" : $"get_{prefix}_streams", ct);
        await Task.WhenAll(cats, items);
        if (cats.Result.ValueKind != JsonValueKind.Array || items.Result.ValueKind != JsonValueKind.Array) throw new ProviderException("The provider returned an invalid library.");
        return (cats.Result.Rows().Where(j => j.At("category_id").Text() != null).Select(j => new Category(j.At("category_id").Text()!, j.At("category_name").Text() ?? "Category")).ToList(),
            items.Result.Rows().Select(j => MediaItem.Parse(j, kind)).OfType<MediaItem>().DistinctBy(x => x.Id).ToList());
    }
    public async Task<SeriesDetails> Series(MediaItem item, CancellationToken ct)
    {
        await detailsGate.WaitAsync(ct);
        try {
            if (details.TryGetValue(item.Id, out var cached) && DateTimeOffset.UtcNow - cached.Time < TimeSpan.FromMinutes(30)) return cached.Details;
            var delay = nextRequest - DateTimeOffset.UtcNow; if (delay > TimeSpan.Zero) await Task.Delay(delay, ct);
            nextRequest = DateTimeOffset.UtcNow.AddMilliseconds(600);
            var parsed = SeriesDetails.Parse(await Request("get_series_info", ct, ("series_id", item.StreamId)), item);
            if (details.Count >= 128) details.Remove(details.MinBy(x => x.Value.Time).Key);
            details[item.Id] = (DateTimeOffset.UtcNow, parsed); return parsed;
        } finally { detailsGate.Release(); }
    }
    public async Task<string> Guide(MediaItem item, CancellationToken ct)
    {
        var json = await Request("get_short_epg", ct, ("stream_id", item.StreamId), ("limit", "3"));
        return string.Join("\n", json.At("epg_listings").Rows().Select(j => {
            var title = j.At("title").Text() ?? "Programme";
            try { title = Encoding.UTF8.GetString(Convert.FromBase64String(title)); } catch (FormatException) { }
            var start = long.TryParse(j.At("start_timestamp").Text(), out var stamp) ? DateTimeOffset.FromUnixTimeSeconds(stamp).ToLocalTime().ToString("HH:mm") : "";
            return start + "  " + title;
        }));
    }
    public void Dispose() { http.Dispose(); }
}
