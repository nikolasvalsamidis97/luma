using System.ComponentModel;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Luma.Core;
public enum LibraryKind { Live, Movie, Series }
public sealed class ProviderException(string message) : Exception(message);
public sealed record Credentials(string Server, string Username, string Password)
{
    public static Credentials Create(string server, string username, string password)
    {
        if (!Uri.TryCreate(server.Trim(), UriKind.Absolute, out var uri) ||
            (uri.Scheme != "https" && uri.Scheme != "http") || string.IsNullOrEmpty(uri.Host) || !string.IsNullOrEmpty(uri.UserInfo))
            throw new ProviderException("Enter a server address beginning with http:// or https://, including its port.");
        var builder = new UriBuilder(uri) { Query = "", Fragment = "" };
        builder.Path = builder.Path.TrimEnd('/');
        if (builder.Path.EndsWith("/player_api.php")) builder.Path = builder.Path[..^15];
        if (string.IsNullOrWhiteSpace(username) || string.IsNullOrEmpty(password)) throw new ProviderException("Enter your provider username and password.");
        return new(builder.Uri.AbsoluteUri.TrimEnd('/'), username.Trim(), password);
    }
    public Uri Api(string? action = null, params (string Key, string Value)[] extra)
    {
        var pairs = new List<(string Key, string Value)> { ("username", Username), ("password", Password) };
        if (action != null) pairs.Add(("action", action)); pairs.AddRange(extra);
        return new(Server + "/player_api.php?" + string.Join("&", pairs.Select(p => Uri.EscapeDataString(p.Key) + "=" + Uri.EscapeDataString(p.Value))));
    }
    public Uri Stream(MediaItem item)
    {
        if (!Regex.IsMatch(item.StreamId, @"^[\p{L}\p{N}_-]+$") || !Regex.IsMatch(item.Extension, @"^[a-zA-Z0-9]+$")) throw new ProviderException("This item has an invalid stream address.");
        return new(Server + $"/{item.Kind.ToString().ToLowerInvariant()}/{Uri.EscapeDataString(Username)}/{Uri.EscapeDataString(Password)}/{item.StreamId}.{item.Extension}");
    }
    public string AccountId => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Server + "\n" + Username)));
    public override string ToString() => "Provider credentials";
}
public static class Json
{
    public static JsonElement At(this JsonElement j, string key) => j.ValueKind == JsonValueKind.Object && j.TryGetProperty(key, out var p) ? p : default;
    public static string? Text(this JsonElement j) => j.ValueKind switch { JsonValueKind.String => j.GetString(), JsonValueKind.Number => j.GetRawText(), JsonValueKind.True => "1", JsonValueKind.False => "0", _ => null };
    public static int? Number(this JsonElement j) => int.TryParse(j.Text(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : null;
    public static IEnumerable<JsonElement> Rows(this JsonElement j) => j.ValueKind == JsonValueKind.Array ? j.EnumerateArray() : [];
}
public sealed record Category(string Id, string Name);
public sealed class MediaItem : INotifyPropertyChanged
{
    public string StreamId { get; init; } = "";
    public LibraryKind Kind { get; init; }
    public string Name { get; init; } = "";
    public string CategoryId { get; init; } = "";
    public string? Artwork { get; init; }
    public string Extension { get; init; } = "mp4";
    public string? Rating { get; init; }
    public string? Plot { get; init; }
    public int? Season { get; init; }
    public int? Episode { get; init; }
    public string? Resolution { get; init; }
    public bool MultiSub { get; init; }
    public string Id => $"{Kind}:{StreamId}";
    public string Badges => string.Join(" · ", new[] { Resolution, MultiSub ? "MULTISUB" : null }.Where(x => x != null));
    public string Subtitle => Kind == LibraryKind.Series && Episode != null ? $"S{Season:00} · E{Episode:00}" : Rating != null ? "★ " + Rating : Kind.ToString();
    private string seasonBadge = "Load seasons";
    [System.Text.Json.Serialization.JsonIgnore]
    public string SeasonBadge { get => Kind == LibraryKind.Series && Episode == null ? seasonBadge : ""; set { seasonBadge = value; PropertyChanged?.Invoke(this, new(nameof(SeasonBadge))); } }
    public event PropertyChangedEventHandler? PropertyChanged;
    public static MediaItem? Parse(JsonElement j, LibraryKind kind)
    {
        var id = j.At(kind == LibraryKind.Series ? "series_id" : "stream_id").Text(); var name = j.At("name").Text();
        if (string.IsNullOrEmpty(id) || name == null) return null;
        var (resolution, multi) = Traits(name, j);
        var art = j.At(kind == LibraryKind.Series ? "cover" : "stream_icon").Text();
        return new() { StreamId = id, Kind = kind, Name = name, CategoryId = j.At("category_id").Text() ?? "", Artwork = SafeArtwork(art), Extension = j.At("container_extension").Text() ?? (kind == LibraryKind.Live ? "ts" : "mp4"), Rating = j.At("rating").Text(), Plot = j.At("plot").Text(), Resolution = resolution, MultiSub = multi };
    }
    public static string? SafeArtwork(string? value) => Uri.TryCreate(value, UriKind.Absolute, out var u) && (u.Scheme == "http" || u.Scheme == "https") ? value : null;
    public static (string? Resolution, bool Multi) Traits(string name, JsonElement j = default)
    {
        bool Match(string p) => Regex.IsMatch(name, @"(?<![\p{L}\p{N}])(?:" + p + @")(?![\p{L}\p{N}])", RegexOptions.IgnoreCase);
        var v = j.At("video").ValueKind == JsonValueKind.Object ? j.At("video") : j;
        int w = v.At("width").Number() ?? 0, h = v.At("height").Number() ?? 0;
        string? resolution = w is >= 3800 and <= 4200 || h == 2160 ? "4K" : w == 1920 || h == 1080 ? "1080p" : Match("4K|UHD|2160P") ? "4K" : Match("1080P|FHD") ? "1080p" : null;
        return (resolution, (j.At("subtitle_count").Number() ?? j.At("subtitles").Rows().Count()) > 1 || Match(@"MULTI[\s_-]*SUB(?:S|TITLE|TITLES)?|MSUB"));
    }
}
public sealed record SeriesDetails(IReadOnlyList<MediaItem> Episodes)
{
    public string Badge {
        get {
            if (Episodes.Any(e => e.Season == null || e.Season < 0)) return "Seasons unknown";
            int n = Episodes.Where(e => e.Season > 0).Select(e => e.Season).Distinct().Count();
            return n == 0 && Episodes.Any(e => e.Season == 0) ? "Specials only" : $"{n} {(n == 1 ? "season" : "seasons")}";
        }
    }
    public static SeriesDetails Parse(JsonElement root, MediaItem series)
    {
        var source = root.At("episodes"); var groups = new List<(int? Season, JsonElement Rows)>();
        if (source.ValueKind == JsonValueKind.Object) {
            foreach (var p in source.EnumerateObject()) { if (p.Value.ValueKind != JsonValueKind.Array) throw new ProviderException("Invalid episode list."); groups.Add((int.TryParse(p.Name, out var s) ? s : null, p.Value)); }
        } else if (source.ValueKind == JsonValueKind.Array) {
            if (source.Rows().All(x => x.ValueKind == JsonValueKind.Object)) groups.Add((null, source));
            else foreach (var a in source.Rows()) { if (a.ValueKind != JsonValueKind.Array) throw new ProviderException("Invalid episode list."); groups.Add((null, a)); }
        } else throw new ProviderException("The provider did not return episode information.");
        var seen = new HashSet<string>(); var episodes = new List<MediaItem>();
        foreach (var (season, rows) in groups) foreach (var j in rows.Rows()) {
            var id = j.At("id").Text(); if (string.IsNullOrEmpty(id) || !seen.Add(id)) continue;
            var name = j.At("title").Text() ?? "Episode"; var info = j.At("info"); var traits = MediaItem.Traits(name, info);
            episodes.Add(new() { StreamId = id, Kind = LibraryKind.Series, Name = name, Artwork = series.Artwork, Extension = j.At("container_extension").Text() ?? "mp4", Season = j.At("season").Number() ?? j.At("season_number").Number() ?? season, Episode = j.At("episode_num").Number(), Plot = info.At("plot").Text(), Resolution = traits.Resolution, MultiSub = traits.Multi });
        }
        if (episodes.Count == 0 && groups.Any(g => g.Rows.GetArrayLength() > 0)) throw new ProviderException("The provider returned invalid episodes.");
        return new(episodes.OrderBy(e => e.Season ?? int.MaxValue).ThenBy(e => e.Episode ?? 0).ThenBy(e => e.StreamId, StringComparer.Ordinal).ToArray());
    }
    public MediaItem? Next(MediaItem current) => current.Season is not null && current.Episode is not null && Episodes.Any(e => e.Id == current.Id)
        ? Episodes.FirstOrDefault(e => e.Season != null && e.Episode != null && e.Id != current.Id && (current.Season > 0 ? e.Season > 0 : e.Season == current.Season) && (e.Season > current.Season || e.Season == current.Season && e.Episode > current.Episode)) : null;
}
public sealed record ProgressEntry(MediaItem Title, MediaItem Playing, long Position, long Duration, DateTimeOffset Updated, bool UpNext = false)
{
    public string Description => UpNext ? "Up next · " + Playing.Subtitle : Playing.Kind == LibraryKind.Series ? Playing.Subtitle + $" · {TimeSpan.FromMilliseconds(Position):h\\:mm\\:ss}" : $"Resume at {TimeSpan.FromMilliseconds(Position):h\\:mm\\:ss}";
}
public sealed class LibraryState
{
    public List<MediaItem> Watchlist { get; set; } = [];
    public List<ProgressEntry> Progress { get; set; } = [];
    public HashSet<string> Favorites { get; set; } = [];
    public void SaveProgress(MediaItem title, MediaItem playing, long position, long duration, bool finished, MediaItem? next)
    {
        if (playing.Kind == LibraryKind.Live || (!finished && position < 1000)) return;
        Progress.RemoveAll(p => p.Title.Id == title.Id);
        if (finished) { if (next != null) Progress.Insert(0, new(title, next, 0, 0, DateTimeOffset.UtcNow, true)); }
        else Progress.Insert(0, new(title, playing, position, duration, DateTimeOffset.UtcNow));
        if (Progress.Count > 200) Progress.RemoveRange(200, Progress.Count - 200);
    }
}
