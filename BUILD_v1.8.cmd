@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
where dotnet >nul 2>nul
if errorlevel 1 (
  echo .NET 8 SDK が必要です。
  pause
  exit /b 1
)

dotnet publish "TaskScheduleTable\TaskScheduleTable.csproj" -c Release -r win-x64 --self-contained true ^
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true ^
  -p:PublishTrimmed=false -o "publish\win-x64"
if errorlevel 1 (
  echo ビルドに失敗しました。
  pause
  exit /b 1
)

echo.
echo 完了: publish\win-x64\タスク_予定表.exe
pause
