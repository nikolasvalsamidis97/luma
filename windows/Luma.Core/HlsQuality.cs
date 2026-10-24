using System.Text.RegularExpressions;
namespace Luma.Core;
public sealed record QualityOption(string Label, int Height, int Width);
public static class HlsQuality
{
    // Keep the original master URL and its audio/subtitle rendition groups.
    public static IReadOnlyList<QualityOption> Parse(string text)
    {
        if (!text.TrimStart().StartsWith("#EXTM3U")) return [];
        var sizes = new Dictionary<int,int>(); (int Width,int Height)? pending=null;
        foreach (var raw in text.Split('\n')) {
            var line=raw.Trim();
            if (line.StartsWith("#EXT-X-STREAM-INF:")) {
                pending=null;
                // Attributes can contain quoted commas (e.g. CODECS and NAME).
                foreach(Match field in Regex.Matches(line[18..],"(?:^|,)([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)")) {
                    if(field.Groups[1].Value!="RESOLUTION")continue;
                    var dimensions=field.Groups[2].Value.Split('x');
                    if(dimensions.Length==2&&int.TryParse(dimensions[0],out int w)&&int.TryParse(dimensions[1],out int h)&&w is >0 and <=16384&&h is >0 and <=16384)pending=(w,h);
                }
            } else if(line.Length>0&&!line.StartsWith('#')) {
                if(pending is {} size)sizes[size.Height]=Math.Max(sizes.GetValueOrDefault(size.Height),size.Width);
                pending=null;
            }
        }
        return sizes.Count<2 ? [] : new[]{new QualityOption("Auto",0,0)}.Concat(sizes.OrderBy(x=>x.Key).Select(x=>new QualityOption(x.Key==2160?"4K":x.Key+"p",x.Key,x.Value))).ToList();
    }
}
