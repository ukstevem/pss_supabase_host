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

echo.
echo ============================================================
echo   REFRESH SELF-HOSTED SUPABASE FROM CLOUD
echo ============================================================
echo.
echo   This will WIPE the dev database and reload from cloud.
echo.
echo   YOU WILL LOSE on self-hosted:
echo     - Any rows you've added to public.* tables
echo     - Any new tables you've added to the public schema
echo     - All auth.users / sessions / identities currently there
echo.
echo   YOU WILL KEEP:
echo     - Anything in custom schemas (e.g. dev_scratch.*)
echo     - VM-level config, Docker, secrets
echo     - The supabase stack itself
echo.
echo   Direction: cloud (read-only) -^> self-hosted (overwritten).
echo   Cloud is NEVER written to.
echo.
echo ============================================================
echo.
set /p CONFIRM=Type YES (uppercase) to continue, anything else to abort:
if /i not "%CONFIRM%"=="YES" (
  echo.
  echo Aborted. No changes made.
  echo.
  pause
  exit /b 0
)

echo.
echo Using bash: %GIT_BASH%
echo Repo root:  %CD%
echo.

REM JUMP_HOST: set to your jump host (e.g. root@10.0.0.84) if you're on
REM VPN and your source IP isn't 10.0.0.x. Leave empty when on the LAN
REM directly. The bash script picks it up via env.
set "JUMP_HOST="

"%GIT_BASH%" -c "JUMP_HOST='%JUMP_HOST%' ./scripts/resync.sh --yes-i-am-sure"
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
