using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
namespace Luma.Windows;
internal sealed class SubtitleWindow : Window
{
    public Action<int>? TrackChanged;
    public Action<double>? DelayChanged;
    public Action? Import;
    public SubtitleStyle SelectedStyle { get; private set; }
    public SubtitleWindow(SubtitleStyle style,double delay,(int Id,string Name)[] tracks,int selected)
    {
        SelectedStyle=style; Title="Subtitles"; Width=460; SizeToContent=SizeToContent.Height; ResizeMode=ResizeMode.NoResize; WindowStartupLocation=WindowStartupLocation.CenterOwner;
        var panel=new StackPanel{Margin=new Thickness(26)}; Content=panel;
        panel.Children.Add(new TextBlock{Text="Subtitles",FontSize=26,FontWeight=FontWeights.SemiBold,Margin=new Thickness(0,0,0,18)});
        void Label(string text)=>panel.Children.Add(new TextBlock{Text=text,Margin=new Thickness(0,12,0,6)});
        Label("Track");
        var choices=tracks.Select(t=>new Choice(t.Id,t.Name)).ToList(); if(choices.All(t=>t.Id!=-1)) choices.Insert(0,new(-1,"Off"));
        var track=new ComboBox{ItemsSource=choices,DisplayMemberPath="Name",SelectedItem=choices.FirstOrDefault(t=>t.Id==selected)};
        track.SelectionChanged+=(_,_)=>{if(track.SelectedItem is Choice c) TrackChanged?.Invoke(c.Id);}; panel.Children.Add(track);
        var import=new Button{Content="Open subtitle file…",Margin=new Thickness(0,10,0,0)}; import.Click+=(_,_)=>Import?.Invoke(); panel.Children.Add(import);
        Label("Size (%)"); var size=new Slider{Minimum=50,Maximum=200,Value=style.Size,TickFrequency=10,IsSnapToTickEnabled=true}; panel.Children.Add(size);
        Label("Text color (hex, e.g. FFFFFF)"); var color=new TextBox{Text=style.Color,MaxLength=7}; panel.Children.Add(color);
        Label("Background color (hex)"); var background=new TextBox{Text=style.Background,MaxLength=7}; panel.Children.Add(background);
        Label("Background opacity"); var opacity=new Slider{Minimum=0,Maximum=100,Value=style.Opacity}; panel.Children.Add(opacity);
        Label("Raise above bottom (pixels)"); var position=new Slider{Minimum=0,Maximum=360,Value=style.Position}; panel.Children.Add(position);
        Label("Delay in seconds (positive = later)"); var sync=new TextBox{Text=delay.ToString(CultureInfo.InvariantCulture)}; panel.Children.Add(sync);
        sync.TextChanged+=(_,_)=>{if(double.TryParse(sync.Text,NumberStyles.Float,CultureInfo.InvariantCulture,out double n)&&double.IsFinite(n)&&Math.Abs(n)<=60)DelayChanged?.Invoke(n);};
        var preview=new TextBlock{Text="Your next chapter starts here.",TextAlignment=TextAlignment.Center,Margin=new Thickness(0,18,0,12),Padding=new Thickness(8)}; panel.Children.Add(preview);
        void Preview(){try{preview.Foreground=new SolidColorBrush((Color)ColorConverter.ConvertFromString("#"+color.Text.TrimStart('#'))); var bg=(Color)ColorConverter.ConvertFromString("#"+background.Text.TrimStart('#'));bg.A=(byte)(opacity.Value*255/100);preview.Background=new SolidColorBrush(bg);preview.FontSize=16*size.Value/100;}catch{}}
        color.TextChanged+=(_,_)=>Preview();background.TextChanged+=(_,_)=>Preview();opacity.ValueChanged+=(_,_)=>Preview();size.ValueChanged+=(_,_)=>Preview();Preview();
        panel.Children.Add(new TextBlock{Text="Apply style briefly reloads the video at your current position. Image subtitles and embedded styling may ignore these colors.",TextWrapping=TextWrapping.Wrap,Foreground=Brushes.LightGray,FontSize=11,Margin=new Thickness(0,0,0,14)});
        var error=new TextBlock{Foreground=Brushes.Salmon,TextWrapping=TextWrapping.Wrap};panel.Children.Add(error);
        var apply=new Button{Content="Apply style",Style=(Style)FindResource("Primary")}; panel.Children.Add(apply);
        apply.Click+=(_,_)=>{string c=color.Text.Trim().TrimStart('#'),b=background.Text.Trim().TrimStart('#');if(!Regex.IsMatch(c,"^[a-fA-F0-9]{6}$")||!Regex.IsMatch(b,"^[a-fA-F0-9]{6}$")){error.Text="Use six hexadecimal digits for each color.";return;}SelectedStyle=new((int)size.Value,c,b,(int)opacity.Value,(int)position.Value);DialogResult=true;};
    }
    private sealed record Choice(int Id,string Name);
}
