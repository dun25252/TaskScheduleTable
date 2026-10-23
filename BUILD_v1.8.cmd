@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0" || goto :dir_error

if not exist "TaskScheduleTable\TaskScheduleTable.csproj" goto :project_missing

set "SDK_OK="
for /f "tokens=*" %%S in ('dotnet --list-sdks 2^>nul ^| findstr /b "8."') do set "SDK_OK=1"
if not defined SDK_OK goto :dotnet_sdk_missing

if exist "publish\win-x64" rmdir /s /q "publish\win-x64"
mkdir "publish\win-x64" >nul 2>&1

dotnet publish "TaskScheduleTable\TaskScheduleTable.csproj" --configuration Release --runtime win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:PublishTrimmed=false --output "publish\win-x64"

if not exist "publish\win-x64\タスク_予定表.exe" goto :build_failed

echo.
echo BUILD OK
echo Output:
echo %CD%\publish\win-x64\タスク_予定表.exe
echo.
explorer.exe "%CD%\publish\win-x64"
goto :end

:dotnet_sdk_missing
echo.
echo ERROR: .NET 8 SDK was not found.
echo.
echo This PC may have only the .NET Runtime.
echo Install the .NET 8 SDK, then run this file again.
echo.
start "" "https://dotnet.microsoft.com/en-us/download/dotnet/8.0"
goto :failed

:project_missing
echo.
echo ERROR: TaskScheduleTable.csproj was not found.
echo Run this CMD from the extracted project folder.
goto :failed

:dir_error
echo.
echo ERROR: Could not open the project folder.
goto :failed

:build_failed
echo.
echo ERROR: Build failed.
echo The EXE was not generated.
goto :failed

:failed
echo.
pause
exit /b 1

:end
echo.
pause
exit /b 0
