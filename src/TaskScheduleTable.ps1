$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# GPUを明示的に使用せず、WPF描画をCPUのソフトウェアレンダリングに固定する。
try { [System.Windows.Interop.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly } catch { }

if ([string]::IsNullOrWhiteSpace([string]$global:TaskTableBootstrapPath)) {
    $script:ScriptPath = $PSCommandPath
} else {
    $script:ScriptPath = [string]$global:TaskTableBootstrapPath
}
if ([string]::IsNullOrWhiteSpace($script:ScriptPath)) {
    $script:ScriptPath = Join-Path (Get-Location).Path 'TaskScheduleTable.ps1'
}

$script:AppName = 'タスク_予定表'
$script:Version = '1.7'
$script:AppDir = Split-Path -Parent $script:ScriptPath
function Resolve-LauncherExePath {
    param([string]$BaseDir)

    foreach ($name in @('タスク_予定表.exe', 'TaskScheduleTable.exe')) {
        $candidate = Join-Path $BaseDir $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }

    try {
        $exeFiles = @(Get-ChildItem -LiteralPath $BaseDir -File -Filter '*.exe' -ErrorAction Stop)
        if ($exeFiles.Count -eq 1) {
            return [System.IO.Path]::GetFullPath($exeFiles[0].FullName)
        }
    } catch { }

    return (Join-Path $BaseDir 'タスク_予定表.exe')
}

$script:ExePath = Resolve-LauncherExePath $script:AppDir
$script:VoiceDir = Join-Path $script:AppDir 'Voice'

# v1.3: エラー音声はエラーログと連動。起動初期のエラーはボイス初期化後まで保留する。
$script:VoiceSystemReady = $false
$script:ErrorVoicePending = $false
$script:LastErrorVoiceRequest = [DateTime]::MinValue

# v1.2: タスク/設定データはバージョンフォルダーから独立した固定保存先を正本とする。
# これにより v1.1 -> v1.2 のようにフォルダー名が変わっても前回データを継続利用できる。
$script:PortableDataDir = Join-Path $script:AppDir 'Data'
$script:UserDataRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'TaskScheduleTable'
$script:DataDir = Join-Path $script:UserDataRoot 'Data'

# Log は従来どおり配布フォルダー内に保持し、ユーザーが直接確認できるようにする。
$script:LogDir = Join-Path $script:AppDir 'Log'
$script:ErrorLogDir = Join-Path $script:LogDir 'Error'

$script:TasksFile = Join-Path $script:DataDir 'tasks.json'
$script:SettingsFile = Join-Path $script:DataDir 'settings.json'
$script:NotificationsFile = Join-Path $script:DataDir 'notifications.json'

$script:PortableTasksFile = Join-Path $script:PortableDataDir 'tasks.json'
$script:PortableSettingsFile = Join-Path $script:PortableDataDir 'settings.json'
$script:PortableNotificationsFile = Join-Path $script:PortableDataDir 'notifications.json'

foreach ($dir in @($script:DataDir, $script:PortableDataDir, $script:LogDir, $script:ErrorLogDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$script:Utf8Bom = New-Object System.Text.UTF8Encoding -ArgumentList $true

function Write-AppLog {
    param([string]$Message, [string]$Level = 'INFO')
    try {
        $day = Get-Date -Format 'yyyyMMdd'
        $path = Join-Path $script:LogDir ("{0}_Log_{1}.txt" -f $script:AppName, $day)
        $line = '[{0}] [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message, [Environment]::NewLine
        [System.IO.File]::AppendAllText($path, $line, $script:Utf8Bom)
    } catch {
        # ログ書き込み失敗でアプリ本体を止めない。
    }
}

function Write-StartupTrace {
    param([string]$Message)
    try {
        $path = Join-Path $script:LogDir 'startup_trace.txt'
        $line = '[{0}] {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message, [Environment]::NewLine
        [System.IO.File]::AppendAllText($path, $line, $script:Utf8Bom)
    } catch { }
}

function Write-ErrorLog {
    param([string]$Message, [System.Exception]$Exception = $null)
    try {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
        $path = Join-Path $script:ErrorLogDir ("{0}_Log_Error_{1}.txt" -f $script:AppName, $stamp)
        $body = @()
        $body += ('APP={0}' -f $script:AppName)
        $body += ('VERSION={0}' -f $script:Version)
        $body += ('DATETIME={0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'))
        $body += ('MESSAGE={0}' -f $Message)
        if ($null -ne $Exception) {
            $body += 'EXCEPTION_BEGIN'
            $body += $Exception.ToString()
            $body += 'EXCEPTION_END'
        }
        [System.IO.File]::WriteAllText($path, (($body -join [Environment]::NewLine) + [Environment]::NewLine), $script:Utf8Bom)

        # v1.3: ボイス再生系そのものの失敗では再帰させない。
        if ($Message -notmatch '^ボイス') {
            $script:ErrorVoicePending = $true
            if ($script:VoiceSystemReady) {
                try {
                    $nowErrorVoice = [DateTime]::Now
                    if (($nowErrorVoice - $script:LastErrorVoiceRequest).TotalSeconds -ge 5) {
                        Queue-Voice 'エラーが発生しました。'
                        $script:LastErrorVoiceRequest = $nowErrorVoice
                        $script:ErrorVoicePending = $false
                    }
                } catch { }
            }
        }
    } catch {
        # エラーログ自体の失敗では再帰しない。
    }
}


function Initialize-DataStore {
    try {
        $pairs = @(
            @($script:PortableTasksFile, $script:TasksFile),
            @($script:PortableSettingsFile, $script:SettingsFile),
            @($script:PortableNotificationsFile, $script:NotificationsFile)
        )
        foreach ($pair in $pairs) {
            $src = [string]$pair[0]
            $dst = [string]$pair[1]
            if (-not (Test-Path -LiteralPath $dst) -and (Test-Path -LiteralPath $src)) {
                Copy-Item -LiteralPath $src -Destination $dst -Force
                Write-AppLog ("固定データ領域へ移行: {0} -> {1}" -f $src, $dst)
            }
        }
        Write-StartupTrace ("データ保存先: {0}" -f $script:DataDir)
    } catch {
        Write-ErrorLog 'データ保存先の初期化/移行に失敗しました。' $_.Exception
    }
}

Initialize-DataStore

Write-StartupTrace '基本初期化完了 / watchdog初期化開始'

# GUI応答停止をUIスレッドとは別のC#監視スレッドで検出し、5秒超の無応答をErrorログへ残す。
$watchdogCode = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

public static class TaskTableFreezeWatchdog
{
    private static Thread worker;
    private static volatile bool running;
    private static long lastBeat;
    private static bool logged;
    private static string errorDir;
    private static string appName;

    public static void Start(string dir, string name)
    {
        if (worker != null) return;
        errorDir = dir;
        appName = name;
        Directory.CreateDirectory(errorDir);
        Interlocked.Exchange(ref lastBeat, Stopwatch.GetTimestamp());
        running = true;
        worker = new Thread(Loop);
        worker.IsBackground = true;
        worker.Name = "TaskTableFreezeWatchdog";
        worker.Start();
    }

    public static void Beat()
    {
        Interlocked.Exchange(ref lastBeat, Stopwatch.GetTimestamp());
    }

    public static void Stop()
    {
        running = false;
    }

    private static void Loop()
    {
        while (running)
        {
            Thread.Sleep(1000);
            long now = Stopwatch.GetTimestamp();
            long beat = Interlocked.Read(ref lastBeat);
            double seconds = (double)(now - beat) / Stopwatch.Frequency;
            if (seconds >= 5.0 && !logged)
            {
                logged = true;
                try
                {
                    string stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss_fff");
                    string path = Path.Combine(errorDir, appName + "_Log_Error_" + stamp + ".txt");
                    string text =
                        "APP=" + appName + Environment.NewLine +
                        "DATETIME=" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + Environment.NewLine +
                        "MESSAGE=GUI応答遅延 / フリーズ疑い（5秒以上ハートビート停止）" + Environment.NewLine +
                        "DETAIL=heartbeat_delay_seconds:" + seconds.ToString("F1") + Environment.NewLine;
                    File.WriteAllText(path, text, new UTF8Encoding(true));
                }
                catch { }
            }
            else if (seconds < 2.0 && logged)
            {
                logged = false;
            }
        }
    }
}
'@
try {
    Add-Type -TypeDefinition $watchdogCode -Language CSharp
    [TaskTableFreezeWatchdog]::Start($script:ErrorLogDir, $script:AppName)
} catch {
    Write-ErrorLog 'フリーズ監視機能の初期化に失敗しました。' $_.Exception
}

Write-StartupTrace 'watchdog初期化処理通過'

function Save-JsonAtomic {
    param([string]$Path, $Object, [int]$Depth = 8)
    try {
        $tmp = $Path + '.tmp'
        $bak = $Path + '.bak'
        $json = ConvertTo-Json -InputObject $Object -Depth $Depth
        [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8Bom)
        if (Test-Path -LiteralPath $Path) {
            Copy-Item -LiteralPath $Path -Destination $bak -Force
        }
        Move-Item -LiteralPath $tmp -Destination $Path -Force
        return $true
    } catch {
        Write-ErrorLog ("JSON保存失敗: {0}" -f $Path) $_.Exception
        return $false
    }
}

function Read-JsonSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        Write-ErrorLog ("JSON読込失敗: {0}" -f $Path) $_.Exception
        $bak = $Path + '.bak'
        if (Test-Path -LiteralPath $bak) {
            try {
                $raw = [System.IO.File]::ReadAllText($bak, [System.Text.Encoding]::UTF8)
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    Write-AppLog ("バックアップから復旧: {0}" -f $Path) 'WARN'
                    return ($raw | ConvertFrom-Json)
                }
            } catch {
                Write-ErrorLog ("JSONバックアップ読込失敗: {0}" -f $bak) $_.Exception
            }
        }
        return $null
    }
}

function Get-PropertyValue {
    param($Object, [string]$Name, $DefaultValue)
    if ($null -eq $Object) { return $DefaultValue }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $DefaultValue }
    if ($null -eq $p.Value) { return $DefaultValue }
    return $p.Value
}

function Normalize-Task {
    param($Task)
    $id = [string](Get-PropertyValue $Task 'Id' '')
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [Guid]::NewGuid().ToString('N') }
    $type = [string](Get-PropertyValue $Task 'Type' 'タスク')
    if ($type -ne '予定') { $type = 'タスク' }
    return [PSCustomObject]@{
        Id = $id
        Type = $type
        Title = [string](Get-PropertyValue $Task 'Title' '')
        Details = [string](Get-PropertyValue $Task 'Details' '')
        Url = [string](Get-PropertyValue $Task 'Url' '')
        UrlEnabled = [bool](Get-PropertyValue $Task 'UrlEnabled' $false)
        Deadline = [string](Get-PropertyValue $Task 'Deadline' '')
        DeadlineEnabled = [bool](Get-PropertyValue $Task 'DeadlineEnabled' $false)
        DeadlineYearExplicit = [bool](Get-PropertyValue $Task 'DeadlineYearExplicit' $false)
        DeadlineMetadataKnown = ($null -ne $Task.PSObject.Properties['DeadlineYearExplicit'])
        Created = [string](Get-PropertyValue $Task 'Created' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        Updated = [string](Get-PropertyValue $Task 'Updated' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    }
}

$script:Tasks = @()
$loadedTasks = Read-JsonSafe $script:TasksFile
if ($null -ne $loadedTasks) {
    foreach ($t in @($loadedTasks)) {
        $script:Tasks += (Normalize-Task $t)
    }
}
Write-StartupTrace ("タスク読込件数: {0} / {1}" -f $script:Tasks.Count, $script:TasksFile)

# v1.3: v1.2以前はMM/DDでも現在年として保存されていた。
# 作成日時より前の期限になっている旧データは、入力時点から見て次に到来する同月日へ一度だけ補正する。
$script:LegacyDeadlineMigrated = $false
foreach ($legacyTask in $script:Tasks) {
    try {
        if ([bool]$legacyTask.DeadlineEnabled -and -not [string]::IsNullOrWhiteSpace([string]$legacyTask.Deadline) -and -not [bool]$legacyTask.DeadlineMetadataKnown) {
            $legacyDue = [DateTime]::ParseExact([string]$legacyTask.Deadline,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
            $legacyCreated = [DateTime]::Parse([string]$legacyTask.Created, [Globalization.CultureInfo]::InvariantCulture)
            if ($legacyDue.Date -lt $legacyCreated.Date) {
                $y = $legacyCreated.Year
                $candidate = New-Object System.DateTime -ArgumentList $y, $legacyDue.Month, $legacyDue.Day
                if ($candidate.Date -lt $legacyCreated.Date) { $candidate = $candidate.AddYears(1) }
                $legacyTask.Deadline = $candidate.ToString('yyyy-MM-dd')
                Write-AppLog ("旧期限を次回到来日に補正: ID={0} {1} -> {2}" -f $legacyTask.Id, $legacyDue.ToString('yyyy-MM-dd'), $legacyTask.Deadline) 'WARN'
                $script:LegacyDeadlineMigrated = $true
            }
            $legacyTask.DeadlineYearExplicit = $false
            $legacyTask.DeadlineMetadataKnown = $true
        }
    } catch {
        Write-ErrorLog ("旧期限移行エラー: ID={0}" -f $legacyTask.Id) $_.Exception
    }
}

$defaultSettings = [PSCustomObject]@{
    Left = 80.0
    Top = 80.0
    Width = 760.0
    Height = 390.0
    FontSize = 13.0
    Locked = $false
    Topmost = $false
}
$loadedSettings = Read-JsonSafe $script:SettingsFile
$script:WindowLeft = [double](Get-PropertyValue $loadedSettings 'Left' $defaultSettings.Left)
$script:WindowTop = [double](Get-PropertyValue $loadedSettings 'Top' $defaultSettings.Top)
$script:WindowWidth = [double](Get-PropertyValue $loadedSettings 'Width' $defaultSettings.Width)
$script:WindowHeight = [double](Get-PropertyValue $loadedSettings 'Height' $defaultSettings.Height)
$script:FontSize = [double](Get-PropertyValue $loadedSettings 'FontSize' $defaultSettings.FontSize)
$script:Locked = [bool](Get-PropertyValue $loadedSettings 'Locked' $defaultSettings.Locked)
$script:AlwaysOnTop = [bool](Get-PropertyValue $loadedSettings 'Topmost' $defaultSettings.Topmost)
if ($script:FontSize -lt 8.0) { $script:FontSize = 8.0 }
if ($script:FontSize -gt 30.0) { $script:FontSize = 30.0 }

$script:NotificationKeys = New-Object 'System.Collections.Generic.HashSet[string]'
$loadedNotifications = Read-JsonSafe $script:NotificationsFile
if ($null -ne $loadedNotifications) {
    $keys = Get-PropertyValue $loadedNotifications 'Keys' @()
    foreach ($k in @($keys)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$k)) {
            [void]$script:NotificationKeys.Add([string]$k)
        }
    }
}

function Save-Tasks {
    $obj = @($script:Tasks)
    $ok = Save-JsonAtomic -Path $script:TasksFile -Object $obj -Depth 8
    if ($ok) {
        # 配布フォルダー側にもミラーし、手動バックアップ/確認を可能にする。
        [void](Save-JsonAtomic -Path $script:PortableTasksFile -Object $obj -Depth 8)
    }
}

function Save-Notifications {
    $obj = [PSCustomObject]@{ Keys = @($script:NotificationKeys) }
    $ok = Save-JsonAtomic -Path $script:NotificationsFile -Object $obj -Depth 4
    if ($ok) {
        [void](Save-JsonAtomic -Path $script:PortableNotificationsFile -Object $obj -Depth 4)
    }
}

function Register-Startup {
    try {
        if (-not (Test-Path -LiteralPath $script:ExePath -PathType Leaf)) {
            $script:ExePath = Resolve-LauncherExePath $script:AppDir
        }
        if (-not (Test-Path -LiteralPath $script:ExePath -PathType Leaf)) {
            throw ('自動起動登録対象のEXEが見つかりません: ' + $script:ExePath)
        }
        Write-StartupTrace ("自動起動EXE解決: {0}" -f $script:ExePath)

        # v1.2: HKCU Run ではなくユーザーの Startup フォルダーへ .lnk を作成する。
        # Windowsの「スタートアップ アプリ」と同等のログオン時起動経路で、管理者権限は不要。
        $startupDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
        if ([string]::IsNullOrWhiteSpace($startupDir)) {
            throw 'Windows Startup フォルダーを取得できませんでした。'
        }
        if (-not (Test-Path -LiteralPath $startupDir)) {
            New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
        }

        $shortcutPath = Join-Path $startupDir 'タスク_予定表.lnk'
        $shell = $null
        $shortcut = $null
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $script:ExePath
            $shortcut.WorkingDirectory = $script:AppDir
            $shortcut.Description = 'タスク・予定表 自動起動'
            $shortcut.WindowStyle = 1
            $shortcut.Save()
        } finally {
            try { if ($null -ne $shortcut) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) } } catch { }
            try { if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } } catch { }
        }

        if (-not (Test-Path -LiteralPath $shortcutPath)) {
            throw ('Startupショートカットの作成確認に失敗しました: ' + $shortcutPath)
        }

        # v1.1以前のRunキーが残っている場合は二重起動防止のため削除。
        try {
            $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            Remove-ItemProperty -Path $runKey -Name 'TaskScheduleTable' -ErrorAction SilentlyContinue
        } catch { }

        Write-AppLog ("Windows自動起動登録: {0} -> {1}" -f $shortcutPath, $script:ExePath)
        Write-StartupTrace ("自動起動登録確認: {0}" -f $shortcutPath)
    } catch {
        Write-ErrorLog 'Windows自動起動登録に失敗しました。' $_.Exception
    }
}

# スタートアップ登録はWindow Loaded直後、他の初期化より先に実施する。

# 二重起動防止。
$script:MutexAcquired = $false
$script:SingleInstanceMutex = [System.Threading.Mutex]::new($false, 'Local\TaskScheduleTable_Don_v1')
try {
    $script:MutexAcquired = $script:SingleInstanceMutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $script:MutexAcquired = $true
}
if (-not $script:MutexAcquired) {
    try {
        [System.Windows.MessageBox]::Show('タスク・予定表はすでに起動しています。', 'タスク・予定表', 'OK', 'Information') | Out-Null
    } catch { }
    try { $script:SingleInstanceMutex.Dispose() } catch { }
    exit
}

function Normalize-Url {
    param([string]$Url)
    $u = $Url.Trim()
    if ([string]::IsNullOrWhiteSpace($u)) { return '' }
    if ($u -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $u = 'https://' + $u
    }
    return $u
}

function Test-Url {
    param([string]$Url)
    try {
        $u = Normalize-Url $Url
        if ([string]::IsNullOrWhiteSpace($u)) { return $false }
        $uri = New-Object System.Uri -ArgumentList $u
        return ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https')
    } catch {
        return $false
    }
}

function Parse-Deadline {
    param([string]$Text)
    $t = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    try {
        if ($t -match '^(\d{4})[/-](\d{1,2})[/-](\d{1,2})$') {
            $parsedDate = New-Object System.DateTime -ArgumentList ([int]$matches[1]), ([int]$matches[2]), ([int]$matches[3])
            return [PSCustomObject]@{ Date = $parsedDate; YearExplicit = $true }
        }
        if ($t -match '^(\d{1,2})[/-](\d{1,2})$') {
            $today = [DateTime]::Today
            $month = [int]$matches[1]
            $day = [int]$matches[2]
            $parsedDate = New-Object System.DateTime -ArgumentList $today.Year, $month, $day
            if ($parsedDate.Date -lt $today) { $parsedDate = $parsedDate.AddYears(1) }
            return [PSCustomObject]@{ Date = $parsedDate; YearExplicit = $false }
        }
    } catch { }
    return $null
}

function Get-TaskById {
    param([string]$Id)
    foreach ($t in $script:Tasks) {
        if ([string]$t.Id -eq $Id) { return $t }
    }
    return $null
}

function Get-TaskIndexById {
    param([string]$Id)
    for ($i = 0; $i -lt $script:Tasks.Count; $i++) {
        if ([string]$script:Tasks[$i].Id -eq $Id) { return $i }
    }
    return -1
}

function Sanitize-LogText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return (($Text -replace "`r", ' ') -replace "`n", ' ')
}

Write-StartupTrace '設定・タスク読込完了 / メインXAML生成開始'

# -------------------------
# WPF Main Window
# -------------------------
$mainXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="タスク・予定表"
        WindowStyle="None"
        ResizeMode="NoResize"
        AllowsTransparency="False"
        Background="#000000"
        BorderBrush="#000000"
        BorderThickness="0"
        Foreground="#00FF66"
        FontFamily="Yu Gothic UI"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType"
        ShowInTaskbar="True"
        MinWidth="430" MinHeight="250">
    <Window.Resources>
        <Style TargetType="{x:Type Button}">
            <Setter Property="Foreground" Value="#00FF66"/>
            <Setter Property="Background" Value="#050505"/>
            <Setter Property="BorderBrush" Value="#00FF66"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="Margin" Value="3"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Center"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="2" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#102010"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#183018"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="{x:Type TextBox}">
            <Setter Property="Foreground" Value="#00FF66"/>
            <Setter Property="Background" Value="#050505"/>
            <Setter Property="BorderBrush" Value="#00FF66"/>
            <Setter Property="CaretBrush" Value="#00FF66"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="5"/>
        </Style>
        <Style TargetType="{x:Type CheckBox}">
            <Setter Property="Foreground" Value="#00FF66"/>
            <Setter Property="Margin" Value="2"/>
        </Style>
        <Style TargetType="{x:Type RadioButton}">
            <Setter Property="Foreground" Value="#00FF66"/>
            <Setter Property="Margin" Value="2,2,14,2"/>
        </Style>
        <Style x:Key="InvisibleResizeThumbStyle" TargetType="{x:Type Thumb}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="IsTabStop" Value="False"/>
            <Setter Property="Opacity" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type Thumb}">
                        <Border Background="Transparent" BorderThickness="0"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- v1.7: Windows既定の白いスクロールバーを使用せず、黒/緑で統一する。 -->
        <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Background" Value="#000000"/>
            <Setter Property="Foreground" Value="#00FF66"/>
            <Setter Property="Width" Value="12"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollBar}">
                        <Border Background="#000000" BorderBrush="#003311" BorderThickness="1,0,0,0">
                            <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" IsDirectionReversed="True" Focusable="False">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Background="#000000" BorderThickness="0" Focusable="False" Opacity="0"/>
                                </Track.DecreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Background="#003311" Foreground="#00FF66" MinHeight="24">
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="{x:Type Thumb}">
                                                <Border Background="#003311" BorderBrush="#00FF66" BorderThickness="1" CornerRadius="2" Margin="1"/>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Background="#000000" BorderThickness="0" Focusable="False" Opacity="0"/>
                                </Track.IncreaseRepeatButton>
                            </Track>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Orientation" Value="Horizontal">
                                <Setter Property="Width" Value="Auto"/>
                                <Setter Property="Height" Value="12"/>
                                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Border BorderBrush="#00FF66" BorderThickness="1" Background="#000000" SnapsToDevicePixels="True">
        <Grid x:Name="RootGrid" Background="#000000" ClipToBounds="True">
            <Grid.RowDefinitions>
                <RowDefinition x:Name="TitleRow" Height="38"/>
                <RowDefinition Height="*"/>
                <RowDefinition x:Name="StatusRow" Height="30"/>
            </Grid.RowDefinitions>

            <Border Grid.Row="0" BorderBrush="#00FF66" BorderThickness="0,0,0,1" Background="#000000">
                <Grid x:Name="TitleBar" Background="#000000">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="TitleText" Grid.Column="0" Text="タスク・予定表" Foreground="#00FF66" VerticalAlignment="Center" Margin="10,0,6,0" FontWeight="SemiBold"/>
                    <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                        <Button x:Name="LockButton" MinWidth="92" Margin="2" Padding="7,3"/>
                        <Button x:Name="TopmostButton" MinWidth="92" Margin="2" Padding="7,3"/>
                        <Button x:Name="MinimizeButton" Content="―" Width="34" Margin="2" Padding="3"/>
                        <Button x:Name="MaximizeButton" Content="□" Width="34" Margin="2" Padding="3"/>
                        <Button x:Name="CloseButton" Content="×" Width="34" Margin="2,2,4,2" Padding="3"/>
                    </StackPanel>
                </Grid>
            </Border>

            <Grid x:Name="ContentGrid" Grid.Row="1" Margin="7">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition x:Name="LeftColumn" Width="128"/>
                    <ColumnDefinition Width="7"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Border x:Name="LeftPanelBorder" Grid.Column="0" BorderBrush="#00FF66" BorderThickness="1" Background="#000000" Padding="5">
                    <ScrollViewer x:Name="ControlScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False" Background="#000000">
                    <StackPanel>
                        <Button x:Name="AddButton" Content="追加" MinHeight="38"/>
                        <Button x:Name="EditButton" Content="編集" MinHeight="38"/>
                        <Button x:Name="DeleteButton" Content="削除" MinHeight="38"/>
                        <Button x:Name="FontUpButton" Content="文字を大きくする" MinHeight="38"/>
                        <Button x:Name="FontDownButton" Content="文字を小さくする" MinHeight="38"/>
                        <TextBlock x:Name="FontLabel" TextAlignment="Center" Foreground="#00FF66" Margin="4,8,4,2"/>
                        <TextBlock x:Name="CtrlHint" Text="Ctrl + ホイールでも変更" TextAlignment="Center" Foreground="#00AA44" TextWrapping="Wrap" Margin="3" FontSize="9"/>
                    </StackPanel>
                    </ScrollViewer>
                </Border>

                <Border Grid.Column="2" BorderBrush="#00FF66" BorderThickness="1" Background="#000000">
                    <Grid>
                        <Grid.RowDefinitions>
                            <RowDefinition x:Name="HeaderRow" Height="34"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <Border Grid.Row="0" BorderBrush="#00FF66" BorderThickness="0,0,0,1" Background="#000000">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition x:Name="HeaderUrlColumn" Width="52"/>
                                    <ColumnDefinition x:Name="HeaderDeadlineColumn" Width="94"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="UrlHeader" Grid.Column="0" Text="URL" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#00FF66"/>
                                <TextBlock x:Name="DeadlineHeader" Grid.Column="1" Text="期限日" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#00FF66"/>
                                <TextBlock x:Name="TaskTitleHeader" Grid.Column="2" Text="予定名 or タスク名" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#00FF66" TextTrimming="CharacterEllipsis"/>
                            </Grid>
                        </Border>
                        <ScrollViewer x:Name="TaskScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False" PanningMode="VerticalOnly" Background="#000000">
                            <StackPanel x:Name="TaskPanel" Background="#000000"/>
                        </ScrollViewer>
                    </Grid>
                </Border>
            </Grid>

            <Border Grid.Row="2" BorderBrush="#00FF66" BorderThickness="0,1,0,0" Background="#000000">
                <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <TextBlock x:Name="StatusText" Grid.Column="0" VerticalAlignment="Center" Margin="8,0" Foreground="#00FF66" TextTrimming="CharacterEllipsis"/>
                    <TextBlock x:Name="CountText" Grid.Column="1" VerticalAlignment="Center" Margin="8,0" Foreground="#00AA44"/>
                </Grid>
            </Border>

            <!-- v1.3: 4辺+4隅の全方向リサイズ。位置固定ONでもサイズ変更は許可する。 -->
            <Thumb x:Name="ResizeLeft" Grid.RowSpan="3" Width="7" HorizontalAlignment="Left" VerticalAlignment="Stretch" Cursor="SizeWE" Style="{StaticResource InvisibleResizeThumbStyle}"/>
            <Thumb x:Name="ResizeRight" Grid.RowSpan="3" Width="7" HorizontalAlignment="Right" VerticalAlignment="Stretch" Cursor="SizeWE" Style="{StaticResource InvisibleResizeThumbStyle}"/>
            <Thumb x:Name="ResizeTop" Grid.RowSpan="3" Height="7" HorizontalAlignment="Stretch" VerticalAlignment="Top" Cursor="SizeNS" Style="{StaticResource InvisibleResizeThumbStyle}"/>
            <Thumb x:Name="ResizeBottom" Grid.RowSpan="3" Height="7" HorizontalAlignment="Stretch" VerticalAlignment="Bottom" Cursor="SizeNS" Style="{StaticResource InvisibleResizeThumbStyle}"/>
            <Thumb x:Name="ResizeTopLeft" Grid.RowSpan="3" Width="15" Height="15" HorizontalAlignment="Left" VerticalAlignment="Top" Cursor="SizeNWSE" Style="{StaticResource InvisibleResizeThumbStyle}"/>
            <Thumb x:Name="ResizeTopRight" Grid.RowSpan="3" Width="15" Height="15" HorizontalAlignment="Right" VerticalAlignment="Top" Cursor="SizeNESW" Style="{StaticResource InvisibleResizeThumbStyle}"/>
            <Thumb x:Name="ResizeBottomLeft" Grid.RowSpan="3" Width="15" Height="15" HorizontalAlignment="Left" VerticalAlignment="Bottom" Cursor="SizeNESW" Style="{StaticResource InvisibleResizeThumbStyle}"/>
            <Thumb x:Name="ResizeBottomRight" Grid.RowSpan="3" Width="15" Height="15" HorizontalAlignment="Right" VerticalAlignment="Bottom" Cursor="SizeNWSE" Style="{StaticResource InvisibleResizeThumbStyle}"/>
        </Grid>
    </Border>
</Window>
"@

[xml]$mainXml = $mainXaml
$mainReader = New-Object System.Xml.XmlNodeReader -ArgumentList $mainXml
$script:Window = [System.Windows.Markup.XamlReader]::Load($mainReader)
Write-StartupTrace 'メインXAMLロード完了'

function Find-MainName([string]$Name) { return $script:Window.FindName($Name) }
$script:RootGrid = Find-MainName 'RootGrid'
$script:TitleBar = Find-MainName 'TitleBar'
$script:TitleText = Find-MainName 'TitleText'
$script:LockButton = Find-MainName 'LockButton'
$script:TopmostButton = Find-MainName 'TopmostButton'
$script:MinimizeButton = Find-MainName 'MinimizeButton'
$script:MaximizeButton = Find-MainName 'MaximizeButton'
$script:CloseButton = Find-MainName 'CloseButton'
$script:AddButton = Find-MainName 'AddButton'
$script:EditButton = Find-MainName 'EditButton'
$script:DeleteButton = Find-MainName 'DeleteButton'
$script:FontUpButton = Find-MainName 'FontUpButton'
$script:FontDownButton = Find-MainName 'FontDownButton'
$script:FontLabel = Find-MainName 'FontLabel'
$script:TaskScroll = Find-MainName 'TaskScroll'
$script:TaskPanel = Find-MainName 'TaskPanel'
$script:StatusText = Find-MainName 'StatusText'
$script:CountText = Find-MainName 'CountText'
$script:LeftColumn = Find-MainName 'LeftColumn'
$script:TitleRow = Find-MainName 'TitleRow'
$script:StatusRow = Find-MainName 'StatusRow'
$script:ContentGrid = Find-MainName 'ContentGrid'
$script:LeftPanelBorder = Find-MainName 'LeftPanelBorder'
$script:ControlScroll = Find-MainName 'ControlScroll'
$script:CtrlHint = Find-MainName 'CtrlHint'
$script:HeaderRow = Find-MainName 'HeaderRow'
$script:HeaderUrlColumn = Find-MainName 'HeaderUrlColumn'
$script:HeaderDeadlineColumn = Find-MainName 'HeaderDeadlineColumn'
$script:UrlHeader = Find-MainName 'UrlHeader'
$script:DeadlineHeader = Find-MainName 'DeadlineHeader'
$script:TaskTitleHeader = Find-MainName 'TaskTitleHeader'
$script:ResizeLeft = Find-MainName 'ResizeLeft'
$script:ResizeRight = Find-MainName 'ResizeRight'
$script:ResizeTop = Find-MainName 'ResizeTop'
$script:ResizeBottom = Find-MainName 'ResizeBottom'
$script:ResizeTopLeft = Find-MainName 'ResizeTopLeft'
$script:ResizeTopRight = Find-MainName 'ResizeTopRight'
$script:ResizeBottomLeft = Find-MainName 'ResizeBottomLeft'
$script:ResizeBottomRight = Find-MainName 'ResizeBottomRight'
$script:IsEdgeResizing = $false

# 保存値が画面外・極端な値なら安全側へ補正する。
$virtualLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
$virtualTop = [System.Windows.SystemParameters]::VirtualScreenTop
$virtualWidth = [System.Windows.SystemParameters]::VirtualScreenWidth
$virtualHeight = [System.Windows.SystemParameters]::VirtualScreenHeight
if ($script:WindowWidth -lt 380) { $script:WindowWidth = 380 }
if ($script:WindowHeight -lt 220) { $script:WindowHeight = 220 }
if ($script:WindowWidth -gt $virtualWidth) { $script:WindowWidth = [Math]::Max(380, $virtualWidth * 0.92) }
if ($script:WindowHeight -gt $virtualHeight) { $script:WindowHeight = [Math]::Max(220, $virtualHeight * 0.92) }
if (($script:WindowLeft + 120) -gt ($virtualLeft + $virtualWidth) -or ($script:WindowTop + 80) -gt ($virtualTop + $virtualHeight) -or ($script:WindowLeft + $script:WindowWidth) -lt ($virtualLeft + 80) -or ($script:WindowTop + 50) -lt $virtualTop) {
    $script:WindowLeft = $virtualLeft + 70
    $script:WindowTop = $virtualTop + 70
}
$script:Window.Left = $script:WindowLeft
$script:Window.Top = $script:WindowTop
$script:Window.Width = $script:WindowWidth
$script:Window.Height = $script:WindowHeight
$script:Window.Topmost = $script:AlwaysOnTop

$script:Mode = 'normal'
$script:TitleBlocks = New-Object System.Collections.ArrayList
$script:UrlPopupTaskId = ''
$script:ClosingNormally = $false
$script:ApplyingLockRect = $false
$script:LockedLeft = $script:Window.Left
$script:LockedTop = $script:Window.Top
$script:LockedWidth = $script:Window.Width
$script:LockedHeight = $script:Window.Height

function Save-Settings {
    try {
        $bounds = $script:Window.RestoreBounds
        if ($script:Window.WindowState -eq [System.Windows.WindowState]::Normal) {
            $left = $script:Window.Left
            $top = $script:Window.Top
            $width = $script:Window.Width
            $height = $script:Window.Height
        } else {
            $left = $bounds.Left
            $top = $bounds.Top
            $width = $bounds.Width
            $height = $bounds.Height
        }
        $obj = [PSCustomObject]@{
            Left = [double]$left
            Top = [double]$top
            Width = [double]$width
            Height = [double]$height
            FontSize = [double]$script:FontSize
            Locked = [bool]$script:Locked
            Topmost = [bool]$script:AlwaysOnTop
        }
        $ok = Save-JsonAtomic -Path $script:SettingsFile -Object $obj -Depth 4
        if ($ok) {
            [void](Save-JsonAtomic -Path $script:PortableSettingsFile -Object $obj -Depth 4)
        }
    } catch {
        Write-ErrorLog 'ウィンドウ設定保存に失敗しました。' $_.Exception
    }
}

function Update-LockTopmostButtons {
    if ($script:Locked) {
        if ($script:Window.WindowState -eq [System.Windows.WindowState]::Normal -and -not $script:ApplyingLockRect) {
            $script:LockedLeft = $script:Window.Left
            $script:LockedTop = $script:Window.Top
            $script:LockedWidth = $script:Window.Width
            $script:LockedHeight = $script:Window.Height
        }
        $script:MaximizeButton.IsEnabled = $false
    } else {
        $script:MaximizeButton.IsEnabled = $true
    }
    $script:Window.Topmost = $script:AlwaysOnTop
    Update-ResponsiveLayout
}

function Update-Status {
    param([string]$Text = '')
    if ([string]::IsNullOrWhiteSpace($Text)) {
        switch ($script:Mode) {
            'edit' { $Text = '編集するタスク / 予定を選択してください。' }
            'delete' { $Text = '削除するタスク / 予定を選択してください。' }
            default { $Text = 'デスクトップ用タスク・予定表' }
        }
    }
    $script:StatusText.Text = $Text
    $script:CountText.Text = ('{0} 件' -f $script:Tasks.Count)
}

function Set-ButtonCompactStyle {
    param([System.Windows.Controls.Button]$Button, [double]$Height, [double]$Font, [System.Windows.Thickness]$Padding)
    if ($null -eq $Button) { return }
    $Button.MinHeight = $Height
    $Button.FontSize = $Font
    $Button.Padding = $Padding
}

function Update-ResponsiveLayout {
    try {
        $w = [double]$script:Window.ActualWidth
        $h = [double]$script:Window.ActualHeight
        if ($w -le 0) { $w = [double]$script:Window.Width }
        if ($h -le 0) { $h = [double]$script:Window.Height }

        $compactWidth = ($w -lt 650.0)
        $veryCompactWidth = ($w -lt 520.0)
        $ultraCompactWidth = ($w -lt 450.0)
        $compactHeight = ($h -lt 350.0)
        $ultraCompactHeight = ($h -lt 285.0)

        # 文字が上下で切れないよう、タイトル・ステータス行は文字サイズに追従させる。
        if ($ultraCompactHeight) {
            $titleHeight = [double][Math]::Max(28.0, [Math]::Ceiling(([double][Math]::Min($script:FontSize, 14.0) * 1.25) + 8.0))
            $statusHeight = [double][Math]::Max(24.0, [Math]::Ceiling(([double][Math]::Min($script:FontSize, 13.0) * 1.15) + 6.0))
            $headerHeight = [double][Math]::Max(26.0, [Math]::Ceiling(([double][Math]::Min($script:FontSize, 13.0) * 1.15) + 6.0))
        } else {
            $titleHeight = [double][Math]::Max(32.0, [Math]::Ceiling(([double]$script:FontSize * 1.35) + 9.0))
            $statusHeight = [double][Math]::Max(26.0, [Math]::Ceiling(([double]$script:FontSize * 1.25) + 7.0))
            $headerHeight = [double][Math]::Max(28.0, [Math]::Ceiling(([double]$script:FontSize * 1.20) + 7.0))
        }
        $script:TitleRow.Height = [System.Windows.GridLength]::new($titleHeight, [System.Windows.GridUnitType]::Pixel)
        $script:StatusRow.Height = [System.Windows.GridLength]::new($statusHeight, [System.Windows.GridUnitType]::Pixel)
        $script:HeaderRow.Height = [System.Windows.GridLength]::new($headerHeight, [System.Windows.GridUnitType]::Pixel)

        if ($compactWidth) {
            $leftWidth = [double][Math]::Max(94.0, [Math]::Min(124.0, 70.0 + ([double]$script:FontSize * 2.4)))
            $script:ContentGrid.Margin = [System.Windows.Thickness]::new(4)
            $script:LeftPanelBorder.Padding = [System.Windows.Thickness]::new(3)
            $script:LockButton.Content = if ($script:Locked) { '固定:ON' } else { '固定:OFF' }
            $script:TopmostButton.Content = if ($script:AlwaysOnTop) { '前面:ON' } else { '前面:OFF' }
            $script:LockButton.MinWidth = 68
            $script:TopmostButton.MinWidth = 68
            $script:LockButton.Padding = [System.Windows.Thickness]::new(4,2,4,2)
            $script:TopmostButton.Padding = [System.Windows.Thickness]::new(4,2,4,2)
            $stateFont = [double][Math]::Max(9.0, [Math]::Min(14.0, $script:FontSize * 0.72))
            $script:LockButton.FontSize = $stateFont
            $script:TopmostButton.FontSize = $stateFont
            $script:FontUpButton.Content = '文字＋'
            $script:FontDownButton.Content = '文字－'
            $script:TitleText.FontSize = [double][Math]::Max(10.0, [Math]::Min($script:FontSize, $script:FontSize * 0.88))
        } else {
            $leftWidth = [double][Math]::Max(118.0, [Math]::Min(190.0, 82.0 + ([double]$script:FontSize * 3.4)))
            $script:ContentGrid.Margin = [System.Windows.Thickness]::new(7)
            $script:LeftPanelBorder.Padding = [System.Windows.Thickness]::new(5)
            $script:LockButton.Content = if ($script:Locked) { '位置固定: ON' } else { '位置固定: OFF' }
            $script:TopmostButton.Content = if ($script:AlwaysOnTop) { '最前面: ON' } else { '最前面: OFF' }
            $script:LockButton.MinWidth = 92
            $script:TopmostButton.MinWidth = 92
            $script:LockButton.Padding = [System.Windows.Thickness]::new(7,3,7,3)
            $script:TopmostButton.Padding = [System.Windows.Thickness]::new(7,3,7,3)
            $script:LockButton.FontSize = $script:FontSize
            $script:TopmostButton.FontSize = $script:FontSize
            $script:FontUpButton.Content = '文字を大きくする'
            $script:FontDownButton.Content = '文字を小さくする'
            $script:TitleText.FontSize = [double][Math]::Max(11.0, $script:FontSize)
        }
        if ($ultraCompactWidth) {
            $leftWidth = 82.0
            $script:ContentGrid.Margin = [System.Windows.Thickness]::new(2)
            $script:LeftPanelBorder.Padding = [System.Windows.Thickness]::new(2)
            $script:LockButton.Content = if ($script:Locked) { '固:ON' } else { '固:OFF' }
            $script:TopmostButton.Content = if ($script:AlwaysOnTop) { '前:ON' } else { '前:OFF' }
            $script:LockButton.MinWidth = 52
            $script:TopmostButton.MinWidth = 52
            $script:LockButton.Padding = [System.Windows.Thickness]::new(2,1,2,1)
            $script:TopmostButton.Padding = [System.Windows.Thickness]::new(2,1,2,1)
            $script:LockButton.FontSize = [double][Math]::Max(8.0, [Math]::Min(11.0, $script:FontSize * 0.62))
            $script:TopmostButton.FontSize = $script:LockButton.FontSize
            foreach ($systemButton in @($script:MinimizeButton,$script:MaximizeButton,$script:CloseButton)) {
                $systemButton.Width = 28
                $systemButton.Padding = [System.Windows.Thickness]::new(1)
                $systemButton.Margin = [System.Windows.Thickness]::new(1)
                $systemButton.FontSize = [double][Math]::Max(9.0, [Math]::Min(12.0, $script:FontSize * 0.65))
            }
            $script:TitleText.FontSize = [double][Math]::Max(8.5, [Math]::Min(11.0, $script:FontSize * 0.60))
            $script:TitleText.Margin = [System.Windows.Thickness]::new(5,0,2,0)
            $script:FontUpButton.Content = '文字＋'
            $script:FontDownButton.Content = '文字－'
        } else {
            $script:MinimizeButton.Width = 34
            $script:MaximizeButton.Width = 34
            $script:CloseButton.Width = 34
            $script:MinimizeButton.Margin = [System.Windows.Thickness]::new(2)
            $script:MaximizeButton.Margin = [System.Windows.Thickness]::new(2)
            $script:CloseButton.Margin = [System.Windows.Thickness]::new(2,2,4,2)
            $script:TitleText.Margin = [System.Windows.Thickness]::new(10,0,6,0)
        }

        $script:LeftColumn.Width = [System.Windows.GridLength]::new($leftWidth, [System.Windows.GridUnitType]::Pixel)

        # 狭い幅でもURL/期限列がタイトル領域を圧迫しすぎないようにする。
        $urlWidth = if ($ultraCompactWidth) { 34.0 } elseif ($veryCompactWidth) { 40.0 } elseif ($compactWidth) { 46.0 } else { 52.0 }
        $deadlineWidth = if ($ultraCompactWidth) { 58.0 } elseif ($veryCompactWidth) { 68.0 } elseif ($compactWidth) { 82.0 } else { 94.0 }
        $script:HeaderUrlColumn.Width = [System.Windows.GridLength]::new($urlWidth, [System.Windows.GridUnitType]::Pixel)
        $script:HeaderDeadlineColumn.Width = [System.Windows.GridLength]::new($deadlineWidth, [System.Windows.GridUnitType]::Pixel)
        $script:RowUrlWidth = $urlWidth
        $script:RowDeadlineWidth = $deadlineWidth

        $headerMax = if ($ultraCompactWidth) { 10.0 } elseif ($veryCompactWidth) { 12.0 } else { 16.0 }
        $headerFont = [double][Math]::Max(9.0, [Math]::Min($script:FontSize, $headerMax))
        $script:UrlHeader.FontSize = $headerFont
        $script:DeadlineHeader.FontSize = $headerFont
        $script:TaskTitleHeader.FontSize = $headerFont

        $buttonHeight = if ($ultraCompactHeight) { [double][Math]::Max(24.0, [Math]::Min(29.0, $script:FontSize * 1.30)) } elseif ($compactHeight) { [double][Math]::Max(27.0, [Math]::Min(34.0, $script:FontSize * 1.55)) } else { [double][Math]::Max(34.0, [Math]::Min(44.0, $script:FontSize * 1.95)) }
        $buttonFont = if ($ultraCompactHeight) { [double][Math]::Max(8.0, [Math]::Min($script:FontSize, 11.5)) } elseif ($compactHeight) { [double][Math]::Max(9.0, [Math]::Min($script:FontSize, 14.0)) } else { [double]$script:FontSize }
        $buttonPadding = if ($ultraCompactHeight) { [System.Windows.Thickness]::new(3,1,3,1) } elseif ($compactHeight) { [System.Windows.Thickness]::new(5,2,5,2) } else { [System.Windows.Thickness]::new(8,5,8,5) }
        foreach ($btn in @($script:AddButton,$script:EditButton,$script:DeleteButton,$script:FontUpButton,$script:FontDownButton)) {
            Set-ButtonCompactStyle $btn $buttonHeight $buttonFont $buttonPadding
        }
        $script:CtrlHint.Visibility = if ($compactHeight) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
        $script:FontLabel.Visibility = if ($ultraCompactHeight) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }
        $script:FontLabel.FontSize = [double][Math]::Max(8.0, [Math]::Min($script:FontSize, 15.0))
        $script:StatusText.FontSize = if ($ultraCompactHeight) { [double][Math]::Max(8.0, [Math]::Min($script:FontSize, 12.0)) } else { [double][Math]::Max(9.0, [Math]::Min($script:FontSize, 17.0)) }
        $script:CountText.FontSize = $script:StatusText.FontSize

        # 最小サイズを従来より縮小。高さ不足時は左操作欄だけ内部スクロールして操作性を維持する。
        $script:Window.MinWidth = [double][Math]::Max(380.0, 285.0 + $leftWidth)
        $script:Window.MinHeight = [double]220.0
    } catch {
        Write-ErrorLog 'レスポンシブレイアウト反映エラー' $_.Exception
    }
}

function Apply-FontSize {
    $script:Window.FontSize = [double]$script:FontSize
    $script:FontLabel.Text = ('文字サイズ: {0:0.0} pt' -f $script:FontSize)
    Update-ResponsiveLayout
    Render-Tasks
    Save-Settings
}

function Get-DueBrush {
    param($Task)
    $green = [System.Windows.Media.Color]::FromRgb(0,255,102)
    if (-not [bool]$Task.DeadlineEnabled -or [string]::IsNullOrWhiteSpace([string]$Task.Deadline)) {
        return ([System.Windows.Media.SolidColorBrush]::new($green))
    }
    try {
        $due = [DateTime]::ParseExact([string]$Task.Deadline, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $days = [int][Math]::Floor(($due.Date - [DateTime]::Today).TotalDays)
        if ($days -ge 14) { return ([System.Windows.Media.SolidColorBrush]::new($green)) }
        if ($days -le 0) {
            $c = [System.Windows.Media.Color]::FromRgb(255,38,52)
            return ([System.Windows.Media.SolidColorBrush]::new($c))
        }
        $ratio = (14.0 - [double]$days) / 14.0
        $r = [int][Math]::Round(255.0 * $ratio)
        $g = [int][Math]::Round(255.0 * (1.0 - $ratio))
        $b = [int][Math]::Round(102.0 - (50.0 * $ratio))
        $c = [System.Windows.Media.Color]::FromRgb([byte]$r, [byte]$g, [byte]$b)
        return ([System.Windows.Media.SolidColorBrush]::new($c))
    } catch {
        return ([System.Windows.Media.SolidColorBrush]::new($green))
    }
}

function Fit-TitleTextBlock {
    param([System.Windows.Controls.TextBlock]$TextBlock)
    try {
        $available = $TextBlock.ActualWidth - 8
        if ($available -le 30) { return }
        $size = [double]$script:FontSize
        $minSize = 5.5
        $probe = New-Object System.Windows.Controls.TextBlock
        $probe.Text = $TextBlock.Text
        $probe.FontFamily = $TextBlock.FontFamily
        $probe.FontWeight = $TextBlock.FontWeight
        $probe.FontStyle = $TextBlock.FontStyle
        $probe.FontStretch = $TextBlock.FontStretch
        $infinite = [System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity)
        while ($size -gt $minSize) {
            $probe.FontSize = $size
            $probe.Measure($infinite)
            if ($probe.DesiredSize.Width -le $available) { break }
            $size -= 0.5
        }
        if ($size -lt $minSize) { $size = $minSize }
        $TextBlock.FontSize = $size
    } catch {
        # TextTrimmingが最終フォールバック。
    }
}

function Fit-AllTaskTitles {
    foreach ($tb in @($script:TitleBlocks)) {
        if ($null -ne $tb) { Fit-TitleTextBlock $tb }
    }
}

Write-StartupTrace 'メインウィンドウ構成完了 / URLポップアップ初期化開始'

# URLクイック操作ポップアップ
$script:UrlPopup = New-Object System.Windows.Controls.Primitives.Popup
$script:UrlPopup.StaysOpen = $false
$script:UrlPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Right
$script:UrlPopup.HorizontalOffset = 4
$popupBorder = New-Object System.Windows.Controls.Border
$popupBorder.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,0,0))
$popupBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,255,102))
$popupBorder.BorderThickness = [System.Windows.Thickness]::new(1)
$popupBorder.Padding = [System.Windows.Thickness]::new(7)
$popupPanel = New-Object System.Windows.Controls.StackPanel
$popupPanel.Width = 300
$script:UrlPopupText = New-Object System.Windows.Controls.TextBox
$script:UrlPopupText.Margin = [System.Windows.Thickness]::new(3)
$script:UrlPopupText.MinHeight = 30
$script:UrlPopupText.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,255,102))
$script:UrlPopupText.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(5,5,5))
$script:UrlPopupText.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,255,102))
$script:UrlPopupText.CaretBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,255,102))
$script:UrlOpenButton = New-Object System.Windows.Controls.Button
$script:UrlOpenButton.Content = 'URLを開く'
$script:UrlSaveButton = New-Object System.Windows.Controls.Button
$script:UrlSaveButton.Content = 'URLを挿入'
$script:UrlNoneButton = New-Object System.Windows.Controls.Button
$script:UrlNoneButton.Content = 'URLをなしに設定する'
$script:UrlDeleteButton = New-Object System.Windows.Controls.Button
$script:UrlDeleteButton.Content = 'URLを削除'
try {
    $script:UrlPopupText.Style = $script:Window.FindResource([System.Windows.Controls.TextBox])
    foreach ($b in @($script:UrlOpenButton,$script:UrlSaveButton,$script:UrlNoneButton,$script:UrlDeleteButton)) {
        $b.Style = $script:Window.FindResource([System.Windows.Controls.Button])
    }
} catch { }
[void]$popupPanel.Children.Add($script:UrlPopupText)[void]$popupPanel.Children.Add($script:UrlOpenButton)
[void]$popupPanel.Children.Add($script:UrlSaveButton)
[void]$popupPanel.Children.Add($script:UrlNoneButton)
[void]$popupPanel.Children.Add($script:UrlDeleteButton)
$popupBorder.Child = $popupPanel
$script:UrlPopup.Child = $popupBorder

Write-StartupTrace 'URLポップアップ初期化完了'

function Open-UrlPopup {
    param([System.Windows.Controls.Button]$Button, [string]$TaskId)
    $task = Get-TaskById $TaskId
    if ($null -eq $task) { return }
    $script:UrlPopupTaskId = $TaskId
    $script:UrlPopup.PlacementTarget = $Button
    $script:UrlPopupText.Text = [string]$task.Url
    $script:UrlOpenButton.IsEnabled = ([bool]$task.UrlEnabled -and (Test-Url ([string]$task.Url)))
    if ([string]::IsNullOrWhiteSpace([string]$task.Url)) { $script:UrlSaveButton.Content = 'URLを挿入' } else { $script:UrlSaveButton.Content = 'URLを変更' }
    $script:UrlNoneButton.IsEnabled = [bool]$task.UrlEnabled
    $script:UrlDeleteButton.IsEnabled = -not [string]::IsNullOrWhiteSpace([string]$task.Url)
    $script:UrlPopup.IsOpen = $true
    $script:UrlPopupText.Focus() | Out-Null
    $script:UrlPopupText.SelectAll()
}

function New-RowBorder {
    param($Task)
    $windowH = [double]$script:Window.ActualHeight
    if ($windowH -le 0) { $windowH = [double]$script:Window.Height }
    if ($windowH -lt 330.0) {
        $rowHeight = [Math]::Max(31.0, [Math]::Min(40.0, ($script:FontSize * 1.55) + 3.0))
    } else {
        $rowHeight = [Math]::Max(36.0, [Math]::Min(52.0, ($script:FontSize * 1.85) + 4.0))
    }
    $border = New-Object System.Windows.Controls.Border
    $border.Height = $rowHeight
    $border.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,110,44))
    $border.BorderThickness = [System.Windows.Thickness]::new(0,0,0,1)
    $border.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,0,0))
    $border.Tag = [string]$Task.Id
    $border.Cursor = 'Hand'

    $grid = New-Object System.Windows.Controls.Grid
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::new([double]$script:RowUrlWidth, [System.Windows.GridUnitType]::Pixel)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new([double]$script:RowDeadlineWidth, [System.Windows.GridUnitType]::Pixel)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::new(1,[System.Windows.GridUnitType]::Star)
    [void]$grid.ColumnDefinitions.Add($c0); [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)

    $urlButton = New-Object System.Windows.Controls.Button
    $urlButton.Tag = [string]$Task.Id
    $urlButton.Content = if ([bool]$Task.UrlEnabled -and -not [string]::IsNullOrWhiteSpace([string]$Task.Url)) { '●' } else { '○' }
    $urlButton.Padding = [System.Windows.Thickness]::new(2)
    $urlMargin = if ([double]$script:Window.ActualWidth -lt 520.0) { 3.0 } else { 5.0 }
    $urlButton.Margin = [System.Windows.Thickness]::new($urlMargin)
    $urlButton.FontSize = if ([double]$script:Window.ActualWidth -lt 520.0) {
        [Math]::Max(10.0, [Math]::Min($script:FontSize, 15.0))
    } else {
        [Math]::Max(11.0, $script:FontSize)
    }
    $urlButton.ToolTip = 'URLメニュー'
    [System.Windows.Controls.Grid]::SetColumn($urlButton,0)
    $urlButton.add_Click({
        param($sender,$e)
        try {
            $e.Handled = $true
            Open-UrlPopup $sender ([string]$sender.Tag)
        } catch { Write-ErrorLog 'URLポップアップ表示エラー' $_.Exception }
    })

    $brush = Get-DueBrush $Task
    $deadline = New-Object System.Windows.Controls.TextBlock
    if ([bool]$Task.DeadlineEnabled -and -not [string]::IsNullOrWhiteSpace([string]$Task.Deadline)) {
        try {
            $d = [DateTime]::ParseExact([string]$Task.Deadline,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
            $deadline.Text = $d.ToString('MM / dd')
        } catch { $deadline.Text = '期限なし' }
    } else {
        $deadline.Text = '期限なし'
    }
    $deadline.Foreground = $brush
    $deadline.HorizontalAlignment = 'Center'
    $deadline.VerticalAlignment = 'Center'
    $deadline.TextTrimming = 'CharacterEllipsis'
    $deadline.FontSize = if ([double]$script:Window.ActualWidth -lt 520.0) {
        [Math]::Max(8.0, [Math]::Min($script:FontSize, 14.0))
    } else {
        [double]$script:FontSize
    }
    [System.Windows.Controls.Grid]::SetColumn($deadline,1)

    $title = New-Object System.Windows.Controls.TextBlock
    $title.Text = [string]$Task.Title
    $title.Foreground = $brush
    $title.VerticalAlignment = 'Center'
    $titleMarginX = if ([double]$script:Window.ActualWidth -lt 520.0) { 3.0 } else { 8.0 }
    $title.Margin = [System.Windows.Thickness]::new($titleMarginX,0,$titleMarginX,0)
    $title.TextWrapping = 'NoWrap'
    $title.TextTrimming = 'CharacterEllipsis'
    $title.FontSize = $script:FontSize
    $title.Tag = [string]$Task.Id
    if (-not [string]::IsNullOrWhiteSpace([string]$Task.Details)) {
        $tipBorder = New-Object System.Windows.Controls.Border
        $tipBorder.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,0,0))
        $tipBorder.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,255,102))
        $tipBorder.BorderThickness = [System.Windows.Thickness]::new(1)
        $tipBorder.Padding = [System.Windows.Thickness]::new(7)
        $tipText = New-Object System.Windows.Controls.TextBlock
        $tipText.Text = [string]$Task.Details
        $tipText.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,255,102))
        $tipText.TextWrapping = 'Wrap'
        $tipText.MaxWidth = 420
        $tipBorder.Child = $tipText
        $title.ToolTip = $tipBorder
    }
    [System.Windows.Controls.Grid]::SetColumn($title,2)
    [void]$script:TitleBlocks.Add($title)

    [void]$grid.Children.Add($urlButton)
    [void]$grid.Children.Add($deadline)
    [void]$grid.Children.Add($title)
    $border.Child = $grid

    $border.add_MouseLeftButtonUp({
        param($sender,$e)
        try {
            $id = [string]$sender.Tag
            if ($script:Mode -eq 'edit') {
                $script:Mode = 'normal'
                Update-Status
                $task = Get-TaskById $id
                if ($null -ne $task) { Edit-Task $task }
                $e.Handled = $true
            } elseif ($script:Mode -eq 'delete') {
                $script:Mode = 'normal'
                Update-Status
                Delete-TaskById $id
                $e.Handled = $true
            }
        } catch {
            Write-ErrorLog 'タスク行クリック処理エラー' $_.Exception
        }
    })
    return $border
}

function Render-Tasks {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $offset = $script:TaskScroll.VerticalOffset
        $script:TaskPanel.Children.Clear()
        $script:TitleBlocks.Clear()
        if ($script:Tasks.Count -eq 0) {
            $empty = New-Object System.Windows.Controls.TextBlock
            $empty.Text = 'タスク / 予定はありません'
            $empty.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(0,150,60))
            $empty.HorizontalAlignment = 'Center'
            $empty.Margin = [System.Windows.Thickness]::new(20)
            [void]$script:TaskPanel.Children.Add($empty)
        } else {
            foreach ($task in $script:Tasks) {
                [void]$script:TaskPanel.Children.Add((New-RowBorder $task))
            }
        }
        Update-Status
        if ($null -ne $script:FitTimer -and -not $script:SuppressFitTimer) {
            $script:FitTimer.Stop()
            $script:FitTimer.Start()
        }
        $script:TaskScroll.ScrollToVerticalOffset($offset)
    } catch {
        Write-ErrorLog 'タスク一覧描画エラー' $_.Exception
    } finally {
        $sw.Stop()
        if ($sw.ElapsedMilliseconds -ge 1500) {
            Write-AppLog ("タスク一覧描画が遅延: {0}ms" -f $sw.ElapsedMilliseconds) 'WARN'
            if ($sw.ElapsedMilliseconds -ge 4000) { Write-ErrorLog ("処理落ち疑い: Render-Tasks {0}ms" -f $sw.ElapsedMilliseconds) }
        }
    }
}

Write-StartupTrace 'タスク行UI関数初期化完了 / ボイス初期化開始'

# -------------------------
# Voice queue
# -------------------------
$script:VoiceQueue = New-Object 'System.Collections.Generic.Queue[string]'
$script:VoicePlayer = New-Object System.Windows.Media.MediaPlayer
$script:VoicePlaying = $false

function Start-NextVoice {
    try {
        if ($script:VoicePlaying) { return }
        if ($script:VoiceQueue.Count -le 0) { return }
        $path = $script:VoiceQueue.Dequeue()
        if (-not (Test-Path -LiteralPath $path)) {
            Write-AppLog ("ボイスファイルなし: {0}" -f $path) 'WARN'
            Start-NextVoice
            return
        }
        $script:VoicePlaying = $true
        $script:VoicePlayer.Open((New-Object System.Uri -ArgumentList $path))
    } catch {
        $script:VoicePlaying = $false
        Write-ErrorLog 'ボイス再生開始エラー' $_.Exception
    }
}

$script:VoicePlayer.add_MediaOpened({
    try { $script:VoicePlayer.Play() } catch { $script:VoicePlaying = $false; Write-ErrorLog 'ボイス再生エラー' $_.Exception; Start-NextVoice }
})
$script:VoicePlayer.add_MediaEnded({
    try { $script:VoicePlayer.Stop(); $script:VoicePlayer.Close() } catch { }
    $script:VoicePlaying = $false
    Start-NextVoice
})
$script:VoicePlayer.add_MediaFailed({
    param($sender,$e)
    $script:VoicePlaying = $false
    try { Write-ErrorLog ('ボイスMediaFailed: ' + $e.ErrorException.Message) $e.ErrorException } catch { }
    try { $script:VoicePlayer.Close() } catch { }
    Start-NextVoice
})

function Queue-Voice {
    param([string]$BaseName)
    $path = Join-Path $script:VoiceDir ($BaseName + '.wav')
    if (-not (Test-Path -LiteralPath $path)) {
        Write-AppLog ("指定ボイスが見つかりません: {0}.wav" -f $BaseName) 'WARN'
        return
    }
    $script:VoiceQueue.Enqueue($path)
    Start-NextVoice
}

$script:VoiceSystemReady = $true

Write-StartupTrace 'ボイス初期化完了 / ダイアログ関数初期化開始'

# -------------------------
# Dialogs
# -------------------------
function Show-ConfirmDialog {
    param([string]$Message, [string]$Title = '確認')
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" WindowStyle="None" ResizeMode="NoResize" Width="430" Height="185" Background="#000000" Foreground="#00FF66" FontFamily="Yu Gothic UI" ShowInTaskbar="False">
 <Border BorderBrush="#00FF66" BorderThickness="1" Background="#000000">
  <Grid Margin="10">
   <Grid.RowDefinitions><RowDefinition Height="32"/><RowDefinition Height="*"/><RowDefinition Height="48"/></Grid.RowDefinitions>
   <TextBlock x:Name="DlgTitle" Grid.Row="0" Foreground="#00FF66" FontWeight="SemiBold" VerticalAlignment="Center"/>
   <TextBlock x:Name="DlgMessage" Grid.Row="1" Foreground="#00FF66" TextWrapping="Wrap" VerticalAlignment="Center" Margin="5"/>
   <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
    <Button x:Name="YesButton" Content="はい" Width="92" Margin="4" Foreground="#00FF66" Background="#050505" BorderBrush="#00FF66" Padding="8"/>
    <Button x:Name="NoButton" Content="いいえ" Width="92" Margin="4" Foreground="#00FF66" Background="#050505" BorderBrush="#00FF66" Padding="8"/>
   </StackPanel>
  </Grid>
 </Border>
</Window>
"@
    [xml]$xml = $xaml
    $reader = New-Object System.Xml.XmlNodeReader -ArgumentList $xml
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $script:Window
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Topmost = $script:Window.Topmost
    $dlg.FontSize = $script:FontSize
    $dlg.FindName('DlgTitle').Text = $Title
    $dlg.FindName('DlgMessage').Text = $Message
    $yes = $dlg.FindName('YesButton')
    $no = $dlg.FindName('NoButton')
    $yes.add_Click({ $dlg.DialogResult = $true; $dlg.Close() })
    $no.add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
    $result = $dlg.ShowDialog()
    return ($result -eq $true)
}

function Show-TaskEditorDialog {
    param($ExistingTask = $null)
    $isEdit = ($null -ne $ExistingTask)
    $dialogTitle = if ($isEdit) { 'タスク / 予定を編集' } else { '新規作成' }
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" WindowStyle="None" ResizeMode="CanResizeWithGrip" Width="620" Height="590" MinWidth="500" MinHeight="500" Background="#000000" Foreground="#00FF66" FontFamily="Yu Gothic UI" ShowInTaskbar="False">
 <Border BorderBrush="#00FF66" BorderThickness="1" Background="#000000">
  <Grid>
   <Grid.RowDefinitions><RowDefinition Height="38"/><RowDefinition Height="*"/><RowDefinition Height="58"/></Grid.RowDefinitions>
   <Border Grid.Row="0" BorderBrush="#00FF66" BorderThickness="0,0,0,1"><Grid x:Name="DialogTitleBar"><TextBlock x:Name="DialogTitle" Margin="10,0" VerticalAlignment="Center" Foreground="#00FF66" FontWeight="SemiBold"/><Button x:Name="DialogClose" Content="×" Width="36" HorizontalAlignment="Right" Margin="2" Foreground="#00FF66" Background="#050505" BorderBrush="#00FF66"/></Grid></Border>
   <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <Grid Margin="14">
     <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
     </Grid.RowDefinitions>
     <TextBlock Grid.Row="0" Text="タスク・予定タイトル" Foreground="#00FF66" Margin="2,5"/>
     <TextBox x:Name="TitleInput" Grid.Row="1" MinHeight="34" Margin="2,0,2,10" Foreground="#00FF66" Background="#050505" BorderBrush="#00FF66" CaretBrush="#00FF66"/>
     <TextBlock Grid.Row="2" Text="種別" Foreground="#00FF66" Margin="2,5"/>
     <StackPanel Grid.Row="3" Orientation="Horizontal" Margin="2,0,2,10"><RadioButton x:Name="TaskRadio" Content="タスク" Foreground="#00FF66" Margin="2,2,18,2"/><RadioButton x:Name="PlanRadio" Content="予定" Foreground="#00FF66" Margin="2"/></StackPanel>
     <TextBlock Grid.Row="4" Text="詳細" Foreground="#00FF66" Margin="2,5"/>
     <TextBox x:Name="DetailsInput" Grid.Row="5" Height="115" AcceptsReturn="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap" Margin="2,0,2,10" Foreground="#00FF66" Background="#050505" BorderBrush="#00FF66" CaretBrush="#00FF66"/>
     <StackPanel Grid.Row="6" Orientation="Vertical" Margin="2,4,2,10">
      <CheckBox x:Name="UrlEnabled" Content="URLを使用する" Foreground="#00FF66" Margin="0,0,0,5"/>
      <TextBox x:Name="UrlInput" MinHeight="34" Foreground="#00FF66" Background="#050505" BorderBrush="#00FF66" CaretBrush="#00FF66"/>
      <TextBlock Text="※ URLを無効にしても入力済みURLは保持。空欄にして保存するとURLデータを削除。" Foreground="#009944" TextWrapping="Wrap" Margin="2,4" FontSize="10"/>
     </StackPanel>
     <StackPanel Grid.Row="7" Orientation="Vertical" Margin="2,4,2,10">
      <CheckBox x:Name="DeadlineEnabled" Content="期限を設定する" Foreground="#00FF66" Margin="0,0,0,5"/>
      <TextBox x:Name="DeadlineInput" MinHeight="34" Foreground="#00FF66" Background="#050505" BorderBrush="#00FF66" CaretBrush="#00FF66"/>
      <TextBlock Text="入力例: 11/25 または 2026/11/25" Foreground="#009944" Margin="2,4" FontSize="10"/>
     </StackPanel>
     <TextBlock x:Name="DialogError" Grid.Row="8" Foreground="#FF3344" TextWrapping="Wrap" Margin="2,6"/>
    </Grid>
   </ScrollViewer>
   <Border Grid.Row="2" BorderBrush="#00FF66" BorderThickness="0,1,0,0">
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="8">
     <Button x:Name="SaveButton" Content="保存" Width="110" Margin="4" Padding="8" Foreground="#00FF66" Background="#050505" BorderBrush="#00FF66"/>
     <Button x:Name="CancelButton" Content="キャンセル" Width="110" Margin="4" Padding="8" Foreground="#00FF66" Background="#050505" BorderBrush="#00FF66"/>
    </StackPanel>
   </Border>
  </Grid>
 </Border>
</Window>
"@
    [xml]$xml = $xaml
    $reader = New-Object System.Xml.XmlNodeReader -ArgumentList $xml
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $script:Window
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.Topmost = $script:Window.Topmost
    $dlg.FontSize = $script:FontSize

    $dlg.FindName('DialogTitle').Text = $dialogTitle
    $titleInput = $dlg.FindName('TitleInput')
    $taskRadio = $dlg.FindName('TaskRadio')
    $planRadio = $dlg.FindName('PlanRadio')
    $detailsInput = $dlg.FindName('DetailsInput')
    $urlEnabled = $dlg.FindName('UrlEnabled')
    $urlInput = $dlg.FindName('UrlInput')
    $deadlineEnabled = $dlg.FindName('DeadlineEnabled')
    $deadlineInput = $dlg.FindName('DeadlineInput')
    $errorText = $dlg.FindName('DialogError')
    $saveButton = $dlg.FindName('SaveButton')
    $cancelButton = $dlg.FindName('CancelButton')
    $dialogClose = $dlg.FindName('DialogClose')
    $dialogTitleBar = $dlg.FindName('DialogTitleBar')

    if ($isEdit) {
        $titleInput.Text = [string]$ExistingTask.Title
        if ([string]$ExistingTask.Type -eq '予定') { $planRadio.IsChecked = $true } else { $taskRadio.IsChecked = $true }
        $detailsInput.Text = [string]$ExistingTask.Details
        $urlEnabled.IsChecked = [bool]$ExistingTask.UrlEnabled
        $urlInput.Text = [string]$ExistingTask.Url
        $deadlineEnabled.IsChecked = [bool]$ExistingTask.DeadlineEnabled
        if (-not [string]::IsNullOrWhiteSpace([string]$ExistingTask.Deadline)) {
            try {
                $dd = [DateTime]::ParseExact([string]$ExistingTask.Deadline,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
                if ([bool]$ExistingTask.DeadlineYearExplicit) { $deadlineInput.Text = $dd.ToString('yyyy/MM/dd') } else { $deadlineInput.Text = $dd.ToString('MM/dd') }
            } catch { $deadlineInput.Text = '' }
        }
    } else {
        $taskRadio.IsChecked = $true
        $urlEnabled.IsChecked = $false
        $deadlineEnabled.IsChecked = $false
    }

    $dialogTitleBar.add_MouseLeftButtonDown({ param($s,$e) try { if ($e.LeftButton -eq 'Pressed') { $dlg.DragMove() } } catch { } })
    $dialogClose.add_Click({ $dlg.DialogResult = $false; $dlg.Close() })
    $cancelButton.add_Click({ $dlg.DialogResult = $false; $dlg.Close() })

    $saveButton.add_Click({
        try {
            $errorText.Text = ''
            $title = $titleInput.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($title)) { $errorText.Text = 'タイトルを入力してください。'; return }
            $url = Normalize-Url $urlInput.Text
            if ([bool]$urlEnabled.IsChecked) {
                if ([string]::IsNullOrWhiteSpace($url)) { $errorText.Text = 'URLを使用する場合はURLを入力してください。'; return }
                if (-not (Test-Url $url)) { $errorText.Text = 'URLは http:// または https:// の形式で入力してください。'; return }
            }
            if ([bool]$deadlineEnabled.IsChecked) {
                $parsed = Parse-Deadline $deadlineInput.Text
                if ($null -eq $parsed) { $errorText.Text = '期限は 11/25 または 2026/11/25 の形式で入力してください。'; return }
                $deadlineInput.Tag = [string]$parsed.Date.ToString('yyyy-MM-dd')
                $deadlineInput.ToolTip = [bool]$parsed.YearExplicit
            } else {
                $deadlineInput.Tag = ''
                $deadlineInput.ToolTip = $false
            }
            $urlInput.Tag = $url
            $dlg.DialogResult = $true
            $dlg.Close()
        } catch {
            $errorText.Text = '保存処理中にエラーが発生しました。Error Logを確認してください。'
            Write-ErrorLog 'タスク編集ダイアログ保存エラー' $_.Exception
        }
    })

    $result = $dlg.ShowDialog()
    if ($result -ne $true) { return $null }
    $type = if ([bool]$planRadio.IsChecked) { '予定' } else { 'タスク' }
    return [PSCustomObject]@{
        Title = $titleInput.Text.Trim()
        Type = $type
        Details = [string]$detailsInput.Text
        Url = [string]$urlInput.Tag
        UrlEnabled = [bool]$urlEnabled.IsChecked
        Deadline = [string]$deadlineInput.Tag
        DeadlineEnabled = [bool]$deadlineEnabled.IsChecked
        DeadlineYearExplicit = [bool]$deadlineInput.ToolTip
    }
}

function Play-FieldChangeVoices {
    param($OldTask, $NewData, [bool]$IsNew)
    if ($IsNew) {
        if (-not [string]::IsNullOrWhiteSpace([string]$NewData.Details)) { Queue-Voice '詳細を作成しました' }
        if ([bool]$NewData.UrlEnabled -and -not [string]::IsNullOrWhiteSpace([string]$NewData.Url)) { Queue-Voice 'URLを作成しました' }
        return
    }
    $oldDetails = [string]$OldTask.Details
    $newDetails = [string]$NewData.Details
    if ([string]::IsNullOrWhiteSpace($oldDetails) -and -not [string]::IsNullOrWhiteSpace($newDetails)) {
        Queue-Voice '詳細を作成しました'
    } elseif (-not [string]::IsNullOrWhiteSpace($oldDetails) -and [string]::IsNullOrWhiteSpace($newDetails)) {
        Queue-Voice '詳細を削除しました'
    } elseif ($oldDetails -ne $newDetails) {
        Queue-Voice '詳細を変更しました'
    }

    $oldUrl = [string]$OldTask.Url
    $newUrl = [string]$NewData.Url
    $oldEnabled = [bool]$OldTask.UrlEnabled
    $newEnabled = [bool]$NewData.UrlEnabled
    if (-not [string]::IsNullOrWhiteSpace($oldUrl) -and [string]::IsNullOrWhiteSpace($newUrl)) {
        Queue-Voice 'URLを削除しました'
    } elseif ($oldEnabled -and -not $newEnabled -and -not [string]::IsNullOrWhiteSpace($newUrl)) {
        Queue-Voice 'URLを無効にしました'
    } elseif ([string]::IsNullOrWhiteSpace($oldUrl) -and $newEnabled -and -not [string]::IsNullOrWhiteSpace($newUrl)) {
        Queue-Voice 'URLを作成しました'
    } elseif (($oldUrl -ne $newUrl) -and -not [string]::IsNullOrWhiteSpace($newUrl)) {
        Queue-Voice 'URLを変更しました'
    } elseif ((-not $oldEnabled) -and $newEnabled -and -not [string]::IsNullOrWhiteSpace($newUrl)) {
        Queue-Voice 'URLを作成しました'
    }

    $oldDeadline = [string]$OldTask.Deadline
    $newDeadline = [string]$NewData.Deadline
    $oldDeadlineEnabled = [bool]$OldTask.DeadlineEnabled
    $newDeadlineEnabled = [bool]$NewData.DeadlineEnabled
    if (($oldDeadline -ne $newDeadline) -or ($oldDeadlineEnabled -ne $newDeadlineEnabled)) {
        Queue-Voice '期限を変更しました'
    }
}

function Add-NewTask {
    $data = Show-TaskEditorDialog
    if ($null -eq $data) { return }
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $task = [PSCustomObject]@{
        Id = [Guid]::NewGuid().ToString('N')
        Type = [string]$data.Type
        Title = [string]$data.Title
        Details = [string]$data.Details
        Url = [string]$data.Url
        UrlEnabled = [bool]$data.UrlEnabled
        Deadline = [string]$data.Deadline
        DeadlineEnabled = [bool]$data.DeadlineEnabled
        DeadlineYearExplicit = [bool]$data.DeadlineYearExplicit
        DeadlineMetadataKnown = $true
        Created = $now
        Updated = $now
    }
    $script:Tasks += $task
    Save-Tasks
    Play-FieldChangeVoices $null $data $true
    Queue-Voice '新規作成が完了しました'
    Write-AppLog ("新規作成: ID={0} TYPE={1} TITLE={2}" -f $task.Id, $task.Type, (Sanitize-LogText $task.Title))
    Render-Tasks
}

function Edit-Task {
    param($Task)
    $data = Show-TaskEditorDialog $Task
    if ($null -eq $data) { return }

    # 保存成功後に変更ボイスを鳴らせるよう、変更前状態を退避。
    $oldTask = [PSCustomObject]@{
        Type = [string]$Task.Type
        Title = [string]$Task.Title
        Details = [string]$Task.Details
        Url = [string]$Task.Url
        UrlEnabled = [bool]$Task.UrlEnabled
        Deadline = [string]$Task.Deadline
        DeadlineEnabled = [bool]$Task.DeadlineEnabled
        DeadlineYearExplicit = [bool]$Task.DeadlineYearExplicit
    }

    $Task.Type = [string]$data.Type
    $Task.Title = [string]$data.Title
    $Task.Details = [string]$data.Details
    $Task.Url = [string]$data.Url
    $Task.UrlEnabled = [bool]$data.UrlEnabled
    $Task.Deadline = [string]$data.Deadline
    $Task.DeadlineEnabled = [bool]$data.DeadlineEnabled
    $Task.DeadlineYearExplicit = [bool]$data.DeadlineYearExplicit
    $Task.DeadlineMetadataKnown = $true
    $Task.Updated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Save-Tasks
    Write-AppLog ("編集: ID={0} TYPE={1} TITLE={2}" -f $Task.Id, $Task.Type, (Sanitize-LogText $Task.Title))
    Render-Tasks

    Play-FieldChangeVoices $oldTask $data $false
    if ([string]$Task.Type -eq '予定') { Queue-Voice '予定を変更しました' } else { Queue-Voice 'タスクを変更しました' }
    # ユーザー指定: 編集時の最後のボイス。
    Queue-Voice '編集を完了しました'
}

function Delete-TaskById {
    param([string]$Id)
    $idx = Get-TaskIndexById $Id
    if ($idx -lt 0) { return }
    $task = $script:Tasks[$idx]
    if (-not (Show-ConfirmDialog ("「{0}」を削除しますか？" -f $task.Title) '削除確認')) { return }
    $new = New-Object System.Collections.ArrayList
    for ($i=0; $i -lt $script:Tasks.Count; $i++) { if ($i -ne $idx) { [void]$new.Add($script:Tasks[$i]) } }
    $script:Tasks = @($new)
    Save-Tasks
    Write-AppLog ("削除: ID={0} TYPE={1} TITLE={2}" -f $task.Id, $task.Type, (Sanitize-LogText $task.Title))
    Render-Tasks
    if ([string]$task.Type -eq '予定') { Queue-Voice '予定を削除しました' } else { Queue-Voice 'タスクを削除しました' }
}

# URL popup actions
$script:UrlOpenButton.add_Click({
    try {
        $task = Get-TaskById $script:UrlPopupTaskId
        if ($null -eq $task) { return }
        if ([bool]$task.UrlEnabled -and (Test-Url ([string]$task.Url))) {
            Start-Process (Normalize-Url ([string]$task.Url))
            Write-AppLog ("URLを開く: ID={0}" -f $task.Id)
            $script:UrlPopup.IsOpen = $false
        }
    } catch { Write-ErrorLog 'URLを開く処理でエラー' $_.Exception }
})

$script:UrlSaveButton.add_Click({
    try {
        $task = Get-TaskById $script:UrlPopupTaskId
        if ($null -eq $task) { return }
        $newUrl = Normalize-Url $script:UrlPopupText.Text
        if (-not (Test-Url $newUrl)) {
            Update-Status 'URLの形式が正しくありません。http:// または https:// を使用してください。'
            return
        }
        $oldUrl = [string]$task.Url
        $oldEnabled = [bool]$task.UrlEnabled
        $task.Url = $newUrl
        $task.UrlEnabled = $true
        $task.Updated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Save-Tasks
        if ([string]::IsNullOrWhiteSpace($oldUrl) -or -not $oldEnabled) { Queue-Voice 'URLを作成しました' } elseif ($oldUrl -ne $newUrl) { Queue-Voice 'URLを変更しました' }
        Write-AppLog ("URL保存: ID={0}" -f $task.Id)
        $script:UrlPopup.IsOpen = $false
        Render-Tasks
    } catch { Write-ErrorLog 'URL挿入/変更エラー' $_.Exception }
})

$script:UrlNoneButton.add_Click({
    try {
        $task = Get-TaskById $script:UrlPopupTaskId
        if ($null -eq $task) { return }
        if ([bool]$task.UrlEnabled) {
            $task.UrlEnabled = $false
            $task.Updated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Save-Tasks
            Queue-Voice 'URLを無効にしました'
            Write-AppLog ("URL無効: ID={0}" -f $task.Id)
        }
        $script:UrlPopup.IsOpen = $false
        Render-Tasks
    } catch { Write-ErrorLog 'URL無効化エラー' $_.Exception }
})

$script:UrlDeleteButton.add_Click({
    try {
        $task = Get-TaskById $script:UrlPopupTaskId
        if ($null -eq $task) { return }
        if (-not [string]::IsNullOrWhiteSpace([string]$task.Url)) {
            $task.Url = ''
            $task.UrlEnabled = $false
            $task.Updated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Save-Tasks
            Queue-Voice 'URLを削除しました'
            Write-AppLog ("URL削除: ID={0}" -f $task.Id)
        }
        $script:UrlPopup.IsOpen = $false
        Render-Tasks
    } catch { Write-ErrorLog 'URL削除エラー' $_.Exception }
})

# 期限/予定日通知: 7日前と3日前、それぞれ1タスクにつき1回のみ。
function Check-DeadlineAlerts {
    try {
        $today = [DateTime]::Today
        $taskAlert = $false
        $planAlert = $false
        $changed = $false
        foreach ($task in $script:Tasks) {
            if (-not [bool]$task.DeadlineEnabled -or [string]::IsNullOrWhiteSpace([string]$task.Deadline)) { continue }
            try {
                $due = [DateTime]::ParseExact([string]$task.Deadline,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
                $days = [int][Math]::Floor(($due.Date - $today).TotalDays)
                if ($days -ne 7 -and $days -ne 3) { continue }
                $key = '{0}|{1}|{2}' -f $task.Id, $today.ToString('yyyy-MM-dd'), $days
                if ($script:NotificationKeys.Contains($key)) { continue }
                [void]$script:NotificationKeys.Add($key)
                $changed = $true
                if ([string]$task.Type -eq '予定') { $planAlert = $true } else { $taskAlert = $true }
                Write-AppLog ("期限通知対象: ID={0} TYPE={1} DAYS={2} TITLE={3}" -f $task.Id, $task.Type, $days, (Sanitize-LogText $task.Title))
            } catch {
                Write-ErrorLog ("期限解析エラー: ID={0}" -f $task.Id) $_.Exception
            }
        }
        if ($changed) { Save-Notifications }
        if ($taskAlert) { Queue-Voice '期限が近いタスクがあります' }
        if ($planAlert) { Queue-Voice '予定が近いものがあります' }
        Render-Tasks
    } catch {
        Write-ErrorLog '期限通知チェックエラー' $_.Exception
    }
}

# -------------------------
# Timers
# -------------------------
$script:SuppressFitTimer = $false
$script:FitTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:FitTimer.Interval = [TimeSpan]::FromMilliseconds(140)
$script:FitTimer.add_Tick({
    $script:FitTimer.Stop()
    $script:SuppressFitTimer = $true
    try {
        Render-Tasks
        $script:Window.UpdateLayout()
        Fit-AllTaskTitles
    } finally {
        $script:SuppressFitTimer = $false
    }
})

$script:SettingsTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SettingsTimer.Interval = [TimeSpan]::FromMilliseconds(650)
$script:SettingsTimer.add_Tick({ $script:SettingsTimer.Stop(); Save-Settings })

$script:HeartbeatTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:HeartbeatTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:HeartbeatTimer.add_Tick({ try { [TaskTableFreezeWatchdog]::Beat() } catch { } })

$script:DeadlineTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DeadlineTimer.Interval = [TimeSpan]::FromMinutes(30)
$script:DeadlineTimer.add_Tick({ Check-DeadlineAlerts })

# -------------------------
# Main event bindings
# -------------------------
$script:AddButton.add_Click({ try { $script:Mode='normal'; Update-Status; Add-NewTask } catch { Write-ErrorLog '新規作成エラー' $_.Exception } })
$script:EditButton.add_Click({ $script:Mode = if ($script:Mode -eq 'edit') { 'normal' } else { 'edit' }; Update-Status })
$script:DeleteButton.add_Click({ $script:Mode = if ($script:Mode -eq 'delete') { 'normal' } else { 'delete' }; Update-Status })
$script:FontUpButton.add_Click({ if ($script:FontSize -lt 30.0) { $script:FontSize = [Math]::Min(30.0, $script:FontSize + 0.5); Write-AppLog ("文字サイズ変更: {0:0.0}" -f $script:FontSize); Apply-FontSize } })
$script:FontDownButton.add_Click({ if ($script:FontSize -gt 8.0) { $script:FontSize = [Math]::Max(8.0, $script:FontSize - 0.5); Write-AppLog ("文字サイズ変更: {0:0.0}" -f $script:FontSize); Apply-FontSize } })

$script:LockButton.add_Click({
    $script:Locked = -not $script:Locked
    Update-LockTopmostButtons
    Write-AppLog ("位置固定: {0}" -f $script:Locked)
    Save-Settings
})
$script:TopmostButton.add_Click({
    $script:AlwaysOnTop = -not $script:AlwaysOnTop
    Update-LockTopmostButtons
    Write-AppLog ("最前面: {0}" -f $script:AlwaysOnTop)
    Save-Settings
})
$script:MinimizeButton.add_Click({ $script:Window.WindowState = [System.Windows.WindowState]::Minimized })
$script:MaximizeButton.add_Click({
    if ($script:Locked) { return }
    if ($script:Window.WindowState -eq [System.Windows.WindowState]::Maximized) { $script:Window.WindowState = [System.Windows.WindowState]::Normal } else { $script:Window.WindowState = [System.Windows.WindowState]::Maximized }
})
$script:CloseButton.add_Click({ $script:Window.Close() })

$script:TitleBar.add_MouseLeftButtonDown({
    param($sender,$e)
    try {
        if ($script:Locked) { return }
        if ($e.ClickCount -eq 2) {
            if ($script:Window.WindowState -eq [System.Windows.WindowState]::Maximized) { $script:Window.WindowState = [System.Windows.WindowState]::Normal } else { $script:Window.WindowState = [System.Windows.WindowState]::Maximized }
            return
        }
        if ($script:Window.WindowState -eq [System.Windows.WindowState]::Maximized) { return }
        $script:Window.DragMove()
    } catch { }
})

function Invoke-EdgeResize {
    param([double]$Dx, [double]$Dy, [bool]$FromLeft, [bool]$FromTop, [bool]$ChangeWidth, [bool]$ChangeHeight)
    if ($script:Window.WindowState -ne [System.Windows.WindowState]::Normal) { return }
    $script:IsEdgeResizing = $true
    try {
        if ($ChangeWidth) {
            if ($FromLeft) {
                $newWidth = $script:Window.Width - $Dx
                if ($newWidth -ge $script:Window.MinWidth) {
                    $script:Window.Left = $script:Window.Left + $Dx
                    $script:Window.Width = $newWidth
                }
            } else {
                $script:Window.Width = [Math]::Max($script:Window.MinWidth, $script:Window.Width + $Dx)
            }
        }
        if ($ChangeHeight) {
            if ($FromTop) {
                $newHeight = $script:Window.Height - $Dy
                if ($newHeight -ge $script:Window.MinHeight) {
                    $script:Window.Top = $script:Window.Top + $Dy
                    $script:Window.Height = $newHeight
                }
            } else {
                $script:Window.Height = [Math]::Max($script:Window.MinHeight, $script:Window.Height + $Dy)
            }
        }
        if ($script:Locked) {
            # リサイズ操作後の新しい位置を固定位置として採用する。
            $script:LockedLeft = $script:Window.Left
            $script:LockedTop = $script:Window.Top
        }
    } finally {
        $script:IsEdgeResizing = $false
    }
}

$script:ResizeLeft.add_DragDelta({ param($s,$e) Invoke-EdgeResize $e.HorizontalChange 0 $true $false $true $false })
$script:ResizeRight.add_DragDelta({ param($s,$e) Invoke-EdgeResize $e.HorizontalChange 0 $false $false $true $false })
$script:ResizeTop.add_DragDelta({ param($s,$e) Invoke-EdgeResize 0 $e.VerticalChange $false $true $false $true })
$script:ResizeBottom.add_DragDelta({ param($s,$e) Invoke-EdgeResize 0 $e.VerticalChange $false $false $false $true })
$script:ResizeTopLeft.add_DragDelta({ param($s,$e) Invoke-EdgeResize $e.HorizontalChange $e.VerticalChange $true $true $true $true })
$script:ResizeTopRight.add_DragDelta({ param($s,$e) Invoke-EdgeResize $e.HorizontalChange $e.VerticalChange $false $true $true $true })
$script:ResizeBottomLeft.add_DragDelta({ param($s,$e) Invoke-EdgeResize $e.HorizontalChange $e.VerticalChange $true $false $true $true })
$script:ResizeBottomRight.add_DragDelta({ param($s,$e) Invoke-EdgeResize $e.HorizontalChange $e.VerticalChange $false $false $true $true })

$script:Window.add_SizeChanged({
    try {
        # v1.6: 小型サイズでは操作列・タイトルバー・行高を再計算し、黒/緑UIのまま文字切れを防止する。
        Update-ResponsiveLayout
        $script:FitTimer.Stop(); $script:FitTimer.Start()
        $script:SettingsTimer.Stop(); $script:SettingsTimer.Start()
    } catch { $script:ApplyingLockRect = $false }
})
$script:Window.add_LocationChanged({
    try {
        if ($script:Locked -and -not $script:IsEdgeResizing -and -not $script:ApplyingLockRect -and $script:Window.WindowState -eq [System.Windows.WindowState]::Normal) {
            $script:ApplyingLockRect = $true
            $script:Window.Left = $script:LockedLeft
            $script:Window.Top = $script:LockedTop
            $script:ApplyingLockRect = $false
        }
        $script:SettingsTimer.Stop(); $script:SettingsTimer.Start()
    } catch { $script:ApplyingLockRect = $false }
})
$script:Window.add_PreviewMouseWheel({
    param($sender,$e)
    try {
        if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) {
            if ($e.Delta -gt 0 -and $script:FontSize -lt 30.0) { $script:FontSize = [Math]::Min(30.0, $script:FontSize + 0.5); Apply-FontSize }
            elseif ($e.Delta -lt 0 -and $script:FontSize -gt 8.0) { $script:FontSize = [Math]::Max(8.0, $script:FontSize - 0.5); Apply-FontSize }
            $e.Handled = $true
        }
    } catch { }
})
$script:Window.add_PreviewKeyDown({
    param($sender,$e)
    if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
        $script:Mode = 'normal'
        $script:UrlPopup.IsOpen = $false
        Update-Status
    }
})

$script:Window.add_Loaded({
    # v1.2: 1処理の失敗で、タスク描画・自動起動登録・ハートビート等が全部止まらないよう個別保護する。
    try { Register-Startup } catch { Write-ErrorLog '自動起動登録呼出エラー' $_.Exception }
    try { $script:HeartbeatTimer.Start() } catch { Write-ErrorLog 'ハートビート開始エラー' $_.Exception }
    try { $script:DeadlineTimer.Start() } catch { Write-ErrorLog '期限タイマー開始エラー' $_.Exception }

    try {
        if ($script:LegacyDeadlineMigrated) { Save-Tasks; Write-StartupTrace '旧期限データ移行を保存' }
    } catch { Write-ErrorLog '旧期限データ保存エラー' $_.Exception }
    try { Update-LockTopmostButtons } catch { Write-ErrorLog '固定/最前面状態反映エラー' $_.Exception }
    try { Apply-FontSize } catch { Write-ErrorLog '文字サイズ初期反映エラー' $_.Exception }
    try {
        Render-Tasks
        Write-StartupTrace ("初回描画完了: {0}件" -f $script:Tasks.Count)
    } catch {
        Write-ErrorLog '起動時タスク描画エラー' $_.Exception
    }

    Write-AppLog ("起動: VERSION={0} TASKS={1} DATA={2}" -f $script:Version, $script:Tasks.Count, $script:DataDir)
    Write-StartupTrace 'Window Loaded主要処理完了'

    try { Queue-Voice '予定表が起動しました' } catch { Write-ErrorLog '起動ボイス再生要求エラー' $_.Exception }
    try {
        if ($script:ErrorVoicePending) {
            Queue-Voice 'エラーが発生しました。'
            $script:LastErrorVoiceRequest = [DateTime]::Now
            $script:ErrorVoicePending = $false
        }
    } catch { }
    try { Check-DeadlineAlerts } catch { Write-ErrorLog '起動時期限チェックエラー' $_.Exception }

    try {
        # 共通仕様: 起動時だけ確実に前面へ出し、永続Topmost設定はその後に戻す。
        $script:SavedTopmostForStartup = $script:AlwaysOnTop
        $script:Window.Topmost = $true
        $script:Window.Activate() | Out-Null
        $script:FrontTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:FrontTimer.Interval = [TimeSpan]::FromMilliseconds(450)
        $script:FrontTimer.add_Tick({
            $script:FrontTimer.Stop()
            $script:Window.Topmost = $script:SavedTopmostForStartup
        })
        $script:FrontTimer.Start()
    } catch {
        Write-ErrorLog '起動時前面表示エラー' $_.Exception
    }
})

$script:Window.add_Closing({
    try {
        $script:ClosingNormally = $true
        Save-Settings
        Save-Tasks
        Write-AppLog '終了'
        $script:HeartbeatTimer.Stop()
        $script:DeadlineTimer.Stop()
        [TaskTableFreezeWatchdog]::Stop()
        try { $script:VoicePlayer.Close() } catch { }
    } catch {
        Write-ErrorLog '終了処理エラー' $_.Exception
    }
})

# Dispatcher上の未処理例外をErrorログへ残す。
$script:App = New-Object System.Windows.Application
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
$script:App.MainWindow = $script:Window
$script:App.add_DispatcherUnhandledException({
    param($sender,$e)
    try { Write-ErrorLog 'Dispatcher未処理例外' $e.Exception } catch { }
    $e.Handled = $true
})

Write-StartupTrace 'Application.Run開始'
try {
    [void]$script:App.Run($script:Window)
} catch {
    Write-ErrorLog 'アプリケーション実行中の致命的エラー' $_.Exception
} finally {
    try { [TaskTableFreezeWatchdog]::Stop() } catch { }
    try {
        if ($null -ne $script:SingleInstanceMutex) {
            if ($script:MutexAcquired) { $script:SingleInstanceMutex.ReleaseMutex() | Out-Null }
            $script:SingleInstanceMutex.Dispose()
        }
    } catch { }
}
