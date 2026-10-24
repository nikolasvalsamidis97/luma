using System.Text.Json;
using System.Text.Json.Serialization;
namespace Luma.Core;

// Persist this collection only in the platform credential vault.
public sealed record SavedConnection(Credentials? Credentials, string? PlaylistUrl, string Name = "", string? Id = null)
{
    [JsonIgnore] public string AccountKey => PlaylistUrl is {} url ? "m3u-"+M3UPlaylist.Identifier(url) : Credentials?.AccountId ?? "invalid";
    [JsonIgnore] public string DisplayName => string.IsNullOrWhiteSpace(Name) ? new Uri(PlaylistUrl ?? Credentials!.Server).Host : Name.Trim();
    [JsonIgnore] public string SourceType => PlaylistUrl == null ? "Xtream Codes" : "M3U";
    public override string ToString() => DisplayName;
}
public sealed class SavedPlaylists
{
    public List<SavedConnection> Connections { get; set; } = [];
    public string? ActiveID { get; set; }
    [JsonIgnore] public SavedConnection? Active => Connections.FirstOrDefault(x=>x.Id==ActiveID);
    public SavedPlaylists Copy() => new(){ Connections=[..Connections], ActiveID=ActiveID };
    public string Remember(SavedConnection value)
    {
        int index=Connections.FindIndex(x=>x.AccountKey==value.AccountKey);
        value=value with { Id=index>=0?Connections[index].Id:value.Id??Guid.NewGuid().ToString(), Name=string.IsNullOrWhiteSpace(value.Name)&&index>=0?Connections[index].Name:value.Name.Trim() };
        if(index>=0)Connections[index]=value;else Connections.Add(value);
        ActiveID=value.Id;return value.Id!;
    }
    public void Remove(string id) { Connections.RemoveAll(x=>x.Id==id);if(ActiveID==id)ActiveID=null; }
    public void Rename(string id,string name) { int i=Connections.FindIndex(x=>x.Id==id);if(i>=0)Connections[i]=Connections[i] with {Name=name.Trim()}; }
    public static SavedPlaylists Decode(byte[] data)
    {
        using var document=JsonDocument.Parse(data);
        if(document.RootElement.TryGetProperty("Connections",out _)) return JsonSerializer.Deserialize<SavedPlaylists>(data) ?? throw new JsonException();
        var result=new SavedPlaylists();
        SavedConnection? old;
        if(document.RootElement.TryGetProperty("Server",out _)) old=new(JsonSerializer.Deserialize<Credentials>(data),null);
        else old=JsonSerializer.Deserialize<SavedConnection>(data);
        if(old==null||(old.Credentials==null)==(old.PlaylistUrl==null))throw new JsonException();
        result.Remember(old);return result;
    }
}
