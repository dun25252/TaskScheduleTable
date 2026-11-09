using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;

namespace TaskScheduleTable;

public partial class TaskEditorWindow : Window
{
    private readonly TaskItem? _existing;
    private readonly AppSettingsModel _settings;
    public TaskItem? Result { get; private set; }

    public TaskEditorWindow(TaskItem? existing, double fontSize, AppSettingsModel settings)
    {
        InitializeComponent();
        _existing = existing;
        _settings = settings;
        FontSize = Math.Clamp(fontSize, 8, 30);
        DialogTitle.Text = existing is null ? "新規作成" : "タスク / 予定を編集";

        ApplyCurrentTheme();

        if (existing is not null)
        {
            TypeCombo.SelectedIndex = existing.Type == "予定" ? 1 : 0;
            TitleBox.Text = existing.Title;
            DetailsBox.Text = existing.Details;
            UrlEnabledCheck.IsChecked = existing.UrlEnabled;
            UrlBox.Text = existing.Url;
            DeadlineEnabledCheck.IsChecked = existing.DeadlineEnabled;
            CompletedCheck.IsChecked = existing.Completed;

            if (existing.DeadlineEnabled && DateTime.TryParseExact(existing.Deadline, "yyyy-MM-dd",
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out var startDate))
            {
                DeadlineBox.Text = existing.DeadlineYearExplicit ? startDate.ToString("yyyy/MM/dd") : startDate.ToString("MM/dd");
            }

            StartTimeBox.Text = existing.StartTime ?? "";

            if (!string.IsNullOrWhiteSpace(existing.EndDate) &&
                DateTime.TryParseExact(existing.EndDate, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out var endDate))
            {
                EndDateBox.Text = endDate.ToString("yyyy/MM/dd");
            }
            EndTimeBox.Text = existing.EndTime ?? "";
        }

        UpdateEnabledStates();
    }

    private void ApplyCurrentTheme()
    {
        var textColor = ParseColorOrDefault(_settings.TextColor, Color.FromRgb(0, 255, 102));
        var backgroundColor = ParseColorOrDefault(_settings.BackgroundColor, Colors.Black);
        Resources["TextColorBrush"] = new SolidColorBrush(textColor);
        Resources["BackgroundColorBrush"] = new SolidColorBrush(backgroundColor);

        var hasImage = !string.IsNullOrWhiteSpace(_settings.BackgroundImagePath) && File.Exists(_settings.BackgroundImagePath);
        var readability = Math.Clamp(_settings.ReadabilityOverlayOpacity, 0.0, 0.70);
        var panel = new SolidColorBrush(backgroundColor) { Opacity = hasImage ? Math.Max(0.18, readability) : 1.0 };
        Resources["PanelBrush"] = panel;

        var luminance = (0.2126 * textColor.R + 0.7152 * textColor.G + 0.0722 * textColor.B) / 255.0;
        Resources["EditorTextHaloEffect"] = new System.Windows.Media.Effects.DropShadowEffect
        {
            Color = luminance >= 0.50 ? Colors.Black : Colors.White,
            ShadowDepth = 0,
            BlurRadius = 3.2,
            Opacity = 1.0
        };

        if (!hasImage)
        {
            EditorBackgroundImage.Source = null;
            EditorBackgroundImage.Opacity = 0;
            EditorBackgroundShade.Opacity = 0;
            return;
        }

        try
        {
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.UriSource = new Uri(_settings.BackgroundImagePath, UriKind.Absolute);
            bitmap.EndInit();
            bitmap.Freeze();
            EditorBackgroundImage.Source = bitmap;
            EditorBackgroundImage.Opacity = 1.0;
            EditorBackgroundShade.Background = new SolidColorBrush(backgroundColor);
            EditorBackgroundShade.Opacity = 1.0 - Math.Clamp(_settings.BackgroundImageOpacity, 0.0, 1.0);
        }
        catch
        {
            EditorBackgroundImage.Source = null;
            EditorBackgroundImage.Opacity = 0;
            EditorBackgroundShade.Opacity = 0;
        }
    }

    private static Color ParseColorOrDefault(string? value, Color fallback)
    {
        if (string.IsNullOrWhiteSpace(value)) return fallback;
        try
        {
            var parsed = ColorConverter.ConvertFromString(value);
            return parsed is Color c ? c : fallback;
        }
        catch { return fallback; }
    }

    private void UrlEnabledCheck_Changed(object sender, RoutedEventArgs e) => UpdateEnabledStates();
    private void DeadlineEnabledCheck_Changed(object sender, RoutedEventArgs e) => UpdateEnabledStates();

    private void UpdateEnabledStates()
    {
        UrlBox.IsEnabled = UrlEnabledCheck.IsChecked == true;
        var enabled = DeadlineEnabledCheck.IsChecked == true;
        DeadlineBox.IsEnabled = enabled;
        StartTimeBox.IsEnabled = enabled;
        EndDateBox.IsEnabled = enabled;
        EndTimeBox.IsEnabled = enabled;
        DateTimeGrid.Opacity = enabled ? 1.0 : 0.42;
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        ValidationText.Text = "";
        var title = TitleBox.Text.Trim();
        if (title.Length == 0)
        {
            ValidationText.Text = "タイトルを入力してください。";
            TitleBox.Focus();
            return;
        }

        var type = ((TypeCombo.SelectedItem as ComboBoxItem)?.Content?.ToString() == "予定") ? "予定" : "タスク";
        var urlEnabled = UrlEnabledCheck.IsChecked == true;
        var url = UrlBox.Text.Trim();
        if (urlEnabled && url.Length > 0 && !UrlHelper.IsHttpUrl(url))
        {
            ValidationText.Text = "URLが正しくありません。";
            UrlBox.Focus();
            return;
        }
        if (url.Length > 0) url = UrlHelper.Normalize(url);

        var deadlineEnabled = DeadlineEnabledCheck.IsChecked == true;
        var deadline = "";
        var startTime = "";
        var endDate = "";
        var endTime = "";
        var yearExplicit = false;

        if (deadlineEnabled)
        {
            if (!TryParseDeadline(DeadlineBox.Text, out var startDate, out yearExplicit))
            {
                ValidationText.Text = "開始日は MM/DD または YYYY/MM/DD で入力してください。";
                DeadlineBox.Focus();
                return;
            }
            deadline = startDate.ToString("yyyy-MM-dd");

            var startRaw = StartTimeBox.Text.Trim();
            TimeSpan startTs = TimeSpan.Zero;
            var hasStartTime = startRaw.Length > 0;
            if (hasStartTime && !TryParseTime(startRaw, false, out startTs, out _))
            {
                ValidationText.Text = "開始時刻は HH:MM で入力してください。";
                StartTimeBox.Focus();
                return;
            }
            if (hasStartTime) startTime = $"{(int)startTs.TotalHours:00}:{startTs.Minutes:00}";

            var endDateRaw = EndDateBox.Text.Trim();
            DateTime parsedEndDate = startDate.Date;
            var hasExplicitEndDate = endDateRaw.Length > 0;
            if (hasExplicitEndDate)
            {
                if (!TryParseDeadlineRelativeTo(endDateRaw, startDate.Date, out parsedEndDate))
                {
                    ValidationText.Text = "終了日は MM/DD または YYYY/MM/DD で入力してください。";
                    EndDateBox.Focus();
                    return;
                }
                endDate = parsedEndDate.ToString("yyyy-MM-dd");
            }

            var endRaw = EndTimeBox.Text.Trim();
            var hasEndTime = endRaw.Length > 0;
            TimeSpan endTs = TimeSpan.Zero;
            var endIs24 = false;
            if (hasEndTime && !TryParseTime(endRaw, true, out endTs, out endIs24))
            {
                ValidationText.Text = "終了時刻は HH:MM で入力してください。24:00も使用できます。";
                EndTimeBox.Focus();
                return;
            }

            if (hasEndTime && !hasStartTime)
            {
                ValidationText.Text = "終了時刻を設定する場合は開始時刻も入力してください。";
                StartTimeBox.Focus();
                return;
            }

            if (hasEndTime)
                endTime = endIs24 ? "24:00" : $"{(int)endTs.TotalHours:00}:{endTs.Minutes:00}";

            if (hasExplicitEndDate && parsedEndDate.Date < startDate.Date)
            {
                ValidationText.Text = "終了日は開始日以降にしてください。";
                EndDateBox.Focus();
                return;
            }

            if (hasStartTime && (hasEndTime || hasExplicitEndDate))
            {
                var startDateTime = startDate.Date + startTs;
                var endBaseDate = hasExplicitEndDate ? parsedEndDate.Date : startDate.Date;
                DateTime endDateTime;

                if (hasEndTime)
                {
                    endDateTime = endIs24 ? endBaseDate.AddDays(1) : endBaseDate + endTs;

                    // 終了日を省略し、終了時刻が開始時刻より早い場合は翌日扱い。
                    if (!hasExplicitEndDate && !endIs24 && endDateTime <= startDateTime)
                    {
                        if (endTs < startTs)
                        {
                            endDateTime = endDateTime.AddDays(1);
                            endDate = endDateTime.Date.ToString("yyyy-MM-dd");
                        }
                        else
                        {
                            ValidationText.Text = "終了時刻は開始時刻より後にしてください。";
                            EndTimeBox.Focus();
                            return;
                        }
                    }
                }
                else
                {
                    endDateTime = endBaseDate.Date.AddDays(1).AddTicks(-1);
                }

                if (endDateTime <= startDateTime)
                {
                    ValidationText.Text = "終了日時は開始日時より後にしてください。";
                    EndTimeBox.Focus();
                    return;
                }
            }
        }

        var now = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        var completed = CompletedCheck.IsChecked == true;
        Result = new TaskItem
        {
            Id = _existing?.Id ?? Guid.NewGuid().ToString("N"),
            Type = type,
            Title = title,
            Details = DetailsBox.Text.Trim(),
            Url = url,
            UrlEnabled = urlEnabled,
            Deadline = deadline,
            DeadlineEnabled = deadlineEnabled,
            DeadlineYearExplicit = yearExplicit,
            DeadlineMetadataKnown = true,
            StartTime = startTime,
            EndDate = endDate,
            EndTime = endTime,
            Completed = completed,
            CompletedAt = completed
                ? (_existing?.Completed == true && !string.IsNullOrWhiteSpace(_existing.CompletedAt) ? _existing.CompletedAt : now)
                : "",
            Created = _existing?.Created ?? now,
            Updated = now
        };

        DialogResult = true;
        Close();
    }

    public static bool TryParseDeadline(string text, out DateTime date, out bool yearExplicit)
    {
        date = default;
        yearExplicit = false;
        var value = (text ?? "").Trim().Replace('-', '/');

        if (DateTime.TryParseExact(value, new[] { "yyyy/M/d", "yyyy/MM/dd" }, CultureInfo.InvariantCulture,
                DateTimeStyles.None, out date))
        {
            yearExplicit = true;
            return true;
        }

        if (DateTime.TryParseExact(value, new[] { "M/d", "MM/dd" }, CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var md))
        {
            var today = DateTime.Today;
            try
            {
                var candidate = new DateTime(today.Year, md.Month, md.Day);
                if (candidate.Date < today) candidate = candidate.AddYears(1);
                date = candidate;
                yearExplicit = false;
                return true;
            }
            catch { }
        }

        return false;
    }

    private static bool TryParseDeadlineRelativeTo(string text, DateTime startDate, out DateTime date)
    {
        date = default;
        var value = (text ?? "").Trim().Replace('-', '/');

        if (DateTime.TryParseExact(value, new[] { "yyyy/M/d", "yyyy/MM/dd" }, CultureInfo.InvariantCulture,
                DateTimeStyles.None, out date))
            return true;

        if (DateTime.TryParseExact(value, new[] { "M/d", "MM/dd" }, CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var md))
        {
            try
            {
                var candidate = new DateTime(startDate.Year, md.Month, md.Day);
                if (candidate.Date < startDate.Date) candidate = candidate.AddYears(1);
                date = candidate;
                return true;
            }
            catch { }
        }

        return false;
    }

    private static bool TryParseTime(string text, bool allow24, out TimeSpan time, out bool is24)
    {
        time = default;
        is24 = false;
        var value = (text ?? "").Trim();

        if (allow24 && value == "24:00")
        {
            is24 = true;
            time = TimeSpan.FromDays(1);
            return true;
        }

        if (!TimeSpan.TryParseExact(value, new[] { @"h\:mm", @"hh\:mm" },
                CultureInfo.InvariantCulture, TimeSpanStyles.None, out var parsed))
            return false;

        if (parsed < TimeSpan.Zero || parsed >= TimeSpan.FromDays(1)) return false;
        time = parsed;
        return true;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e) { DialogResult = false; Close(); }
    private void CloseButton_Click(object sender, RoutedEventArgs e) { DialogResult = false; Close(); }

    private void DialogTitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left)
        {
            try { DragMove(); } catch { }
        }
    }
}
