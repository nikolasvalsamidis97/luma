using System.Windows;
namespace Luma.Windows;
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, args) => {
            // Never display exception messages that may contain provider URLs or passwords.
            MessageBox.Show("Luma couldn't finish this action. Please restart the app and try again.", "Luma", MessageBoxButton.OK, MessageBoxImage.Warning);
            args.Handled = true;
        };
    }
}
