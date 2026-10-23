@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0" || goto :dir_error

where dotnet.exe >nul 2>&1
if errorlevel 1 goto :dotnet_missing

if not exist "TaskScheduleTable\TaskScheduleTable.csproj" goto :project_missing

if exist "publish\win-x64" rmdir /s /q "publish\win-x64"
mkdir "publish\win-x64" >nul 2>&1

dotnet publish "TaskScheduleTable\TaskScheduleTable.csproj" --configuration Release --runtime win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true -p:PublishTrimmed=false --output "publish\win-x64"
if errorlevel 1 goto :build_failed

echo.
echo BUILD OK
echo Output folder:
echo %CD%\publish\win-x64
echo.
explorer.exe "%CD%\publish\win-x64"
goto :end

:dotnet_missing
echo.
echo ERROR: .NET 8 SDK was not found.
echo Install .NET 8 SDK and run this file again.
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
goto :failed

:failed
echo.
pause
exit /b 1

:end
echo.
pause
exit /b 0
