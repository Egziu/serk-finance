; Serk Finance Windows installer (NSIS 3, Unicode). Built by scripts/build-installers.sh:
;   makensis -DVERSION=0.4.0-rc1 -DVERSION4=0.4.0.0 -DSRC=<staged folder> -DOUTFILE=<exe> serk-finance.nsi
; Installs the application to Program Files, keeps company data in ProgramData\SerkFinance
; (readable only by administrators and the service), and runs it as the "SerkFinance" Windows
; service under the LocalService account.
Unicode true
SetCompressor /SOLID lzma
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "Sections.nsh"

!define APP "Serk Finance"
!define SERVICE "SerkFinance"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\SerkFinance"
!define PORT "8080"

Name "${APP} ${VERSION}"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\Serk Finance"
InstallDirRegKey HKLM "Software\SerkFinance" "InstallDir"
RequestExecutionLevel admin
BrandingText "${APP} ${VERSION}"
ShowInstDetails show
VIProductVersion "${VERSION4}"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "CompanyName" "Serk Technologies Group"
VIAddVersionKey "FileDescription" "${APP} installer"
VIAddVersionKey "LegalCopyright" "Serk Technologies Group"

!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "Install ${APP}"
!define MUI_WELCOMEPAGE_TEXT "This installs ${APP} ${VERSION} on this computer: the accounting application, its own database and a web interface that everyone in your office can open in a browser.$\r$\n$\r$\nAfter installation, your browser opens the setup page where you create your company and the first administrator.$\r$\n$\r$\nClick Next to continue."
!define MUI_FINISHPAGE_TITLE "${APP} is installed"
!define MUI_FINISHPAGE_TEXT "${APP} runs in the background as a Windows service and starts with Windows.$\r$\n$\r$\nOpen it any time from the Start menu or at http://localhost:${PORT}. Other computers in the office can use this computer's name or address with port ${PORT}."
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_TEXT "Open ${APP} and set up my company"
!define MUI_FINISHPAGE_RUN_FUNCTION OpenApp
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\README-INSTALL.txt"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Show the installation guide"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${SRC}\LICENSE-INSTALL.txt"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Var DATA
Var LOCALONLY

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "${APP} needs 64-bit Windows 10 or later."
    Abort
  ${EndIf}
  SetRegView 64
  SetShellVarContext all
  StrCpy $DATA "$APPDATA\SerkFinance"
FunctionEnd

Function OpenApp
  ExecShell "open" "$INSTDIR\starting.html"
FunctionEnd

; Stops the service if it exists and waits until it has stopped (database closed cleanly).
Function StopService
  nsExec::ExecToLog 'sc.exe stop ${SERVICE}'
  Pop $0
  StrCpy $1 0
  ${Do}
    nsExec::ExecToStack 'sc.exe query ${SERVICE}'
    Pop $0
    Pop $2
    ${If} $0 != 0
      ${Break}
    ${EndIf}
    StrCpy $3 $2
    Push $2
    Push "STOPPED"
    Call StrContains
    Pop $4
    ${If} $4 != ""
      ${Break}
    ${EndIf}
    Sleep 1000
    IntOp $1 $1 + 1
  ${LoopUntil} $1 >= 90
FunctionEnd

; StrContains: push haystack, push needle; pops "" when absent, else the needle.
Function StrContains
  Exch $R1 ; needle
  Exch
  Exch $R2 ; haystack
  Push $R3
  Push $R4
  Push $R5
  StrLen $R3 $R1
  StrCpy $R4 0
  StrCpy $R5 ""
  loop:
    StrCpy $R0 $R2 $R3 $R4
    StrCmp $R0 "" done
    StrCmp $R0 $R1 found
    IntOp $R4 $R4 + 1
    Goto loop
  found:
    StrCpy $R5 $R1
  done:
  StrCpy $R1 $R5
  Pop $R5
  Pop $R4
  Pop $R3
  Pop $R2
  Exch $R1
FunctionEnd

Section "${APP} (required)" SecMain
  SectionIn RO
  SetRegView 64
  SetShellVarContext all
  DetailPrint "Stopping ${APP} if it is running…"
  Call StopService
  SetOutPath "$INSTDIR"
  File /r "${SRC}\*.*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  DetailPrint "Preparing the data folder $DATA…"
  CreateDirectory "$DATA"
  ; Administrators and SYSTEM: full control; LocalService (the service account): modify. No access for other users.
  nsExec::ExecToLog 'icacls "$DATA" /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F *S-1-5-19:(OI)(CI)M'

  StrCpy $LOCALONLY ""
  ${IfNot} ${SectionIsSelected} 1
    StrCpy $LOCALONLY " --local-only"
  ${EndIf}
  DetailPrint "Registering the ${SERVICE} service…"
  nsExec::ExecToLog 'sc.exe query ${SERVICE}'
  Pop $0
  ${If} $0 == 0
    nsExec::ExecToLog 'sc.exe config ${SERVICE} binPath= "\"$INSTDIR\serk-server.exe\" service --data \"$DATA\"$LOCALONLY" start= delayed-auto obj= "NT AUTHORITY\LocalService" DisplayName= "${APP}"'
  ${Else}
    nsExec::ExecToLog 'sc.exe create ${SERVICE} binPath= "\"$INSTDIR\serk-server.exe\" service --data \"$DATA\"$LOCALONLY" start= delayed-auto obj= "NT AUTHORITY\LocalService" DisplayName= "${APP}"'
  ${EndIf}
  nsExec::ExecToLog 'sc.exe description ${SERVICE} "Serk Finance accounting server: database and web application on port ${PORT}."'
  nsExec::ExecToLog 'sc.exe failure ${SERVICE} reset= 86400 actions= restart/60000/restart/60000//'
  DetailPrint "Starting ${APP}…"
  nsExec::ExecToLog 'sc.exe start ${SERVICE}'

  WriteRegStr HKLM "Software\SerkFinance" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\SerkFinance" "DataDir" "$DATA"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayName" "${APP}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINSTKEY}" "Publisher" "Serk Technologies Group"
  WriteRegStr HKLM "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\serk-server.exe"
  WriteRegStr HKLM "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${UNINSTKEY}" "URLInfoAbout" "http://localhost:${PORT}/"
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoRepair" 1
SectionEnd

Section "Allow other computers in the office to connect" SecNet
  DetailPrint "Opening port ${PORT} for the office network (private and domain networks only)…"
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="${APP}"'
  nsExec::ExecToLog 'netsh advfirewall firewall add rule name="${APP}" dir=in action=allow protocol=TCP localport=${PORT} profile=private,domain program="$INSTDIR\serk-server.exe"'
SectionEnd

Section "Start menu and desktop shortcuts" SecShortcuts
  SetShellVarContext all
  CreateDirectory "$SMPROGRAMS\${APP}"
  WriteINIStr "$SMPROGRAMS\${APP}\${APP}.url" "InternetShortcut" "URL" "http://localhost:${PORT}/"
  WriteINIStr "$DESKTOP\${APP}.url" "InternetShortcut" "URL" "http://localhost:${PORT}/"
  CreateShortCut "$SMPROGRAMS\${APP}\Back up now.lnk" "$INSTDIR\backup-now.cmd"
  CreateShortCut "$SMPROGRAMS\${APP}\Reset a password.lnk" "$INSTDIR\reset-password.cmd"
  CreateShortCut "$SMPROGRAMS\${APP}\Installation guide.lnk" "$INSTDIR\README-INSTALL.txt"
  CreateShortCut "$SMPROGRAMS\${APP}\Uninstall ${APP}.lnk" "$INSTDIR\Uninstall.exe"
SectionEnd

LangString DESC_Main ${LANG_ENGLISH} "The application, the bundled PostgreSQL database and the Windows service."
LangString DESC_Net ${LANG_ENGLISH} "Lets other computers on your office network use ${APP} in their browser (opens port ${PORT} in Windows Firewall for private networks). Leave unticked to use it on this computer only."
LangString DESC_Short ${LANG_ENGLISH} "Shortcuts to open ${APP}, back up, reset a password and uninstall."
!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} $(DESC_Main)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecNet} $(DESC_Net)
  !insertmacro MUI_DESCRIPTION_TEXT ${SecShortcuts} $(DESC_Short)
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Function un.onInit
  SetRegView 64
  SetShellVarContext all
  ReadRegStr $DATA HKLM "Software\SerkFinance" "DataDir"
  ${If} $DATA == ""
    StrCpy $DATA "$APPDATA\SerkFinance"
  ${EndIf}
FunctionEnd

Section "Uninstall"
  SetRegView 64
  SetShellVarContext all
  DetailPrint "Stopping and removing the ${SERVICE} service…"
  nsExec::ExecToLog 'sc.exe stop ${SERVICE}'
  Sleep 8000
  nsExec::ExecToLog 'sc.exe delete ${SERVICE}'
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="${APP}"'
  Delete "$SMPROGRAMS\${APP}\*.*"
  RMDir "$SMPROGRAMS\${APP}"
  Delete "$DESKTOP\${APP}.url"
  RMDir /r "$INSTDIR\web"
  RMDir /r "$INSTDIR\pgsql"
  Delete "$INSTDIR\serk-server.exe"
  Delete "$INSTDIR\starting.html"
  Delete "$INSTDIR\backup-now.cmd"
  Delete "$INSTDIR\reset-password.cmd"
  Delete "$INSTDIR\README-INSTALL.txt"
  Delete "$INSTDIR\LICENSE-INSTALL.txt"
  Delete "$INSTDIR\THIRD-PARTY-NOTICES.txt"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_DEFBUTTON2 "Also delete ALL company data and backups in $DATA?$\r$\n$\r$\nChoose No to keep them (recommended) so a later installation can use them again." IDNO keep
    RMDir /r "$DATA"
  keep:
  DeleteRegKey HKLM "${UNINSTKEY}"
  DeleteRegKey HKLM "Software\SerkFinance"
SectionEnd
