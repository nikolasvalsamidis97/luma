using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using Luma.Core;
namespace Luma.Windows;
internal static class Storage
{
    internal static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Luma");
    static Storage() => Directory.CreateDirectory(Root);
    private static void Save<T>(string name, T value)
    {
        // DPAPI binds credentials and personal library data to the current Windows login.
        byte[] encrypted = ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(value), null, DataProtectionScope.CurrentUser);
        string target = Path.Combine(Root, name), temp = target + ".tmp";
        File.WriteAllBytes(temp, encrypted); File.Move(temp, target, true);
    }
    private static T? Load<T>(string name)
    {
        try { return JsonSerializer.Deserialize<T>(ProtectedData.Unprotect(File.ReadAllBytes(Path.Combine(Root, name)), null, DataProtectionScope.CurrentUser)); }
        catch (Exception e) when (e is IOException or CryptographicException or JsonException or UnauthorizedAccessException) { return default; }
    }
    internal static SavedPlaylists LoadPlaylists() {
        string file=File.Exists(Path.Combine(Root,"connection.dat"))?"connection.dat":"account.dat";
        if(!File.Exists(Path.Combine(Root,file)))return new();
        return SavedPlaylists.Decode(ProtectedData.Unprotect(File.ReadAllBytes(Path.Combine(Root,file)),null,DataProtectionScope.CurrentUser));
    }
    internal static void SavePlaylists(SavedPlaylists value) {
        Save("connection.dat",value);
        File.Delete(Path.Combine(Root,"account.dat"));
    }
    internal static LibraryState LoadLibrary(string account) => Load<LibraryState>("library-" + account + ".dat") ?? new();
    internal static void SaveLibrary(string account, LibraryState value) => Save("library-" + account + ".dat", value);
    internal static SubtitleStyle LoadStyle() => Load<SubtitleStyle>("subtitles.dat") ?? new();
    internal static void SaveStyle(SubtitleStyle value) => Save("subtitles.dat", value);
}
internal sealed record SubtitleStyle(int Size = 100, string Color = "FFFFFF", string Background = "000000", int Opacity = 65, int Position = 0)
{
    internal string[] Options => ["--text-renderer=freetype", "--freetype-rel-fontsize=20", $"--sub-text-scale={Math.Clamp(Size,50,200)}",
        $"--freetype-color={Convert.ToInt32(Color,16)}", $"--freetype-background-color={Convert.ToInt32(Background,16)}",
        $"--freetype-background-opacity={Math.Clamp(Opacity,0,100)*255/100}", $"--sub-margin={Math.Clamp(Position,0,360)}"];
}
