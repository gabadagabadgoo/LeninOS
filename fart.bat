@echo off
title LENINOS CONSTRUCTION BUREAU - RED OCTOBER v3.2
color 4E
echo.
echo =====================================================================
echo  LENINOS v3.2 - RED OCTOBER REVISION
echo  APPLICATION BUILD SYSTEM
echo =====================================================================
echo.

set "LOGFILE=%CD%\build_crash.log"
echo [%date% %time%] Build started > "%LOGFILE%"

echo [STATE] Launching build engine...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0_build_engine.ps1"
set "PS_ERR=%ERRORLEVEL%"

if %PS_ERR% neq 0 (
    echo.
    echo [ERROR] Build engine failed with code %PS_ERR%
    echo.
    echo ===== CRASH LOG =====
    if exist "%LOGFILE%" type "%LOGFILE%"
    echo =====================
    pause
    exit /b 1
)

if exist "LeninOS-win32-x64\LeninOS.exe" (
    echo.
    echo =====================================================================
    echo  BUILD COMPLETE
    echo =====================================================================
    echo.
    echo  OUTPUT: LeninOS-win32-x64\LeninOS.exe
    echo.
    echo  STATE ARCADE BUREAU: In The Party menu.
    echo  UNDERGROUND NET: Type "underground" in Terminal.
    echo.
) else (
    echo [STATE] Build packaged in dev mode. Check above for details.
)

echo Launch LeninOS now? [Y/N]
set /p LAUNCHAPP=" > "
if /i "%LAUNCHAPP%"=="Y" (
    if exist "LeninOS-win32-x64\LeninOS.exe" (
        start "" "LeninOS-win32-x64\LeninOS.exe"
    ) else (
        echo [ERROR] Executable not found.
    )
)

echo.
echo GLORY TO THE WORKERS' STATE!
echo Build log: %LOGFILE%
pause
exit /b 0