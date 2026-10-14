@echo off
rem Run this AFTER every Pandora run. Double-click and pick 0_Master.hkx in the file picker.
if "%~1"=="" goto pick
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0OStimNodeDiet.ps1" -Path "%~1"
goto end
:pick
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0OStimNodeDiet.ps1"
:end
pause
