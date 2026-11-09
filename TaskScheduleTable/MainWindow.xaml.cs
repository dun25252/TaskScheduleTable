using Microsoft.Win32;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Brush = System.Windows.Media.Brush;
using Color = System.Windows.Media.Color;
using Button = System.Windows.Controls.Button;
using MessageBox = System.Windows.MessageBox;
using OpenFileDialog = Microsoft.Win32.OpenFileDialog;

namespace TaskScheduleTable;

public partial class MainWindow : Window
{
    private enum SelectMode { Normal, Edit }

    private List<TaskItem> _tasks = [];
    private AppSettingsModel _settings = new();
    private NotificationState _notificationState = new();
    private readonly HashSet<string> _notificationKeys = new(StringComparer.Ordinal);
    private SelectMode _mode;
    private TaskItem? _urlPopupTask;
    private bool _initialized;
    private bool _restoring;
    private double _rowCompleteWidth = 46;
    private double _rowUrlWidth = 54;
    private double _rowDeadlineWidth = 150;
    private double _rowOrderWidth = 62;
    private double _rowDeleteWidth = 46;

    private readonly DispatcherTimer _saveTimer = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private readonly DispatcherTimer _layoutTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private readonly DispatcherTimer _notificationTimer = new() { Interval = TimeSpan.FromMinutes(30) };

    public MainWindow()
    {
        InitializeComponent();

        _saveTimer.Tick += (_, _) => { _saveTimer.Stop(); SaveSettingsNow(); };
        _layoutTimer.Tick += (_, _) => { _layoutTimer.Stop(); RefreshTasks(); };
        _notificationTimer.Tick += (_, _) => CheckDeadlineNotifications();

        Loaded += MainWindow_Loaded;
        LocationChanged += (_, _) => ScheduleSaveSettings();
        SizeChanged += (_, _) =>
        {
            UpdateResponsiveLayout();
            _layoutTimer.Stop();
            _layoutTimer.Start();
            ScheduleSaveSettings();
        };
        StateChanged += (_, _) => { UpdateResponsiveLayout(); ScheduleSaveSettings(); };
        Closing += (_, _) => SaveSettingsNow();
        PreviewMouseWheel += MainWindow_PreviewMouseWheel;
    }

    private void MainWindow_Loaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _tasks = AppServices.Data.LoadTasks();
            _settings = AppServices.Data.LoadSettings();
            _settings.VoiceVolume = Math.Clamp(_settings.VoiceVolume, 0.0, 1.0);
            if (_settings.SortMode != "Manual") _settings.SortMode = "Deadline";
            AppServices.Voice.Volume = _settings.VoiceVolume;
            _notificationState = AppServices.Data.LoadNotifications();
            foreach (var key in _notificationState.Keys) _notificationKeys.Add(key);

            RestoreWindowSettings();
            ApplyBackground();
            UpdateResponsiveLayout();
            RefreshTasks();
            UpdateStatus();

            AppServices.Startup.EnsureRegistered();
            AppServices.Log.Write($"起動完了 / タスク {_tasks.Count} 件");
            AppServices.Voice.Queue("予定表が起動しました");

            _notificationTimer.Start();
            CheckDeadlineNotifications();
            _initialized = true;

            Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() =>
            {
                var intendedTopmost = _settings.Topmost;
                WindowState = WindowState == WindowState.Minimized ? WindowState.Normal : WindowState;
                Topmost = true;
                Activate();
                Focus();
                Dispatcher.BeginInvoke(new Action(() => Topmost = intendedTopmost));
            }));
        }
        catch (Exception ex)
        {
            AppServices.Log.WriteError("起動初期化エラー", ex);
            AppServices.Voice.Queue("エラーが発生しました。");
            MessageBox.Show("初期化中にエラーが発生しました。Log\\Error を確認してください。", "タスク・予定表",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void RestoreWindowSettings()
    {
        _restoring = true;
        try
        {
            _settings.FontSize = Math.Clamp(_settings.FontSize, 8, 30);
            _settings.Width = Math.Clamp(_settings.Width, MinWidth, Math.Max(MinWidth, SystemParameters.VirtualScreenWidth * 0.95));
            _settings.Height = Math.Clamp(_settings.Height, MinHeight, Math.Max(MinHeight, SystemParameters.VirtualScreenHeight * 0.95));

            Width = _settings.Width;
            Height = _settings.Height;
            Left = _settings.Left;
            Top = _settings.Top;
            ClampWindowToVisibleArea();

            FontSize = _settings.FontSize;
            Topmost = _settings.Topmost;
            LockButton.Content = _settings.Locked ? "位置固定: ON" : "位置固定: OFF";
            TopmostButton.Content = _settings.Topmost ? "最前面: ON" : "最前面: OFF";
            FontLabel.Text = $"文字サイズ: {_settings.FontSize:0.0} pt";
            SortButton.Content = _settings.SortMode == "Manual" ? "並び: 手動" : "並び: 期限順";

            BackgroundOpacitySlider.Value = Math.Clamp(_settings.BackgroundImageOpacity * 100.0, 0, 100);
            ReadabilityOpacitySlider.Value = Math.Clamp(_settings.ReadabilityOverlayOpacity * 100.0, 0, 70);
            ApplyThemeColors();
            VoiceVolumeSlider.Value = Math.Clamp(_settings.VoiceVolume * 100.0, 0, 100);
            UpdateVoiceVolumeLabel();
            UpdateBackgroundOpacityLabel();
            UpdateReadabilityOpacityLabel();
        }
        finally { _restoring = false; }
    }

    private void ClampWindowToVisibleArea()
    {
        var vl = SystemParameters.VirtualScreenLeft;
        var vt = SystemParameters.VirtualScreenTop;
        var vr = vl + SystemParameters.VirtualScreenWidth;
        var vb = vt + SystemParameters.VirtualScreenHeight;

        if (Left + 100 > vr || Top + 60 > vb || Left + Width < vl + 60 || Top + Height < vt + 40)
        {
            Left = vl + 60;
            Top = vt + 60;
        }
    }

    private void ScheduleSaveSettings()
    {
        if (!_initialized || _restoring) return;
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void SaveSettingsNow()
    {
        if (_restoring) return;
        try
        {
            var bounds = WindowState == WindowState.Normal
                ? new Rect(Left, Top, ActualWidth > 0 ? ActualWidth : Width, ActualHeight > 0 ? ActualHeight : Height)
                : RestoreBounds;

            _settings.Left = bounds.Left;
            _settings.Top = bounds.Top;
            _settings.Width = Math.Max(MinWidth, bounds.Width);
            _settings.Height = Math.Max(MinHeight, bounds.Height);
            _settings.FontSize = Math.Clamp(_settings.FontSize, 8, 30);
            _settings.Topmost = Topmost;
            AppServices.Data.SaveSettings(_settings);
        }
        catch (Exception ex) { AppServices.Log.WriteError("表示設定保存エラー", ex); }
    }

    private void UpdateResponsiveLayout()
    {
        var w = ActualWidth > 0 ? ActualWidth : Width;
        var h = ActualHeight > 0 ? ActualHeight : Height;
        var compact = w < 650;
        var veryCompact = w < 520;
        var ultra = w < 450;
        var shortHeight = h < 335;
        var ultraShort = h < 285;

        if (ultra)
        {
            LeftColumn.Width = new GridLength(88);
            ContentGrid.Margin = new Thickness(2);
            LeftPanel.Padding = new Thickness(2);
            LockButton.Content = _settings.Locked ? "固:ON" : "固:OFF";
            TopmostButton.Content = _settings.Topmost ? "前:ON" : "前:OFF";
            LockButton.MinWidth = 50;
            TopmostButton.MinWidth = 50;
            TitleText.Text = "タスク表";
            FontUpButton.Content = "文字＋";
            FontDownButton.Content = "文字－";
            BackgroundButton.Content = "背景";
            _rowCompleteWidth = 30;
            _rowUrlWidth = 32;
            _rowDeadlineWidth = 80;
            _rowOrderWidth = 50;
            _rowDeleteWidth = 34;
        }
        else if (veryCompact)
        {
            LeftColumn.Width = new GridLength(Math.Clamp(72 + _settings.FontSize * 2.1, 100, 128));
            ContentGrid.Margin = new Thickness(4);
            LeftPanel.Padding = new Thickness(3);
            LockButton.Content = _settings.Locked ? "固定:ON" : "固定:OFF";
            TopmostButton.Content = _settings.Topmost ? "前面:ON" : "前面:OFF";
            LockButton.MinWidth = 67;
            TopmostButton.MinWidth = 67;
            TitleText.Text = "タスク・予定表";
            FontUpButton.Content = "文字＋";
            FontDownButton.Content = "文字－";
            _rowCompleteWidth = 34;
            _rowUrlWidth = 38;
            _rowDeadlineWidth = 100;
            _rowOrderWidth = 54;
            _rowDeleteWidth = 38;
        }
        else if (compact)
        {
            LeftColumn.Width = new GridLength(Math.Clamp(78 + _settings.FontSize * 2.4, 115, 150));
            ContentGrid.Margin = new Thickness(5);
            LeftPanel.Padding = new Thickness(4);
            LockButton.Content = _settings.Locked ? "固定:ON" : "固定:OFF";
            TopmostButton.Content = _settings.Topmost ? "前面:ON" : "前面:OFF";
            LockButton.MinWidth = 72;
            TopmostButton.MinWidth = 72;
            TitleText.Text = "タスク・予定表";
            FontUpButton.Content = "文字＋";
            FontDownButton.Content = "文字－";
            _rowCompleteWidth = 38;
            _rowUrlWidth = 44;
            _rowDeadlineWidth = 120;
            _rowOrderWidth = 58;
            _rowDeleteWidth = 42;
        }
        else
        {
            LeftColumn.Width = new GridLength(Math.Clamp(86 + _settings.FontSize * 3.0, 145, 190));
            ContentGrid.Margin = new Thickness(7);
            LeftPanel.Padding = new Thickness(5);
            LockButton.Content = _settings.Locked ? "位置固定: ON" : "位置固定: OFF";
            TopmostButton.Content = _settings.Topmost ? "最前面: ON" : "最前面: OFF";
            LockButton.MinWidth = 92;
            TopmostButton.MinWidth = 92;
            TitleText.Text = "タスク・予定表";
            FontUpButton.Content = "文字を大きくする";
            FontDownButton.Content = "文字を小さくする";
            _rowCompleteWidth = 46;
            _rowUrlWidth = 54;
            _rowDeadlineWidth = 150;
            _rowOrderWidth = 62;
            _rowDeleteWidth = 46;
        }

        HeaderCompleteColumn.Width = new GridLength(_rowCompleteWidth);
        HeaderUrlColumn.Width = new GridLength(_rowUrlWidth);
        HeaderDeadlineColumn.Width = new GridLength(_rowDeadlineWidth);
        HeaderOrderColumn.Width = new GridLength(_rowOrderWidth);
        HeaderDeleteColumn.Width = new GridLength(_rowDeleteWidth);

        var titleFont = ultra ? Math.Clamp(_settings.FontSize * 0.62, 8.5, 11.5) : compact ? Math.Clamp(_settings.FontSize * 0.82, 10, 15) : _settings.FontSize;
        TitleText.FontSize = titleFont;
        var headerFont = ultra ? Math.Clamp(_settings.FontSize * 0.72, 8, 15) : veryCompact ? Math.Clamp(_settings.FontSize * 0.82, 8, 19) : Math.Clamp(_settings.FontSize, 9, 24);
        CompleteHeader.FontSize = UrlHeader.FontSize = DeadlineHeader.FontSize = TaskTitleHeader.FontSize = OrderHeader.FontSize = DeleteHeader.FontSize = headerFont;

        var buttonFont = ultraShort ? Math.Clamp(_settings.FontSize, 8, 14) : shortHeight ? Math.Clamp(_settings.FontSize, 8.5, 18) : Math.Clamp(_settings.FontSize, 9, 26);
        foreach (var button in new[] { AddButton, EditButton, SortButton, FontUpButton, FontDownButton, BackgroundButton, VoiceButton })
        {
            button.FontSize = buttonFont;
            button.MinHeight = ultraShort ? 24 : shortHeight ? 27 : 32;
            button.Padding = ultraShort ? new Thickness(3, 1, 3, 1) : shortHeight ? new Thickness(5, 2, 5, 2) : new Thickness(8, 4, 8, 4);
        }

        LockButton.FontSize = TopmostButton.FontSize = ultra ? Math.Clamp(_settings.FontSize * 0.65, 8, 11) : compact ? Math.Clamp(_settings.FontSize * 0.75, 9, 13) : _settings.FontSize;
        MinimizeButton.FontSize = MaximizeButton.FontSize = CloseButton.FontSize = Math.Clamp(_settings.FontSize, 9, 15);
        MinimizeButton.Width = MaximizeButton.Width = CloseButton.Width = ultra ? 28 : 34;

        FontLabel.Visibility = ultraShort ? Visibility.Collapsed : Visibility.Visible;
        CtrlHint.Visibility = shortHeight ? Visibility.Collapsed : Visibility.Visible;
        FontLabel.FontSize = Math.Clamp(_settings.FontSize, 8, 22);
        StatusText.FontSize = CountText.FontSize = ultraShort ? Math.Clamp(_settings.FontSize, 8, 14) : Math.Clamp(_settings.FontSize, 9, 24);

        TitleRow.Height = new GridLength(ultraShort ? 29 : Math.Max(33, Math.Ceiling(titleFont * 1.35 + 8)));
        HeaderRow.Height = new GridLength(ultraShort ? 26 : Math.Max(29, Math.Ceiling(headerFont * 1.25 + 7)));
        StatusRow.Height = new GridLength(ultraShort ? 24 : Math.Max(26, Math.Ceiling(StatusText.FontSize * 1.2 + 6)));

        FontLabel.Text = $"文字サイズ: {_settings.FontSize:0.0} pt";
    }

    private double CurrentRowHeight()
    {
        var h = ActualHeight > 0 ? ActualHeight : Height;
        if (h < 285) return Math.Clamp(_settings.FontSize * 1.35 + 8, 30, 50);
        if (h < 335) return Math.Clamp(_settings.FontSize * 1.55 + 8, 34, 62);
        return Math.Clamp(_settings.FontSize * 1.85 + 8, 38, 80);
    }

    private void RefreshTasks()
    {
        if (TaskPanel is null) return;
        var offset = TaskScroll.VerticalOffset;
        TaskPanel.Children.Clear();

        var displayTasks = GetDisplayTasks().ToList();

        if (displayTasks.Count == 0)
        {
            TaskPanel.Children.Add(new TextBlock
            {
                Text = "タスク / 予定はありません",
                Foreground = new SolidColorBrush(GetThemeTextColor()),
                HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
                Margin = new Thickness(20),
                FontSize = Math.Clamp(_settings.FontSize, 8, 30)
            });
        }
        else
        {
            foreach (var task in displayTasks) TaskPanel.Children.Add(CreateTaskRow(task));
        }

        UpdateCountText();
        SortButton.Content = _settings.SortMode == "Manual" ? "並び: 手動" : "並び: 期限順";
        Dispatcher.BeginInvoke(new Action(() => TaskScroll.ScrollToVerticalOffset(offset)), DispatcherPriority.Loaded);
    }

    private IEnumerable<TaskItem> GetDisplayTasks()
    {
        if (_settings.SortMode == "Manual")
        {
            return _tasks
                .OrderBy(x => x.ManualOrder <= 0 ? int.MaxValue : x.ManualOrder)
                .ThenBy(x => x.Created, StringComparer.Ordinal);
        }

        return _tasks
            .OrderBy(x => x.Completed ? 1 : 0)
            .ThenBy(x => TryGetTaskStartDateTime(x, out _) ? 0 : 1)
            .ThenBy(x => TryGetTaskStartDateTime(x, out var dt) ? dt : DateTime.MaxValue)
            .ThenBy(x => x.ManualOrder <= 0 ? int.MaxValue : x.ManualOrder)
            .ThenBy(x => x.Created, StringComparer.Ordinal);
    }

    private void NormalizeManualOrder(IEnumerable<TaskItem> ordered)
    {
        var order = 10;
        foreach (var task in ordered)
        {
            task.ManualOrder = order;
            order += 10;
        }
    }

    private void UpdateCountText()
    {
        var completed = _tasks.Count(x => x.Completed);
        CountText.Text = completed > 0 ? $"{_tasks.Count} 件 / 完了 {completed}" : $"{_tasks.Count} 件";
    }

    private UIElement CreateTaskRow(TaskItem task)
    {
        var dueBrush = GetDueBrush(task);
        var row = new Border
        {
            Height = CurrentRowHeight(),
            BorderBrush = new SolidColorBrush(GetThemeTextColor()),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Tag = task.Id,
            Cursor = System.Windows.Input.Cursors.Arrow,
            ClipToBounds = true,
            Opacity = task.Completed ? 0.62 : 1.0
        };
        row.SetResourceReference(Border.BackgroundProperty, "RowFillBrush");

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(_rowCompleteWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(_rowUrlWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(_rowDeadlineWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(_rowOrderWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(_rowDeleteWidth) });

        var complete = new CheckBox
        {
            IsChecked = task.Completed,
            Tag = task.Id,
            ToolTip = task.Completed ? "完了を取り消す" : "完了にする",
            Focusable = false,
            LayoutTransform = new ScaleTransform(
                ActualWidth < 520 ? 1.0 : Math.Clamp(_settings.FontSize / 13.0, 1.0, 1.55),
                ActualWidth < 520 ? 1.0 : Math.Clamp(_settings.FontSize / 13.0, 1.0, 1.55))
        };
        complete.Click += (_, e) =>
        {
            e.Handled = true;
            SetCompleted(task, complete.IsChecked == true);
        };
        Grid.SetColumn(complete, 0);

        var url = new Button
        {
            Content = task.UrlEnabled && !string.IsNullOrWhiteSpace(task.Url) ? "●" : "○",
            Tag = task.Id,
            Padding = new Thickness(1),
            Margin = new Thickness(ActualWidth < 520 ? 2 : 4),
            FontSize = Math.Clamp(_settings.FontSize, 8, 30),
            ToolTip = "URLメニュー"
        };
        url.Click += (sender, e) =>
        {
            e.Handled = true;
            OpenUrlPopup(task, (Button)sender);
        };
        Grid.SetColumn(url, 1);

        var deadline = new TextBlock
        {
            Text = DateTimeText(task),
            Foreground = dueBrush,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            VerticalAlignment = System.Windows.VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
            FontSize = ActualWidth < 520 ? Math.Clamp(_settings.FontSize, 7.5, 18) : Math.Clamp(_settings.FontSize, 8, 30),
            Margin = new Thickness(2, 0, 2, 0),
            Effect = (System.Windows.Media.Effects.Effect)FindResource("TextHaloEffect"),
            TextDecorations = task.Completed ? TextDecorations.Strikethrough : null
        };
        Grid.SetColumn(deadline, 2);

        var title = new AutoFitTextBlock
        {
            Text = task.Title,
            Foreground = dueBrush,
            VerticalAlignment = System.Windows.VerticalAlignment.Center,
            Margin = new Thickness(ActualWidth < 520 ? 3 : 8, 0, ActualWidth < 520 ? 3 : 8, 0),
            BaseFontSize = _settings.FontSize,
            MinFitFontSize = 6.0,
            FontWeight = FontWeights.SemiBold,
            ToolTip = string.IsNullOrWhiteSpace(task.Details) ? task.Title : task.Details,
            Effect = (System.Windows.Media.Effects.Effect)FindResource("TextHaloEffect"),
            TextDecorations = task.Completed ? TextDecorations.Strikethrough : null
        };
        Grid.SetColumn(title, 3);

        var orderPanel = new Grid { Margin = new Thickness(1) };
        orderPanel.ColumnDefinitions.Add(new ColumnDefinition());
        orderPanel.ColumnDefinitions.Add(new ColumnDefinition());

        var up = new Button
        {
            Content = "▲",
            Padding = new Thickness(0),
            Margin = new Thickness(1),
            MinHeight = 20,
            FontSize = Math.Clamp(_settings.FontSize * 0.75, 8, 18),
            ToolTip = "上へ。期限順の場合は手動順へ切り替えます。"
        };
        up.Click += (_, e) =>
        {
            e.Handled = true;
            MoveTask(task, -1);
        };
        Grid.SetColumn(up, 0);

        var down = new Button
        {
            Content = "▼",
            Padding = new Thickness(0),
            Margin = new Thickness(1),
            MinHeight = 20,
            FontSize = Math.Clamp(_settings.FontSize * 0.75, 8, 18),
            ToolTip = "下へ。期限順の場合は手動順へ切り替えます。"
        };
        down.Click += (_, e) =>
        {
            e.Handled = true;
            MoveTask(task, 1);
        };
        Grid.SetColumn(down, 1);

        orderPanel.Children.Add(up);
        orderPanel.Children.Add(down);
        Grid.SetColumn(orderPanel, 4);

        var delete = new Button
        {
            Content = "×",
            Padding = new Thickness(0),
            Margin = new Thickness(ActualWidth < 520 ? 2 : 4),
            MinHeight = 20,
            FontSize = Math.Clamp(_settings.FontSize, 9, 24),
            FontWeight = FontWeights.Bold,
            Foreground = new SolidColorBrush(Color.FromRgb(255, 72, 84)),
            ToolTip = "完全に削除"
        };
        delete.Click += (_, e) =>
        {
            e.Handled = true;
            DeleteTask(task);
        };
        Grid.SetColumn(delete, 5);

        grid.Children.Add(complete);
        grid.Children.Add(url);
        grid.Children.Add(deadline);
        grid.Children.Add(title);
        grid.Children.Add(orderPanel);
        grid.Children.Add(delete);
        row.Child = grid;

        row.MouseLeftButtonUp += (_, e) =>
        {
            if (_mode == SelectMode.Edit)
            {
                _mode = SelectMode.Normal;
                UpdateStatus();
                EditTask(task);
                e.Handled = true;
            }
        };

        return row;
    }

    private void SetCompleted(TaskItem task, bool completed)
    {
        task.Completed = completed;
        task.CompletedAt = completed ? DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") : "";
        task.Updated = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        AppServices.Data.SaveTasks(_tasks);
        AppServices.Log.Write($"完了状態変更: {task.Type} / {task.Title} / {(task.Completed ? "完了" : "未完了")}");
        RefreshTasks();
        UpdateStatus(task.Completed ? $"「{task.Title}」を完了にしました。" : $"「{task.Title}」を未完了に戻しました。");
    }

    private void MoveTask(TaskItem task, int direction)
    {
        if (_settings.SortMode != "Manual")
        {
            NormalizeManualOrder(GetDisplayTasks().ToList());
            _settings.SortMode = "Manual";
        }

        var ordered = _tasks.OrderBy(x => x.ManualOrder).ThenBy(x => x.Created, StringComparer.Ordinal).ToList();
        var index = ordered.FindIndex(x => x.Id == task.Id);
        var otherIndex = index + direction;
        if (index < 0 || otherIndex < 0 || otherIndex >= ordered.Count)
        {
            RefreshTasks();
            return;
        }

        (ordered[index].ManualOrder, ordered[otherIndex].ManualOrder) =
            (ordered[otherIndex].ManualOrder, ordered[index].ManualOrder);

        AppServices.Data.SaveTasks(_tasks);
        AppServices.Data.SaveSettings(_settings);
        RefreshTasks();
        UpdateStatus("手動順に切り替えて順番を変更しました。");
    }

    private void SortButton_Click(object sender, RoutedEventArgs e)
    {
        if (_settings.SortMode == "Manual")
        {
            _settings.SortMode = "Deadline";
            UpdateStatus("期限が近い順に並び替えました。");
        }
        else
        {
            NormalizeManualOrder(GetDisplayTasks().ToList());
            _settings.SortMode = "Manual";
            AppServices.Data.SaveTasks(_tasks);
            UpdateStatus("手動順に切り替えました。▲▼で変更できます。");
        }

        AppServices.Data.SaveSettings(_settings);
        RefreshTasks();
    }

    private static string DateTimeText(TaskItem task)
    {
        if (!task.DeadlineEnabled || string.IsNullOrWhiteSpace(task.Deadline)) return "日時なし";
        if (!DateTime.TryParseExact(task.Deadline, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var startDate))
            return "日時なし";

        var start = startDate.ToString("MM/dd");
        if (!string.IsNullOrWhiteSpace(task.StartTime)) start += " " + task.StartTime;

        var endDate = default(DateTime);
        var hasEndDate = !string.IsNullOrWhiteSpace(task.EndDate) &&
            DateTime.TryParseExact(task.EndDate, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out endDate);
        var hasEndTime = !string.IsNullOrWhiteSpace(task.EndTime);

        if (!hasEndDate && !hasEndTime) return start;

        string end;
        if (hasEndDate)
        {
            end = endDate.ToString("MM/dd");
            if (hasEndTime) end += " " + task.EndTime;
        }
        else
        {
            end = task.EndTime;
        }

        return $"{start}～{end}";
    }

    private static bool TryGetTaskStartDateTime(TaskItem task, out DateTime start)
    {
        start = default;
        if (!task.DeadlineEnabled || !DateTime.TryParseExact(task.Deadline, "yyyy-MM-dd",
                CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
            return false;

        start = date.Date;
        if (!string.IsNullOrWhiteSpace(task.StartTime) &&
            TimeSpan.TryParseExact(task.StartTime, new[] { @"h\:mm", @"hh\:mm" },
                CultureInfo.InvariantCulture, TimeSpanStyles.None, out var time))
            start = start.Add(time);

        return true;
    }

    private Brush GetDueBrush(TaskItem task)
    {
        var baseColor = GetThemeTextColor();
        if (task.Completed) return new SolidColorBrush(baseColor);
        if (!TryGetTaskStartDateTime(task, out var due))
            return new SolidColorBrush(baseColor);

        var days = (int)Math.Floor((due.Date - DateTime.Today).TotalDays);
        if (days >= 14) return new SolidColorBrush(baseColor);

        var warning = Color.FromRgb(255, 38, 52);
        if (days <= 0) return new SolidColorBrush(warning);

        var ratio = Math.Clamp((14.0 - days) / 14.0, 0.0, 1.0);
        return new SolidColorBrush(Color.FromRgb(
            LerpByte(baseColor.R, warning.R, ratio),
            LerpByte(baseColor.G, warning.G, ratio),
            LerpByte(baseColor.B, warning.B, ratio)));
    }

    private static byte LerpByte(byte a, byte b, double t)
        => (byte)Math.Clamp((int)Math.Round(a + ((b - a) * t)), 0, 255);

    private void AddButton_Click(object sender, RoutedEventArgs e)
    {
        var editor = CreateEditor(null);
        if (editor.ShowDialog() != true || editor.Result is null) return;
        var task = editor.Result;
        if (task.ManualOrder <= 0)
            task.ManualOrder = _tasks.Count == 0 ? 10 : _tasks.Max(x => x.ManualOrder) + 10;
        _tasks.Add(task);
        AppServices.Data.SaveTasks(_tasks);
        AppServices.Log.Write($"新規作成: {task.Type} / {task.Title}");
        if (!string.IsNullOrWhiteSpace(task.Details)) AppServices.Voice.Queue("詳細を作成しました");
        if (task.UrlEnabled && !string.IsNullOrWhiteSpace(task.Url)) AppServices.Voice.Queue("URLを作成しました");
        AppServices.Voice.Queue("新規作成が完了しました");
        RefreshTasks();
    }

    private TaskEditorWindow CreateEditor(TaskItem? task)
    {
        var editor = new TaskEditorWindow(task is null ? null : CloneTask(task), _settings.FontSize, _settings)
        {
            Owner = this,
            Topmost = Topmost
        };
        return editor;
    }

    private void EditButton_Click(object sender, RoutedEventArgs e)
    {
        _mode = _mode == SelectMode.Edit ? SelectMode.Normal : SelectMode.Edit;
        UpdateStatus();
    }

    private void EditTask(TaskItem original)
    {
        var before = CloneTask(original);
        var editor = CreateEditor(original);
        if (editor.ShowDialog() != true || editor.Result is null) return;
        var after = editor.Result;
        var index = _tasks.FindIndex(x => x.Id == original.Id);
        if (index < 0) return;
        _tasks[index] = after;
        AppServices.Data.SaveTasks(_tasks);
        AppServices.Log.Write($"編集: {after.Type} / {after.Title}");
        QueueEditVoices(before, after);
        RefreshTasks();
    }

    private static TaskItem CloneTask(TaskItem t) => new()
    {
        Id = t.Id, Type = t.Type, Title = t.Title, Details = t.Details, Url = t.Url, UrlEnabled = t.UrlEnabled,
        Deadline = t.Deadline, DeadlineEnabled = t.DeadlineEnabled, DeadlineYearExplicit = t.DeadlineYearExplicit,
        DeadlineMetadataKnown = t.DeadlineMetadataKnown, StartTime = t.StartTime, EndDate = t.EndDate, EndTime = t.EndTime,
        Completed = t.Completed, CompletedAt = t.CompletedAt, ManualOrder = t.ManualOrder, Created = t.Created, Updated = t.Updated
    };

    private static void QueueEditVoices(TaskItem before, TaskItem after)
    {
        if (!string.Equals(before.Details, after.Details, StringComparison.Ordinal))
        {
            if (string.IsNullOrWhiteSpace(before.Details) && !string.IsNullOrWhiteSpace(after.Details)) AppServices.Voice.Queue("詳細を作成しました");
            else if (!string.IsNullOrWhiteSpace(before.Details) && string.IsNullOrWhiteSpace(after.Details)) AppServices.Voice.Queue("詳細を削除しました");
            else AppServices.Voice.Queue("詳細を変更しました");
        }

        if (!string.Equals(before.Url, after.Url, StringComparison.Ordinal) || before.UrlEnabled != after.UrlEnabled)
        {
            if (!after.UrlEnabled && before.UrlEnabled) AppServices.Voice.Queue("URLを無効にしました");
            else if (string.IsNullOrWhiteSpace(before.Url) && !string.IsNullOrWhiteSpace(after.Url)) AppServices.Voice.Queue("URLを作成しました");
            else if (!string.IsNullOrWhiteSpace(before.Url) && string.IsNullOrWhiteSpace(after.Url)) AppServices.Voice.Queue("URLを削除しました");
            else AppServices.Voice.Queue("URLを変更しました");
        }

        if (before.DeadlineEnabled != after.DeadlineEnabled ||
            !string.Equals(before.Deadline, after.Deadline, StringComparison.Ordinal) ||
            !string.Equals(before.StartTime, after.StartTime, StringComparison.Ordinal) ||
            !string.Equals(before.EndDate, after.EndDate, StringComparison.Ordinal) ||
            !string.Equals(before.EndTime, after.EndTime, StringComparison.Ordinal))
            AppServices.Voice.Queue("期限を変更しました");

        AppServices.Voice.Queue(after.Type == "予定" ? "予定を変更しました" : "タスクを変更しました");
        AppServices.Voice.Queue("編集を完了しました");
    }

    private void DeleteTask(TaskItem task)
    {
        var result = MessageBox.Show($"「{task.Title}」を削除しますか？", "削除確認", MessageBoxButton.YesNo, MessageBoxImage.Question);
        if (result != MessageBoxResult.Yes) return;
        _tasks.RemoveAll(x => x.Id == task.Id);
        if (_settings.SortMode == "Manual") NormalizeManualOrder(_tasks.OrderBy(x => x.ManualOrder).ThenBy(x => x.Created, StringComparer.Ordinal));
        AppServices.Data.SaveTasks(_tasks);
        AppServices.Log.Write($"削除: {task.Type} / {task.Title}");
        AppServices.Voice.Queue(task.Type == "予定" ? "予定を削除しました" : "タスクを削除しました");
        RefreshTasks();
    }

    private void FontUpButton_Click(object sender, RoutedEventArgs e) => ChangeFontSize(1.0);
    private void FontDownButton_Click(object sender, RoutedEventArgs e) => ChangeFontSize(-1.0);

    private void ChangeFontSize(double delta)
    {
        var value = Math.Clamp(_settings.FontSize + delta, 8, 30);
        if (Math.Abs(value - _settings.FontSize) < 0.01) return;

        _settings.FontSize = value;
        FontSize = value;
        FontLabel.Text = $"文字サイズ: {_settings.FontSize:0.0} pt";

        UpdateResponsiveLayout();
        RefreshTasks();
        AppServices.Data.SaveSettings(_settings);

        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() =>
        {
            UpdateResponsiveLayout();
            RefreshTasks();
        }));
    }

    private void MainWindow_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
        {
            ChangeFontSize(e.Delta > 0 ? 1.0 : -1.0);
            e.Handled = true;
        }
    }

    private void TaskScroll_PreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control) return;
        TaskScroll.ScrollToVerticalOffset(TaskScroll.VerticalOffset - e.Delta / 3.0);
        e.Handled = true;
    }

    private void UpdateStatus(string? text = null)
    {
        StatusText.Text = text ?? (_mode == SelectMode.Edit
            ? "編集するタスク / 予定を選択してください。"
            : "デスクトップ用タスク・予定表");
        UpdateCountText();
    }

    private void LockButton_Click(object sender, RoutedEventArgs e)
    {
        _settings.Locked = !_settings.Locked;
        UpdateResponsiveLayout();
        ScheduleSaveSettings();
        AppServices.Log.Write($"位置固定: {(_settings.Locked ? "ON" : "OFF")}");
    }

    private void TopmostButton_Click(object sender, RoutedEventArgs e)
    {
        _settings.Topmost = !_settings.Topmost;
        Topmost = _settings.Topmost;
        UpdateResponsiveLayout();
        ScheduleSaveSettings();
        AppServices.Log.Write($"最前面: {(_settings.Topmost ? "ON" : "OFF")}");
    }

    private void MinimizeButton_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;
    private void MaximizeButton_Click(object sender, RoutedEventArgs e) => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        if (e.ClickCount == 2)
        {
            MaximizeButton_Click(sender, e);
            return;
        }
        if (_settings.Locked || WindowState == WindowState.Maximized) return;
        try { DragMove(); } catch { }
    }

    private void OpenUrlPopup(TaskItem task, Button button)
    {
        _urlPopupTask = task;
        UrlPopup.PlacementTarget = button;
        UrlPopupText.Text = task.Url;
        UrlOpenButton.IsEnabled = task.UrlEnabled && UrlHelper.IsHttpUrl(task.Url);
        UrlDisableButton.IsEnabled = task.UrlEnabled;
        UrlDeleteButton.IsEnabled = !string.IsNullOrWhiteSpace(task.Url);
        UrlPopup.IsOpen = true;
        Dispatcher.BeginInvoke(new Action(() => { UrlPopupText.Focus(); UrlPopupText.SelectAll(); }));
    }

    private void UrlOpenButton_Click(object sender, RoutedEventArgs e)
    {
        if (_urlPopupTask is null) return;
        try { UrlHelper.Open(_urlPopupTask.Url); }
        catch (Exception ex)
        {
            AppServices.Log.WriteError("URLオープンエラー", ex);
            AppServices.Voice.Queue("エラーが発生しました。");
            UpdateStatus("URLを開けませんでした。");
        }
    }

    private void UrlSaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (_urlPopupTask is null) return;
        var raw = UrlPopupText.Text.Trim();
        if (raw.Length == 0 || !UrlHelper.IsHttpUrl(raw))
        {
            UpdateStatus("URLが正しくありません。");
            return;
        }
        var hadUrl = !string.IsNullOrWhiteSpace(_urlPopupTask.Url);
        _urlPopupTask.Url = UrlHelper.Normalize(raw);
        _urlPopupTask.UrlEnabled = true;
        _urlPopupTask.Updated = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        AppServices.Data.SaveTasks(_tasks);
        AppServices.Voice.Queue(hadUrl ? "URLを変更しました" : "URLを作成しました");
        AppServices.Log.Write($"URL保存: {_urlPopupTask.Title}");
        UrlPopup.IsOpen = false;
        RefreshTasks();
    }

    private void UrlDisableButton_Click(object sender, RoutedEventArgs e)
    {
        if (_urlPopupTask is null) return;
        _urlPopupTask.UrlEnabled = false;
        _urlPopupTask.Updated = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        AppServices.Data.SaveTasks(_tasks);
        AppServices.Voice.Queue("URLを無効にしました");
        UrlPopup.IsOpen = false;
        RefreshTasks();
    }

    private void UrlDeleteButton_Click(object sender, RoutedEventArgs e)
    {
        if (_urlPopupTask is null) return;
        _urlPopupTask.Url = "";
        _urlPopupTask.UrlEnabled = false;
        _urlPopupTask.Updated = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        AppServices.Data.SaveTasks(_tasks);
        AppServices.Voice.Queue("URLを削除しました");
        UrlPopup.IsOpen = false;
        RefreshTasks();
    }

    private void VoiceButton_Click(object sender, RoutedEventArgs e)
    {
        VoicePopup.PlacementTarget = VoiceButton;
        VoiceVolumeSlider.Value = Math.Clamp(_settings.VoiceVolume * 100.0, 0, 100);
        UpdateVoiceVolumeLabel();
        VoicePopup.IsOpen = true;
    }

    private void VoiceVolumeSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (VoiceVolumeSlider is null) return;
        _settings.VoiceVolume = Math.Clamp(e.NewValue / 100.0, 0.0, 1.0);
        AppServices.Voice.Volume = _settings.VoiceVolume;
        UpdateVoiceVolumeLabel();
        if (_initialized) ScheduleSaveSettings();
    }

    private void UpdateVoiceVolumeLabel()
    {
        if (VoiceVolumeLabel is not null)
            VoiceVolumeLabel.Text = $"{Math.Round(_settings.VoiceVolume * 100):0}%";
    }

    private void VoiceTestButton_Click(object sender, RoutedEventArgs e)
    {
        AppServices.Voice.Queue("予定表が起動しました");
    }

    private void BackgroundButton_Click(object sender, RoutedEventArgs e)
    {
        BackgroundPopup.PlacementTarget = BackgroundButton;
        ApplyThemeColors();
        BackgroundOpacitySlider.Value = Math.Clamp(_settings.BackgroundImageOpacity * 100.0, 0, 100);
        ReadabilityOpacitySlider.Value = Math.Clamp(_settings.ReadabilityOverlayOpacity * 100.0, 0, 70);
        UpdateBackgroundOpacityLabel();
        UpdateReadabilityOpacityLabel();
        BackgroundPopup.IsOpen = true;
    }

    private void TextColorChoose_Click(object sender, RoutedEventArgs e)
    {
        var before = _settings.TextColor;
        var chosen = ShowColorDialog(before);
        if (chosen is null || string.Equals(chosen, before, StringComparison.OrdinalIgnoreCase)) return;

        var wasDefault = string.Equals(before, "#00FF66", StringComparison.OrdinalIgnoreCase);
        _settings.TextColor = chosen;
        ApplyThemeColors();
        ApplyBackgroundVisibility();
        RefreshTasks();
        AppServices.Data.SaveSettings(_settings);
        AppServices.Voice.Queue(wasDefault ? "文字の色を設定しました" : "文字の色を変更しました");
        UpdateStatus($"文字色を {_settings.TextColor} に変更しました。");
    }

    private void BackgroundColorChoose_Click(object sender, RoutedEventArgs e)
    {
        var before = _settings.BackgroundColor;
        var chosen = ShowColorDialog(before);
        if (chosen is null || string.Equals(chosen, before, StringComparison.OrdinalIgnoreCase)) return;

        var wasDefault = string.Equals(before, "#000000", StringComparison.OrdinalIgnoreCase);
        _settings.BackgroundColor = chosen;
        ApplyThemeColors();
        ApplyBackgroundVisibility();
        RefreshTasks();
        AppServices.Data.SaveSettings(_settings);
        AppServices.Voice.Queue(wasDefault ? "背景を設定しました" : "背景を変更しました");
        UpdateStatus($"背景色を {_settings.BackgroundColor} に変更しました。");
    }

    private void ResetColors_Click(object sender, RoutedEventArgs e)
    {
        var textChanged = !string.Equals(_settings.TextColor, "#00FF66", StringComparison.OrdinalIgnoreCase);
        var backgroundChanged = !string.Equals(_settings.BackgroundColor, "#000000", StringComparison.OrdinalIgnoreCase);

        _settings.TextColor = "#00FF66";
        _settings.BackgroundColor = "#000000";
        ApplyThemeColors();
        ApplyBackgroundVisibility();
        RefreshTasks();
        AppServices.Data.SaveSettings(_settings);

        if (textChanged) AppServices.Voice.Queue("文字の色を変更しました");
        if (backgroundChanged) AppServices.Voice.Queue("背景を変更しました");
        UpdateStatus("文字色と背景色を初期値に戻しました。");
    }

    private string? ShowColorDialog(string initialHex)
    {
        var initial = ParseColorOrDefault(initialHex, Color.FromRgb(0, 255, 102));
        using var dialog = new System.Windows.Forms.ColorDialog
        {
            AllowFullOpen = true,
            AnyColor = true,
            FullOpen = true,
            Color = System.Drawing.Color.FromArgb(initial.R, initial.G, initial.B)
        };

        return dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK
            ? $"#{dialog.Color.R:X2}{dialog.Color.G:X2}{dialog.Color.B:X2}"
            : null;
    }

    private void ApplyThemeColors()
    {
        var textColor = ParseColorOrDefault(_settings.TextColor, Color.FromRgb(0, 255, 102));
        var backgroundColor = ParseColorOrDefault(_settings.BackgroundColor, Colors.Black);

        _settings.TextColor = $"#{textColor.R:X2}{textColor.G:X2}{textColor.B:X2}";
        _settings.BackgroundColor = $"#{backgroundColor.R:X2}{backgroundColor.G:X2}{backgroundColor.B:X2}";

        Resources["TextColorBrush"] = new SolidColorBrush(textColor);
        Resources["BackgroundColorBrush"] = new SolidColorBrush(backgroundColor);

        SetSurfaceBrushColor("ChromeFillBrush", backgroundColor);
        SetSurfaceBrushColor("PanelFillBrush", backgroundColor);
        SetSurfaceBrushColor("HeaderFillBrush", backgroundColor);
        SetSurfaceBrushColor("ButtonFillBrush", backgroundColor);
        SetSurfaceBrushColor("RowFillBrush", backgroundColor);

        var luminance = (0.2126 * textColor.R + 0.7152 * textColor.G + 0.0722 * textColor.B) / 255.0;
        Resources["TextHaloEffect"] = new System.Windows.Media.Effects.DropShadowEffect
        {
            Color = luminance >= 0.50 ? Colors.Black : Colors.White,
            ShadowDepth = 0,
            BlurRadius = 3.2,
            Opacity = 1.0
        };

        if (TextColorPreview is not null)
            TextColorPreview.Background = new SolidColorBrush(textColor);
        if (BackgroundColorPreview is not null)
            BackgroundColorPreview.Background = new SolidColorBrush(backgroundColor);
    }

    private static Color ParseColorOrDefault(string? value, Color fallback)
    {
        if (string.IsNullOrWhiteSpace(value)) return fallback;
        try
        {
            var parsed = System.Windows.Media.ColorConverter.ConvertFromString(value);
            return parsed is Color c ? c : fallback;
        }
        catch { return fallback; }
    }

    private Color GetThemeTextColor()
        => ParseColorOrDefault(_settings.TextColor, Color.FromRgb(0, 255, 102));

    private void SetSurfaceBrushColor(string key, Color color)
    {
        if (Resources[key] is SolidColorBrush brush)
        {
            var opacity = brush.Opacity;
            var replacement = new SolidColorBrush(color) { Opacity = opacity };
            Resources[key] = replacement;
        }
    }

    private void BackgroundChoose_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "背景画像を選択",
            Filter = "画像ファイル|*.jpg;*.jpeg;*.png;*.bmp;*.webp|すべてのファイル|*.*"
        };
        if (dialog.ShowDialog(this) != true) return;
        try
        {
            var hadBackground = !string.IsNullOrWhiteSpace(_settings.BackgroundImagePath) && File.Exists(_settings.BackgroundImagePath);
            _settings.BackgroundImagePath = AppServices.Background.Import(dialog.FileName);
            if (_settings.BackgroundImageOpacity <= 0) _settings.BackgroundImageOpacity = 0.45;
            ApplyBackground();
            AppServices.Data.SaveSettings(_settings);
            AppServices.Voice.Queue(hadBackground ? "背景を変更しました" : "背景を設定しました");
            UpdateStatus("背景画像を設定しました。");
        }
        catch (Exception ex)
        {
            AppServices.Log.WriteError("背景画像設定エラー", ex);
            AppServices.Voice.Queue("エラーが発生しました。");
            MessageBox.Show(ex.Message, "背景画像", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void BackgroundClear_Click(object sender, RoutedEventArgs e)
    {
        AppServices.Background.Clear();
        _settings.BackgroundImagePath = "";
        ApplyBackground();
        AppServices.Data.SaveSettings(_settings);
        AppServices.Voice.Queue("背景を変更しました");
        BackgroundPopup.IsOpen = false;
        UpdateStatus("背景画像を解除しました。");
    }

    private void BackgroundOpacitySlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (BackgroundImage is null) return;
        _settings.BackgroundImageOpacity = Math.Clamp(e.NewValue / 100.0, 0, 1);
        ApplyBackgroundVisibility();
        UpdateBackgroundOpacityLabel();
        if (_initialized) ScheduleSaveSettings();
    }

    private void ReadabilityOpacitySlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (BackgroundImage is null) return;
        _settings.ReadabilityOverlayOpacity = Math.Clamp(e.NewValue / 100.0, 0, 0.70);
        ApplyBackgroundVisibility();
        UpdateReadabilityOpacityLabel();
        if (_initialized) ScheduleSaveSettings();
    }

    private void UpdateBackgroundOpacityLabel()
    {
        if (BackgroundOpacityLabel is not null) BackgroundOpacityLabel.Text = $"{Math.Round(_settings.BackgroundImageOpacity * 100):0}%";
    }

    private void UpdateReadabilityOpacityLabel()
    {
        if (ReadabilityOpacityLabel is not null) ReadabilityOpacityLabel.Text = $"{Math.Round(_settings.ReadabilityOverlayOpacity * 100):0}%";
    }

    private void ApplyBackground()
    {
        try
        {
            var path = _settings.BackgroundImagePath;
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                path = Directory.Exists(AppServices.Paths.AssetDir)
                    ? Directory.EnumerateFiles(AppServices.Paths.AssetDir, "background.*").FirstOrDefault() ?? ""
                    : "";
                if (!string.IsNullOrWhiteSpace(path)) _settings.BackgroundImagePath = path;
            }

            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            {
                BackgroundImage.Source = null;
                ApplyBackgroundVisibility();
                return;
            }

            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.UriSource = new Uri(path, UriKind.Absolute);
            bitmap.EndInit();
            bitmap.Freeze();
            BackgroundImage.Source = bitmap;
            ApplyBackgroundVisibility();
            UpdateBackgroundOpacityLabel();
        }
        catch (Exception ex)
        {
            BackgroundImage.Source = null;
            ApplyBackgroundVisibility();
            AppServices.Log.WriteError("背景画像読込エラー", ex);
            AppServices.Voice.Queue("エラーが発生しました。");
        }
    }

    private void ApplyBackgroundVisibility()
    {
        var hasImage = BackgroundImage.Source is not null;
        var visibility = Math.Clamp(_settings.BackgroundImageOpacity, 0, 1);

        // 背景画像がある場合は画像自体を常に100%描画し、
        // 全面の黒レイヤーだけを反比例させる。
        // 100% = 黒レイヤーなし / 0% = 完全な黒背景。
        BackgroundImage.Opacity = hasImage ? 1.0 : 0.0;
        BackgroundShade.Opacity = hasImage ? 1.0 - visibility : 0.0;

        // 背景画像がある間は、タイトル・左右パネル・行・ボタンの黒塗りを消す。
        // これにより100%設定時は写真をGUI全面でそのまま確認できる。
        var readability = Math.Clamp(_settings.ReadabilityOverlayOpacity, 0.0, 0.70);
        var panelOpacity = hasImage ? readability : 1.0;
        var chromeOpacity = hasImage ? Math.Clamp(readability + 0.10, 0.0, 0.80) : 1.0;
        var headerOpacity = hasImage ? Math.Clamp(readability + 0.06, 0.0, 0.76) : 1.0;
        var buttonOpacity = hasImage ? Math.Clamp(readability + 0.12, 0.0, 0.82) : 0.85;

        SetSurfaceBrushOpacity("ChromeFillBrush", chromeOpacity);
        SetSurfaceBrushOpacity("PanelFillBrush", panelOpacity);
        SetSurfaceBrushOpacity("HeaderFillBrush", headerOpacity);
        SetSurfaceBrushOpacity("RowFillBrush", panelOpacity);
        SetSurfaceBrushOpacity("ButtonFillBrush", buttonOpacity);
    }

    private void SetSurfaceBrushOpacity(string key, double opacity)
    {
        if (Resources[key] is SolidColorBrush brush)
        {
            if (brush.IsFrozen)
            {
                var clone = brush.Clone();
                clone.Opacity = opacity;
                Resources[key] = clone;
            }
            else
            {
                brush.Opacity = opacity;
            }
        }
    }

    private void CheckDeadlineNotifications()
    {
        try
        {
            var today = DateTime.Today;
            var playTask = false;
            var playSchedule = false;
            var changed = false;

            foreach (var task in _tasks)
            {
                if (task.Completed || !TryGetTaskStartDateTime(task, out var due)) continue;
                var days = (int)(due.Date - today).TotalDays;
                if (days is not (7 or 3)) continue;

                var key = $"{task.Id}|{days}|{today:yyyy-MM-dd}";
                if (!_notificationKeys.Add(key)) continue;
                changed = true;
                if (task.Type == "予定") playSchedule = true; else playTask = true;
            }

            if (changed)
            {
                _notificationState.Keys = _notificationKeys.ToList();
                AppServices.Data.SaveNotifications(_notificationState);
            }
            if (playTask) AppServices.Voice.Queue("期限が近いタスクがあります");
            if (playSchedule) AppServices.Voice.Queue("予定が近いものがあります");
        }
        catch (Exception ex) { AppServices.Log.WriteError("期限通知チェックエラー", ex); }
    }}
