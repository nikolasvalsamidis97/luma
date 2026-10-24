using System.Globalization;
using System.Windows.Data;
using System.Windows.Media.Imaging;
namespace Luma.Windows;
public sealed class PosterConverter : IValueConverter
{
    public object? Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        if (value is not string text || !Uri.TryCreate(text,UriKind.Absolute,out var uri) || (uri.Scheme!="https"&&uri.Scheme!="http")) return null;
        try { var bitmap=new BitmapImage();bitmap.BeginInit();bitmap.DecodePixelWidth=340;bitmap.UriSource=uri;bitmap.EndInit();return bitmap; } catch { return null; }
    }
    public object ConvertBack(object value,Type targetType,object parameter,CultureInfo culture) => throw new NotSupportedException();
}
