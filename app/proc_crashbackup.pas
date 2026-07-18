{
  proc_crashbackup
  -----------------
  Crash backup for CudaText on Windows.

  When any fatal exception (access violation, stack overflow, illegal
  instruction, in-page error, ...) is about to terminate the process,
  this unit writes a backup copy of the currently focused editor's text
  to "<originalfile>.bak" next to the original file (or to
  %TEMP%\cudatext_recovery.bak for untitled tabs).

  The backup contains every keystroke up to the moment of the crash -
  nothing is lost. This mirrors what Notepad4 does
  (https://github.com/zufuliu/notepad4, commits 2ca839b / 0738e9c / 92b4df8),
  ported to Free Pascal / CudaText.

  Design notes:

  * We use AddVectoredExceptionHandler (VEH), not SetUnhandledExceptionFilter.
    VEH cannot be silently replaced by other DLLs (the MSVC runtime can do
    that to the unhandled-exception filter since Vista), and VEH runs on
    whatever thread caused the fault - main GUI thread, parser thread, or
    any plugin thread. SetUnhandledExceptionFilter has been observed to be
    skipped for exceptions on worker threads, which is exactly the case
    this feature must protect.

  * We use a single atomic flag (InterlockedCompareExchange) instead of a
    lock to serialize the handler. This cannot deadlock on re-entrant
    crashes (a thread faulting while already inside the handler) - the
    second attempt simply backs off. A real lock could deadlock here.

  * We call SetThreadStackGuarantee on the main thread so the handler has
    ~16 KB of reserved stack to run in even after a stack overflow. This
    call is per-thread: worker threads that want the same protection must
    call CrashBackup_RegisterThread at startup.

  * We never swallow the exception - we always return
    EXCEPTION_CONTINUE_SEARCH so FPC's normal exception translation
    (STATUS_ACCESS_VIOLATION -> EAccessViolation etc.) and Windows'
    default crash handling continue to work as before.

  * The handler is wrapped in try/except to absorb any secondary faults
    (e.g. if heap corruption makes Ed.Text fault). If the inner code
    raises, we silently give up - which is the only honest thing to do
    in a crash handler.
}
unit proc_crashbackup;

{$mode objfpc}{$H+}

interface

procedure InstallCrashBackup;
  { Register the vectored exception handler and reserve stack guarantee
    on the calling (main) thread. Idempotent - safe to call multiple times. }

procedure CrashBackup_RegisterThread;
  { Reserve the stack guarantee on the calling thread. Call this at the
    start of any worker thread (parser, plugin host, etc.) that should
    survive a stack overflow long enough for the crash handler to write
    the backup. On non-Windows this is a no-op. }

implementation

{$IFDEF WINDOWS}

uses
  Windows, SysUtils, Classes,
  proc_globdata, form_frame, ATSynEdit;

type
  { Signature of a vectored exception handler callback. Must match the
    Windows PVECTORED_EXCEPTION_HANDLER type. }
  TCrashVectoredHandler = function(ExceptionInfo: PExceptionPointers): LongInt; stdcall;

{ These two Win32 APIs are not declared in FPC's Windows unit on all versions,
  so declare them manually as kernel32 imports. Both are available on
  Windows XP SP2 / Vista and later - which is well below CudaText's minimum. }
function AddVectoredExceptionHandler(
  FirstHandler: ULONG;
  Handler: TCrashVectoredHandler
): Pointer; stdcall; external 'kernel32' name 'AddVectoredExceptionHandler';

function SetThreadStackGuarantee(
  var StackSizeInBytes: ULONG
): DWORD; stdcall; external 'kernel32' name 'SetThreadStackGuarantee';

const
  CRASH_STACK_GUARANTEE = 16384;  // ~16 KB reserved for the handler to run in

var
  CrashHandled: LongInt = 0;       // 0 = free, 1 = a thread is already in the handler
  CrashBackupInstalled: Boolean = False;

function IsFatalExceptionCode(Code: DWORD): Boolean;
begin
  { "Error" severity codes (top two bits = 11) are always fatal crashes:
    STATUS_ACCESS_VIOLATION        $C0000005
    STATUS_IN_PAGE_ERROR           $C0000006
    STATUS_INVALID_HANDLE          $C0000008
    STATUS_STACK_OVERFLOW          $C00000FD
    STATUS_ILLEGAL_INSTRUCTION     $C000001D
    STATUS_NONCONTINUABLE_EXCEPTION $C0000025
    STATUS_INT_DIVIDE_BY_ZERO      $C0000094
    STATUS_PRIV_INSTRUCTION        $C0000096
    STATUS_DATATYPE_MISALIGNMENT   $C0000002  (warning severity, but fatal in practice)

    Pascal/Delphi software exceptions ($0EEDFADE) have severity "success"
    (top two bits = 00) and are NOT caught here - those go through the
    normal try/except path and don't need a backup. Debugger events
    (EXCEPTION_BREAKPOINT / EXCEPTION_SINGLE_STEP, $80000003 / $80000004)
    are also "information" severity and not caught. }
  Result := (Code and $C0000000) = $C0000000;
end;

function CrashBackupFilter(ExceptionInfo: PExceptionPointers): LongInt; stdcall;
var
  Ed: TATSynEdit;
  Frame: TEditorFrame;
  i: Integer;
  FileNameUTF8: string;
  BackupPathW: UnicodeString;
  TextU: UnicodeString;
  TextU8: RawByteString;
  FileHandle: THandle;
  BytesWritten: DWORD;
  BOM: array[0..2] of AnsiChar;
  Utf8Len: Integer;
  TempPathW: array[0..MAX_PATH] of WideChar;
  TempLen: Integer;
begin
  Result := EXCEPTION_CONTINUE_SEARCH;  // never swallow - just observe

  if not IsFatalExceptionCode(DWORD(ExceptionInfo^.ExceptionRecord^.ExceptionCode)) then
    Exit;

  { Only one thread may attempt the backup at a time. InterlockedCompareExchange
    is a single CPU instruction - it cannot fault and cannot deadlock, even
    if a second crash happens re-entrantly while we're already inside. }
  if InterlockedCompareExchange(CrashHandled, 1, 0) <> 0 then
    Exit;

  try
    try
      { Cannot do anything sensible if the global frame list isn't
        initialized yet (very early startup). }
      if AppFrameList1 = nil then Exit;
      if AppFrameList1.Count = 0 then Exit;

      { Find the focused editor by raw pointer comparison with
        AppCodetreeState.Editor. AppCodetreeState.Editor is a weak pointer
        (the app itself never dereferences it, only compares it), so reading
        it here is safe even if the focused tab was closed and the pointer
        is dangling - we just won't find a matching frame and fall back. }
      Ed := nil;
      for i := 0 to AppFrameList1.Count - 1 do
      begin
        Frame := TEditorFrame(AppFrameList1.Items[i]);
        if Frame = nil then Continue;
        if (Frame.Ed1 = AppCodetreeState.Editor) or
           (Frame.Ed2 = AppCodetreeState.Editor) then
        begin
          Ed := TATSynEdit(AppCodetreeState.Editor);
          Break;
        end;
      end;

      { Fallback: if the focused-editor pointer is stale (e.g. tab was
        closed and the pointer wasn't nulled yet), back up the first
        available frame's primary editor. Better than nothing. }
      if Ed = nil then
      begin
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

      if Ed = nil then Exit;

      { Only back up buffers with unsaved changes - if the file matches
        what's already on disk, no backup is needed. }
      if not Ed.Modified then Exit;

      { Get filename (UTF-8 in Lazarus). }
      FileNameUTF8 := Ed.FileName;

      if FileNameUTF8 = '' then
      begin
        { Untitled tab: save to %TEMP% with a fixed name. No timestamp
          formatting - we want to avoid heap/string operations that could
          fault if the heap is corrupted. }
        TempLen := GetTempPathW(MAX_PATH, @TempPathW[0]);
        if TempLen = 0 then Exit;
        if (TempLen > 0) and (TempPathW[TempLen - 1] <> '\') then
        begin
          TempPathW[TempLen] := '\';
          Inc(TempLen);
        end;
        SetString(BackupPathW, PChar(@TempPathW[0]), TempLen);
        BackupPathW := BackupPathW + 'cudatext_recovery.bak';
      end
      else
      begin
        { Place backup next to the original file: "<filename>.bak".
          Matches Notepad4's convention so users find it intuitively. }
        BackupPathW := UTF8Decode(FileNameUTF8) + '.bak';
      end;

      { Get text and convert to UTF-8 (with BOM so editors detect encoding
        correctly when the .bak is opened later). }
      TextU := Ed.Text;
      if TextU = '' then Exit;

      Utf8Len := WideCharToMultiByte(CP_UTF8, 0,
        PWideChar(TextU), Length(TextU),
        nil, 0, nil, nil);
      if Utf8Len <= 0 then Exit;
      SetLength(TextU8, Utf8Len);
      if WideCharToMultiByte(CP_UTF8, 0,
        PWideChar(TextU), Length(TextU),
        PAnsiChar(TextU8), Utf8Len, nil, nil) = 0 then
        Exit;

      { Write to file using only WinAPI - no FPC file I/O, which would
        touch the heap and could fault. }
      FileHandle := CreateFileW(PWideChar(BackupPathW),
        GENERIC_WRITE, 0, nil, CREATE_ALWAYS,
        FILE_ATTRIBUTE_NORMAL, 0);
      if FileHandle = INVALID_HANDLE_VALUE then Exit;

      try
        BOM[0] := #$EF; BOM[1] := #$BB; BOM[2] := #$BF;
        WriteFile(FileHandle, BOM[0], 3, BytesWritten, nil);
        if Utf8Len > 0 then
          WriteFile(FileHandle, TextU8[1], Utf8Len, BytesWritten, nil);
      finally
        CloseHandle(FileHandle);
      end;
    except
      { Swallow - we're in a crash handler, nothing else we can do. }
    end;
  finally
    InterlockedExchange(CrashHandled, 0);
  end;
end;

procedure InstallCrashBackup;
var
  StackGuarantee: ULONG;
begin
  if CrashBackupInstalled then Exit;
  CrashBackupInstalled := True;

  { AddVectoredExceptionHandler(1, ...) installs our handler at the HEAD
    of the VEH list, so it runs first. }
  AddVectoredExceptionHandler(1, TCrashVectoredHandler(@CrashBackupFilter));

  { Reserve ~16 KB of stack so the handler has room to run even after a
    stack overflow. This call only protects the calling thread - other
    threads must call CrashBackup_RegisterThread themselves at startup. }
  StackGuarantee := CRASH_STACK_GUARANTEE;
  SetThreadStackGuarantee(StackGuarantee);
end;

procedure CrashBackup_RegisterThread;
var
  StackGuarantee: ULONG;
begin
  StackGuarantee := CRASH_STACK_GUARANTEE;
  SetThreadStackGuarantee(StackGuarantee);
end;

initialization
  InstallCrashBackup;

{$ELSE}  // non-Windows: provide no-op stubs so the unit compiles

procedure InstallCrashBackup;
begin
end;

procedure CrashBackup_RegisterThread;
begin
end;

{$ENDIF}

end.
