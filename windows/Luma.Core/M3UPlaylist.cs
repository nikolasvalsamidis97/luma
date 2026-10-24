using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
namespace Luma.Core;

/// <summary>Playback URLs remain in memory; saved items contain opaque hashes only.</summary>
public sealed class M3UPlaylist
{
    private readonly List<MediaItem> items = [];
    private readonly Dictionary<string,Uri> streams = [];
    private readonly Dictionary<string,List<MediaItem>> episodes = [];
    private readonly Dictionary<string,string> groups = [];
    public static string Identifier(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
    public static Uri Url(string text, Uri? relativeTo = null)
    {
        Uri? uri;
        bool valid = relativeTo == null ? Uri.TryCreate(text.Trim(),UriKind.Absolute,out uri) : Uri.TryCreate(relativeTo,text.Trim(),out uri);
        if (!valid || uri == null || (uri.Scheme != "http" && uri.Scheme != "https") || string.IsNullOrEmpty(uri.Host) || uri.UserInfo != "")
            throw new ProviderException("Enter a valid HTTP or HTTPS playlist link.");
        return uri;
    }
    public (List<Category> Categories,List<MediaItem> Items) Library(LibraryKind kind)
    {
        var selected = items.Where(x=>x.Kind==kind).ToList(); var ids = selected.Select(x=>x.CategoryId).ToHashSet();
        return (groups.Where(x=>ids.Contains(x.Key)).Select(x=>new Category(x.Key,x.Value)).OrderBy(x=>x.Name).ToList(),selected);
    }
    public Uri Stream(MediaItem item) => streams.TryGetValue(item.StreamId,out var url) ? url : throw new ProviderException("This title is no longer in the playlist. Refresh your library.");
    public SeriesDetails Series(MediaItem item) => episodes.TryGetValue(item.StreamId,out var values) ? new(values) : throw new ProviderException("This series is no longer in the playlist. Refresh your library.");
    public static async Task<M3UPlaylist> Load(Uri source,CancellationToken ct, HttpMessageHandler? handler = null)
    {
        using var http = new HttpClient(handler ?? new HttpClientHandler { UseCookies=false,AutomaticDecompression=DecompressionMethods.All }) { Timeout=TimeSpan.FromSeconds(30) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Luma/0.3");
        try {
            using var response = await http.GetAsync(Url(source.AbsoluteUri),HttpCompletionOption.ResponseHeadersRead,ct);
            if (!response.IsSuccessStatusCode) throw new ProviderException($"The playlist provider returned HTTP {(int)response.StatusCode}. Check your link or try again later.");
            const int limit = 32*1024*1024;
            if(response.Content.Headers.ContentLength > limit) throw new ProviderException("This playlist exceeds the 32 MB limit.");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(30));
            using var input = await response.Content.ReadAsStreamAsync(timeout.Token); using var output = new MemoryStream(); byte[] buffer = new byte[16384]; int count;
            while((count=await input.ReadAsync(buffer,timeout.Token))>0) {
                if(output.Length+count>limit) throw new ProviderException("This playlist exceeds the 32 MB limit.");
                output.Write(buffer,0,count);
            }
            ct.ThrowIfCancellationRequested();
            var text=new UTF8Encoding(false,true).GetString(output.ToArray());
            var finalUrl=response.RequestMessage?.RequestUri ?? source;
            return await Task.Run(()=>Parse(text,finalUrl),ct);
        } catch(OperationCanceledException) when(ct.IsCancellationRequested) { throw; }
        catch(ProviderException) { throw; }
        catch { throw new ProviderException("Could not download the playlist. Check your link and connection, then try again."); }
    }
    public static M3UPlaylist Parse(string text,Uri source)
    {
        var basis=Url(source.AbsoluteUri); var lines=text.Replace("\uFEFF","").Split(['\r','\n'],StringSplitOptions.RemoveEmptyEntries).Select(x=>x.Trim()).Where(x=>x!="").ToArray();
        bool extended=lines.Length>0 && lines[0].Split((char[]?)null,StringSplitOptions.RemoveEmptyEntries)[0].Equals("#EXTM3U",StringComparison.OrdinalIgnoreCase);
        if(!extended){if(lines.Length==0||lines[0].StartsWith('#'))throw Invalid();try{foreach(var line in lines.Where(x=>!x.StartsWith('#')))Url(line);}catch(ProviderException){throw Invalid();}}
        var result=new M3UPlaylist();
        if(lines.Any(x=>x.StartsWith("#EXT-X-"))) {
            var id=Identifier(basis.AbsoluteUri);result.items.Add(new(){StreamId=id,Kind=LibraryKind.Live,Name="Live stream",Extension="m3u8"});result.streams[id]=basis;return result;
        }
        var attrs=new Regex("""([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s]+))""");
        var episodic=new Regex(@"^(.*?)\s*[-–: ]*\bS(\d{1,3})E(\d{1,4})\b",RegexOptions.IgnoreCase);
        Dictionary<string,string> metadata=[];string title="",group="";HashSet<string> seen=[];
        foreach(var line in lines) {
            if(line.StartsWith("#EXTINF:")) {
                metadata.Clear();title="";group="";char quote='\0';int comma=-1;
                for(int i=0;i<line.Length;i++){char ch=line[i];if(ch=='"'||ch=='\''){if(quote==ch)quote='\0';else if(quote=='\0')quote=ch;}if(ch==','&&quote=='\0'){comma=i;break;}}
                string header=comma<0?line:line[..comma];if(comma>=0)title=line[(comma+1)..].Trim();
                foreach(Match m in attrs.Matches(header)) metadata[m.Groups[1].Value.ToLowerInvariant()]=Enumerable.Range(2,3).Select(i=>m.Groups[i]).First(g=>g.Success).Value;
                group=metadata.GetValueOrDefault("group-title","");
            } else if(line.StartsWith("#EXTGRP:")) group=line[8..];
            else if(!line.StartsWith('#')) {
                try {
                    Uri stream;try{stream=Url(line,basis);}catch(ProviderException){continue;}
                    string id=Identifier(stream.AbsoluteUri);if(!seen.Add(id))continue;
                    string name=title!=""?title:metadata.GetValueOrDefault("tvg-name","");if(name=="")name="Untitled channel";
                    string category=group==""?"":Identifier(group);if(group!="")result.groups[category]=group;
                    string? art=null;if(metadata.TryGetValue("tvg-logo",out var logo))try{art=Url(logo,basis).AbsoluteUri;}catch(ProviderException){}
                    string type=metadata.GetValueOrDefault("tvg-type","").ToLowerInvariant(),path=stream.AbsolutePath.ToLowerInvariant();var match=episodic.Match(name);
                    var kind=type switch { "live"=>LibraryKind.Live, "movie" or "vod"=>LibraryKind.Movie, "series"=>LibraryKind.Series,
                        _=>path.StartsWith("/series/")||match.Success?LibraryKind.Series:path.StartsWith("/movie/")?LibraryKind.Movie:LibraryKind.Live };
                    string extension=Path.GetExtension(stream.AbsolutePath).TrimStart('.');var traits=MediaItem.Traits(name);
                    var item=new MediaItem{StreamId=id,Kind=kind,Name=name,CategoryId=category,Artwork=art,Extension=extension==""?(kind==LibraryKind.Live?"ts":"mp4"):extension,
                        Season=match.Success?int.Parse(match.Groups[2].Value):null,Episode=match.Success?int.Parse(match.Groups[3].Value):null,Resolution=traits.Resolution,MultiSub=traits.Multi};
                    result.streams[id]=stream;
                    if(kind==LibraryKind.Series){
                        string show=metadata.GetValueOrDefault("series-name",match.Success?match.Groups[1].Value.Trim():name);if(show=="")show=name;
                        string seriesId=Identifier("series\n"+group+"\n"+show);
                        if(!result.episodes.ContainsKey(seriesId)){result.episodes[seriesId]=[];result.items.Add(new(){StreamId=seriesId,Kind=LibraryKind.Series,Name=show,CategoryId=category,Artwork=art});}
                        result.episodes[seriesId].Add(item);
                    } else result.items.Add(item);
                } finally {metadata.Clear();title="";group="";}
            }
        }
        if(result.items.Count==0)throw Invalid();
        foreach(var key in result.episodes.Keys.ToList())result.episodes[key]=result.episodes[key].OrderBy(x=>x.Season??int.MaxValue).ThenBy(x=>x.Episode??int.MaxValue).ThenBy(x=>x.Name).ToList();
        return result;
    }
    private static ProviderException Invalid()=>new("This link did not return a supported M3U playlist with playable HTTP or HTTPS entries.");
}
