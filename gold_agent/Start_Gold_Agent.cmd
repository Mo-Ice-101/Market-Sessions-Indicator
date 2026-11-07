@echo off
setlocal
cd /d "%~dp0"
if errorlevel 1 goto failed
echo Gold news monitor - no order execution or EA changes
echo.
if exist ".venv\Scripts\python.exe" goto dependencies
py -3.11 -c "import struct, sys; sys.exit(0 if struct.calcsize('P') == 8 else 1)"
if errorlevel 1 (
    echo ERROR: Python 3.11 64-bit is required. Install it with the Python launcher.
    goto failed
)
echo Creating the local Python environment...
py -3.11 -m venv ".venv"
if errorlevel 1 goto failed

:dependencies
".venv\Scripts\python.exe" -c "import MetaTrader5, streamlit"
if not errorlevel 1 goto start
echo Installing the missing MT5 connector...
".venv\Scripts\python.exe" -m pip install -r "requirements.txt"
if errorlevel 1 goto failed

:start
".venv\Scripts\python.exe" "launcher.py"
if errorlevel 1 goto failed
echo.
echo Monitor stopped.
pause
exit /b 0

:failed
echo.
echo Startup failed. Read the error above before trying again.
pause
exit /b 1
