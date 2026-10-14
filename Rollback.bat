@echo off
rem Restores 0_Master.hkx from 0_Master.hkx.original. Running Pandora again does the same.
if "%~1"=="" goto pick
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0OStimNodeDiet.ps1" -Rollback -Path "%~1"
goto end
:pick
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0OStimNodeDiet.ps1" -Rollback
:end
pause
