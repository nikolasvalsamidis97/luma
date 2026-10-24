using System.Net;
using System.Text;
using System.Text.Json;
using Luma.Core;
int passed=0;
void Check(bool ok,string name){if(!ok)throw new Exception(name);passed++;Console.WriteLine("PASS: "+name);}
JsonElement Json(string text)=>JsonDocument.Parse(text).RootElement.Clone();
var credentials=Credentials.Create("https://example.test:8443/base/player_api.php?old=1#x","  u+/@  ","p+/%?&");
Check(credentials.Server=="https://example.test:8443/base","server normalization");
Check(credentials.Api().Query.Contains("username=u%2B%2F%40")&&credentials.Api().Query.Contains("password=p%2B%2F%25%3F%26"),"query credentials are encoded");
var movie=new MediaItem{StreamId="123",Kind=LibraryKind.Movie,Name="Film",Extension="mkv"};
Check(credentials.Stream(movie).AbsoluteUri=="https://example.test:8443/base/movie/u%2B%2F%40/p%2B%2F%25%3F%26/123.mkv","stream credentials remain individual path segments");
Check(!credentials.ToString().Contains(credentials.Password),"credential record does not echo secrets");
foreach(var bad in new[]{"file:///tmp/video","https://user:secret@example.test","wrong"}){try{Credentials.Create(bad,"u","p");throw new Exception("accepted bad server");}catch(ProviderException){passed++;}}
try{credentials.Stream(new MediaItem{StreamId="../x",Extension="mp4"});throw new Exception("accepted traversal");}catch(ProviderException){Check(true,"invalid stream ID rejected");}
Check(MediaItem.Parse(Json("{\"stream_id\":42,\"name\":\"Film FHD MULTISUB\",\"rating\":8.5}"),LibraryKind.Movie) is {StreamId:"42",Resolution:"1080p",MultiSub:true},"mixed IDs/ratings and title badges");
Check(!MediaItem.Traits("MULTI AUDIO 4kids").Multi&&MediaItem.Traits("MULTI AUDIO 4kids").Resolution==null,"no false MULTI or 4K badges");
Check(MediaItem.Traits("Movie",Json("{\"video\":{\"width\":3840,\"height\":1600},\"subtitle_count\":2}"))==("4K",true),"structured media traits");
var series=new MediaItem{StreamId="s1",Kind=LibraryKind.Series,Name="Series"};
var details=SeriesDetails.Parse(Json("""
{"episodes":{"0":[{"id":"sp","season":0,"episode_num":1}],"1":[{"id":1,"episode_num":1},{"id":2,"episode_num":"2"}],"2":[],"3":[{"id":3,"episode_num":1},{"id":3,"episode_num":1}]}}
"""),series);
Check(details.Badge=="2 seasons"&&details.Episodes.Count==4,"season badges count populated regular seasons and deduplicate episodes");
Check(details.Next(details.Episodes.Single(e=>e.StreamId=="2"))?.StreamId=="3","next episode crosses regular season boundary");
Check(details.Next(details.Episodes.Single(e=>e.StreamId=="sp"))==null,"specials do not jump into regular episodes");
Check(SeriesDetails.Parse(Json("{\"episodes\":[{\"id\":9,\"episode_num\":1}]}"),series).Badge=="Seasons unknown","missing metadata is not a guessed season");
Check(SeriesDetails.Parse(Json("{\"episodes\":{\"0\":[{\"id\":9,\"episode_num\":1}]}}"),series).Badge=="Specials only","specials-only badge");
var state=new LibraryState();state.Watchlist.Add(series);state.SaveProgress(series,details.Episodes[1],10000,100000,false,null);
var roundtrip=JsonSerializer.Deserialize<LibraryState>(JsonSerializer.Serialize(state))!;
Check(roundtrip.Progress.Single().Position==10000&&roundtrip.Watchlist.Single().Id==series.Id,"watchlist and progress serialization");
state.SaveProgress(series,details.Episodes[1],100000,100000,true,details.Episodes[2]);
Check(state.Progress.Single().UpNext&&state.Progress.Single().Position==0,"completed episode advances Continue Watching");
state.SaveProgress(series,details.Episodes[2],100000,100000,true,null);Check(state.Progress.Count==0,"finished final episode leaves Continue Watching");
var hls="""
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d,mp4a.40"
720.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080
1080.m3u8
#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=50000,RESOLUTION=3840x2160
iframe.m3u8
""";
Check(HlsQuality.Parse(hls).Select(x=>x.Label).SequenceEqual(new[]{"Auto","720p","1080p"}),"HLS ignores iframe variants and preserves resolution choices");
Check(HlsQuality.Parse("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=90000\naudio.m3u8").Count==0,"audio-only playlist has no invented quality choices");
var handler=new FixtureHandler();using var client=new XtreamClient(credentials,handler);
await client.Authenticate(CancellationToken.None);var library=await client.Library(LibraryKind.Movie,CancellationToken.None);
Check(library.Items.Count==1&&library.Categories.Single().Id=="1","provider fixture authentication, categories and deduplication");
Check(handler.UserAgents.All(x=>x=="Luma/0.3"),"provider-facing identity remains stable");
handler.Fail=true;
try{await client.Authenticate(CancellationToken.None);throw new Exception("accepted HTTP error");}catch(ProviderException ex){Check(ex.Message.Contains("403")&&!ex.Message.Contains(credentials.Password),"HTTP errors never expose credential URLs");}
var playlistSource=new Uri("https://example.test/folder/list.m3u?token=private-token");
var playlistText="""
#EXTM3U url-tvg="guide.xml"
#EXTINF:-1 tvg-name="Fallback" tvg-logo="logos/news.png" group-title="News, local",News, local
live.ts?token=stream-secret
#EXTINF:-1,Duplicate
live.ts?token=stream-secret
#EXTINF:-1 tvg-type="movie" group-title='Films',Film 4K MULTISUB
/movie/u/p/1.mkv
#EXTINF:-1 group-title="Drama",The Coast S02E01 - New chapter
/series/u/p/201.mkv
#EXTINF:-1 group-title="Drama",The Coast S01E02 - Two
/series/u/p/102.mkv
#EXTINF:-1 group-title="Drama",The Coast S01E01 - One
/series/u/p/101.mkv
#EXTINF:-1 tvg-type="series",Unknown series
/series/u/p/unknown.mkv
#EXTINF:-1 tvg-name="Fallback"
#EXTGRP:Other
/live/fallback.ts
#EXTINF:-1,Unsafe
file:///etc/passwd
""";
var playlist=M3UPlaylist.Parse("\uFEFF"+playlistText.Replace("\n","\r\n"),playlistSource);
var channels=playlist.Library(LibraryKind.Live);var films=playlist.Library(LibraryKind.Movie).Items;var shows=playlist.Library(LibraryKind.Series).Items;
Check(channels.Items.Count==2&&channels.Categories.Count==2&&channels.Items[0].Name=="News, local"&&channels.Items[1].Name=="Fallback","M3U quoted commas, fallback names, EXTGRP, BOM, CRLF and deduplication");
Check(playlist.Stream(channels.Items[0]).AbsoluteUri=="https://example.test/folder/live.ts?token=stream-secret"&&channels.Items[0].Artwork=="https://example.test/folder/logos/news.png","M3U relative stream and artwork resolution");
Check(films.Count==1&&films[0].Resolution=="4K"&&films[0].MultiSub&&films[0].Extension=="mkv","M3U explicit movies and badges");
var listed=playlist.Series(shows[0]);
Check(shows.Count==2&&shows[0].Name=="The Coast"&&listed.Badge=="2 seasons"&&listed.Episodes.Select(x=>x.Episode).SequenceEqual(new int?[]{1,2,1}),"M3U season grouping and episode ordering");
Check(playlist.Series(shows[1]).Badge=="Seasons unknown","M3U missing seasons remain unknown");
string savedItems=JsonSerializer.Serialize(channels.Items.Concat(films).Concat(shows).Concat(listed.Episodes));
Check(!savedItems.Contains("stream-secret")&&!savedItems.Contains("private-token")&&!savedItems.Contains("/series/u/p"),"M3U saved items contain no playback credentials");
Check(M3UPlaylist.Parse("https://example.test/one.ts\nhttps://example.test/two.ts",playlistSource).Library(LibraryKind.Live).Items.Count==2,"plain M3U without metadata header");
Check(M3UPlaylist.Parse("#EXTM3U\n#EXTINF:-1 tvg-type=movie,Film S01E01\n/one.mp4",playlistSource).Library(LibraryKind.Movie).Items.Count==1,"explicit M3U type wins over title hints");
var directHls=M3UPlaylist.Parse("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts",playlistSource);
Check(directHls.Library(LibraryKind.Live).Items.Count==1&&directHls.Stream(directHls.Library(LibraryKind.Live).Items[0])==playlistSource,"HLS link is one playable stream");
Check(M3UPlaylist.Parse(playlistText,playlistSource).Library(LibraryKind.Movie).Items[0].Id==films[0].Id,"M3U stable identities across reload");
foreach(var invalid in new[]{"<html>Sign in</html>","#EXTM3U\n#EXTINF:-1,Unsafe\nfile:///tmp/movie.mp4","#EXTM3U"}){try{M3UPlaylist.Parse(invalid,playlistSource);throw new Exception("Accepted invalid M3U");}catch(ProviderException){Check(true,"invalid M3U rejected");}}
foreach(var invalid in new[]{"file:///tmp/list.m3u","https://u:p@example.test/list","not a link"}){try{M3UPlaylist.Url(invalid);throw new Exception("Accepted invalid M3U source");}catch(ProviderException){Check(true,"invalid M3U URL rejected");}}
try{playlist.Stream(new(){StreamId="removed"});throw new Exception("Resolved removed entry");}catch(ProviderException){Check(true,"removed M3U entry reports safe error");}
var downloaded=await M3UPlaylist.Load(playlistSource,CancellationToken.None,new PlaylistHandler("ok"));
Check(downloaded.Stream(downloaded.Library(LibraryKind.Live).Items[0]).AbsoluteUri=="https://cdn.example.test/redirected/video.ts","M3U loader resolves against final response URL");
foreach(var mode in new[]{"denied","large","html"}){try{await M3UPlaylist.Load(playlistSource,CancellationToken.None,new PlaylistHandler(mode));throw new Exception("Accepted failed download");}catch(ProviderException ex){Check(!ex.Message.Contains("private-token")&&!ex.Message.Contains("https://"),"M3U loader safe "+mode+" failure");}}
using(var cancel=new CancellationTokenSource()){cancel.Cancel();try{await M3UPlaylist.Load(playlistSource,cancel.Token,new PlaylistHandler("ok"));throw new Exception("Ignored cancellation");}catch(OperationCanceledException){Check(true,"M3U download cancellation");}}
var savedProviders=new SavedPlaylists();
var firstProvider=Credentials.Create("https://one.test","same-user","one");var secondProvider=Credentials.Create("https://two.test","same-user","two");
string firstId=savedProviders.Remember(new(firstProvider,null,"Home")),secondId=savedProviders.Remember(new(secondProvider,null,"Sports"));
Check(firstId!=secondId&&savedProviders.Connections.Count==2&&savedProviders.Active?.Credentials==secondProvider,"multiple provider accounts and active selection");
Check(savedProviders.Connections[0].AccountKey!=savedProviders.Connections[1].AccountKey,"same username on different servers keeps separate history");
var rotated=Credentials.Create("https://one.test","same-user","changed");
Check(savedProviders.Remember(new(rotated,null))==firstId&&savedProviders.Connections.Count==2&&savedProviders.Active?.Name=="Home"&&savedProviders.Active?.Credentials?.Password=="changed","updated credentials retain playlist identity and name");
savedProviders.Rename(firstId," Living room ");Check(savedProviders.Active?.Name=="Living room","playlist rename");
savedProviders.ActiveID=secondId;var providersRoundtrip=SavedPlaylists.Decode(JsonSerializer.SerializeToUtf8Bytes(savedProviders));
Check(providersRoundtrip.Active?.Id==secondId&&providersRoundtrip.Connections.Count==2,"multiple playlists persistence");
var migratedProvider=SavedPlaylists.Decode(JsonSerializer.SerializeToUtf8Bytes(firstProvider));
Check(migratedProvider.Connections.Count==1&&migratedProvider.Active?.Credentials==firstProvider,"legacy credentials migration");
var migratedConnection=SavedPlaylists.Decode(JsonSerializer.SerializeToUtf8Bytes(new{Credentials=firstProvider,PlaylistUrl=(string?)null}));
Check(migratedConnection.Active?.DisplayName=="one.test","legacy connection migration");
var migratedM3U=SavedPlaylists.Decode(Encoding.UTF8.GetBytes("{\"PlaylistUrl\":\"https://m3u.test/list?secret=one\"}"));
Check(migratedM3U.Active?.SourceType=="M3U","legacy M3U migration");
savedProviders.Remember(migratedM3U.Active!);savedProviders.ActiveID=null;
var disconnectedProviders=SavedPlaylists.Decode(JsonSerializer.SerializeToUtf8Bytes(savedProviders));
Check(disconnectedProviders.Active==null&&disconnectedProviders.Connections.Count==3,"disconnect retains saved playlists");
savedProviders.ActiveID=secondId;savedProviders.Remove(firstId);Check(savedProviders.Active?.Id==secondId&&savedProviders.Connections.Count==2,"remove another playlist preserves current connection");
savedProviders.Remove(secondId);Check(savedProviders.Active==null&&savedProviders.Connections.Count==1,"remove current playlist disconnects only it");
try{SavedPlaylists.Decode(Encoding.UTF8.GetBytes("{}"));throw new Exception("Invalid vault accepted");}catch(JsonException){Check(true,"invalid playlist vault rejected");}
Console.WriteLine($"{passed} Windows core checks passed.");
sealed class FixtureHandler:HttpMessageHandler
{
 public bool Fail; public List<string> UserAgents=[];
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct){
  UserAgents.Add(request.Headers.UserAgent.ToString());if(Fail)return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden));
  string data=request.RequestUri!.Query.Contains("get_vod_categories")?"[{\"category_id\":1,\"category_name\":\"Films\"}]":request.RequestUri.Query.Contains("get_vod_streams")?"[{\"stream_id\":1,\"name\":\"Film\"},{\"stream_id\":1,\"name\":\"Duplicate\"}]":"{\"user_info\":{\"auth\":1,\"status\":\"Active\"}}";
  return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(data,Encoding.UTF8,"application/json")});
 }
}

sealed class PlaylistHandler(string mode):HttpMessageHandler
{
 protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken ct){
  ct.ThrowIfCancellationRequested();if(request.Headers.UserAgent.ToString()!="Luma/0.3")throw new Exception("Wrong user agent");
  var response=new HttpResponseMessage(mode=="denied"?HttpStatusCode.Forbidden:HttpStatusCode.OK){RequestMessage=new(HttpMethod.Get,"https://cdn.example.test/redirected/list.m3u"),Content=new StringContent(mode=="html"?"<html>Login</html>":"#EXTM3U\n#EXTINF:-1,News\nvideo.ts")};
  if(mode=="large")response.Content.Headers.ContentLength=40000000;
  return Task.FromResult(response);
 }
}
