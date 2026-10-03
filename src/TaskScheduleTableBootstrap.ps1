$ErrorActionPreference = 'Stop'
$appDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($appDir)) { $appDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$logDir = Join-Path $appDir 'Log'
$errorDir = Join-Path $logDir 'Error'
try {
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $errorDir)) { New-Item -ItemType Directory -Path $errorDir -Force | Out-Null }
} catch { }
$enc = New-Object System.Text.UTF8Encoding -ArgumentList $true
$trace = Join-Path $logDir 'bootstrap_trace.txt'
function Write-BootTrace([string]$text) {
    try {
        [System.IO.File]::AppendAllText($trace, ('[{0}] {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $text, [Environment]::NewLine), $enc)
    } catch { }
}
function Write-BootError([System.Exception]$ex) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $path = Join-Path $errorDir ('タスク_予定表_Log_Error_{0}.txt' -f $stamp)
    $body = @(
        'APP=タスク_予定表',
        'VERSION=1.6',
        ('DATETIME={0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')),
        'MESSAGE=起動ブートストラップで初期化エラー',
        'EXCEPTION_BEGIN',
        $ex.ToString(),
        'EXCEPTION_END'
    ) -join [Environment]::NewLine
    try { [System.IO.File]::WriteAllText($path, $body + [Environment]::NewLine, $enc) } catch { }
    return $path
}
Write-BootTrace 'bootstrap start'
try {
    $main = Join-Path $appDir 'TaskScheduleTable.ps1'
    if (-not (Test-Path -LiteralPath $main)) { throw ('TaskScheduleTable.ps1 が見つかりません: ' + $main) }
    $global:TaskTableBootstrapPath = $main
    Write-BootTrace ('main invoke: ' + $main)
    & $main
    Write-BootTrace 'main returned normally'
    exit 0
} catch {
    $errorPath = Write-BootError $_.Exception
    Write-BootTrace ('fatal: ' + $_.Exception.Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("タスク・予定表の初期化に失敗しました。`r`n`r`n詳細ログを作成しました:`r`n$errorPath", 'タスク・予定表', 'OK', 'Error') | Out-Null
    } catch { }
    exit 71
}
