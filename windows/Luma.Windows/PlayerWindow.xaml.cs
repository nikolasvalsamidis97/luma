using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using LibVLCSharp.Shared;
using Luma.Core;
using Microsoft.Win32;
namespace Luma.Windows;
public partial class PlayerWindow : Window
{
    private readonly Func<MediaItem,Uri> resolveStream;
    private readonly MediaItem title;
    private MediaItem current;
    private readonly SeriesDetails? episodes;
    private readonly Action<MediaItem,long,long,bool,MediaItem?> save;
    private LibVLC? vlc;
    private MediaPlayer? player;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private readonly DispatcherTimer clickTimer = new();
    private readonly CancellationTokenSource lifetime = new();
    private SubtitleStyle style = Storage.LoadStyle();
    private bool seeking, closing, fullscreen, finished, restorePaused;
    private long resumeAt, subtitleDelay, lastSave;
    private long? pausedSeek;
    private int resumeAttempts, selectedAudio = int.MinValue, selectedSub = int.MinValue, qualityGeneration;
    private IReadOnlyList<QualityOption> qualities = [];
    private readonly List<string> subtitleFiles = [];
    private QualityOption? selectedQuality;
    private WindowState oldState;
    private Rect oldBounds;
    [DllImport("kernel32.dll")] private static extern uint SetThreadExecutionState(uint flags);
    [DllImport("user32.dll")] private static extern uint GetDoubleClickTime();
    public PlayerWindow(Func<MediaItem,Uri> resolveStream, MediaItem title, MediaItem current, SeriesDetails? episodes, long position, Action<MediaItem,long,long,bool,MediaItem?> save)
    {
        this.resolveStream=resolveStream; this.title=title; this.current=current; this.episodes=episodes; this.save=save; resumeAt=position;
        InitializeComponent(); Loaded += (_,_) => Start(true); timer.Tick += Tick;
        clickTimer.Interval=TimeSpan.FromMilliseconds(GetDoubleClickTime());
        clickTimer.Tick+=(_,_)=>{ clickTimer.Stop(); if(!closing) Pause_Click(this,new RoutedEventArgs()); };
        Closing += (_,_) => { closing=true; lifetime.Cancel(); timer.Stop(); clickTimer.Stop(); Save(); SetThreadExecutionState(0x80000000); Video.MediaPlayer=null; player?.Stop(); player?.Dispose(); vlc?.Dispose(); };
    }
    private void Start(bool rebuild)
    {
        try {
            if (rebuild) {
                Video.MediaPlayer=null; player?.Stop(); player?.Dispose(); vlc?.Dispose();
                LibVLCSharp.Shared.Core.Initialize();
                vlc=new LibVLC(new[] { "--no-video-title-show", "--no-mouse-events", "--no-keyboard-events", "--no-osd", "--avcodec-hw=any", "--http-user-agent=Luma/0.3" }.Concat(style.Options).Concat(selectedQuality is { Height: > 0 } q ? new[] { "--adaptive-logic=highest", $"--adaptive-maxwidth={q.Width}", $"--adaptive-maxheight={q.Height}" } : Array.Empty<string>()).ToArray());
                player=new MediaPlayer(vlc) { EnableHardwareDecoding=true, Volume=(int)Volume.Value };
                var source=player;
                player.EndReached += (_,_) => Dispatcher.BeginInvoke(() => { if (!closing && player==source && source.State==VLCState.Ended) { finished=true; resumeAt=0; PlaybackStatus.Text="Finished"; Save(); NextEpisode.Visibility=episodes?.Next(current)!=null ? Visibility.Visible : Visibility.Collapsed; SetThreadExecutionState(0x80000000); } });
                player.EncounteredError += (_,_) => Dispatcher.BeginInvoke(() => { if (!closing && player==source) { PlaybackStatus.Text="This video couldn't be played. Check your connection or try another provider entry."; SetThreadExecutionState(0x80000000); } });
                Video.MediaPlayer=player;
            }
            finished=false; pausedSeek=null; resumeAttempts=0; lastSave=0; VideoTitle.Text=current.Name; PlaybackStatus.Text="Opening…"; NextEpisode.Visibility=Visibility.Collapsed;
            using var media=new Media(vlc!,resolveStream(current));
            media.AddOption(":network-caching="+(current.Kind==LibraryKind.Live ? "1500" : "4000"));
            foreach (var file in subtitleFiles) media.AddSlave(MediaSlaveType.Subtitle,4,new Uri(file));
            if (resumeAt>0) media.AddOption(":start-time="+(resumeAt/1000.0).ToString(System.Globalization.CultureInfo.InvariantCulture));
            player!.Play(media); timer.Start(); _=DiscoverQuality();
        } catch { PlaybackStatus.Text="Could not start playback. Make sure the complete Luma folder was extracted."; }
    }
    private async Task DiscoverQuality()
    {
        int version=++qualityGeneration; qualities=[]; QualityButton.Visibility=Visibility.Collapsed;
        if (!current.Extension.Equals("m3u8",StringComparison.OrdinalIgnoreCase)) return;
        try {
            using var http=new HttpClient(new HttpClientHandler{UseCookies=false}) { Timeout=TimeSpan.FromSeconds(12),MaxResponseContentBufferSize=1024*1024 };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("Luma/0.3");
            var result=HlsQuality.Parse(await http.GetStringAsync(resolveStream(current),lifetime.Token));
            if (!closing && version==qualityGeneration) { qualities=result; QualityButton.Visibility=qualities.Count>1 ? Visibility.Visible : Visibility.Collapsed; }
        } catch { /* Optional master playlist discovery must not stop playback. */ }
    }
    private void Tick(object? sender, EventArgs e)
    {
        if (player==null || closing) return;
        bool playing=player.IsPlaying;
        SetThreadExecutionState(playing ? 0x80000002u : 0x80000000u); // Display-only assertion; no simulated keyboard activity.
        if (playing && resumeAt>0 && !player.IsSeekable && resumeAttempts++>12) resumeAt=0;
        if (playing && resumeAt>0 && player.IsSeekable) {
            if (Math.Abs(player.Time-resumeAt)<2500 || resumeAttempts++>12) { resumeAt=0; ApplyTracks(); if (restorePaused) { player.SetPause(true); restorePaused=false; } }
            else player.Time=resumeAt;
        } else if (playing && resumeAt==0) { ApplyTracks(); if (restorePaused) { player.SetPause(true); restorePaused=false; } }
        long duration=Math.Max(0,player.Length), elapsed=Math.Max(0,pausedSeek ?? player.Time);
        if (!seeking) { Seek.Maximum=Math.Max(1,duration); Seek.Value=Math.Min(elapsed,Seek.Maximum); }
        Seek.IsEnabled=player.IsSeekable && duration>0;
        Elapsed.Text=FormatTime(elapsed); Duration.Text=current.Kind==LibraryKind.Live ? "LIVE" : FormatTime(duration);
        PauseButton.Content=playing ? "⏸" : "▶";
        if (player.State is VLCState.Playing or VLCState.Paused) PlaybackStatus.Text=playing ? "Playing" : "Paused";
        else if (player.State==VLCState.Buffering) PlaybackStatus.Text="Buffering…";
        NextEpisode.Visibility=episodes?.Next(current)!=null && (finished || duration>0 && elapsed>0 && duration-elapsed<=Math.Min(90000,duration/10)) ? Visibility.Visible : Visibility.Collapsed;
        if (!finished && resumeAt==0 && Environment.TickCount64-lastSave>5000) { Save(); lastSave=Environment.TickCount64; }
        if (qualities.Count==0 && player.VideoTrackDescription?.Length>1) QualityButton.Visibility=Visibility.Visible;
    }
    private void ApplyTracks()
    {
        if (player==null) return;
        if (selectedAudio!=int.MinValue && player.AudioTrackDescription.Any(t=>t.Id==selectedAudio)) { player.SetAudioTrack(selectedAudio); selectedAudio=int.MinValue; }
        if (selectedSub!=int.MinValue && (selectedSub==-1 || player.SpuDescription.Any(t=>t.Id==selectedSub))) { player.SetSpu(selectedSub); selectedSub=int.MinValue; }
        player.SetSpuDelay(subtitleDelay);
    }
    private void Save() { if (player!=null && resumeAt==0) save(current,Math.Max(0,pausedSeek ?? player.Time),Math.Max(0,player.Length),finished,episodes?.Next(current)); }
    private static string FormatTime(long ms) => TimeSpan.FromMilliseconds(ms).ToString(ms>=3600000 ? @"h\:mm\:ss" : @"m\:ss");
    private void Pause_Click(object sender,RoutedEventArgs e) { if (finished) { resumeAt=0; Start(false); } else if(player!=null) { if(!player.IsPlaying && pausedSeek is long target) { player.Time=target; pausedSeek=null; } player.Pause(); } Save(); }
    private void Back_Click(object sender,RoutedEventArgs e) => Close();
    private void Next_Click(object sender,RoutedEventArgs e)
    {
        var next=episodes?.Next(current); if (next==null) return;
        Save(); player?.Stop(); current=next; resumeAt=0; restorePaused=false; subtitleDelay=0; selectedAudio=selectedSub=int.MinValue; selectedQuality=null; subtitleFiles.Clear(); Start(true);
    }
    private void Seek_Start(object sender,MouseButtonEventArgs e) => seeking=true;
    private void Seek_End(object sender,MouseButtonEventArgs e) { if (player?.IsSeekable==true) { resumeAt=0; pausedSeek=null; player.Time=(long)Seek.Value; finished=false; } seeking=false; }
    private void Skip(int seconds) {
        if(current.Kind==LibraryKind.Live || player?.IsSeekable!=true || player.Length<=0) return;
        resumeAt=0; restorePaused=false;
        long target=Math.Clamp((pausedSeek ?? player.Time)+seconds*1000L,0,Math.Max(0,player.Length-500));
        bool paused=!player.IsPlaying;
        player.Time=target;
        if(paused) { pausedSeek=target; player.NextFrame(); Tick(null,EventArgs.Empty); }
        finished=false;
    }
    private void Video_Click(object sender,MouseButtonEventArgs e) {
        clickTimer.Stop(); ((UIElement)sender).Focus();
        if(e.ClickCount==2) ToggleFullscreen();
        else if(e.ClickCount==1) clickTimer.Start();
        e.Handled=true;
    }
    private void Volume_Changed(object sender,RoutedPropertyChangedEventArgs<double> e) { if (player!=null) player.Volume=(int)e.NewValue; }
    private void Fullscreen_Click(object sender,RoutedEventArgs e) => ToggleFullscreen();
    private void ToggleFullscreen()
    {
        if (!fullscreen) { oldState=WindowState; oldBounds=RestoreBounds; WindowState=WindowState.Normal; WindowStyle=WindowStyle.None; ResizeMode=ResizeMode.NoResize; WindowState=WindowState.Maximized; }
        else { WindowState=WindowState.Normal; WindowStyle=WindowStyle.SingleBorderWindow; ResizeMode=ResizeMode.CanResize; Left=oldBounds.Left; Top=oldBounds.Top; Width=oldBounds.Width; Height=oldBounds.Height; WindowState=oldState; }
        fullscreen=!fullscreen;
    }
    private void Player_KeyDown(object sender,KeyEventArgs e)
    {
        if(e.Handled || Keyboard.Modifiers!=ModifierKeys.None || Keyboard.FocusedElement is System.Windows.Controls.Primitives.TextBoxBase or PasswordBox or ComboBox) return;
        if (e.Key==Key.F11 || e.Key==Key.Escape && fullscreen) { ToggleFullscreen(); e.Handled=true; }
        else if (e.Key==Key.Space) { if(!e.IsRepeat) Pause_Click(sender,e); e.Handled=true; }
        else if(e.Key==Key.Left || e.Key==Key.Right) { Skip(e.Key==Key.Left ? -10 : 10); e.Handled=true; }
    }
    private void Audio_Click(object sender,RoutedEventArgs e)
    {
        if (player==null) return;
        var choices=player.AudioTrackDescription.Select(t=>new TrackChoice(t.Id,t.Name)).ToList();
        ShowSelector("Audio track",choices,player.AudioTrack,id=>player.SetAudioTrack(id));
    }
    private sealed record TrackChoice(int Id,string Name);
    private void ShowSelector(string title,IReadOnlyList<TrackChoice> choices,int selected,Action<int> apply)
    {
        var panel=new StackPanel { Margin=new Thickness(24) };
        panel.Children.Add(new TextBlock { Text=title,FontSize=22,Margin=new Thickness(0,0,0,18) });
        if (choices.Count==0) panel.Children.Add(new TextBlock {Text="No tracks are available yet.",TextWrapping=TextWrapping.Wrap});
        else { var combo=new ComboBox { ItemsSource=choices,DisplayMemberPath="Name",SelectedItem=choices.FirstOrDefault(x=>x.Id==selected),MinWidth=280 }; combo.SelectionChanged+=(_,_)=>{if(combo.SelectedItem is TrackChoice t) apply(t.Id);}; panel.Children.Add(combo); }
        new Window {Title=title,Owner=this,Content=panel,SizeToContent=SizeToContent.WidthAndHeight,WindowStartupLocation=WindowStartupLocation.CenterOwner,ResizeMode=ResizeMode.NoResize}.ShowDialog();
    }
    private void Quality_Click(object sender,RoutedEventArgs e)
    {
        if (player==null) return;
        if (qualities.Count>1) ShowSelector("Playback quality",qualities.Select(q=>new TrackChoice(q.Height,q.Label)).ToArray(),selectedQuality?.Height ?? 0,id=>{if(id!=(selectedQuality?.Height ?? 0)){selectedQuality=qualities.FirstOrDefault(q=>q.Height==id);Reload(true);}});
        else ShowSelector("Video track",player.VideoTrackDescription.Select(t=>new TrackChoice(t.Id,t.Name)).ToArray(),player.VideoTrack,id=>player.SetVideoTrack(id));
    }
    private void Reload(bool rebuild)
    {
        if (player==null) return;
        Save(); resumeAt=current.Kind==LibraryKind.Live ? 0 : Math.Max(0,pausedSeek ?? player.Time); restorePaused=!player.IsPlaying;
        selectedAudio=player.AudioTrack; selectedSub=player.Spu; player.Stop(); Start(rebuild);
    }
    private void Subtitles_Click(object sender,RoutedEventArgs e)
    {
        if (player==null) return;
        var dialog=new SubtitleWindow(style,subtitleDelay/1000000.0,player.SpuDescription.Select(t=>(t.Id,t.Name)).ToArray(),player.Spu) {Owner=this};
        dialog.TrackChanged=id=>player.SetSpu(id);
        dialog.DelayChanged=seconds=>{subtitleDelay=(long)(seconds*1000000);player.SetSpuDelay(subtitleDelay);};
        dialog.Import=()=>{var file=new OpenFileDialog {Filter="Subtitles|*.srt;*.vtt;*.ass;*.ssa|All files|*.*"}; if(file.ShowDialog(dialog)==true) { subtitleFiles.Add(file.FileName); player.AddSlave(MediaSlaveType.Subtitle,new Uri(file.FileName).AbsoluteUri,true); }};
        if(dialog.ShowDialog()==true) {style=dialog.SelectedStyle; Storage.SaveStyle(style); Reload(true);}
    }
}
