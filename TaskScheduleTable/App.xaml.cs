using System.Threading;
using System.Windows;

namespace TaskScheduleTable;

public partial class App : Application
{
    private Mutex? _mutex;

    protected override void OnStartup(StartupEventArgs e)
    {
        const string mutexName = @"Local\TaskScheduleTable_Don_v2";
        _mutex = new Mutex(true, mutexName, out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show("タスク・予定表はすでに起動しています。", "タスク・予定表",
                MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        DispatcherUnhandledException += (_, args) =>
        {
            try { AppServices.Log.WriteError("未処理UIエラー", args.Exception); } catch { }
            MessageBox.Show("エラーが発生しました。Log\\Error を確認してください。", "タスク・予定表",
                MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };

        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            try
            {
                if (args.ExceptionObject is Exception ex)
                    AppServices.Log.WriteError("未処理アプリケーションエラー", ex);
            }
            catch { }
        };

        base.OnStartup(e);
        var window = new MainWindow();
        MainWindow = window;
        window.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        try { _mutex?.ReleaseMutex(); } catch { }
        _mutex?.Dispose();
        base.OnExit(e);
    }
}
