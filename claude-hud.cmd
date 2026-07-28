@echo off
rem Claude HUD - lanciatore da doppio click.
rem Passa da qui perche' un .ps1 col doppio click si apre nell'editor.
rem   -ExecutionPolicy Bypass  non dipende dalla policy della macchina
rem   -WindowStyle Hidden      niente finestra di PowerShell
rem   start "" /b + exit       questa console non resta aperta
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%USERPROFILE%\.claude\claude-hud-widget.ps1"
exit
