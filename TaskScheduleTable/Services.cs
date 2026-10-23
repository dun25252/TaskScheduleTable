using Microsoft.Win32;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;

namespace TaskScheduleTable;

public static class AppServices
{
    public static AppPaths Paths { get; } = new();
    public static LogService Log { get; } = new(Paths);
    public static DataService Data { get; } = new(Paths, Log);
    public static VoiceService Voice { get; } = new(Paths, Log);
    public static StartupService Startup { get; } = new(Log);
    public static BackgroundService Background { get; } = new(Paths, Log);
}

public sealed class AppPaths
{
    public string AppDir { get; } = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
    public string LocalRoot { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TaskScheduleTable");
    public string DataDir => Path.Combine(LocalRoot, "Data");
    public string AssetDir => Path.Combine(LocalRoot, "Assets");
    public string TasksFile => Path.Combine(DataDir, "tasks.json");
    public string SettingsFile => Path.Combine(DataDir, "settings.json");
    public string NotificationsFile => Path.Combine(DataDir, "notifications.json");
    public string VoiceDir => Path.Combine(AppDir, "Voice");
    public string PortableDataDir => Path.Combine(AppDir, "Data");
    public string PortableLogDir => Path.Combine(AppDir, "Log");

    public AppPaths()
    {
        Directory.CreateDirectory(DataDir);
        Directory.CreateDirectory(AssetDir);
        TryCreate(PortableDataDir);
        TryCreate(PortableLogDir);
        TryCreate(Path.Combine(PortableLogDir, "Error"));
    }

    private static void TryCreate(string path)
    {
        try { Directory.CreateDirectory(path); } catch { }
    }
}

public sealed class LogService
{
    private readonly AppPaths _paths;
    private readonly object _gate = new();
    private readonly string _fallbackLogDir;

    public LogService(AppPaths paths)
    {
        _paths = paths;
        _fallbackLogDir = Path.Combine(paths.LocalRoot, "Log");
        Directory.CreateDirectory(_fallbackLogDir);
        Directory.CreateDirectory(Path.Combine(_fallbackLogDir, "Error"));
    }

    public void Write(string message, string level = "INFO")
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}\t{level}\t{message}{Environment.NewLine}";
        lock (_gate)
        {
            var file = Path.Combine(ResolveLogDir(false), $"タスク_予定表_Log_{DateTime.Now:yyyyMMdd}.txt");
            try { File.AppendAllText(file, line, new UTF8Encoding(true)); } catch { }
        }
    }

    public void WriteError(string message, Exception? exception = null)
    {
        var text = new StringBuilder()
            .AppendLine("APP=タスク_予定表")
            .AppendLine("VERSION=1.10")
            .AppendLine($"DATETIME={DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}")
            .AppendLine($"MESSAGE={message}")
            .AppendLine("EXCEPTION_BEGIN")
            .AppendLine(exception?.ToString() ?? "(none)")
            .AppendLine("EXCEPTION_END")
            .ToString();

        lock (_gate)
        {
            var dir = ResolveLogDir(true);
            var file = Path.Combine(dir, $"タスク_予定表_Log_Error_{DateTime.Now:yyyyMMdd_HHmmss_fff}.txt");
            try { File.WriteAllText(file, text, new UTF8Encoding(true)); } catch { }
        }
    }

    private string ResolveLogDir(bool error)
    {
        var portable = error ? Path.Combine(_paths.PortableLogDir, "Error") : _paths.PortableLogDir;
        try
        {
            Directory.CreateDirectory(portable);
            var probe = Path.Combine(portable, ".write_test");
            File.WriteAllText(probe, "1");
            File.Delete(probe);
            return portable;
        }
        catch
        {
            var fallback = error ? Path.Combine(_fallbackLogDir, "Error") : _fallbackLogDir;
            Directory.CreateDirectory(fallback);
            return fallback;
        }
    }
}

public sealed class DataService
{
    private readonly AppPaths _paths;
    private readonly LogService _log;
    private readonly JsonSerializerOptions _json = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    public DataService(AppPaths paths, LogService log)
    {
        _paths = paths;
        _log = log;
    }

    public List<TaskItem> LoadTasks()
    {
        var items = Load<List<TaskItem>>(_paths.TasksFile) ?? [];
        foreach (var t in items)
        {
            if (string.IsNullOrWhiteSpace(t.Id)) t.Id = Guid.NewGuid().ToString("N");
            if (t.Type != "予定") t.Type = "タスク";
            t.Title ??= "";
            t.Details ??= "";
            t.Url ??= "";
            t.Deadline ??= "";
            if (string.IsNullOrWhiteSpace(t.Created)) t.Created = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            if (string.IsNullOrWhiteSpace(t.Updated)) t.Updated = t.Created;
        }
        return items;
    }

    public AppSettingsModel LoadSettings() => Load<AppSettingsModel>(_paths.SettingsFile) ?? new AppSettingsModel();
    public NotificationState LoadNotifications() => Load<NotificationState>(_paths.NotificationsFile) ?? new NotificationState();

    public void SaveTasks(IEnumerable<TaskItem> tasks)
    {
        SaveAtomic(_paths.TasksFile, tasks.ToList());
        TryMirror(Path.Combine(_paths.PortableDataDir, "tasks.json"), tasks.ToList());
    }

    public void SaveSettings(AppSettingsModel settings)
    {
        SaveAtomic(_paths.SettingsFile, settings);
        TryMirror(Path.Combine(_paths.PortableDataDir, "settings.json"), settings);
    }

    public void SaveNotifications(NotificationState state)
    {
        SaveAtomic(_paths.NotificationsFile, state);
        TryMirror(Path.Combine(_paths.PortableDataDir, "notifications.json"), state);
    }

    private T? Load<T>(string path)
    {
        foreach (var candidate in new[] { path, path + ".bak" })
        {
            if (!File.Exists(candidate)) continue;
            try
            {
                var json = File.ReadAllText(candidate, Encoding.UTF8);
                if (!string.IsNullOrWhiteSpace(json)) return JsonSerializer.Deserialize<T>(json, _json);
            }
            catch (Exception ex)
            {
                _log.WriteError($"JSON読込失敗: {candidate}", ex);
            }
        }
        return default;
    }

    private void SaveAtomic<T>(string path, T value)
    {
        var tmp = path + ".tmp";
        var bak = path + ".bak";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var json = JsonSerializer.Serialize(value, _json);
            File.WriteAllText(tmp, json, new UTF8Encoding(false));
            if (File.Exists(path)) File.Copy(path, bak, true);
            File.Move(tmp, path, true);
        }
        catch (Exception ex)
        {
            try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
            _log.WriteError($"JSON保存失敗: {path}", ex);
        }
    }

    private void TryMirror<T>(string path, T value)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(value, _json), new UTF8Encoding(false));
        }
        catch { }
    }
}

public sealed class StartupService
{
    private readonly LogService _log;
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "TaskScheduleTable";

    public StartupService(LogService log) => _log = log;

    public void EnsureRegistered()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (string.IsNullOrWhiteSpace(exe) || !File.Exists(exe))
                throw new FileNotFoundException("実行中のEXEパスを取得できませんでした。", exe);

            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true) ?? Registry.CurrentUser.CreateSubKey(RunKey);
            key?.SetValue(ValueName, $"\"{exe}\"", RegistryValueKind.String);
            RemoveLegacyShortcut();
            _log.Write($"Windows自動起動登録: {exe}");
        }
        catch (Exception ex)
        {
            _log.WriteError("Windows自動起動登録に失敗しました。", ex);
        }
    }

    private static void RemoveLegacyShortcut()
    {
        try
        {
            var startup = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
            var old = Path.Combine(startup, "タスク_予定表.lnk");
            if (File.Exists(old)) File.Delete(old);
        }
        catch { }
    }
}

public sealed class VoiceService
{
    private readonly AppPaths _paths;
    private readonly LogService _log;
    private readonly Queue<string> _queue = new();
    private readonly MediaPlayer _player = new();
    private bool _playing;

    public VoiceService(AppPaths paths, LogService log)
    {
        _paths = paths;
        _log = log;
        _player.MediaEnded += (_, _) => FinishCurrent();
        _player.MediaFailed += (_, e) =>
        {
            _log.WriteError("ボイス再生に失敗しました。", e.ErrorException);
            FinishCurrent();
        };
    }

    public void Queue(string baseName)
    {
        Application.Current.Dispatcher.Invoke(() =>
        {
            var path = Path.Combine(_paths.VoiceDir, baseName + ".wav");
            if (!File.Exists(path))
            {
                _log.Write($"VOICEなし: {baseName}.wav", "WARN");
                return;
            }
            _queue.Enqueue(path);
            StartNext();
        });
    }

    private void StartNext()
    {
        if (_playing || _queue.Count == 0) return;
        var path = _queue.Dequeue();
        try
        {
            _playing = true;
            _player.Open(new Uri(path, UriKind.Absolute));
            _player.Play();
        }
        catch (Exception ex)
        {
            _playing = false;
            _log.WriteError("ボイス再生開始エラー", ex);
            StartNext();
        }
    }

    private void FinishCurrent()
    {
        try { _player.Stop(); _player.Close(); } catch { }
        _playing = false;
        StartNext();
    }
}

public sealed class BackgroundService
{
    private readonly AppPaths _paths;
    private readonly LogService _log;
    private static readonly HashSet<string> AllowedExtensions = new(StringComparer.OrdinalIgnoreCase)
    { ".jpg", ".jpeg", ".png", ".bmp", ".webp" };

    public BackgroundService(AppPaths paths, LogService log)
    {
        _paths = paths;
        _log = log;
    }

    public string Import(string source)
    {
        var ext = Path.GetExtension(source);
        if (!AllowedExtensions.Contains(ext)) throw new InvalidOperationException("対応画像は JPG / PNG / BMP / WEBP です。");
        Directory.CreateDirectory(_paths.AssetDir);
        foreach (var old in Directory.EnumerateFiles(_paths.AssetDir, "background.*"))
        {
            try { File.Delete(old); } catch { }
        }
        var dest = Path.Combine(_paths.AssetDir, "background" + ext.ToLowerInvariant());
        File.Copy(source, dest, true);
        _log.Write($"背景画像を設定: {dest}");
        return dest;
    }

    public void Clear()
    {
        try
        {
            if (Directory.Exists(_paths.AssetDir))
            {
                foreach (var file in Directory.EnumerateFiles(_paths.AssetDir, "background.*"))
                    File.Delete(file);
            }
            _log.Write("背景画像を解除");
        }
        catch (Exception ex) { _log.WriteError("背景画像削除エラー", ex); }
    }
}

public static class UrlHelper
{
    public static string Normalize(string value)
    {
        var s = (value ?? "").Trim();
        if (s.Length == 0) return "";
        if (!s.Contains("://", StringComparison.Ordinal)) s = "https://" + s;
        return s;
    }

    public static bool IsHttpUrl(string value)
    {
        return Uri.TryCreate(Normalize(value), UriKind.Absolute, out var uri) &&
               (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps);
    }

    public static void Open(string value)
    {
        var url = Normalize(value);
        if (!IsHttpUrl(url)) throw new InvalidOperationException("URLが正しくありません。");
        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    }
}
