@echo off
rem Test double for mpv: speaks just enough of the JSON IPC protocol to
rem exercise MpvController end-to-end (launch, named-pipe connect, property
rem observation, end-file classification). Not part of the shipped app.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mock-mpv.ps1" %*
exit /b %ERRORLEVEL%
