using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace TaskScheduleTable;

public partial class TaskEditorWindow : Window
{
    private readonly TaskItem? _existing;
    public TaskItem? Result { get; private set; }

    public TaskEditorWindow(TaskItem? existing, double fontSize)
    {
        InitializeComponent();
        _existing = existing;
        FontSize = Math.Clamp(fontSize, 8, 30);
        DialogTitle.Text = existing is null ? "新規作成" : "タスク / 予定を編集";

        if (existing is not null)
        {
            TypeCombo.SelectedIndex = existing.Type == "予定" ? 1 : 0;
            TitleBox.Text = existing.Title;
            DetailsBox.Text = existing.Details;
            UrlEnabledCheck.IsChecked = existing.UrlEnabled;
            UrlBox.Text = existing.Url;
            DeadlineEnabledCheck.IsChecked = existing.DeadlineEnabled;
            if (existing.DeadlineEnabled && DateTime.TryParseExact(existing.Deadline, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                    DateTimeStyles.None, out var d))
            {
                DeadlineBox.Text = existing.DeadlineYearExplicit ? d.ToString("yyyy/MM/dd") : d.ToString("MM/dd");
            }
        }

        UpdateEnabledStates();
    }

    private void UrlEnabledCheck_Changed(object sender, RoutedEventArgs e) => UpdateEnabledStates();
    private void DeadlineEnabledCheck_Changed(object sender, RoutedEventArgs e) => UpdateEnabledStates();

    private void UpdateEnabledStates()
    {
        UrlBox.IsEnabled = UrlEnabledCheck.IsChecked == true;
        DeadlineBox.IsEnabled = DeadlineEnabledCheck.IsChecked == true;
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
        var yearExplicit = false;
        if (deadlineEnabled)
        {
            if (!TryParseDeadline(DeadlineBox.Text, out var date, out yearExplicit))
            {
                ValidationText.Text = "期限は MM/DD または YYYY/MM/DD で入力してください。";
                DeadlineBox.Focus();
                return;
            }
            deadline = date.ToString("yyyy-MM-dd");
        }

        var now = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
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
