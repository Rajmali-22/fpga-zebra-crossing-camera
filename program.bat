@echo off
rem Program the EDGE Artix-7 with the zebra-crossing camera, then run the self-test.
rem   program.bat                       -> bitstream\zebracam.bit (default build)
rem   program.bat bitstream\zebracam_proven.bit   -> fallback build (see README)
cd /d %~dp0
set BIT=%1
if "%BIT%"=="" set BIT=bitstream\zebracam.bit
set VIVADO=C:\Xilinx\Vivado\2024.2\bin\vivado.bat
if not exist "%VIVADO%" set VIVADO=vivado
call "%VIVADO%" -mode batch -nojournal -nolog -source vivado\program.tcl -tclargs %BIT%
if errorlevel 1 goto :eof
echo.
echo Waiting 3 s for the camera to be configured...
timeout /t 3 /nobreak >nul
python host\zebracam.py auto selftest
