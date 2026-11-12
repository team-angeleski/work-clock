; Darnell Jr. was called Work Clock. Two things the rename would otherwise get wrong:
; 1. Windows drops a trailing full stop from folder names, so install into "Darnell Jr" (no dot)
;    rather than "Darnell Jr.", which other tools may not find again.
; 2. A copy installed under the old name would stay behind (with its own start-at-login entry).
;    Remove it quietly. Focus history lives in %APPDATA%\WorkClock and is not touched.
!macro NSIS_HOOK_PREINSTALL
  ${If} $INSTDIR == "$LOCALAPPDATA\Darnell Jr."
    StrCpy $INSTDIR "$LOCALAPPDATA\Darnell Jr"
    SetOutPath $INSTDIR
  ${EndIf}
  ${If} ${FileExists} "$LOCALAPPDATA\Work Clock\uninstall.exe"
    ExecWait '"$LOCALAPPDATA\Work Clock\uninstall.exe" /S /UPDATE _?=$LOCALAPPDATA\Work Clock'
    RMDir /r "$LOCALAPPDATA\Work Clock"
  ${EndIf}
!macroend
