using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;

namespace Recappi.WinUI;

// App-wide design tokens and control templates. Colors mirror the macOS palette
// (RecappiMini/Views/Theme/ThemePalette.swift) so both apps share one brand;
// light/dark values switch through ThemeResource with each window's theme.
internal static class RecappiTheme
{
    private static readonly (string Key, uint Light, uint Dark)[] Tokens =
    [
        ("RecappiSurfacePanel", 0xFFFFFFFF, 0xFF2D2D2D),
        ("RecappiChipFill", 0x8CEFEFF1, 0x8C424242),
        ("RecappiChipHover", 0xBFEFEFF1, 0xBF424242),
        ("RecappiBorderHairline", 0x1A000000, 0x0FFFFFFF),
        ("RecappiBorderSubtle", 0x24000000, 0x1AFFFFFF),
        ("RecappiControlHover", 0x0D000000, 0x12FFFFFF),
        ("RecappiControlPress", 0x14000000, 0x1FFFFFFF),
        ("RecappiNeutralFill", 0x09000000, 0x12FFFFFF),
        // Floating-pill text keeps higher minimum contrast than page labels.
        ("RecappiTextPrimary", 0xF2000000, 0xF2FFFFFF),
        ("RecappiTextSecondary", 0xC7000000, 0xCCFFFFFF),
        ("RecappiTextTertiary", 0x9E000000, 0xA3FFFFFF),
        // Light surfaces need the deeper green; dark surfaces the brighter one.
        ("RecappiAccent", 0xFF047857, 0xFF34D399),
        ("RecappiAccentSoftFill", 0x12047857, 0x1F34D399),
        ("RecappiAccentStroke", 0x29047857, 0x3834D399),
        ("RecappiAccentChipFill", 0x1F047857, 0x1F34D399),
        ("RecappiAccentChipHover", 0x33047857, 0x3334D399),
        ("RecappiRecord", 0xFFFF453A, 0xFFFF453A),
        ("RecappiRecordHover", 0xFFFF3B30, 0xFFFF3B30),
        ("RecappiRecordStroke", 0x42FFFFFF, 0x42FFFFFF),
        ("RecappiDanger", 0xFFD70015, 0xFFFF6961),
        ("RecappiDangerFill", 0x12FF453A, 0x1FFF453A),
        ("RecappiDangerHover", 0x24FF453A, 0x33FF453A),
        ("RecappiDangerStroke", 0x38FF453A, 0x47FF453A),
        ("RecappiWarning", 0xFFC2410C, 0xFFF2754F),
        ("RecappiWaveUnlit", 0x38111827, 0x33FFFFFF),
        // Recorder glass: a light legibility fill over acrylic, as on macOS.
        ("RecappiGlassFill", 0x29FFFFFF, 0x47000000),
        ("RecappiGlassEdge", 0xFFDADADD, 0xFF3F3F42),
        // Live captions: a fixed dark subtitle scrim and white text in both themes.
        ("RecappiCaptionScrim", 0x8C000000, 0x8C000000),
        ("RecappiCaptionText", 0xF5FFFFFF, 0xF5FFFFFF),
        ("RecappiCaptionTextSecondary", 0xC7FFFFFF, 0xC7FFFFFF),
        ("RecappiCaptionTextMuted", 0x99FFFFFF, 0x99FFFFFF),
        // Page windows (library, settings, account, onboarding).
        ("RecappiSurfaceWindow", 0xFFF7F7F8, 0xFF1C1C1C),
        ("RecappiSurfaceCard", 0xFFFFFFFF, 0xFF262626),
        ("RecappiSurfaceLiveCaption", 0xFFF2F2F4, 0xFF333333),
        ("RecappiCardSubtle", 0x06000000, 0x05FFFFFF),
        ("RecappiCardSubtleActive", 0x0C000000, 0x0FFFFFFF),
        ("RecappiLabel", 0xEB000000, 0xEBFFFFFF),
        ("RecappiLabelSecondary", 0x99000000, 0x9EFFFFFF),
        ("RecappiLabelTertiary", 0x66000000, 0x61FFFFFF),
        ("RecappiButtonFill", 0xFFFFFFFF, 0x0FFFFFFF),
        ("RecappiButtonHover", 0xFFF4F4F6, 0x17FFFFFF),
        ("RecappiButtonPress", 0xFFECECEF, 0x0AFFFFFF),
        ("RecappiAccentHover", 0xFF065F46, 0xFF6EE7B7),
        ("RecappiOnAccent", 0xFFFFFFFF, 0xFF052E1F),
        // NavigationView lightweight styling: the pane sits on the window surface.
        ("NavigationViewDefaultPaneBackground", 0x00000000, 0x00000000),
        ("NavigationViewExpandedPaneBackground", 0x00000000, 0x00000000),
        ("NavigationViewTopPaneBackground", 0x00000000, 0x00000000),
        ("NavigationViewContentBackground", 0xFFFFFFFF, 0xFF262626),
        ("NavigationViewContentGridBorderBrush", 0x1A000000, 0x0FFFFFFF),
    ];
    // WinUI's own controls (TextBox focus, ToggleSwitch, SelectorBar, ListView,
    // NavigationView indicators) read these keys; override them with the brand.
    private static readonly (string Key, uint Light, uint Dark)[] SystemColors =
    [
        ("SystemAccentColor", 0xFF059669, 0xFF10B981),
        ("SystemAccentColorLight1", 0xFF10B981, 0xFF34D399),
        ("SystemAccentColorLight2", 0xFF34D399, 0xFF34D399),
        ("SystemAccentColorLight3", 0xFF6EE7B7, 0xFF6EE7B7),
        ("SystemAccentColorDark1", 0xFF047857, 0xFF059669),
        ("SystemAccentColorDark2", 0xFF065F46, 0xFF047857),
        ("SystemAccentColorDark3", 0xFF064E3B, 0xFF065F46),
    ];
    private static ResourceDictionary? dictionary;
    private static bool merged;

    public static void Ensure()
    {
        if (merged) return;
        dictionary = (ResourceDictionary)Microsoft.UI.Xaml.Markup.XamlReader.Load(Build());
        Application.Current.Resources.MergedDictionaries.Add(dictionary);
        merged = true;
    }
    // Code-built elements cannot use ThemeResource markup; follow the element's theme instead.
    public static Brush Brush(string key, ElementTheme theme)
    {
        Ensure();
        return (Brush)((ResourceDictionary)dictionary!.ThemeDictionaries[theme == ElementTheme.Light ? "Light" : "Dark"])[key];
    }
    public static void Bind(FrameworkElement element, string key, Action<Brush> apply)
    {
        apply(Brush(key, element.ActualTheme));
        element.ActualThemeChanged += (sender, _) => apply(Brush(key, sender.ActualTheme));
    }
    public static Style Style(string key) { Ensure(); return (Style)Application.Current.Resources[key]; }

    private static string Build()
    {
        var xaml = new StringBuilder("<ResourceDictionary xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'><ResourceDictionary.ThemeDictionaries>");
        // "Default" is the dark fallback, including high contrast.
        foreach (var (theme, light) in new[] { ("Light", true), ("Dark", false), ("Default", false) })
        {
            xaml.Append($"<ResourceDictionary x:Key='{theme}'>");
            foreach (var token in Tokens) xaml.Append($"<SolidColorBrush x:Key='{token.Key}' Color='#{(light ? token.Light : token.Dark):X8}'/>");
            foreach (var token in SystemColors) xaml.Append($"<Color x:Key='{token.Key}'>#{(light ? token.Light : token.Dark):X8}</Color>");
            xaml.Append("</ResourceDictionary>");
        }
        xaml.Append("</ResourceDictionary.ThemeDictionaries>");
        xaml.Append("<CornerRadius x:Key='ControlCornerRadius'>6</CornerRadius><CornerRadius x:Key='OverlayCornerRadius'>10</CornerRadius>");
        xaml.Append(Styles);
        return xaml.Append("</ResourceDictionary>").ToString();
    }

    private const string Presenter = "<ContentPresenter x:Name='Presenter' Content='{TemplateBinding Content}' ContentTemplate='{TemplateBinding ContentTemplate}' Foreground='{TemplateBinding Foreground}' Padding='{TemplateBinding Padding}' HorizontalContentAlignment='{TemplateBinding HorizontalContentAlignment}' VerticalContentAlignment='{TemplateBinding VerticalContentAlignment}'/>";

    private static string ButtonStyle(string key, string target, string setters, string hover, string press, string disabled = "<Setter Target='Root.Opacity' Value='0.4'/>") => $@"
<Style x:Key='{key}' TargetType='{target}'>
  <Setter Property='UseSystemFocusVisuals' Value='True'/>
  <Setter Property='Padding' Value='0'/>
  <Setter Property='HorizontalContentAlignment' Value='Center'/>
  <Setter Property='VerticalContentAlignment' Value='Center'/>
  <Setter Property='CornerRadius' Value='6'/>
  <Setter Property='BorderThickness' Value='0'/>
  <Setter Property='Background' Value='Transparent'/>
  <Setter Property='BorderBrush' Value='Transparent'/>
  {setters}
  <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='{target}'>
    <Grid x:Name='Root' Background='{{TemplateBinding Background}}' BorderBrush='{{TemplateBinding BorderBrush}}' BorderThickness='{{TemplateBinding BorderThickness}}' CornerRadius='{{TemplateBinding CornerRadius}}'>
      <VisualStateManager.VisualStateGroups><VisualStateGroup x:Name='CommonStates'>
        <VisualState x:Name='Normal'/>
        <VisualState x:Name='PointerOver'><VisualState.Setters>{hover}</VisualState.Setters></VisualState>
        <VisualState x:Name='Pressed'><VisualState.Setters>{press}</VisualState.Setters></VisualState>
        <VisualState x:Name='Disabled'><VisualState.Setters>{disabled}</VisualState.Setters></VisualState>
      </VisualStateGroup></VisualStateManager.VisualStateGroups>
      {Presenter}
    </Grid>
  </ControlTemplate></Setter.Value></Setter>
</Style>";

    private static string Text(string key, string brush, double size, string extra = "") => $@"
<Style x:Key='{key}' TargetType='TextBlock'>
  <Setter Property='Foreground' Value='{{ThemeResource {brush}}}'/>
  <Setter Property='FontSize' Value='{size}'/>
  <Setter Property='VerticalAlignment' Value='Center'/>
  <Setter Property='TextTrimming' Value='CharacterEllipsis'/>
  <Setter Property='TextWrapping' Value='NoWrap'/>
  {extra}
</Style>";

    private static string Icon(string key, string brush) => $@"
<Style x:Key='{key}' TargetType='FontIcon'><Setter Property='Foreground' Value='{{ThemeResource {brush}}}'/></Style>";

    private static string Fill(string key, string brush) => $@"
<Style x:Key='{key}' TargetType='Ellipse'><Setter Property='Fill' Value='{{ThemeResource {brush}}}'/></Style>";

    private static readonly string Styles =
        ButtonStyle("RecappiIconButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiTextSecondary}'/><Setter Property='Width' Value='28'/><Setter Property='Height' Value='28'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiControlHover}'/><Setter Target='Presenter.Foreground' Value='{ThemeResource RecappiTextPrimary}'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiControlPress}'/><Setter Target='Presenter.Foreground' Value='{ThemeResource RecappiTextPrimary}'/>") +
        ButtonStyle("RecappiChipButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiTextPrimary}'/><Setter Property='Background' Value='{ThemeResource RecappiChipFill}'/><Setter Property='BorderBrush' Value='{ThemeResource RecappiBorderSubtle}'/><Setter Property='BorderThickness' Value='1'/><Setter Property='Height' Value='28'/><Setter Property='FontSize' Value='12'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiChipHover}'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiControlPress}'/>") +
        ButtonStyle("RecappiDangerChipButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiDanger}'/><Setter Property='Background' Value='{ThemeResource RecappiDangerFill}'/><Setter Property='BorderBrush' Value='{ThemeResource RecappiDangerStroke}'/><Setter Property='BorderThickness' Value='1'/><Setter Property='Height' Value='24'/><Setter Property='Padding' Value='9,0'/><Setter Property='FontSize' Value='12'/><Setter Property='FontWeight' Value='SemiBold'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiDangerHover}'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiDangerHover}'/>") +
        ButtonStyle("RecappiAccentChipButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiAccent}'/><Setter Property='Background' Value='{ThemeResource RecappiAccentChipFill}'/><Setter Property='Height' Value='24'/><Setter Property='Padding' Value='10,0'/><Setter Property='CornerRadius' Value='12'/><Setter Property='FontSize' Value='12'/><Setter Property='FontWeight' Value='SemiBold'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiAccentChipHover}'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiAccentChipHover}'/>") +
        ButtonStyle("RecappiQuietButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiTextSecondary}'/><Setter Property='Height' Value='24'/><Setter Property='Padding' Value='6,0'/><Setter Property='FontSize' Value='12'/>",
            "<Setter Target='Presenter.Foreground' Value='{ThemeResource RecappiTextPrimary}'/><Setter Target='Root.Background' Value='{ThemeResource RecappiControlHover}'/>",
            "<Setter Target='Presenter.Foreground' Value='{ThemeResource RecappiTextPrimary}'/><Setter Target='Root.Background' Value='{ThemeResource RecappiControlPress}'/>") +
        ButtonStyle("RecappiMenuButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiTextPrimary}'/><Setter Property='HorizontalAlignment' Value='Stretch'/><Setter Property='HorizontalContentAlignment' Value='Left'/><Setter Property='Height' Value='32'/><Setter Property='Padding' Value='10,0'/><Setter Property='FontSize' Value='13'/><Setter Property='CornerRadius' Value='4'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiControlHover}'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiControlPress}'/>") + $@"
<Style x:Key='RecappiRecordButton' TargetType='Button'>
  <Setter Property='UseSystemFocusVisuals' Value='True'/>
  <Setter Property='Width' Value='28'/><Setter Property='Height' Value='28'/>
  <Setter Property='Padding' Value='0'/>
  <Setter Property='CornerRadius' Value='14'/>
  <Setter Property='Foreground' Value='White'/>
  <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='Button'>
    <Grid x:Name='Root' RenderTransformOrigin='0.5,0.5'>
      <Grid.RenderTransform><ScaleTransform x:Name='Scale'/></Grid.RenderTransform>
      <VisualStateManager.VisualStateGroups><VisualStateGroup x:Name='CommonStates'>
        <VisualState x:Name='Normal'/>
        <VisualState x:Name='PointerOver'><VisualState.Setters><Setter Target='Disc.Fill' Value='{{ThemeResource RecappiRecordHover}}'/><Setter Target='Scale.ScaleX' Value='1.04'/><Setter Target='Scale.ScaleY' Value='1.04'/></VisualState.Setters></VisualState>
        <VisualState x:Name='Pressed'><VisualState.Setters><Setter Target='Disc.Fill' Value='{{ThemeResource RecappiRecordHover}}'/><Setter Target='Scale.ScaleX' Value='0.94'/><Setter Target='Scale.ScaleY' Value='0.94'/></VisualState.Setters></VisualState>
        <VisualState x:Name='Disabled'><VisualState.Setters><Setter Target='Root.Opacity' Value='0.45'/></VisualState.Setters></VisualState>
      </VisualStateGroup></VisualStateManager.VisualStateGroups>
      <Ellipse x:Name='Disc' Fill='{{ThemeResource RecappiRecord}}' Stroke='{{ThemeResource RecappiRecordStroke}}' StrokeThickness='1'/>
      {Presenter}
    </Grid>
  </ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key='RecappiToggleButton' TargetType='ToggleButton'>
  <Setter Property='UseSystemFocusVisuals' Value='True'/>
  <Setter Property='Width' Value='28'/><Setter Property='Height' Value='28'/>
  <Setter Property='Padding' Value='0'/>
  <Setter Property='HorizontalContentAlignment' Value='Center'/>
  <Setter Property='VerticalContentAlignment' Value='Center'/>
  <Setter Property='CornerRadius' Value='6'/>
  <Setter Property='BorderThickness' Value='1'/>
  <Setter Property='Background' Value='{{ThemeResource RecappiNeutralFill}}'/>
  <Setter Property='BorderBrush' Value='{{ThemeResource RecappiBorderHairline}}'/>
  <Setter Property='Foreground' Value='{{ThemeResource RecappiTextTertiary}}'/>
  <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ToggleButton'>
    <Grid x:Name='Root' Background='{{TemplateBinding Background}}' BorderBrush='{{TemplateBinding BorderBrush}}' BorderThickness='{{TemplateBinding BorderThickness}}' CornerRadius='{{TemplateBinding CornerRadius}}'>
      <VisualStateManager.VisualStateGroups><VisualStateGroup x:Name='CommonStates'>
        <VisualState x:Name='Normal'/>
        <VisualState x:Name='PointerOver'><VisualState.Setters><Setter Target='Root.Background' Value='{{ThemeResource RecappiControlHover}}'/><Setter Target='Presenter.Foreground' Value='{{ThemeResource RecappiTextSecondary}}'/></VisualState.Setters></VisualState>
        <VisualState x:Name='Pressed'><VisualState.Setters><Setter Target='Root.Background' Value='{{ThemeResource RecappiControlPress}}'/></VisualState.Setters></VisualState>
        <VisualState x:Name='Disabled'><VisualState.Setters><Setter Target='Root.Opacity' Value='0.4'/></VisualState.Setters></VisualState>
        <VisualState x:Name='Checked'><VisualState.Setters>{CheckedSetters}</VisualState.Setters></VisualState>
        <VisualState x:Name='CheckedPointerOver'><VisualState.Setters>{CheckedSetters}<Setter Target='Root.Background' Value='{{ThemeResource RecappiAccentChipFill}}'/></VisualState.Setters></VisualState>
        <VisualState x:Name='CheckedPressed'><VisualState.Setters>{CheckedSetters}<Setter Target='Root.Background' Value='{{ThemeResource RecappiAccentChipHover}}'/></VisualState.Setters></VisualState>
        <VisualState x:Name='CheckedDisabled'><VisualState.Setters>{CheckedSetters}<Setter Target='Root.Opacity' Value='0.4'/></VisualState.Setters></VisualState>
      </VisualStateGroup></VisualStateManager.VisualStateGroups>
      {Presenter}
      <Ellipse x:Name='LiveDot' Width='6' Height='6' Margin='0,2,2,0' HorizontalAlignment='Right' VerticalAlignment='Top' Fill='{{ThemeResource RecappiAccent}}' Stroke='{{ThemeResource RecappiSurfacePanel}}' StrokeThickness='1' Visibility='Collapsed'/>
    </Grid>
  </ControlTemplate></Setter.Value></Setter>
</Style>" +
        Text("RecappiLabelPrimary", "RecappiTextPrimary", 12.5) +
        Text("RecappiLabelSecondary", "RecappiTextSecondary", 11.5) +
        Text("RecappiLabelTertiary", "RecappiTextTertiary", 11.5) +
        Text("RecappiTimer", "RecappiTextPrimary", 12, "<Setter Property='FontFamily' Value='Cascadia Mono, Consolas'/><Setter Property='FontWeight' Value='SemiBold'/>") +
        Text("RecappiDuration", "RecappiTextTertiary", 11.5, "<Setter Property='FontFamily' Value='Cascadia Mono, Consolas'/>") +
        Text("RecappiStatusAccent", "RecappiAccent", 12, "<Setter Property='FontWeight' Value='SemiBold'/>") +
        Text("RecappiStatusWarning", "RecappiWarning", 12, "<Setter Property='FontWeight' Value='SemiBold'/>") +
        Text("RecappiStatusNeutral", "RecappiTextSecondary", 12, "<Setter Property='FontWeight' Value='SemiBold'/>") +
        Text("RecappiError", "RecappiDanger", 11.5, "<Setter Property='TextWrapping' Value='Wrap'/>") +
        Icon("RecappiIconAccent", "RecappiAccent") + Icon("RecappiIconWarning", "RecappiWarning") +
        Icon("RecappiIconNeutral", "RecappiTextSecondary") + Icon("RecappiIconDanger", "RecappiDanger") +
        Fill("RecappiDotAccent", "RecappiAccent") + Fill("RecappiDotUnlit", "RecappiWaveUnlit") +
        ButtonStyle("RecappiButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiLabel}'/><Setter Property='Background' Value='{ThemeResource RecappiButtonFill}'/><Setter Property='BorderBrush' Value='{ThemeResource RecappiBorderSubtle}'/><Setter Property='BorderThickness' Value='1'/><Setter Property='MinHeight' Value='32'/><Setter Property='Padding' Value='12,0'/><Setter Property='FontSize' Value='13'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiButtonHover}'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiButtonPress}'/><Setter Target='Presenter.Foreground' Value='{ThemeResource RecappiLabelSecondary}'/>") +
        ButtonStyle("RecappiPrimaryButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiOnAccent}'/><Setter Property='Background' Value='{ThemeResource RecappiAccent}'/><Setter Property='MinHeight' Value='32'/><Setter Property='Padding' Value='14,0'/><Setter Property='FontSize' Value='13'/><Setter Property='FontWeight' Value='SemiBold'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiAccentHover}'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiAccentHover}'/><Setter Target='Root.Opacity' Value='0.85'/>",
            "<Setter Target='Root.Opacity' Value='0.35'/>") +
        ButtonStyle("RecappiSubtleButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiLabel}'/><Setter Property='MinHeight' Value='32'/><Setter Property='Padding' Value='10,0'/><Setter Property='FontSize' Value='13'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiControlHover}'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiControlPress}'/>") +
        ButtonStyle("RecappiCitationButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiLabel}'/><Setter Property='Background' Value='{ThemeResource RecappiAccentSoftFill}'/><Setter Property='BorderBrush' Value='{ThemeResource RecappiAccentStroke}'/><Setter Property='BorderThickness' Value='1'/><Setter Property='MinHeight' Value='30'/><Setter Property='Padding' Value='10,4'/><Setter Property='FontSize' Value='12.5'/><Setter Property='HorizontalContentAlignment' Value='Left'/><Setter Property='CornerRadius' Value='8'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiAccentChipHover}'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiAccentChipHover}'/>") +
        ButtonStyle("RecappiTimestampButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiAccent}'/><Setter Property='Background' Value='{ThemeResource RecappiAccentSoftFill}'/><Setter Property='Height' Value='22'/><Setter Property='Padding' Value='8,0'/><Setter Property='FontSize' Value='11.5'/><Setter Property='FontFamily' Value='Cascadia Mono, Consolas'/><Setter Property='CornerRadius' Value='11'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiAccentChipHover}'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiAccentChipHover}'/>", "<Setter Target='Root.Opacity' Value='0.5'/>") +
        ButtonStyle("RecappiPlayButton", "Button",
            "<Setter Property='Foreground' Value='{ThemeResource RecappiOnAccent}'/><Setter Property='Background' Value='{ThemeResource RecappiAccent}'/><Setter Property='Width' Value='34'/><Setter Property='Height' Value='34'/><Setter Property='CornerRadius' Value='17'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiAccentHover}'/>",
            "<Setter Target='Root.Background' Value='{ThemeResource RecappiAccentHover}'/><Setter Target='Root.Opacity' Value='0.85'/>") +
        Text("RecappiCaptionBadge", "RecappiCaptionText", 9.5, "<Setter Property='FontWeight' Value='SemiBold'/>") +
        Text("RecappiCaptionPane", "RecappiCaptionTextMuted", 9.5, "<Setter Property='FontWeight' Value='Bold'/>") +
        Text("RecappiCaptionOriginal", "RecappiCaptionText", 16, "<Setter Property='FontWeight' Value='SemiBold'/>") +
        Text("RecappiCaptionTranslation", "RecappiCaptionTextSecondary", 15, "<Setter Property='FontWeight' Value='Medium'/>") + @"
<Style x:Key='RecappiCaptionSegment' TargetType='ToggleButton'>
  <Setter Property='UseSystemFocusVisuals' Value='True'/>
  <Setter Property='Width' Value='24'/><Setter Property='Height' Value='18'/>
  <Setter Property='Padding' Value='0'/>
  <Setter Property='Foreground' Value='#8CFFFFFF'/>
  <Setter Property='Template'><Setter.Value><ControlTemplate TargetType='ToggleButton'>
    <Grid x:Name='Root' Background='Transparent' CornerRadius='9'>
      <VisualStateManager.VisualStateGroups><VisualStateGroup x:Name='CommonStates'>
        <VisualState x:Name='Normal'/>
        <VisualState x:Name='PointerOver'><VisualState.Setters><Setter Target='Root.Background' Value='#1AFFFFFF'/></VisualState.Setters></VisualState>
        <VisualState x:Name='Pressed'><VisualState.Setters><Setter Target='Root.Background' Value='#1AFFFFFF'/></VisualState.Setters></VisualState>
        <VisualState x:Name='Disabled'><VisualState.Setters><Setter Target='Root.Opacity' Value='0.4'/></VisualState.Setters></VisualState>
        <VisualState x:Name='Checked'><VisualState.Setters><Setter Target='Root.Background' Value='#33FFFFFF'/><Setter Target='Presenter.Foreground' Value='#F5FFFFFF'/></VisualState.Setters></VisualState>
        <VisualState x:Name='CheckedPointerOver'><VisualState.Setters><Setter Target='Root.Background' Value='#40FFFFFF'/><Setter Target='Presenter.Foreground' Value='#F5FFFFFF'/></VisualState.Setters></VisualState>
        <VisualState x:Name='CheckedPressed'><VisualState.Setters><Setter Target='Root.Background' Value='#40FFFFFF'/><Setter Target='Presenter.Foreground' Value='#F5FFFFFF'/></VisualState.Setters></VisualState>
        <VisualState x:Name='CheckedDisabled'><VisualState.Setters><Setter Target='Root.Opacity' Value='0.4'/></VisualState.Setters></VisualState>
      </VisualStateGroup></VisualStateManager.VisualStateGroups>
      <ContentPresenter x:Name='Presenter' Content='{TemplateBinding Content}' Foreground='{TemplateBinding Foreground}' HorizontalAlignment='Center' VerticalAlignment='Center'/>
    </Grid>
  </ControlTemplate></Setter.Value></Setter>
</Style>" +
        Text("RecappiPageTitle", "RecappiLabel", 22, "<Setter Property='FontWeight' Value='SemiBold'/><Setter Property='TextWrapping' Value='Wrap'/>") +
        Text("RecappiSectionTitle", "RecappiLabel", 15, "<Setter Property='FontWeight' Value='SemiBold'/>") +
        Text("RecappiBody", "RecappiLabel", 14, "<Setter Property='TextWrapping' Value='Wrap'/><Setter Property='LineHeight' Value='23'/>") +
        Text("RecappiBodySecondary", "RecappiLabelSecondary", 13, "<Setter Property='TextWrapping' Value='Wrap'/>") +
        Text("RecappiCaption", "RecappiLabelTertiary", 12) +
        Text("RecappiEyebrow", "RecappiLabelSecondary", 12, "<Setter Property='FontWeight' Value='SemiBold'/>");

    private const string CheckedSetters = "<Setter Target='Root.Background' Value='{ThemeResource RecappiAccentSoftFill}'/><Setter Target='Root.BorderBrush' Value='{ThemeResource RecappiAccentStroke}'/><Setter Target='Presenter.Foreground' Value='{ThemeResource RecappiAccent}'/><Setter Target='LiveDot.Visibility' Value='Visible'/>";

    public static FontIcon Glyph(string glyph, double size = 13) => new() { Glyph = glyph, FontSize = size, FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets") };
    public static TextBlock Label(string text, string style) => new() { Text = text, Style = Style(style) };

    // Brand tile: green gradient with the headset mark, as on macOS.
    public static Border LogoTile(double size)
    {
        var gradient = new LinearGradientBrush { StartPoint = new(0, 0), EndPoint = new(1, 1) };
        gradient.GradientStops.Add(new GradientStop { Color = Windows.UI.Color.FromArgb(255, 52, 211, 153), Offset = 0 });
        gradient.GradientStops.Add(new GradientStop { Color = Windows.UI.Color.FromArgb(255, 16, 185, 129), Offset = 1 });
        var sheen = new LinearGradientBrush { StartPoint = new(0, 0), EndPoint = new(1, 1) };
        sheen.GradientStops.Add(new GradientStop { Color = Windows.UI.Color.FromArgb(61, 255, 255, 255), Offset = 0 });
        sheen.GradientStops.Add(new GradientStop { Color = Windows.UI.Color.FromArgb(5, 255, 255, 255), Offset = 1 });
        var mark = new Grid { Background = sheen };
        var logo = System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "Recappi.png");
        if (File.Exists(logo))
            mark.Children.Add(new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(logo)), Margin = new Thickness(size * 0.1), Opacity = 0.85 });
        return new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.25), Background = gradient, Child = mark,
            BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(46, 255, 255, 255)), BorderThickness = new Thickness(1)
        };
    }

    public static Storyboard Pulse(UIElement target)
    {
        var animation = new DoubleAnimation { From = 1, To = 0.3, Duration = TimeSpan.FromMilliseconds(900), AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut } };
        Storyboard.SetTarget(animation, target); Storyboard.SetTargetProperty(animation, nameof(UIElement.Opacity));
        var storyboard = new Storyboard(); storyboard.Children.Add(animation); return storyboard;
    }

    public static void FadeIn(UIElement target)
    {
        var animation = new DoubleAnimation { From = 0, To = 1, Duration = TimeSpan.FromMilliseconds(200),
            EasingFunction = new ExponentialEase { EasingMode = EasingMode.EaseOut, Exponent = 5 } };
        Storyboard.SetTarget(animation, target); Storyboard.SetTargetProperty(animation, nameof(UIElement.Opacity));
        var storyboard = new Storyboard(); storyboard.Children.Add(animation); storyboard.Begin();
    }
}

// Scrolling level history drawn as a dot matrix, as in the macOS recorder pill.
internal sealed class DotMatrixMeter : Canvas
{
    private const int Rows = 5;
    private const double ColumnStep = 6;
    private readonly List<double> history = [];
    private readonly List<(Ellipse Unlit, Ellipse Lit)[]> columns = [];
    public double Latest { get; private set; }

    public DotMatrixMeter()
    {
        Height = 28;
        SizeChanged += (_, _) => Rebuild();
    }
    public void Push(double level)
    {
        Latest = Math.Clamp(level, 0, 1);
        history.Add(Latest);
        if (history.Count > 128) history.RemoveAt(0);
        Paint();
    }
    public void Clear() { history.Clear(); Latest = 0; Paint(); }
    private void Rebuild()
    {
        var count = Math.Max(1, (int)(ActualWidth / ColumnStep));
        if (count == columns.Count) return;
        Children.Clear(); columns.Clear();
        var rowStep = ActualHeight / Rows;
        var dot = Math.Min(ColumnStep, rowStep) * 0.6;
        var offset = (ActualWidth - count * ColumnStep) / 2;
        for (var column = 0; column < count; column++)
        {
            var cells = new (Ellipse, Ellipse)[Rows];
            for (var row = 0; row < Rows; row++)
            {
                var unlit = new Ellipse { Width = dot, Height = dot, Style = RecappiTheme.Style("RecappiDotUnlit") };
                var lit = new Ellipse { Width = dot, Height = dot, Style = RecappiTheme.Style("RecappiDotAccent"), Opacity = 0 };
                var x = offset + column * ColumnStep + (ColumnStep - dot) / 2; var y = row * rowStep + (rowStep - dot) / 2;
                foreach (var cell in new[] { unlit, lit }) { SetLeft(cell, x); SetTop(cell, y); Children.Add(cell); }
                cells[row] = (unlit, lit);
            }
            columns.Add(cells);
        }
        Paint();
    }
    private void Paint()
    {
        for (var column = 0; column < columns.Count; column++)
        {
            // Newest samples enter from the right edge.
            var index = history.Count - columns.Count + column;
            var level = index >= 0 ? history[index] : 0;
            var height = level < 0.04 ? 0 : Math.Max(1, Math.Pow(level, 0.58) * Rows);
            for (var row = 0; row < Rows; row++)
            {
                var fill = height - (Rows - row - 1);
                columns[column][row].Lit.Opacity = fill <= 0 ? 0 : fill >= 1 ? 1 : fill * fill * (3 - 2 * fill);
            }
        }
    }
}
