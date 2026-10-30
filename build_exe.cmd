@echo off
setlocal EnableExtensions
cd /d "%~dp0"

rem Build a one-file UnrealFX.exe (tkinter OBS window + winsound) via PyInstaller.
rem Requires: py -3 with pip. Output: UnrealFX.exe in this folder.

where py >nul 2>&1
if errorlevel 1 (
    echo [build_exe] Python launcher 'py' not found.
    exit /b 1
)

echo [build_exe] Ensuring PyInstaller...
py -3 -m pip install --upgrade pyinstaller >nul
if errorlevel 1 (
    echo [build_exe] pip install pyinstaller failed.
    exit /b 1
)

if exist build rmdir /s /q build
if exist dist rmdir /s /q dist
if exist UnrealFX.spec del /f /q UnrealFX.spec

echo [build_exe] Compiling UnrealFX.py...
py -3 -m PyInstaller --noconfirm --clean --onefile --windowed ^
  --name UnrealFX ^
  --icon "files\squigicon.ico" ^
  --hidden-import tkinter ^
  --hidden-import winsound ^
  "UnrealFX.py"
if errorlevel 1 (
    echo [build_exe] PyInstaller failed.
    exit /b 1
)

if not exist "dist\UnrealFX.exe" (
    echo [build_exe] Missing dist\UnrealFX.exe
    exit /b 1
)

copy /y "dist\UnrealFX.exe" "UnrealFX.exe" >nul
echo [build_exe] Wrote %CD%\UnrealFX.exe

rmdir /s /q build
rmdir /s /q dist
del /f /q UnrealFX.spec >nul 2>&1
echo [build_exe] Done.
exit /b 0
