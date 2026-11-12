using Microsoft.Win32;
using System.Diagnostics;
using System.IO;
using System.Windows;

namespace TaskScheduleTableUpdater;

public partial class MainWindow : Window
{
    private readonly string _baseDir;
    private readonly string _payloadDir;

    public MainWindow()
    {
        InitializeComponent();

        _baseDir = AppContext.BaseDirectory;
        _payloadDir = Path.Combine(_baseDir, "UpdateFiles");

        TargetPathBox.Text = DetectTargetExe() ?? "";
        ShowInitialStatus();
    }

    private void ShowInitialStatus()
    {
        if (!Directory.Exists(_payloadDir))
        {
            StatusText.Text = "更新データが見つかりません。ZIPを完全に展開してから起動してください。";
            UpdateButton.IsEnabled = false;
            return;
        }

        var payloadExe = GetPayloadExe();
        if (payloadExe is null)
        {
            StatusText.Text = "UpdateFiles 内に更新用EXEがありません。";
            UpdateButton.IsEnabled = false;
            return;
        }

        if (!string.IsNullOrWhiteSpace(TargetPathBox.Text) && File.Exists(TargetPathBox.Text))
        {
            StatusText.Text =
                "旧バージョンを検出しました。\n\n" +
                TargetPathBox.Text +
                "\n\n「アップデート」を押すと、旧EXEをバックアップしてv2.6へ更新します。";
        }
        else
        {
            StatusText.Text =
                "旧バージョンを自動検出できませんでした。\n" +
                "「参照...」から現在使用中の タスク_予定表.exe を選択してください。";
        }
    }

    private string? DetectTargetExe()
    {
        var candidates = new List<string>();

        AddCandidateDirectory(candidates, _baseDir);

        var parent = Directory.GetParent(_baseDir);
        if (parent is not null)
        {
            AddCandidateDirectory(candidates, parent.FullName);
            var grand = parent.Parent;
            if (grand is not null) AddCandidateDirectory(candidates, grand.FullName);
        }

        foreach (var dir in new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads")
        })
        {
            AddCandidateDirectory(candidates, dir);
        }

        return candidates.FirstOrDefault(File.Exists);
    }

    private static void AddCandidateDirectory(List<string> list, string? directory)
    {
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory)) return;

        var direct = Path.Combine(directory, "タスク_予定表.exe");
        if (File.Exists(direct)) list.Add(direct);

        try
        {
            foreach (var exe in Directory.EnumerateFiles(directory, "タスク_予定表.exe", SearchOption.TopDirectoryOnly))
                if (!list.Contains(exe, StringComparer.OrdinalIgnoreCase)) list.Add(exe);
        }
        catch { }
    }

    private void Browse_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "現在使用中の タスク_予定表.exe を選択",
            Filter = "タスク_予定表.exe|タスク_予定表.exe|EXE (*.exe)|*.exe",
            CheckFileExists = true,
            Multiselect = false
        };

        if (dialog.ShowDialog(this) == true)
        {
            TargetPathBox.Text = dialog.FileName;
            StatusText.Text = "更新対象を選択しました。\n\n" + dialog.FileName;
        }
    }

    private async void Update_Click(object sender, RoutedEventArgs e)
    {
        UpdateButton.IsEnabled = false;

        try
        {
            var targetExe = TargetPathBox.Text.Trim();
            if (!File.Exists(targetExe))
                throw new InvalidOperationException("更新対象のEXEが見つかりません。");

            if (!string.Equals(Path.GetFileName(targetExe), "タスク_予定表.exe", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("タスク_予定表.exe を選択してください。");

            var payloadExe = GetPayloadExe()
                ?? throw new InvalidOperationException("更新用EXEが見つかりません。");

            var targetDir = Path.GetDirectoryName(targetExe)
                ?? throw new InvalidOperationException("更新対象フォルダを取得できません。");

            StatusText.Text = "アプリを終了しています...";
            await Task.Delay(100);

            foreach (var process in Process.GetProcessesByName("タスク_予定表"))
            {
                try
                {
                    process.CloseMainWindow();
                    if (!process.WaitForExit(1500)) process.Kill(true);
                }
                catch { }
            }

            var stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
            var backupDir = Path.Combine(targetDir, "Backup_PreUpdate", stamp);
            Directory.CreateDirectory(backupDir);

            File.Copy(targetExe, Path.Combine(backupDir, "タスク_予定表.exe"), true);

            StatusText.Text = "v2.6本体を更新しています...";
            await Task.Delay(100);

            CopyFileWithRetry(payloadExe, targetExe);

            var payloadVoice = Path.Combine(_payloadDir, "Voice");
            var targetVoice = Path.Combine(targetDir, "Voice");
            if (Directory.Exists(payloadVoice))
            {
                Directory.CreateDirectory(targetVoice);
                foreach (var source in Directory.EnumerateFiles(payloadVoice, "*", SearchOption.AllDirectories))
                {
                    var relative = Path.GetRelativePath(payloadVoice, source);
                    var destination = Path.Combine(targetVoice, relative);
                    Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                    File.Copy(source, destination, true);
                }
            }

            var payloadIcon = Path.Combine(_payloadDir, "TaskScheduleTable.ico");
            if (File.Exists(payloadIcon))
                File.Copy(payloadIcon, Path.Combine(targetDir, "TaskScheduleTable.ico"), true);

            StatusText.Text =
                "アップデート完了。\n\n" +
                "バックアップ: " + backupDir +
                "\n\nタスク・背景・色・VOICE音量などの設定はそのままです。\n" +
                "v2.6を起動します。";

            await Task.Delay(500);
            Process.Start(new ProcessStartInfo(targetExe) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            StatusText.Text =
                "アップデートに失敗しました。\n\n" +
                ex.Message +
                "\n\n対象EXEを「参照...」から選び直して再実行してください。";
            UpdateButton.IsEnabled = true;
        }
    }

    private string? GetPayloadExe()
    {
        if (!Directory.Exists(_payloadDir)) return null;

        var exact = Path.Combine(_payloadDir, "タスク_予定表.exe");
        if (File.Exists(exact)) return exact;

        return Directory.EnumerateFiles(_payloadDir, "*.exe", SearchOption.TopDirectoryOnly)
            .FirstOrDefault(path =>
                !Path.GetFileName(path).Contains("Updater", StringComparison.OrdinalIgnoreCase));
    }

    private static void CopyFileWithRetry(string source, string destination)
    {
        Exception? last = null;

        for (var i = 0; i < 10; i++)
        {
            try
            {
                File.Copy(source, destination, true);
                return;
            }
            catch (Exception ex)
            {
                last = ex;
                Thread.Sleep(300);
            }
        }

        throw new IOException("本体EXEを置き換えられませんでした。", last);
    }
}
