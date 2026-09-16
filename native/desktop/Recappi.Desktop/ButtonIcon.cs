using System.Windows;
using System.Windows.Media;

namespace Recappi.Desktop;

/// <summary>Optional vector icon without replacing a button's accessible text content.</summary>
public static class ButtonIcon
{
    public static readonly DependencyProperty GeometryProperty = DependencyProperty.RegisterAttached(
        "Geometry", typeof(Geometry), typeof(ButtonIcon), new PropertyMetadata(null));
    public static Geometry? GetGeometry(DependencyObject element) => (Geometry?)element.GetValue(GeometryProperty);
    public static void SetGeometry(DependencyObject element, Geometry? value) => element.SetValue(GeometryProperty, value);
    public static readonly DependencyProperty IconOnlyProperty = DependencyProperty.RegisterAttached(
        "IconOnly", typeof(bool), typeof(ButtonIcon), new PropertyMetadata(false));
    public static bool GetIconOnly(DependencyObject element) => (bool)element.GetValue(IconOnlyProperty);
    public static void SetIconOnly(DependencyObject element, bool value) => element.SetValue(IconOnlyProperty, value);
}
