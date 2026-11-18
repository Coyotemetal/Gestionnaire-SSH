@echo off
:: ==========================================================
::  Lance le Gestionnaire SSH (interface : ssh-manager.ps1)
::  Les deux fichiers + vms.txt doivent etre dans le meme dossier.
:: ==========================================================
set "PS1=%~dp0ssh-manager.ps1"

if not exist "%PS1%" (
    echo [ERREUR] ssh-manager.ps1 est introuvable a cote de ce script.
    pause
    exit /b 1
)

:: Windows Terminal disponible : on ouvre le gestionnaire dedans (rendu optimal)
where wt >nul 2>&1
if %errorlevel%==0 (
    start "" wt -w new --title "SSH Manager" --suppressApplicationTitle powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
) else (
    start "SSH Manager" powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
)
exit /b 0
