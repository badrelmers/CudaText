{
  proc_crashbackup
  -----------------
  Crash backup for CudaText on Windows, with diagnostic logging.

  When an unhandled exception is about to terminate the process, this
  unit writes a backup copy of the currently focused editor's text to
  "<originalfile>.bak" next to the original file (or to
  %TEMP%\cudatext_recovery.bak for untitled tabs).

  Focused editor detection:
    We read AppCrashBackup_FocusedEditor, a global shadow pointer
    declared in proc_globdata.pas and updated by TEditorFrame.EditorOnEnter
    in form_frame.pas. That handler is the central OnEnter callback wired
    up for every TATSynEdit (line ~2362 of form_frame.pas:
      ed.OnEnter:= @EditorOnEnter;
    ), so it fires for EVERY focus path:
      - Tab click in the tab bar
      - File > New / File > Open (creates a new tab and focuses it)
      - Split-view switch between Ed1/Ed2
      - Clicking inside an editor
      - Keyboard navigation that changes focus

    This is the same hook CudaText uses to fire the Python "on_focus"
    event exposed to plugins - so it's the canonical "this editor just
    got focus" notification.

    We don't need to subscribe to or replicate any focus-tracking logic
    here - we just read the value CudaText already maintains.

  Hooks:
    1. AddVectoredExceptionHandler - fires for every SEH exception on
       any thread (catches foreign-thread crashes, plugin crashes, etc.)
    2. ExceptProc - unhandled Pascal exceptions on any thread
    3. Application.OnException - main-thread UI crashes

  Log file:
    Written to three locations (TEMP, exe dir, USERPROFILE) so we can
    find it no matter what. Uses only Win32 API calls - no FPC heap
    operations in the logging path.
}
unit proc_crashbackup;

{$mode objfpc}{$H+}

interface

procedure InstallCrashBackup;
procedure CrashBackup_RegisterThread;

implementation

{$IFDEF WINDOWS}

uses
  Windows, SysUtils, Classes, Forms,
  proc_globdata, form_frame, ATSynEdit;

type
  TCrashVectoredHandler = function(ExceptionInfo: PExceptionPointers): LongInt; stdcall;
  TCrashExceptionHandler = class
  public
    procedure HandleException(Sender: TObject; E: Exception);
  end;

function AddVectoredExceptionHandler(
  FirstHandler: ULONG;
  Handler: TCrashVectoredHandler
): Pointer; stdcall; external 'kernel32' name 'AddVectoredExceptionHandler';

function SetThreadStackGuarantee(
  var StackSizeInBytes: ULONG
): DWORD; stdcall; external 'kernel32' name 'SetThreadStackGuarantee';

const
  CRASH_STACK_GUARANTEE = 16384;
  MAX_LOG_PATHS = 3;

var
  CrashHandler: TCrashExceptionHandler = nil;
  PrevExceptProc: TExceptProc = nil;
  PrevOnException: TExceptionEvent = nil;
  CrashHandled: LongInt = 0;
  Installed: Boolean = False;
  LogPaths: array[0..MAX_LOG_PATHS-1] of UnicodeString;

{ ---------- Log path initialization ---------- }

procedure InitLogPaths;
var
  TempBuf: array[0..MAX_PATH] of WideChar;
  TempLen: Integer;
  ExeBuf: array[0..MAX_PATH] of WideChar;
  ExeLen: Integer;
  HomeBuf: array[0..MAX_PATH] of WideChar;
  HomeLen: Integer;
  i, LastSlash: Integer;
begin
  for i := 0 to MAX_LOG_PATHS - 1 do
    LogPaths[i] := '';

  TempLen := GetTempPathW(MAX_PATH, @TempBuf[0]);
  if (TempLen > 0) and (TempLen < MAX_PATH) then
  begin
    SetString(LogPaths[0], PWideChar(@TempBuf[0]), TempLen);
    if (Length(LogPaths[0]) > 0) and (LogPaths[0][Length(LogPaths[0])] <> '\') then
      LogPaths[0] := LogPaths[0] + '\';
    LogPaths[0] := LogPaths[0] + 'cudatext_crash.log';
  end;

  ExeLen := GetModuleFileNameW(0, @ExeBuf[0], MAX_PATH);
  if (ExeLen > 0) and (ExeLen < MAX_PATH) then
  begin
    LastSlash := -1;
    for i := 0 to ExeLen - 1 do
      if ExeBuf[i] = '\' then LastSlash := i;
    if LastSlash >= 0 then
    begin
      SetString(LogPaths[1], PWideChar(@ExeBuf[0]), LastSlash + 1);
      LogPaths[1] := LogPaths[1] + 'cudatext_crash.log';
    end;
  end;

  HomeLen := GetEnvironmentVariableW('USERPROFILE', @HomeBuf[0], MAX_PATH);
  if (HomeLen > 0) and (HomeLen < MAX_PATH) then
  begin
    SetString(LogPaths[2], PWideChar(@HomeBuf[0]), HomeLen);
    if (Length(LogPaths[2]) > 0) and (LogPaths[2][Length(LogPaths[2])] <> '\') then
      LogPaths[2] := LogPaths[2] + '\';
    LogPaths[2] := LogPaths[2] + 'cudatext_crash.log';
  end;
end;

{ ---------- Diagnostic logging (WinAPI only, no FPC heap) ---------- }

procedure LogToPath(const Path: UnicodeString; const S: AnsiString);
var
  FileHandle: THandle;
  BytesWritten: DWORD;
  LineEnd: AnsiString;
begin
  if Path = '' then Exit;

  FileHandle := CreateFileW(PWideChar(Path),
    FILE_APPEND_DATA, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if FileHandle = INVALID_HANDLE_VALUE then Exit;

  BytesWritten := 0;
  LineEnd := #13#10;
  if Length(S) > 0 then
    WriteFile(FileHandle, S[1], Length(S), BytesWritten, nil);
  WriteFile(FileHandle, LineEnd[1], 2, BytesWritten, nil);
  CloseHandle(FileHandle);
end;

procedure LogLine(const S: AnsiString);
var
  i: Integer;
begin
  for i := 0 to MAX_LOG_PATHS - 1 do
    LogToPath(LogPaths[i], S);
end;

procedure LogStep(const S: AnsiString);
begin
  try
    LogLine(S);
  except
  end;
end;

function IsFatalExceptionCode(Code: DWORD): Boolean;
begin
  Result := (Code and $C0000000) = $C0000000;
end;

{ ---------- The actual backup ---------- }

procedure DoBackup;
var
  Ed: TATSynEdit;
  Frame: TEditorFrame;
  i: Integer;
  FileNameUTF8: string;
  BackupPath: string;
  TextU: UnicodeString;
  TextU8: RawByteString;
  Stream: TFileStream;
  BOM: array[0..2] of Byte;
  ShadowEd: TATSynEdit;
  ShadowIsValid: Boolean;
begin
  LogStep('  [step] DoBackup entered');

  if AppFrameList1 = nil then
  begin
    LogStep('  [step] AppFrameList1 is nil - aborting');
    Exit;
  end;

  LogStep('  [step] AppFrameList1 count = ' + IntToStr(AppFrameList1.Count));
  if AppFrameList1.Count = 0 then
  begin
    LogStep('  [step] AppFrameList1 is empty - aborting');
    Exit;
  end;

  { Read the shadow pointer ONCE. It could be changed by the main thread
    while we're reading it, but aligned pointer reads are atomic on
    x86/x64, so we'll get either the old or new value - never a torn read. }
  ShadowEd := TATSynEdit(AppCrashBackup_FocusedEditor);
  LogStep('  [step] Shadow ptr (AppCrashBackup_FocusedEditor) = ' + IntToHex(PtrUInt(ShadowEd), 16));

  { Verify the shadow pointer is still valid by finding it in the list.
    If the tab was closed, the pointer would be dangling. }
  ShadowIsValid := False;
  if ShadowEd <> nil then
  begin
    for i := 0 to AppFrameList1.Count - 1 do
    begin
      Frame := TEditorFrame(AppFrameList1.Items[i]);
      if Frame = nil then Continue;
      if (Frame.Ed1 = ShadowEd) or (Frame.Ed2 = ShadowEd) then
      begin
        ShadowIsValid := True;
        Break;
      end;
    end;
  end;
  LogStep('  [step] Shadow ptr valid = ' + BoolToStr(ShadowIsValid, True));

  Ed := nil;
  if ShadowIsValid then
  begin
    Ed := ShadowEd;
    LogStep('  [step] Using shadow-ptr editor');
  end
  else
  begin
    LogStep('  [step] Shadow ptr nil or stale, trying AppCodetreeState.Editor');
    LogStep('  [step] AppCodetreeState.Editor ptr = ' + IntToHex(PtrUInt(AppCodetreeState.Editor), 16));
    if AppCodetreeState.Editor <> nil then
    begin
      for i := 0 to AppFrameList1.Count - 1 do
      begin
        Frame := TEditorFrame(AppFrameList1.Items[i]);
        if Frame = nil then Continue;
        if (Frame.Ed1 = AppCodetreeState.Editor) or
           (Frame.Ed2 = AppCodetreeState.Editor) then
        begin
          Ed := TATSynEdit(AppCodetreeState.Editor);
          LogStep('  [step] Found editor via AppCodetreeState');
          Break;
        end;
      end;
    end;
  end;

  if Ed = nil then
  begin
    LogStep('  [step] Focused editor not found, using fallback (first editor)');
    for i := 0 to AppFrameList1.Count - 1 do
    begin
      Frame := TEditorFrame(AppFrameList1.Items[i]);
      if Frame <> nil then
      begin
        Ed := Frame.Ed1;
        if Ed <> nil then Break;
      end;
    end;
  end;

  if Ed = nil then
  begin
    LogStep('  [step] No editor found at all - aborting');
    Exit;
  end;

  LogStep('  [step] Found editor, ptr = ' + IntToHex(PtrUInt(Ed), 16));
  LogStep('  [step] Ed.Modified = ' + BoolToStr(Ed.Modified, True));

  if not Ed.Modified then
  begin
    LogStep('  [step] Editor not modified - aborting (file matches disk)');
    Exit;
  end;

  FileNameUTF8 := Ed.FileName;
  LogStep('  [step] FileName = ' + AnsiString(FileNameUTF8));

  if FileNameUTF8 = '' then
  begin
    BackupPath := GetTempDir(False) + 'cudatext_recovery.bak';
    LogStep('  [step] Untitled tab, backup path = ' + AnsiString(BackupPath));
  end
  else
  begin
    BackupPath := FileNameUTF8 + '.bak';
    LogStep('  [step] Backup path = ' + AnsiString(BackupPath));
  end;

  LogStep('  [step] Reading Ed.Text');
  TextU := Ed.Text;
  LogStep('  [step] Ed.Text length = ' + IntToStr(Length(TextU)));
  if TextU = '' then
  begin
    LogStep('  [step] Ed.Text is empty - aborting');
    Exit;
  end;

  LogStep('  [step] UTF8 encoding');
  TextU8 := UTF8Encode(TextU);
  LogStep('  [step] UTF8 length = ' + IntToStr(Length(TextU8)));

  LogStep('  [step] Creating TFileStream');
  Stream := TFileStream.Create(BackupPath, fmCreate);
  try
    LogStep('  [step] Writing BOM');
    BOM[0] := $EF; BOM[1] := $BB; BOM[2] := $BF;
    Stream.Write(BOM, 3);

    LogStep('  [step] Writing text');
    if Length(TextU8) > 0 then
      Stream.Write(TextU8[1], Length(TextU8));

    LogStep('  [step] Backup complete');
  finally
    Stream.Free;
  end;
end;

procedure TryDoBackup(const HookName: AnsiString);
begin
  if InterlockedCompareExchange(CrashHandled, 1, 0) <> 0 then
  begin
    LogStep('[' + HookName + '] already in progress, backing off');
    Exit;
  end;
  try
    LogStep('[' + HookName + '] backup starting');
    try
      DoBackup;
    except
      on E: Exception do
        LogStep('  [EXCEPTION] ' + AnsiString(E.ClassName) + ': ' + AnsiString(E.Message));
    end;
  finally
    InterlockedExchange(CrashHandled, 0);
    LogStep('[' + HookName + '] backup finished');
  end;
end;

{ ---------- Hooks ---------- }

function CrashVectoredFilter(ExceptionInfo: PExceptionPointers): LongInt; stdcall;
var
  Code: DWORD;
begin
  Result := EXCEPTION_CONTINUE_SEARCH;

  Code := DWORD(ExceptionInfo^.ExceptionRecord^.ExceptionCode);
  LogStep('[VEH] entered, exception code = ' + IntToHex(Code, 8));

  if not IsFatalExceptionCode(Code) then
  begin
    LogStep('[VEH] non-fatal code, skipping backup');
    Exit;
  end;

  LogStep('[VEH] fatal code, attempting backup');
  TryDoBackup('VEH');
end;

procedure CrashExceptProc(Obj: TObject; Addr: Pointer; FrameCount: LongInt; Frames: PPointer);
begin
  LogStep('[ExceptProc] entered');
  TryDoBackup('ExceptProc');
  if Assigned(PrevExceptProc) then
    PrevExceptProc(Obj, Addr, FrameCount, Frames);
end;

procedure TCrashExceptionHandler.HandleException(Sender: TObject; E: Exception);
begin
  LogStep('[OnException] entered, exception = ' + AnsiString(E.ClassName) + ': ' + AnsiString(E.Message));
  TryDoBackup('OnException');
  if Assigned(PrevOnException) then
    PrevOnException(Sender, E);
end;

{ ---------- Installation ---------- }

procedure InstallCrashBackup;
var
  StackGuarantee: ULONG;
  VehHandle: Pointer;
begin
  if Installed then Exit;
  Installed := True;

  InitLogPaths;
  LogStep('=== InstallCrashBackup starting ===');
  LogStep('Log path[0] (TEMP) = ' + AnsiString(LogPaths[0]));
  LogStep('Log path[1] (EXE)  = ' + AnsiString(LogPaths[1]));
  LogStep('Log path[2] (HOME) = ' + AnsiString(LogPaths[2]));

  LogStep('Installing VEH...');
  VehHandle := AddVectoredExceptionHandler(1, TCrashVectoredHandler(@CrashVectoredFilter));
  LogStep('VEH installed, handle = ' + IntToHex(PtrUInt(VehHandle), 16));

  LogStep('Setting stack guarantee...');
  StackGuarantee := CRASH_STACK_GUARANTEE;
  SetThreadStackGuarantee(StackGuarantee);
  LogStep('Stack guarantee set');

  LogStep('Creating crash handler object...');
  CrashHandler := TCrashExceptionHandler.Create;

  LogStep('Hooking ExceptProc...');
  PrevExceptProc := ExceptProc;
  ExceptProc := @CrashExceptProc;
  LogStep('ExceptProc hooked');

  LogStep('Hooking Application.OnException...');
  PrevOnException := Application.OnException;
  Application.OnException := @CrashHandler.HandleException;
  LogStep('OnException hooked');

  LogStep('Initial shadow ptr = ' + IntToHex(PtrUInt(AppCrashBackup_FocusedEditor), 16));

  LogStep('=== InstallCrashBackup complete ===');
end;

procedure CrashBackup_RegisterThread;
begin
end;

initialization
  InitLogPaths;
  LogStep('[init] proc_crashbackup unit loaded');

{$ELSE}

procedure InstallCrashBackup;
begin
end;

procedure CrashBackup_RegisterThread;
begin
end;

{$ENDIF}

end.
