using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Luma.Core;
namespace Luma.Windows;
public partial class MainWindow : Window
{
    private SavedPlaylists savedPlaylists = new();
    private string? activePlaylistId;
    private bool updatingPlaylists, connecting, savedPlaylistsReadable = true;
    private readonly CancellationTokenSource lifetime = new();
    private XtreamClient? client;
    private M3UPlaylist? playlist;
    private Uri? playlistUrl;
    private string AccountId => playlistUrl != null ? "m3u-"+M3UPlaylist.Identifier(playlistUrl.AbsoluteUri) : client!.Credentials.AccountId;
    private Task<SeriesDetails> GetSeries(MediaItem item,CancellationToken ct) => playlist != null ? Task.FromResult(playlist.Series(item)) : client!.Series(item,ct);
    private void Source_Changed(object sender,SelectionChangedEventArgs e) {
        if(XtreamFields==null||PlaylistFields==null)return;
        XtreamFields.Visibility=SourceInput.SelectedIndex==0?Visibility.Visible:Visibility.Collapsed;
        PlaylistFields.Visibility=SourceInput.SelectedIndex==1?Visibility.Visible:Visibility.Collapsed;
    }
    private LibraryState library = new();
    private LibraryKind kind = LibraryKind.Movie;
    private List<MediaItem> items = [], filtered = [];
    private CancellationTokenSource loading = new(), badges = new();
    private readonly DispatcherTimer searchTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly Dictionary<LibraryKind, (List<Category>, List<MediaItem>)> catalog = [];
    private int page, generation, opening;
    private bool demo;
    private MediaItem? series;
    private SeriesDetails? seriesDetails;
    private const int PageSize = 48;
    private void Access_Click(object sender,RoutedEventArgs e) {
        var panel=new StackPanel {Margin=new Thickness(28),Width=400};
        panel.Children.Add(new TextBlock {Text="Luma full version",FontSize=28,FontWeight=FontWeights.SemiBold,Margin=new Thickness(0,0,0,18)});
        panel.Children.Add(new TextBlock {Text="Free early access",FontSize=16,Foreground=(System.Windows.Media.Brush)FindResource("Accent"),Margin=new Thickness(0,0,0,12)});
        panel.Children.Add(new TextBlock {Text="You’re using the free Windows preview. Trials and upgrades aren’t available yet, so there’s no countdown and no payment required in this release.",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,22)});
        panel.Children.Add(new TextBlock {Text="Coming soon: 3-day free trial",FontSize=19,FontWeight=FontWeights.SemiBold,Margin=new Thickness(0,0,0,10)});
        panel.Children.Add(new TextBlock {Text="Then €4/month for the full version. No card to start. No automatic charge. Subscribe only if you choose to continue.",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,22)});
        panel.Children.Add(new TextBlock {Text="TV content and provider subscriptions are not included.",TextWrapping=TextWrapping.Wrap,FontSize=12});
        var dialog=new Window {Title="Luma access",Owner=this,Content=panel,SizeToContent=SizeToContent.WidthAndHeight,ResizeMode=ResizeMode.NoResize,WindowStartupLocation=WindowStartupLocation.CenterOwner};
        var done=new Button {Content="Done",Margin=new Thickness(0,24,0,0)}; done.Click+=(_,_)=>dialog.Close(); panel.Children.Add(done); dialog.ShowDialog();
    }
    public MainWindow()
    {
        InitializeComponent(); searchTimer.Tick += (_, _) => { searchTimer.Stop(); ApplyFilter(); };
        try {
            savedPlaylists=Storage.LoadPlaylists(); UpdatePlaylistLists();
            if(savedPlaylists.Active is {} saved) FillConnection(saved);
        } catch { savedPlaylistsReadable=false; LoginMessage.Text="Your saved playlists could not be read. Restart Luma and try again."; }
        Closed += (_, _) => { lifetime.Cancel(); loading.Cancel(); badges.Cancel(); client?.Dispose(); searchTimer.Stop(); };
    }
    private void FillConnection(SavedConnection saved) {
        PlaylistNameInput.Text=saved.DisplayName;
        if(saved.Credentials is {} c){SourceInput.SelectedIndex=0;ServerInput.Text=c.Server;UsernameInput.Text=c.Username;PasswordInput.Password=c.Password;}
        else {SourceInput.SelectedIndex=1;PlaylistInput.Password=saved.PlaylistUrl??"";}
    }
    private void UpdatePlaylistLists() {
        updatingPlaylists=true;
        PlaylistSwitcher.ItemsSource=savedPlaylists.Connections.ToList();PlaylistSwitcher.SelectedItem=savedPlaylists.Connections.FirstOrDefault(x=>x.Id==activePlaylistId);
        SavedLoginList.ItemsSource=savedPlaylists.Connections.ToList();SavedLoginList.SelectedItem=savedPlaylists.Active??savedPlaylists.Connections.FirstOrDefault();
        SavedLoginPanel.Visibility=savedPlaylists.Connections.Count>0?Visibility.Visible:Visibility.Collapsed;
        updatingPlaylists=false;
    }
    private async void Playlist_Changed(object sender,SelectionChangedEventArgs e) {
        if(updatingPlaylists||connecting||PlaylistSwitcher.SelectedItem is not SavedConnection selected||selected.Id==activePlaylistId)return;
        await ConnectSource(selected,true);
    }
    private async void OpenSaved_Click(object sender,RoutedEventArgs e) { if(SavedLoginList.SelectedItem is SavedConnection selected)await ConnectSource(selected,true); }
    private void AddPlaylist_Click(object sender,RoutedEventArgs e) {
        if(connecting)return;
        PlaylistNameInput.Clear();ServerInput.Clear();UsernameInput.Clear();PasswordInput.Clear();PlaylistInput.Clear();SourceInput.SelectedIndex=0;
        RememberInput.IsChecked=true;LoginMessage.Text="";CancelAddButton.Visibility=Visibility.Visible;LibraryPanel.Visibility=Visibility.Collapsed;LoginPanel.Visibility=Visibility.Visible;
    }
    private void CancelAdd_Click(object sender,RoutedEventArgs e) {LoginPanel.Visibility=Visibility.Collapsed;LibraryPanel.Visibility=Visibility.Visible;PasswordInput.Clear();PlaylistInput.Clear();}
    private async void Connect_Click(object sender, RoutedEventArgs e) {
        try {
            var value=SourceInput.SelectedIndex==1?new SavedConnection(null,M3UPlaylist.Url(PlaylistInput.Password).AbsoluteUri,PlaylistNameInput.Text):new SavedConnection(Credentials.Create(ServerInput.Text,UsernameInput.Text,PasswordInput.Password),null,PlaylistNameInput.Text);
            await ConnectSource(value,RememberInput.IsChecked==true);
        } catch(Exception ex) {LoginMessage.Text=SafeError(ex);}
    }
    private async Task ConnectSource(SavedConnection value,bool remember) {
        if(connecting)return;
        connecting=true;LoginPanel.IsEnabled=false;PlaylistSwitcher.IsEnabled=false;LoginMessage.Text="Connecting…";StatusMessage.Text="Connecting playlist…";
        XtreamClient? candidate=null;
        try {
            if(!savedPlaylistsReadable)throw new ProviderException("Your saved playlists could not be read. Restart Luma before changing them.");
            Uri? link=null;M3UPlaylist? loaded=null;
            if(value.PlaylistUrl is {} url){link=M3UPlaylist.Url(url);loaded=await M3UPlaylist.Load(link,lifetime.Token);}
            else {candidate=new(value.Credentials!);await candidate.Authenticate(lifetime.Token);}
            lifetime.Token.ThrowIfCancellationRequested();
            var next=savedPlaylists.Copy();var active=remember?next.Remember(value):null;if(!remember)next.ActiveID=null;
            Storage.SavePlaylists(next);
            loading.Cancel();badges.Cancel();generation++;opening++;
            client?.Dispose();client=candidate;candidate=null;playlist=loaded;playlistUrl=link;demo=false;
            savedPlaylists=next;activePlaylistId=active;UpdatePlaylistLists();
            library=Storage.LoadLibrary(AccountId);AccountLabel.Text=savedPlaylists.Active?.DisplayName??value.DisplayName;FavoritesOnly.IsChecked=false;
            catalog.Clear();LoginPanel.Visibility=Visibility.Collapsed;LibraryPanel.Visibility=Visibility.Visible;CancelAddButton.Visibility=Visibility.Collapsed;
            PasswordInput.Clear();PlaylistInput.Clear();await LoadLibrary(link!=null?LibraryKind.Live:LibraryKind.Movie);
        } catch(OperationCanceledException) when(lifetime.IsCancellationRequested) {}
        catch(Exception ex) {LoginMessage.Text=ex is ProviderException?ex.Message:"Could not connect or save this playlist. Please try again.";StatusMessage.Text=LoginMessage.Text;UpdatePlaylistLists();}
        finally {candidate?.Dispose();connecting=false;LoginPanel.IsEnabled=true;PlaylistSwitcher.IsEnabled=true;}
    }
    private void ManagePlaylists_Click(object sender,RoutedEventArgs e) {
        if(connecting||!savedPlaylistsReadable)return;
        var manager=new PlaylistManagerWindow(savedPlaylists,activePlaylistId,(id,name)=>{
            var next=savedPlaylists.Copy();next.Rename(id,name);Storage.SavePlaylists(next);savedPlaylists=next;UpdatePlaylistLists();
            if(id==activePlaylistId)AccountLabel.Text=savedPlaylists.Active?.DisplayName??name;
        },id=>{
            var next=savedPlaylists.Copy();next.Remove(id);Storage.SavePlaylists(next);savedPlaylists=next;
            if(id==activePlaylistId)Disconnect();else UpdatePlaylistLists();
        }) {Owner=this};manager.ShowDialog();
    }
    private async void Demo_Click(object sender, RoutedEventArgs e)
    {
        client?.Dispose(); client=null; playlist=null; playlistUrl=null; activePlaylistId=null;UpdatePlaylistLists();demo = true; library = new(); catalog.Clear(); AccountLabel.Text = "Preview · fictional library";
        LoginPanel.Visibility = Visibility.Collapsed; LibraryPanel.Visibility = Visibility.Visible; await LoadLibrary(LibraryKind.Movie);
    }
    private async void Navigate_Click(object sender, RoutedEventArgs e) => await LoadLibrary(Enum.Parse<LibraryKind>((string)((Button)sender).Tag));
    private async Task LoadLibrary(LibraryKind selected, bool force = false)
    {
        loading.Cancel(); loading = new(); badges.Cancel(); var ct = loading.Token; int version = ++generation;
        opening++;
        if(force && client!=null){var credentials=client.Credentials;client.Dispose();client=new(credentials);catalog.Clear();}
        kind = selected; page = 0; series = null; seriesDetails = null; EpisodesPanel.Visibility = Visibility.Collapsed; BrowsePanel.Visibility = Visibility.Visible;
        SectionTitle.Text = kind == LibraryKind.Live ? "Live TV" : kind == LibraryKind.Movie ? "Movies" : "Series";
        StatusMessage.Text = "Loading library…"; Cards.ItemsSource = null; SearchInput.Text = ""; items = [];
        UpdateShelves();
        try {
            (List<Category> Categories, List<MediaItem> Items) result;
            if (demo) result = ([], Enumerable.Range(1, 12).Select(i => new MediaItem { StreamId = i.ToString(), Kind = kind, Name = new[] { "Northern Lights", "The Long Weekend", "Beyond the Coast", "Quiet City" }[(i - 1) % 4] + (i > 4 ? $" · {i}" : ""), Rating = "8", Resolution = i % 3 == 0 ? "4K" : "1080p", MultiSub = i % 2 == 0 }).ToList());
            else if (!force && catalog.TryGetValue(kind, out var cached)) result = cached;
            else {
                if(playlistUrl!=null){
                    var loaded=force||playlist==null?await M3UPlaylist.Load(playlistUrl,ct):playlist;
                    if(version!=generation||ct.IsCancellationRequested)return;
                    playlist=loaded;catalog.Clear();result=loaded.Library(kind);
                } else result=await client!.Library(kind,ct);
                if(version==generation)catalog[kind]=result;
            }
            if (version != generation || ct.IsCancellationRequested) return;
            items = result.Items; CategoryList.ItemsSource = new[] { new Category("", "All " + SectionTitle.Text.ToLowerInvariant()) }.Concat(result.Categories); CategoryList.SelectedIndex = 0;
            StatusMessage.Text = demo ? "Preview library — these are fictional titles. Connect your account to watch." : ""; ApplyFilter();
        } catch (OperationCanceledException) { }
        catch (Exception ex) { if (version == generation) StatusMessage.Text = SafeError(ex); }
    }
    private static string SafeError(Exception ex) => ex is ProviderException ? ex.Message : "This action couldn't be completed. Please try again.";
    private void ApplyFilter()
    {
        if (!IsInitialized) return;
        var category = (CategoryList.SelectedItem as Category)?.Id ?? ""; var query = SearchInput.Text.Trim();
        IEnumerable<MediaItem> source = items.Where(i => (category == "" || i.CategoryId == category) && i.Name.Contains(query, StringComparison.CurrentCultureIgnoreCase) && (FavoritesOnly.IsChecked != true || library.Favorites.Contains(i.Id)));
        if (Alphabetical.IsChecked == true) source = source.OrderBy(i => i.Name, StringComparer.CurrentCultureIgnoreCase);
        filtered = source.ToList(); page = 0; ShowPage();
    }
    private async void ShowPage()
    {
        badges.Cancel(); badges = new(); var ct = badges.Token;
        int count = Math.Max(1, (filtered.Count + PageSize - 1) / PageSize); page = Math.Clamp(page, 0, count - 1);
        var visible = filtered.Skip(page * PageSize).Take(PageSize).ToList(); Cards.ItemsSource = visible;
        ResultsLabel.Text = filtered.Count == 0 ? "No titles found" : $"Explore {SectionTitle.Text.ToLowerInvariant()} · {filtered.Count:N0}";
        PageLabel.Text = $"{page + 1} / {count}"; PreviousPage.IsEnabled = page > 0; NextPage.IsEnabled = page + 1 < count;
        BrowsePanel.ScrollToTop();
        if (kind != LibraryKind.Series) return;
        foreach (var item in visible) {
            if (ct.IsCancellationRequested) break;
            if (demo) { item.SeasonBadge = "2 seasons"; continue; }
            try { var detail = await GetSeries(item, ct); if (!ct.IsCancellationRequested) item.SeasonBadge = detail.Badge; }
            catch (OperationCanceledException) { break; }
            catch { item.SeasonBadge = "Retry seasons"; }
        }
    }
    private void Search_Changed(object sender, TextChangedEventArgs e) { if (!IsInitialized) return; searchTimer.Stop(); searchTimer.Start(); }
    private void Category_Changed(object sender, SelectionChangedEventArgs e) => ApplyFilter();
    private void Filter_Changed(object sender, RoutedEventArgs e) => ApplyFilter();
    private void Previous_Click(object sender, RoutedEventArgs e) { page--; ShowPage(); }
    private void Next_Click(object sender, RoutedEventArgs e) { page++; ShowPage(); }
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await LoadLibrary(kind, true);
    private async void Open_Click(object sender, RoutedEventArgs e) { if (((Button)sender).Tag is MediaItem item) await Open(item); }
    private async Task Open(MediaItem item)
    {
        if (demo) { StatusMessage.Text = "Connect your own provider account to play video."; return; }
        if (item.Kind != LibraryKind.Series) { Play(item, item, null, library.Progress.FirstOrDefault(p => p.Title.Id == item.Id)?.Position ?? 0); return; }
        badges.Cancel(); var token = loading.Token; int version = generation, request = ++opening; StatusMessage.Text = "Loading episodes…";
        try {
            var detail = await GetSeries(item, token); if (version != generation || request != opening || token.IsCancellationRequested) return;
            series = item; seriesDetails = detail; item.SeasonBadge = detail.Badge;
            BrowsePanel.Visibility = Visibility.Collapsed; EpisodesPanel.Visibility = Visibility.Visible; SeriesTitle.Text = item.Name;
            SeasonList.ItemsSource = detail.Episodes.Select(x => x.Season).Distinct().Select(s => new SeasonOption(s, s == 0 ? "Specials" : s == null ? "Unnumbered episodes" : $"Season {s}")); SeasonList.SelectedIndex = 0;
            StatusMessage.Text = detail.Episodes.Count == 0 ? "No episodes are listed for this title." : "";
        } catch (OperationCanceledException) { }
        catch (Exception ex) { if (version == generation) StatusMessage.Text = SafeError(ex); }
    }
    private sealed record SeasonOption(int? Number, string Name);
    private void Season_Changed(object sender, SelectionChangedEventArgs e) { if (SeasonList.SelectedItem is SeasonOption option) EpisodesList.ItemsSource = seriesDetails?.Episodes.Where(x => x.Season == option.Number).ToList(); }
    private void Episode_Click(object sender, RoutedEventArgs e) { if (((Button)sender).Tag is MediaItem ep && series != null) Play(series, ep, seriesDetails, library.Progress.FirstOrDefault(p => p.Title.Id == series.Id && p.Playing.Id == ep.Id)?.Position ?? 0); }
    private void Play(MediaItem title, MediaItem item, SeriesDetails? details, long position)
    {
        if (client == null && playlist == null) return;
        try {
            badges.Cancel();
            Func<MediaItem,Uri> resolve=playlist is {} p?p.Stream:client!.Credentials.Stream;
            // Resolve before opening so removed playlist entries produce a useful error.
            _=resolve(item);
            var player = new PlayerWindow(resolve, title, item, details, position, (playing, time, duration, finished, next) => {
                library.SaveProgress(title, playing, time, duration, finished, next); SaveLibrary();
            }) { Owner = this };
            player.ShowDialog(); UpdateShelves();
        } catch(ProviderException ex) {StatusMessage.Text=ex.Message;}
        catch { StatusMessage.Text = "The player could not start. Extract the complete Luma folder and try again."; }
    }
    private async void Resume_Click(object sender, RoutedEventArgs e)
    {
        if (((Button)sender).Tag is not ProgressEntry progress || demo) return;
        if (progress.Title.Kind == LibraryKind.Series) { await Open(progress.Title); if (series?.Id != progress.Title.Id || seriesDetails == null) return; var ep = seriesDetails.Episodes.FirstOrDefault(x => x.Id == progress.Playing.Id); if (ep == null) { StatusMessage.Text = "That episode is no longer listed by your provider."; return; } SeasonList.SelectedItem = SeasonList.Items.Cast<SeasonOption>().FirstOrDefault(s => s.Number == ep.Season); Play(progress.Title, ep, seriesDetails, progress.Position); }
        else Play(progress.Title, progress.Playing, null, progress.Position);
    }
    private void BackToLibrary_Click(object sender, RoutedEventArgs e) { EpisodesPanel.Visibility = Visibility.Collapsed; BrowsePanel.Visibility = Visibility.Visible; StatusMessage.Text = ""; }
    private void Watchlist_Click(object sender, RoutedEventArgs e)
    {
        if (((Button)sender).Tag is not MediaItem item || item.Kind == LibraryKind.Live) return;
        if (library.Watchlist.Any(x => x.Id == item.Id)) library.Watchlist.RemoveAll(x => x.Id == item.Id);
        else { library.Watchlist.Insert(0, item); if (library.Watchlist.Count > 500) library.Watchlist.RemoveAt(500); }
        SaveLibrary(); UpdateShelves();
    }
    private void Favorite_Click(object sender, RoutedEventArgs e) { if (((Button)sender).Tag is MediaItem item) { if (!library.Favorites.Add(item.Id)) library.Favorites.Remove(item.Id); SaveLibrary(); ((Button)sender).Content = library.Favorites.Contains(item.Id) ? "♥" : "♡"; if (FavoritesOnly.IsChecked == true) ApplyFilter(); } }
    private void RemoveProgress_Click(object sender, RoutedEventArgs e) { if (((Button)sender).Tag is ProgressEntry p) { library.Progress.RemoveAll(x => x.Title.Id == p.Title.Id); SaveLibrary(); UpdateShelves(); } }
    private void SaveLibrary() { if (!demo && (client != null || playlist != null)) try { Storage.SaveLibrary(AccountId, library); } catch { StatusMessage.Text = "Your progress couldn't be saved on this PC."; } }
    private void UpdateShelves()
    {
        Shelves.Visibility = kind == LibraryKind.Live ? Visibility.Collapsed : Visibility.Visible;
        var progress = library.Progress.Where(x => x.Title.Kind == kind).ToList(); var watchlist = library.Watchlist.Where(x => x.Kind == kind).ToList();
        ContinueList.ItemsSource = progress; WatchlistList.ItemsSource = watchlist; ContinueEmpty.Visibility = progress.Count == 0 ? Visibility.Visible : Visibility.Collapsed; WatchlistEmpty.Visibility = watchlist.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    private void SignOut_Click(object sender, RoutedEventArgs e) {
        if(connecting)return;
        try {var next=savedPlaylists.Copy();next.ActiveID=null;Storage.SavePlaylists(next);savedPlaylists=next;Disconnect();}
        catch {StatusMessage.Text="Could not save your playlist settings. Please try again.";}
    }
    private void Disconnect() {
        loading.Cancel();badges.Cancel();generation++;opening++;client?.Dispose();client=null;playlist=null;playlistUrl=null;activePlaylistId=null;demo=false;
        catalog.Clear();library=new();items.Clear();series=null;seriesDetails=null;UpdatePlaylistLists();
        PasswordInput.Clear();PlaylistInput.Clear();LoginMessage.Text="";CancelAddButton.Visibility=Visibility.Collapsed;LibraryPanel.Visibility=Visibility.Collapsed;LoginPanel.Visibility=Visibility.Visible;
    }
}
