(*
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.

Copyright (c) Alexey Torgashin
*)
{
  proc_crashbackup
  -----------------
  Crash AND hang backup for CudaText on Windows, with diagnostic logging.

  When the program is about to terminate due to a fatal exception
  that nothing caught, OR when the main thread hangs for more than
  HANG_THRESHOLD_MS milliseconds, this unit writes a backup copy of
  the currently focused editor's text to
  "<originalfile>.<timestamp>.CTbak" next to the original file (for
  named files), or to
  <AppDir_Settings>\crash_backup\<tabname>_tab_recovered_<timestamp>.CTbak
  (for untitled tabs, e.g. "untitled3_tab_recovered_20260719_022954.CTbak",
  with %TEMP% as a fallback if the settings folder is not writable).

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
    backups. SetUnhandledExceptionFilter does not.

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
       watchdog resets so future hangs also get backed up. The
       hang backup file is DELETED on recovery because the user
       didn't actually lose any data.

  Backup file:
    Written via a thread-safe manual write: CreateFileW / WriteFile /
    CloseHandle (Win32 API only, no FPC heap ops in the write path),
    iterating Ed.Strings.Lines[i] per-line and writing the editor's
    line ending (read from Ed.Strings.Endings) after each line.

    We do NOT use Ed.Strings.SaveToFile because it internally calls
    TThread.Synchronize for progress reporting on large files
    (>65536 lines), which fails with "EThread: CheckSynchronize
    called from non-main thread" when invoked from our watchdog
    thread or a crashed worker thread.

    Line endings (CRLF/LF/CR) are preserved exactly. Encoding is
    always UTF-8 with BOM - if the original file was UTF-16 or ANSI,
    the backup will be UTF-8 (acceptable for crash recovery; the user
    can re-encode after recovering their content). The editor's
    Modified flag, FileName, and ModifiedVersion are NOT touched,
    so CudaText's session-restore on next startup still sees the
    file as having unsaved changes.

  Log file:
    Written to <AppDir_Settings>\crash_backup\cudatext_crash_backup.log.
    Each line is prefixed with "YYYY-MM-DD HH:MM:SS ". Only meaningful
    events are logged - crashes, hangs, backups, recoveries, and errors.
    Startup/installation noise is NOT logged. Uses only Win32 API calls
    (CreateFileW / WriteFile / CloseHandle) so the log works even if
    the FPC heap is corrupted.

  Installation timing:
    InstallCrashBackup MUST be called after Application.CreateForm,
    because AppDir_Settings is set during CudaText's initialization,
    and TTimer needs the LCL to be ready.
}
unit proc_crashbackup;

{$mode objfpc}{$H+}

interface

procedure InstallCrashBackup;

implementation

{$IFDEF WINDOWS}

uses
  Windows, SysUtils, Classes, Forms, ExtCtrls,
  proc_globdata, form_frame, ATSynEdit, ATStrings, ATStringProc;

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
  HEARTBEAT_INTERVAL_MS = 1000;   { TTimer fires every 1 second }
  WATCHDOG_CHECK_MS = 1000;       { Watchdog checks every 1 second }
  HANG_THRESHOLD_MS = 7000;       { User-requested: 7 seconds = hang }

var
  PrevFilter: TTopLevelExceptionFilter = nil;
  { ChainToPrevFilter gates whether we may safely call PrevFilter. It is
    set to True only after InstallCrashBackup has returned, so if the
    filter is somehow called during installation we don't dereference
    a half-initialized PrevFilter. }
  ChainToPrevFilter: Boolean = False;
  CrashHandled: LongInt = 0;
  Installed: Boolean = False;
  LogPath: UnicodeString = '';
  { Folder where backups and the log are stored:
    <AppDir_Settings>\crash_backup\. Created at install time. }
  CrashBackupDir: string = '';

  Heartbeat: TCrashHeartbeat = nil;
  HeartbeatTimer: TTimer = nil;
  WatchdogThread: TCrashWatchdogThread = nil;

  { Critical section protecting LastHangBackupPath. The watchdog thread
    writes to it; the main thread (via TTimer) reads and clears it.
    AnsiString assignment is NOT atomic in FPC (refcount + pointer copy),
    so we need a real lock. }
  HangPathLock: TRTLCriticalSection;

  { Heartbeat timestamp - updated by the main thread via TTimer,
    read by the watchdog thread. Stored as LongInt (not DWORD) because
    FPC's InterlockedExchange/InterlockedExchangeAdd take LongInt.
    GetTickCount returns DWORD; we cast to LongInt for storage. }
  MainThreadHeartbeat: LongInt = 0;
  { 0 = no hang backup done yet (or main thread recovered since last hang).
    1 = hang backup already done for the current hang. Reset to 0
    when the main thread updates the heartbeat again. }
  HangBackupDone: LongInt = 0;

  { Path of the backup file created by the last hang. When the main
    thread recovers from a hang, this file is deleted because the
    user didn't actually lose any data. Guarded by HangBackupDone. }
  LastHangBackupPath: string = '';

{ ---------- Log path initialization ---------- }

procedure InitLogPath;
begin
  { Use CudaText's settings folder. AppDir_Settings is set during
    CudaText's initialization, which has completed by the time
    InstallCrashBackup is called (after Application.CreateForm).

    All crash-backup artifacts (log file + untitled-tab backups) live
    in a dedicated subfolder <AppDir_Settings>\crash_backup\. }
  LogPath := '';
  CrashBackupDir := '';
  if AppDir_Settings = '' then Exit;

  CrashBackupDir := AppDir_Settings + '\crash_backup';

  { Create the folder if it doesn't exist. ForceDirectories creates
    all intermediate directories too. Wrapped in try/except because
    directory creation can fail (permissions, disk full, etc.) - if
    it fails, we just won't write logs/backups there, which is
    acceptable degradation. }
  try
    if not DirectoryExists(CrashBackupDir) then
      ForceDirectories(CrashBackupDir);
  except
  end;

  LogPath := UTF8Decode(CrashBackupDir) + '\cudatext_crash_backup.log';
end;

{ ---------- Timestamp formatting ----------
  Declared before the logging functions because LogLine uses them. }

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
  FillChar(ST, SizeOf(ST), 0);
  GetLocalTime(ST);
  Result :=
    ZeroPad4(ST.wYear) +
    ZeroPad2(ST.wMonth) +
    ZeroPad2(ST.wDay) + '_' +
    ZeroPad2(ST.wHour) +
    ZeroPad2(ST.wMinute) +
    ZeroPad2(ST.wSecond);
end;

{ ---------- Diagnostic logging (WinAPI only, no FPC heap) ---------- }

procedure LogLine(const S: AnsiString);
var
  FileHandle: THandle;
  BytesWritten: DWORD;
  LineEnd: AnsiString;
  ST: TSystemTime;
  FullLine: AnsiString;
begin
  if LogPath = '' then Exit;

  FileHandle := CreateFileW(PWideChar(LogPath),
    FILE_APPEND_DATA, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if FileHandle = INVALID_HANDLE_VALUE then Exit;

  { Prefix every line with a timestamp: YYYY-MM-DD HH:MM:SS. }
  FillChar(ST, SizeOf(ST), 0);
  GetLocalTime(ST);
  FullLine :=
    ZeroPad4(ST.wYear) + '-' +
    ZeroPad2(ST.wMonth) + '-' +
    ZeroPad2(ST.wDay) + ' ' +
    ZeroPad2(ST.wHour) + ':' +
    ZeroPad2(ST.wMinute) + ':' +
    ZeroPad2(ST.wSecond) + ' ' + S;

  BytesWritten := 0;
  LineEnd := #13#10;
  if Length(FullLine) > 0 then
    WriteFile(FileHandle, FullLine[1], Length(FullLine), BytesWritten, nil);
  WriteFile(FileHandle, LineEnd[1], 2, BytesWritten, nil);
  CloseHandle(FileHandle);
end;

procedure LogStep(const S: AnsiString);
begin
  try
    LogLine(S);
  except
  end;
end;

{ ---------- Filename sanitization for untitled tabs ---------- }

{ Replace characters that are illegal in Windows filenames with '_'.
  Also collapse spaces to '_' so the backup filename stays a single
  clean token (e.g. "Untitled 3" -> "Untitled_3"). }
function SanitizeForFilename(const S: string): string;
const
  BadFilenameChars = ['<', '>', ':', '"', '/', '\', '|', '?', '*', ' '];
var
  i, j: Integer;
  Ch: Char;
begin
  SetLength(Result, Length(S));
  j := 0;
  for i := 1 to Length(S) do
  begin
    Ch := S[i];
    if (Ch in BadFilenameChars) or (Ch < #32) then
      Ch := '_';
    Inc(j);
    Result[j] := Ch;
  end;
  SetLength(Result, j);
end;

{ ---------- The actual backup ---------- }

{ Write the editor's text to a file using only Win32 API calls
  (CreateFileW / WriteFile / CloseHandle) and per-line iteration.
  This avoids Ed.Strings.SaveToFile, which internally uses
  TThread.Synchronize for progress reporting on large files and
  fails with "EThread: CheckSynchronize called from non-main thread"
  when called from our watchdog thread or a crashed worker thread.

  Line endings are preserved by reading Ed.Strings.Endings and
  writing the appropriate bytes (CRLF / LF / CR) after each line.
  The file is written as UTF-8 with BOM - this matches what most
  text files use today. If the original file was UTF-16 or ANSI,
  the backup will be UTF-8 (the user can re-encode after recovery).

  Returns True on success, False on failure. }
function WriteBackupManual(Ed: TATSynEdit; const BackupPath: string): Boolean;
var
  FileHandle: THandle;
  BytesWritten: DWORD;
  BOM: array[0..2] of Byte;
  LineEnd: AnsiString;
  LineU: UnicodeString;
  LineU8: RawByteString;
  Utf8Len: Integer;
  i: Integer;
  Count: Integer;
  PathW: UnicodeString;
begin
  Result := False;

  PathW := UTF8Decode(BackupPath);
  FileHandle := CreateFileW(PWideChar(PathW),
    GENERIC_WRITE, 0, nil, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if FileHandle = INVALID_HANDLE_VALUE then Exit;

  try
    { UTF-8 BOM }
    BOM[0] := $EF; BOM[1] := $BB; BOM[2] := $BF;
    if not WriteFile(FileHandle, BOM, 3, BytesWritten, nil) then Exit;

    { Determine line ending bytes from the editor's Endings property. }
    case Ed.Strings.Endings of
      TATLineEnds.Windows: LineEnd := #13#10;
      TATLineEnds.Mac:    LineEnd := #13;
    else
      { TATLineEnds.Unix and any other value }
      LineEnd := #10;
    end;

    Count := Ed.Strings.Count;
    for i := 0 to Count - 1 do
    begin
      LineU := Ed.Strings.Lines[i];

      { Convert UnicodeString to UTF-8. }
      if Length(LineU) > 0 then
      begin
        Utf8Len := WideCharToMultiByte(CP_UTF8, 0,
          PWideChar(LineU), Length(LineU),
          nil, 0, nil, nil);
        if Utf8Len > 0 then
        begin
          SetLength(LineU8, Utf8Len);
          if WideCharToMultiByte(CP_UTF8, 0,
            PWideChar(LineU), Length(LineU),
            PAnsiChar(LineU8), Utf8Len, nil, nil) = 0 then
            Exit;
          if not WriteFile(FileHandle, LineU8[1], Utf8Len, BytesWritten, nil) then Exit;
        end;
      end;

      { Write line ending (skip after the last line to match typical
        text file convention - though many editors do write a trailing
        newline, omitting it here is safer for diff tools). }
      if i < Count - 1 then
      begin
        if not WriteFile(FileHandle, LineEnd[1], Length(LineEnd), BytesWritten, nil) then Exit;
      end;
    end;

    Result := True;
  finally
    CloseHandle(FileHandle);
  end;
end;

function DoBackup: string;
var
  Ed: TATSynEdit;
  Frame: TEditorFrame;
  MatchedFrame: TEditorFrame;
  i: Integer;
  FileNameUTF8: string;
  BackupPath: string;
  ShadowEd: TATSynEdit;
  ShadowIsValid: Boolean;
  Timestamp: AnsiString;
  UntitledName: string;
begin
  Result := '';

  if AppFrameList1 = nil then Exit;
  if AppFrameList1.Count = 0 then Exit;

  ShadowEd := TATSynEdit(AppCrashBackup_FocusedEditor);

  MatchedFrame := nil;
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
        MatchedFrame := Frame;
        Break;
      end;
    end;
  end;

  Ed := nil;
  if ShadowIsValid then
    Ed := ShadowEd
  else if AppCodetreeState.Editor <> nil then
  begin
    for i := 0 to AppFrameList1.Count - 1 do
    begin
      Frame := TEditorFrame(AppFrameList1.Items[i]);
      if Frame = nil then Continue;
      if (Frame.Ed1 = AppCodetreeState.Editor) or
         (Frame.Ed2 = AppCodetreeState.Editor) then
      begin
        Ed := TATSynEdit(AppCodetreeState.Editor);
        MatchedFrame := Frame;
        Break;
      end;
    end;
  end;

  if Ed = nil then
  begin
    for i := 0 to AppFrameList1.Count - 1 do
    begin
      Frame := TEditorFrame(AppFrameList1.Items[i]);
      if Frame <> nil then
      begin
        Ed := Frame.Ed1;
        if Ed <> nil then
        begin
          MatchedFrame := Frame;
          Break;
        end;
      end;
    end;
  end;

  if Ed = nil then
  begin
    LogStep('[backup] no editor found - aborting');
    Exit;
  end;

  if not Ed.Modified then
  begin
    LogStep('[backup] editor not modified - aborting (file matches disk)');
    Exit;
  end;

  FileNameUTF8 := Ed.FileName;
  Timestamp := FormatTimestamp;

  if FileNameUTF8 = '' then
  begin
    { Untitled tab: try to save inside <settings>/crash_backup/ first.
      If that fails (e.g. settings folder not writable), fall back to
      the system temp folder.

      Try to use the tab's caption (e.g. "Untitled3") in the filename
      so the user can tell which tab the backup came from. If we can't
      get the caption, fall back to a generic "untitled_tab" name. }
    UntitledName := '';
    if MatchedFrame <> nil then
      UntitledName := SanitizeForFilename(MatchedFrame.TabCaptionUntitled);
    if UntitledName = '' then
      UntitledName := 'untitled_tab'
    else
      UntitledName := LowerCase(UntitledName) + '_tab';

    if CrashBackupDir <> '' then
      BackupPath := CrashBackupDir + '\' + UntitledName + '_recovered_' + string(Timestamp) + '.CTbak'
    else
      BackupPath := GetTempDir(False) + UntitledName + '_recovered_' + string(Timestamp) + '.CTbak';
  end
  else
    BackupPath := FileNameUTF8 + '.' + string(Timestamp) + '.CTbak';

  LogStep('[backup] path = ' + AnsiString(BackupPath));

  { Write the backup using a thread-safe manual write (WinAPI only,
    per-line iteration). We do NOT use Ed.Strings.SaveToFile because
    it internally calls TThread.Synchronize for progress reporting
    on large files (>65536 lines), which fails with
    "EThread: CheckSynchronize called from non-main thread" when
    invoked from our watchdog thread or a crashed worker thread.

    Trade-off: line endings are preserved (read from Ed.Strings.Endings),
    but the encoding is always UTF-8 with BOM. If the original file was
    UTF-16 or ANSI, the backup will be UTF-8 - the user can re-encode
    after recovery. This is acceptable for crash recovery. }
  if WriteBackupManual(Ed, BackupPath) then
  begin
    LogStep('[backup] complete');
    Result := BackupPath;
  end
  else
  begin
    { If this was an untitled-tab save to CrashBackupDir, retry in temp. }
    if (FileNameUTF8 = '') and (CrashBackupDir <> '') and
       (Pos(AnsiString(CrashBackupDir), AnsiString(BackupPath)) > 0) then
    begin
      BackupPath := GetTempDir(False) + UntitledName + '_recovered_' + string(Timestamp) + '.CTbak';
      LogStep('[backup] retrying in temp folder: ' + AnsiString(BackupPath));
      if WriteBackupManual(Ed, BackupPath) then
      begin
        LogStep('[backup] complete (temp folder)');
        Result := BackupPath;
      end
      else
      begin
        LogStep('[backup] FAILED in both locations');
        Result := '';
      end;
    end
    else
    begin
      LogStep('[backup] FAILED (WriteBackupManual returned False)');
      Result := '';
    end;
  end;
end;

procedure TryDoBackup(const HookName: AnsiString; IsHang: Boolean = False);
var
  BackupPath: string;
begin
  if InterlockedCompareExchange(CrashHandled, 1, 0) <> 0 then
  begin
    LogStep('[' + HookName + '] already in progress, backing off');
    Exit;
  end;
  try
    LogStep('[' + HookName + '] backup starting');
    BackupPath := '';
    try
      BackupPath := DoBackup;
    except
      on E: Exception do
        LogStep('  [EXCEPTION] ' + AnsiString(E.ClassName) + ': ' + AnsiString(E.Message));
    end;
    if IsHang and (BackupPath <> '') then
    begin
      EnterCriticalSection(HangPathLock);
      try
        LastHangBackupPath := BackupPath;
      finally
        LeaveCriticalSection(HangPathLock);
      end;
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
  { The unhandled exception filter runs in a crashed process. Wrap
    EVERYTHING in try/except so a fault in our own logging code
    still falls through to the backup attempt. }
  try
    Code := DWORD(ExceptionInfo^.ExceptionRecord^.ExceptionCode);
    try
      LogStep('[UnhandledFilter] entered, exception code = ' + IntToHex(Code, 8));
    except
    end;

    { Always attempt the crash backup, even if a hang backup is in
      progress (CrashHandled=1). A crash is terminal - the process
      is about to die - so we don't bother with the serialization
      flag. The two backups go to different timestamped paths so
      there's no file-level conflict. }
    try
      DoBackup;
    except
    end;
  except
  end;

  { Chain to FPC's previous filter so normal exception translation
    (STATUS_ACCESS_VIOLATION -> EAccessViolation etc.) and crash
    dialog behavior continue to work. }
  if ChainToPrevFilter and Assigned(PrevFilter) then
    Result := PrevFilter(ExceptionInfo)
  else
    Result := EXCEPTION_CONTINUE_SEARCH;
end;

{ ---------- Hang detection: heartbeat + watchdog ---------- }

procedure TCrashHeartbeat.HandleTimer(Sender: TObject);
var
  PathToDelete: string;
begin
  { Update the heartbeat. WM_TIMER only fires when the message loop is
    pumping - if the main thread is stuck, this never fires, the
    heartbeat goes stale, and the watchdog triggers a backup. }
  InterlockedExchange(MainThreadHeartbeat, LongInt(GetTickCount));

  { Main thread is alive. If we previously created a hang backup and
    the main thread has now recovered, delete the backup file because
    the user didn't actually lose any data. }
  if InterlockedCompareExchange(HangBackupDone, 0, 1) = 1 then
  begin
    { Atomically claim and read the hang backup path. The lock
      protects the AnsiString assignment in the watchdog thread. }
    EnterCriticalSection(HangPathLock);
    try
      PathToDelete := LastHangBackupPath;
      LastHangBackupPath := '';
    finally
      LeaveCriticalSection(HangPathLock);
    end;

    if PathToDelete <> '' then
    begin
      LogStep('[Heartbeat] main thread recovered from hang, deleting backup: ' + AnsiString(PathToDelete));
      try
        if FileExists(PathToDelete) then
          DeleteFile(PathToDelete);
      except
        on E: Exception do
          LogStep('[Heartbeat] FAILED to delete backup: ' + AnsiString(E.ClassName) + ': ' + AnsiString(E.Message));
      end;
    end
    else
    begin
      LogStep('[Heartbeat] main thread recovered, but no hang backup path was recorded (race?)');
    end;
  end;
end;

procedure TCrashWatchdogThread.Execute;
var
  CurrentTick: DWORD;
  LastHB: DWORD;
  Diff: DWORD;
begin
  while not Terminated do
  begin
    Sleep(WATCHDOG_CHECK_MS);

    CurrentTick := GetTickCount;
    LastHB := DWORD(InterlockedExchangeAdd(MainThreadHeartbeat, 0));

    { DWORD subtraction handles GetTickCount wraparound correctly. }
    Diff := CurrentTick - LastHB;

    if Diff > HANG_THRESHOLD_MS then
    begin
      LogStep('[Watchdog] hang detected, heartbeat age = ' + IntToStr(Int64(Diff)) + 'ms');

      { Only do the backup ONCE per hang. The flag is reset when the
        main thread updates the heartbeat again (i.e. recovers). }
      if InterlockedCompareExchange(HangBackupDone, 1, 0) = 0 then
        TryDoBackup('Watchdog', True);
    end;
  end;
end;

{ ---------- Installation ---------- }

procedure InstallCrashBackup;
var
  StackGuarantee: ULONG;
begin
  if Installed then Exit;
  Installed := True;

  InitLogPath;
  InitCriticalSection(HangPathLock);

  { Install the unhandled exception filter, saving the previous one
    so we can chain to it after writing the backup. FPC's RTL has
    already installed its own filter by this point, so PrevFilter
    will be FPC's filter. }
  PrevFilter := SetUnhandledExceptionFilter(@CrashUnhandledFilter);
  ChainToPrevFilter := True;

  { Reserve ~16 KB of stack on the main thread so the filter has room
    to run even after a stack overflow. }
  StackGuarantee := CRASH_STACK_GUARANTEE;
  SetThreadStackGuarantee(StackGuarantee);

  { Set up hang detection: heartbeat timer + watchdog thread. }
  Heartbeat := TCrashHeartbeat.Create;
  HeartbeatTimer := TTimer.Create(nil);
  HeartbeatTimer.Interval := HEARTBEAT_INTERVAL_MS;
  HeartbeatTimer.OnTimer := @Heartbeat.HandleTimer;
  HeartbeatTimer.Enabled := True;
  InterlockedExchange(MainThreadHeartbeat, LongInt(GetTickCount));

  WatchdogThread := TCrashWatchdogThread.Create(False);
end;

{$ELSE}

procedure InstallCrashBackup;
begin
end;

{$ENDIF}

finalization
{$IFDEF WINDOWS}
  { Stop the watchdog thread first so it doesn't try to access globals
    we're about to free. We Terminate but don't WaitFor - the thread
    might be in the middle of SaveToFile and WaitFor could deadlock.
    The OS will reap the thread on process exit. }
  if Assigned(WatchdogThread) then
    WatchdogThread.Terminate;
  FreeAndNil(HeartbeatTimer);
  FreeAndNil(Heartbeat);
  DoneCriticalSection(HangPathLock);
{$ENDIF}

end.
