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
!include "WordFunc.nsh"

!define APP "Serk Finance"
!define SERVICE "SerkFinance"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\SerkFinance"
!define PORT "8080"

Name "${APP} ${VERSION}"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\Serk Finance"
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
Var PREVDIR

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "${APP} needs 64-bit Windows 10 or later."
    Abort
  ${EndIf}
  SetRegView 64
  SetShellVarContext all
  StrCpy $DATA "$APPDATA\SerkFinance"
  ; The previous installation's folder and data folder (64-bit registry view).
  ReadRegStr $PREVDIR HKLM "Software\SerkFinance" "InstallDir"
  ${If} $PREVDIR != ""
    StrCpy $INSTDIR $PREVDIR
  ${EndIf}
  ReadRegStr $0 HKLM "Software\SerkFinance" "DataDir"
  ${If} $0 != ""
    StrCpy $DATA $0
  ${EndIf}
  ; Never install an older version over a newer one (its database would be too new for it).
  ReadRegStr $0 HKLM "Software\SerkFinance" "Version4"
  ${If} $0 != ""
    ${VersionCompare} "$0" "${VERSION4}" $1
    ${If} $1 == 1
      MessageBox MB_ICONSTOP "A newer version of ${APP} is installed. Installing an older version over it is not supported." /SD IDOK
      Abort
    ${EndIf}
  ${EndIf}
  ReadRegStr $0 HKLM "${UNINSTKEY}" "DisplayVersion"
  ${If} $0 != ""
  ${AndIf} $0 != "${VERSION}"
    MessageBox MB_OKCANCEL|MB_ICONINFORMATION "${APP} $0 is installed. This replaces it with version ${VERSION}; your company data is kept.$\r$\n$\r$\nMake a backup first (Start menu > ${APP} > Back up now). Installing an older version over a newer one is not supported." /SD IDOK IDOK +2
    Abort
  ${EndIf}
FunctionEnd

; Opens the page as the signed-in user, not with the installer's administrator rights.
Function OpenApp
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\starting.html"'
FunctionEnd

; Locks FOLDER to Administrators and SYSTEM (full control) plus the EXTRA grants, owned by
; Administrators. All existing permissions on the folder and everything inside are removed
; first, so a folder created in advance by another user keeps none of that user's access.
; A junction or symbolic link is refused, so the permissions cannot be redirected elsewhere.
!macro LockFolder FOLDER EXTRA
  nsExec::ExecToLog `powershell.exe -NoProfile -NonInteractive -Command "if ((Get-Item -LiteralPath '${FOLDER}' -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 3 }"`
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "${FOLDER} is a link to another folder or cannot be checked (exit $0). Remove it, or choose another folder, and run the installer again." /SD IDOK
    Abort
  ${EndIf}
  nsExec::ExecToLog 'icacls "${FOLDER}" /setowner *S-1-5-32-544 /T /C /Q'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Could not take ownership of ${FOLDER} (icacls exit $0)." /SD IDOK
    Abort
  ${EndIf}
  nsExec::ExecToLog 'icacls "${FOLDER}" /reset /T /C /Q'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Could not reset permissions on ${FOLDER} (icacls exit $0)." /SD IDOK
    Abort
  ${EndIf}
  nsExec::ExecToLog 'icacls "${FOLDER}" /inheritance:r /grant:r *S-1-5-32-544:(OI)(CI)F *S-1-5-18:(OI)(CI)F ${EXTRA} /Q'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Could not set permissions on ${FOLDER} (icacls exit $0)." /SD IDOK
    Abort
  ${EndIf}
!macroend

; Stops the service and waits until it has stopped (database closed cleanly). A database
; process of this installation that is still running afterwards is ended.
!macro StopServiceBody
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
    Push $2
    Push "STOPPED"
    Call ${UN}StrContains
    Pop $4
    ${If} $4 != ""
      ${Break}
    ${EndIf}
    Sleep 1000
    IntOp $1 $1 + 1
  ${LoopUntil} $1 >= 90
  nsExec::ExecToLog `powershell.exe -NoProfile -NonInteractive -Command "Get-Process serk-server,postgres -ErrorAction SilentlyContinue | Where-Object { $$_.Path -like '$INSTDIR\*' } | Stop-Process -Force"`
  Pop $0
!macroend

; StrContains: push haystack, push needle; pops "" when absent, else the needle.
!macro StrContainsBody

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
!macroend
Function StrContains
  !insertmacro StrContainsBody
FunctionEnd
Function un.StrContains
  !insertmacro StrContainsBody
FunctionEnd
!define UN ""
Function StopService
  !insertmacro StopServiceBody
FunctionEnd
!undef UN
!define UN "un."
Function un.StopService
  !insertmacro StopServiceBody
FunctionEnd
!undef UN

Section "${APP} (required)" SecMain
  SectionIn RO
  SetRegView 64
  SetShellVarContext all
  DetailPrint "Stopping ${APP} if it is running…"
  Call StopService
  ; Permissions are set on the whole install folder, so it must be this program's own folder:
  ; the previous installation's, a folder named "Serk Finance", or an empty one.
  ${If} ${FileExists} "$INSTDIR\*.*"
  ${AndIf} $INSTDIR != $PREVDIR
    StrCpy $0 $INSTDIR "" -12
    ${If} $0 != "Serk Finance"
      FindFirst $1 $2 "$INSTDIR\*.*"
      StrCpy $3 0
      ${DoWhile} $2 != ""
        ${If} $2 != "."
        ${AndIf} $2 != ".."
          StrCpy $3 1
        ${EndIf}
        FindNext $1 $2
      ${Loop}
      FindClose $1
      ${If} $3 == 1
        MessageBox MB_ICONSTOP "$INSTDIR is not empty. Choose an empty folder, or a folder named Serk Finance." /SD IDOK
        Abort
      ${EndIf}
    ${EndIf}
  ${EndIf}
  CreateDirectory "$INSTDIR"
  ; The service runs these programs: only administrators may change them, wherever installed.
  ; The folder is locked before anything is copied into it.
  !insertmacro LockFolder "$INSTDIR" "*S-1-5-19:(OI)(CI)RX *S-1-5-32-545:(OI)(CI)RX"
  SetOutPath "$INSTDIR"
  File /r "${SRC}\*.*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  DetailPrint "Preparing the data folder $DATA…"
  ; A data folder that exists without a recorded installation may have been prepared by
  ; someone else: it is used only when an administrator confirms (never in a silent install).
  ReadRegStr $0 HKLM "${UNINSTKEY}" "DisplayVersion"
  ${If} $0 == ""
  ${AndIf} ${FileExists} "$DATA\*.*"
    MessageBox MB_YESNO|MB_ICONQUESTION "$DATA already exists (for example, data kept from an earlier installation).$\r$\n$\r$\nUse it? Choose No to stop; then move that folder away if you do not know where it came from." /SD IDNO IDYES +2
    Abort
  ${EndIf}
  CreateDirectory "$DATA"
  ; LocalService (the service account) may modify; other users have no access.
  !insertmacro LockFolder "$DATA" "*S-1-5-19:(OI)(CI)M"

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
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "Could not register the ${SERVICE} service (sc.exe exit $0). See the details above." /SD IDOK
    Abort
  ${EndIf}
  nsExec::ExecToLog 'sc.exe description ${SERVICE} "Serk Finance accounting server: database and web application on port ${PORT}."'
  Pop $0
  nsExec::ExecToLog 'sc.exe failure ${SERVICE} reset= 86400 actions= restart/60000/restart/60000//'
  Pop $0
  ; Also restart after the service stops with an error, not only after a crash.
  nsExec::ExecToLog 'sc.exe failureflag ${SERVICE} 1'
  Pop $0
  ; The office-network rule is added again below only when that option is ticked.
  nsExec::ExecToLog 'netsh advfirewall firewall delete rule name="${APP}"'
  Pop $0
  DetailPrint "Starting ${APP}…"
  nsExec::ExecToLog 'sc.exe start ${SERVICE}'
  Pop $0
  ${If} $0 != 0
    MessageBox MB_ICONEXCLAMATION "${APP} was installed but did not start (sc.exe exit $0). Restart the computer, or see $DATA\logs." /SD IDOK
  ${EndIf}

  WriteRegStr HKLM "Software\SerkFinance" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\SerkFinance" "DataDir" "$DATA"
  WriteRegStr HKLM "Software\SerkFinance" "Version4" "${VERSION4}"
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
  Call un.StopService
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
  MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_DEFBUTTON2 "Also delete ALL company data and backups in $DATA?$\r$\n$\r$\nChoose No to keep them (recommended) so a later installation can use them again." /SD IDNO IDNO keep
    RMDir /r "$DATA"
  keep:
  DeleteRegKey HKLM "${UNINSTKEY}"
  DeleteRegKey HKLM "Software\SerkFinance"
SectionEnd
