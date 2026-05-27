@echo off
pushd "%~dp0rtl"
python python\jtag_rtl_infer.py %*
set ERR=%ERRORLEVEL%
popd
exit /b %ERR%
