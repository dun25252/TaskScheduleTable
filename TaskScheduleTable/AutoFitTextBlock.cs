using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace TaskScheduleTable;

public sealed class AutoFitTextBlock : TextBlock
{
    public static readonly DependencyProperty BaseFontSizeProperty = DependencyProperty.Register(
        nameof(BaseFontSize), typeof(double), typeof(AutoFitTextBlock),
        new FrameworkPropertyMetadata(13d, FrameworkPropertyMetadataOptions.AffectsMeasure, (_, _) => { }));

    public static readonly DependencyProperty MinFitFontSizeProperty = DependencyProperty.Register(
        nameof(MinFitFontSize), typeof(double), typeof(AutoFitTextBlock),
        new FrameworkPropertyMetadata(6d));

    private bool _pending;

    public double BaseFontSize
    {
        get => (double)GetValue(BaseFontSizeProperty);
        set => SetValue(BaseFontSizeProperty, value);
    }

    public double MinFitFontSize
    {
        get => (double)GetValue(MinFitFontSizeProperty);
        set => SetValue(MinFitFontSizeProperty, value);
    }

    public AutoFitTextBlock()
    {
        TextWrapping = TextWrapping.NoWrap;
        TextTrimming = TextTrimming.CharacterEllipsis;
        SizeChanged += (_, _) => QueueFit();
        Loaded += (_, _) => QueueFit();
        TargetUpdated += (_, _) => QueueFit();
    }

    private void QueueFit()
    {
        if (_pending) return;
        _pending = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            _pending = false;
            Fit();
        }));
    }

    private void Fit()
    {
        var available = ActualWidth - Margin.Left - Margin.Right - 2;
        if (available <= 8 || string.IsNullOrEmpty(Text))
        {
            FontSize = Math.Max(MinFitFontSize, Math.Min(BaseFontSize, 13));
            return;
        }

        var max = Math.Max(MinFitFontSize, BaseFontSize);
        var min = Math.Max(5.5, MinFitFontSize);
        var size = max;
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;

        while (size > min)
        {
            var formatted = new FormattedText(
                Text,
                CultureInfo.CurrentUICulture,
                System.Windows.FlowDirection.LeftToRight,
                new Typeface(FontFamily, FontStyle, FontWeight, FontStretch),
                size,
                Foreground,
                dpi);

            if (formatted.WidthIncludingTrailingWhitespace <= available)
                break;
            size -= 0.5;
        }

        FontSize = Math.Max(min, size);
    }
}
