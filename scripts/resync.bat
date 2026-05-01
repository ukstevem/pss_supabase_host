@echo off
REM scripts/resync.bat — Windows wrapper for resync.sh.
REM
REM Double-click to run, or create a desktop shortcut to this file.
REM See docs/08_resync.md "Windows desktop shortcut" for setup details.
REM
REM What it does:
REM   1. cd to the repo root (parent of scripts/)
REM   2. Locates Git Bash (bash.exe)
REM   3. Runs scripts/resync.sh under bash
REM   4. Pauses so you can read the output before the window closes

setlocal

REM Repo root = parent of the directory this .bat lives in
cd /d "%~dp0\.."

REM Try the common Git for Windows install paths in order.
set "GIT_BASH="
if exist "C:\Program Files\Git\bin\bash.exe" set "GIT_BASH=C:\Program Files\Git\bin\bash.exe"
if not defined GIT_BASH if exist "C:\Program Files (x86)\Git\bin\bash.exe" set "GIT_BASH=C:\Program Files (x86)\Git\bin\bash.exe"
if not defined GIT_BASH if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "GIT_BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

if not defined GIT_BASH (
  echo.
  echo Could not find Git Bash. Install Git for Windows from https://gitforwindows.org/
  echo Or edit this .bat to point GIT_BASH at your bash.exe location.
  echo.
  pause
  exit /b 1
)

echo Using bash: %GIT_BASH%
echo Repo root:  %CD%
echo.

"%GIT_BASH%" -c "./scripts/resync.sh"
set "RC=%ERRORLEVEL%"

echo.
if %RC% equ 0 (
  echo --- resync.sh finished successfully ---
) else (
  echo --- resync.sh exited with code %RC% ---
)
echo.
pause
exit /b %RC%
