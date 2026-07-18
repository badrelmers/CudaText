{
  proc_crashbackup
  -----------------
  Crash AND hang backup for CudaText on Windows, with diagnostic logging.

  When the program is about to terminate due to a fatal exception
  that nothing caught, OR when the main thread hangs for more than
  HANG_THRESHOLD_MS milliseconds, this unit writes a backup copy of
  the currently focused editor's text to
  "<originalfile>.<timestamp>.bak" next to the original file (or to
  %TEMP%\cudatext_recovery_<timestamp>.bak for untitled tabs).

  The timestamp format is YYYYMMDD_HHMMSS, e.g. 20260323_130455.

  Focused editor detection:
    We read AppCrashBackup_FocusedEditor, a global shadow pointer
    declared in proc_globdata.pas and updated by TEditorFrame.EditorOnEnter
    in form_frame.pas. That handler is the central OnEnter callback wired
    up for every TATSynEdit, so it fires for every focus path: tab clicks,
    File>New, File>Open, split-view switches, etc.

  Crash detection:
    We use SetUnhandledExceptionFilter. This is the Windows API that
    fires ONLY when an exception has propagated through every handler
    in the application and nothing caught it - i.e. a real crash.

    This is fundamentally different from AddVectoredExceptionHandler
    (VEH), which fires for EVERY exception including ones the
    application is about to catch. CudaText's Python integration
    raises Python errors as real SEH exceptions (code $E0465043,
    .NET CLR exception, marked non-continuable) and then catches
    them at a higher level. VEH sees these and creates false-positive
    backups. SetUnhandledExceptionFilter does not, because by the
    time it's called, the application has already had its chance to
    catch the exception.

    We chain to the previous filter (which FPC's RTL installs to
    translate STATUS_ACCESS_VIOLATION etc. into EAccessViolation).
    This preserves FPC's normal exception behavior.

  Hang detection:
    A "hang" is when the main thread stops processing messages
    (stuck in an infinite loop, deadlock, or blocking syscall). No
    exception is raised - the main thread is just stuck. Windows
    detects this after ~5 seconds of no message processing and shows
    the "Application Not Responding" / AppHangB1 dialog.

    We detect hangs with a TTimer + watchdog thread:
    1. A TTimer (firing on the main thread via WM_TIMER every
       HEARTBEAT_INTERVAL_MS) updates a global "heartbeat" timestamp.
       WM_TIMER only fires when the message loop is pumping messages -
       if the main thread hangs, the timer stops firing.
    2. A background watchdog thread checks the heartbeat every
       WATCHDOG_CHECK_MS. If the heartbeat is more than
       HANG_THRESHOLD_MS stale, the watchdog runs the backup.
    3. If the main thread recovers (heartbeat updates again), the
       watchdog resets so future hangs also get backed up.

    This catches the AppHangB1 case: by the time Windows shows the
    "Wait or Kill" dialog, our watchdog has already written the
    backup, so clicking "Kill" doesn't lose data.

  Installation timing:
    InstallCrashBackup MUST be called after Application.CreateForm.

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
  Windows, SysUtils, Classes, Forms, ExtCtrls,
  proc_globdata, form_frame, ATSynEdit;

type
  { Signature of a top-level exception filter callback. Must match
    the Windows LPTOP_LEVEL_EXCEPTION_FILTER type. }
  TTopLevelExceptionFilter = function(ExceptionInfo: PExceptionPointers): LongInt; stdcall;

  { Provides the method pointer for TTimer.OnTimer. }
  TCrashHeartbeat = class
  public
    procedure HandleTimer(Sender: TObject);
  end;

  { Watchdog thread that monitors the main thread heartbeat and
    triggers a backup if the main thread hangs. }
  TCrashWatchdogThread = class(TThread)
  protected
    procedure Execute; override;
  end;

{ SetUnhandledExceptionFilter is not declared in FPC's Windows unit on
  all versions, so declare it manually as a kernel32 import. }
function SetUnhandledExceptionFilter(
  Filter: TTopLevelExceptionFilter
): TTopLevelExceptionFilter; stdcall; external 'kernel32' name 'SetUnhandledExceptionFilter';

function SetThreadStackGuarantee(
  var StackSizeInBytes: ULONG
): DWORD; stdcall; external 'kernel32' name 'SetThreadStackGuarantee';

const
  CRASH_STACK_GUARANTEE = 16384;
  MAX_LOG_PATHS = 3;
  HEARTBEAT_INTERVAL_MS = 1000;   { TTimer fires every 1 second }
  WATCHDOG_CHECK_MS = 1000;       { Watchdog checks every 1 second }
  HANG_THRESHOLD_MS = 7000;       { User-requested: 7 seconds = hang }

var
  PrevFilter: TTopLevelExceptionFilter = nil;
  ChainToPrevFilter: Boolean = False;
  CrashHandled: LongInt = 0;
  Installed: Boolean = False;
  LogPaths: array[0..MAX_LOG_PATHS-1] of UnicodeString;

  Heartbeat: TCrashHeartbeat = nil;
  HeartbeatTimer: TTimer = nil;
  WatchdogThread: TCrashWatchdogThread = nil;

  { Heartbeat timestamp - updated by the main thread via TTimer,
    read by the watchdog thread. Aligned 32-bit reads/writes are
    atomic on x86/x64, but we use InterlockedExchange for clarity
    and portability. DWORD subtraction handles GetTickCount
    wraparound (every ~49 days) correctly via modular arithmetic. }
  MainThreadHeartbeat: DWORD = 0;
  { 0 = no hang backup done yet (or main thread recovered since last hang).
    1 = hang backup already done for the current hang. Reset to 0
    when the main thread updates the heartbeat again. }
  HangBackupDone: LongInt = 0;

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

{ ---------- Timestamp formatting ---------- }

function ZeroPad2(N: Integer): AnsiString;
begin
  if N < 10 then
    Result := '0' + IntToStr(N)
  else
    Result := IntToStr(N);
end;

function ZeroPad4(N: Integer): AnsiString;
var
  S: AnsiString;
begin
  S := IntToStr(N);
  while Length(S) < 4 do
    S := '0' + S;
  Result := S;
end;

function FormatTimestamp: AnsiString;
var
  ST: TSystemTime;
begin
  GetLocalTime(ST);
  Result :=
    ZeroPad4(ST.wYear) +
    ZeroPad2(ST.wMonth) +
    ZeroPad2(ST.wDay) + '_' +
    ZeroPad2(ST.wHour) +
    ZeroPad2(ST.wMinute) +
    ZeroPad2(ST.wSecond);
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
  Timestamp: AnsiString;
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

  ShadowEd := TATSynEdit(AppCrashBackup_FocusedEditor);
  LogStep('  [step] Shadow ptr (AppCrashBackup_FocusedEditor) = ' + IntToHex(PtrUInt(ShadowEd), 16));

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

  Timestamp := FormatTimestamp;
  LogStep('  [step] Timestamp = ' + Timestamp);

  if FileNameUTF8 = '' then
  begin
    BackupPath := GetTempDir(False) + 'cudatext_recovery_' + string(Timestamp) + '.bak';
    LogStep('  [step] Untitled tab, backup path = ' + AnsiString(BackupPath));
  end
  else
  begin
    BackupPath := FileNameUTF8 + '.' + string(Timestamp) + '.bak';
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

{ ---------- Crash detection: unhandled exception filter ---------- }

function CrashUnhandledFilter(ExceptionInfo: PExceptionPointers): LongInt; stdcall;
var
  Code: DWORD;
begin
  Code := DWORD(ExceptionInfo^.ExceptionRecord^.ExceptionCode);
  LogStep('[UnhandledFilter] entered, exception code = ' + IntToHex(Code, 8));

  TryDoBackup('UnhandledFilter');

  if ChainToPrevFilter and Assigned(PrevFilter) then
    Result := PrevFilter(ExceptionInfo)
  else
    Result := EXCEPTION_CONTINUE_SEARCH;
end;

{ ---------- Hang detection: heartbeat + watchdog ---------- }

procedure TCrashHeartbeat.HandleTimer(Sender: TObject);
begin
  { Called by TTimer via WM_TIMER on the main thread. WM_TIMER only
    fires when the message loop is pumping - if the main thread is
    stuck, this never fires, the heartbeat goes stale, and the
    watchdog triggers a backup. }
  InterlockedExchange(MainThreadHeartbeat, LongInt(GetTickCount));
  { Main thread is alive - reset the hang-backup-done flag so a future
    hang can also be backed up. }
  InterlockedExchange(HangBackupDone, 0);
end;

procedure TCrashWatchdogThread.Execute;
var
  Now: DWORD;
  LastHB: DWORD;
  Diff: DWORD;
begin
  LogStep('[Watchdog] thread started');
  while not Terminated do
  begin
    Sleep(WATCHDOG_CHECK_MS);

    Now := GetTickCount;
    { Atomic read of the heartbeat. InterlockedExchangeAdd with 0
      returns the old value without modifying it. }
    LastHB := DWORD(InterlockedExchangeAdd(MainThreadHeartbeat, 0));

    { DWORD subtraction handles GetTickCount wraparound correctly
      via modular arithmetic. }
    Diff := Now - LastHB;

    if Diff > HANG_THRESHOLD_MS then
    begin
      LogStep('[Watchdog] hang detected, heartbeat age = ' + IntToStr(Int64(Diff)) + 'ms');

      { Only do the backup ONCE per hang. If we already did it,
        don't spam more backups. The flag is reset when the main
        thread updates the heartbeat again (i.e. recovers). }
      if InterlockedCompareExchange(HangBackupDone, 1, 0) = 0 then
      begin
        TryDoBackup('Watchdog');
      end
      else
      begin
        LogStep('[Watchdog] hang backup already done for this hang, waiting for recovery');
      end;
    end;
  end;
  LogStep('[Watchdog] thread terminating');
end;

{ ---------- Installation ---------- }

procedure InstallCrashBackup;
var
  StackGuarantee: ULONG;
begin
  if Installed then Exit;
  Installed := True;

  InitLogPaths;
  LogStep('=== InstallCrashBackup starting ===');
  LogStep('Log path[0] (TEMP) = ' + AnsiString(LogPaths[0]));
  LogStep('Log path[1] (EXE)  = ' + AnsiString(LogPaths[1]));
  LogStep('Log path[2] (HOME) = ' + AnsiString(LogPaths[2]));

  LogStep('Installing SetUnhandledExceptionFilter (chaining to FPC''s previous filter)...');
  PrevFilter := SetUnhandledExceptionFilter(@CrashUnhandledFilter);
  ChainToPrevFilter := True;
  LogStep('Filter installed, prev filter ptr = ' + IntToHex(PtrUInt(PrevFilter), 16));

  LogStep('Setting stack guarantee...');
  StackGuarantee := CRASH_STACK_GUARANTEE;
  SetThreadStackGuarantee(StackGuarantee);
  LogStep('Stack guarantee set');

  LogStep('Setting up hang detection (heartbeat timer + watchdog thread)...');
  Heartbeat := TCrashHeartbeat.Create;
  HeartbeatTimer := TTimer.Create(nil);
  HeartbeatTimer.Interval := HEARTBEAT_INTERVAL_MS;
  HeartbeatTimer.OnTimer := @Heartbeat.HandleTimer;
  HeartbeatTimer.Enabled := True;
  { Seed the initial heartbeat so the watchdog doesn't immediately
    fire before the first WM_TIMER arrives. }
  InterlockedExchange(MainThreadHeartbeat, LongInt(GetTickCount));
  LogStep('Heartbeat timer installed, interval = ' + IntToStr(HEARTBEAT_INTERVAL_MS) + 'ms');

  WatchdogThread := TCrashWatchdogThread.Create(False);
  LogStep('Watchdog thread started, hang threshold = ' + IntToStr(HANG_THRESHOLD_MS) + 'ms');

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
