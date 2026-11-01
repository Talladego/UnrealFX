@echo off
setlocal EnableExtensions
cd /d "%~dp0"

rem Build a one-file UnrealFX.exe (tkinter OBS window + winsound) via PyInstaller.
rem Requires: py -3 with pip. Output: dist\UnrealFX.exe (never copied into the repo root;
rem release zips are built by .github/workflows/release.yml). Keep the PyInstaller
rem version and flags below in sync with that workflow.

where py >nul 2>&1
if errorlevel 1 (
    echo [build_exe] Python launcher 'py' not found.
    exit /b 1
)

echo [build_exe] Ensuring PyInstaller...
py -3 -m pip install "pyinstaller==6.22.3" >nul
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

echo [build_exe] Wrote %CD%\dist\UnrealFX.exe
echo [build_exe] To test it, copy it next to files\ in your installed AddOns\UnrealFX folder.

rmdir /s /q build
del /f /q UnrealFX.spec >nul 2>&1
echo [build_exe] Done.
exit /b 0
