@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "PAYLOAD=%~dp0UpdateFiles"
set "TARGET=%~dp0"

if not exist "%PAYLOAD%\*.exe" goto :missing_payload

for %%F in ("%PAYLOAD%\*.exe") do set "APP=%%~nxF"

if not exist "%TARGET%%APP%" (
  for %%D in ("%~dp0..") do set "TARGET=%%~fD\"
)

if not exist "%TARGET%%APP%" goto :target_not_found

taskkill /IM "%APP%" /F >nul 2>&1
timeout /t 1 /nobreak >nul

if not exist "%TARGET%Backup_PreUpdate" mkdir "%TARGET%Backup_PreUpdate" >nul 2>&1
copy /Y "%TARGET%%APP%" "%TARGET%Backup_PreUpdate\%APP%" >nul

copy /Y "%PAYLOAD%\%APP%" "%TARGET%%APP%" >nul
if errorlevel 1 goto :copy_failed

if not exist "%TARGET%Voice" mkdir "%TARGET%Voice" >nul 2>&1
xcopy /E /I /Y "%PAYLOAD%\Voice\*" "%TARGET%Voice\" >nul
if errorlevel 1 goto :copy_failed

if exist "%PAYLOAD%\TaskScheduleTable.ico" (
  copy /Y "%PAYLOAD%\TaskScheduleTable.ico" "%TARGET%TaskScheduleTable.ico" >nul
)

start "" "%TARGET%%APP%"
exit /b 0

:missing_payload
echo Update payload was not found.
echo Please extract the updater ZIP completely and run this file again.
pause
exit /b 2

:target_not_found
echo The old TaskScheduleTable installation was not found.
echo Extract this updater inside the old application folder, then run it again.
pause
exit /b 3

:copy_failed
echo Update failed while copying files.
echo The old EXE backup is in Backup_PreUpdate.
pause
exit /b 4
