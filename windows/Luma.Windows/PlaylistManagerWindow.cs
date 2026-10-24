using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Luma.Core;
namespace Luma.Windows;
public sealed class PlaylistManagerWindow : Window
{
    public PlaylistManagerWindow(SavedPlaylists playlists,string? active,Action<string,string> rename,Action<string> remove)
    {
        Title="Your playlists";Width=620;Height=440;WindowStartupLocation=WindowStartupLocation.CenterOwner;
        var layout=new DockPanel{Margin=new Thickness(24)};Content=layout;
        var heading=new TextBlock{Text="Your playlists",FontSize=24,Margin=new Thickness(0,0,0,16)};DockPanel.SetDock(heading,Dock.Top);layout.Children.Add(heading);
        var done=new Button{Content="Done",HorizontalAlignment=HorizontalAlignment.Right,Margin=new Thickness(0,16,0,0)};done.Click+=(_,_)=>Close();DockPanel.SetDock(done,Dock.Bottom);layout.Children.Add(done);
        var error=new TextBlock{Foreground=Brushes.Coral,TextWrapping=TextWrapping.Wrap};DockPanel.SetDock(error,Dock.Bottom);layout.Children.Add(error);
        var rows=new StackPanel();layout.Children.Add(new ScrollViewer{Content=rows,VerticalScrollBarVisibility=ScrollBarVisibility.Auto});
        if(playlists.Connections.Count==0)rows.Children.Add(new TextBlock{Text="No saved playlists yet. Use Add playlist to connect one."});
        foreach(var playlist in playlists.Connections.ToList()) {
            var row=new DockPanel{Margin=new Thickness(0,0,0,14)};
            var delete=new Button{Content="Remove",Margin=new Thickness(8,0,0,0)};DockPanel.SetDock(delete,Dock.Right);row.Children.Add(delete);
            var save=new Button{Content="Save name",Margin=new Thickness(8,0,0,0)};DockPanel.SetDock(save,Dock.Right);row.Children.Add(save);
            var info=new StackPanel();var name=new TextBox{Text=playlist.DisplayName};info.Children.Add(name);info.Children.Add(new TextBlock{Text=playlist.SourceType+(playlist.Id==active?" · Current playlist":""),FontSize=11,Foreground=Brushes.Gray,Margin=new Thickness(0,6,0,0)});row.Children.Add(info);rows.Children.Add(row);
            save.Click+=(_,_)=>{try{rename(playlist.Id!,name.Text);error.Text="";}catch{error.Text="The playlist name couldn't be saved. Please try again.";}};
            delete.Click+=(_,_)=>{try{remove(playlist.Id!);rows.Children.Remove(row);error.Text="";}catch{error.Text="The playlist couldn't be removed. Please try again.";}};
        }
    }
}
