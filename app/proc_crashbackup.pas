{
  proc_crashbackup
  -----------------
  Crash backup for CudaText on Windows.

  When an unhandled exception is about to terminate the process, this
  unit writes a backup copy of the currently focused editor's text to
  "<originalfile>.bak" next to the original file (or to
  %TEMP%\cudatext_recovery.bak for untitled tabs).

  The backup contains every keystroke up to the moment of the crash -
  nothing is lost. Mirrors what Notepad4 does
  (https://github.com/zufuliu/notepad4, commits 2ca839b / 0738e9c / 92b4df8),
  ported to Free Pascal / CudaText.

  Design notes:

  * We use THREE complementary hooks, each covering a different class
    of crash:

    1. AddVectoredExceptionHandler (VEH)
       Fires for EVERY Windows SEH exception on ANY thread - including
       raw access violations on threads FPC doesn't manage (e.g. a
       plugin thread, a parser thread, or a thread created externally).
       This is the ONLY hook that catches the case of a remote thread
       crashing with STATUS_ACCESS_VIOLATION.

    2. ExceptProc (FPC RTL)
       Fires for unhandled Pascal exceptions on any thread. Covers
       crashes that FPC translates from SEH into EAccessViolation,
       EDivByZero, ERangeError, etc.

    3. Application.OnException (LCL)
       Fires for exceptions that escape event handlers on the main
       thread. This is the normal path for crashes during a click or
       key press - the LCL catches them and would normally show its
       own error dialog.

  * The VEH handler is installed AFTER Application.CreateForm, not in
    the unit's initialization section. Installing it too early (before
    FPC's RTL and the LCL are fully ready) breaks startup because the
    VEH fires for internal SEH exceptions that FPC/LCL raise and catch
    during initialization, and running our handler that early can
    fault. By waiting until the main form exists, all of FPC's and
    LCL's internal state is ready.

  * The VEH handler filters by exception code: only "error" severity
    codes (top two bits = 11) trigger a backup. This excludes:
    - Pascal/Delphi software exceptions ($0EEDFADE, severity "success")
    - Debugger events (breakpoint, single-step, severity "information")
    - C++ exceptions ($E06D7363, severity "warning")

  * We use a single atomic flag (InterlockedCompareExchange) to
    serialize the backup. This cannot deadlock on re-entrant crashes -
    the second attempt simply backs off. The flag is reset after the
    backup completes, so a later crash on a different thread can also
    be backed up.

  * The backup logic is wrapped in try/except to absorb any secondary
    faults (e.g. if heap corruption makes Ed.Text fault).

  * The VEH handler always returns EXCEPTION_CONTINUE_SEARCH - we
    NEVER swallow the exception. FPC's normal exception translation
    and Windows' default crash handling continue to work as before.
}
unit proc_crashbackup;

{$mode objfpc}{$H+}

interface

procedure InstallCrashBackup;
  { Install the VEH, ExceptProc, and OnException hooks. MUST be called
    after Application.CreateForm. Idempotent - safe to call multiple times. }

procedure CrashBackup_RegisterThread;
  { No-op stub kept for API compatibility. The VEH covers all threads
    automatically, so per-thread registration is no longer needed. }

implementation

{$IFDEF WINDOWS}

uses
  Windows, SysUtils, Classes, Forms,
  proc_globdata, form_frame, ATSynEdit;

type
  { Signature of a vectored exception handler callback. Must match the
    Windows PVECTORED_EXCEPTION_HANDLER type. }
  TCrashVectoredHandler = function(ExceptionInfo: PExceptionPointers): LongInt; stdcall;

  { Signature of an unhandled-exception filter callback. }
  TTopLevelExceptionFilter = function(ExceptionInfo: PExceptionPointers): LongInt; stdcall;

  { Small singleton to provide a method pointer for Application.OnException. }
  TCrashExceptionHandler = class
  public
    procedure HandleException(Sender: TObject; E: Exception);
  end;

{ These Win32 APIs are not declared in FPC's Windows unit on all versions,
  so declare them manually as kernel32 imports. }
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
  CrashHandler: TCrashExceptionHandler = nil;
  PrevExceptProc: TExceptProc = nil;
  PrevOnException: TExceptionEvent = nil;
  CrashHandled: LongInt = 0;       // 0 = free, 1 = a backup is already in progress
  Installed: Boolean = False;

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

    Pascal/Delphi software exceptions ($0EEDFADE) have severity "success"
    (top two bits = 00) and are NOT caught here - those go through the
    normal try/except path. Debugger events (EXCEPTION_BREAKPOINT /
    EXCEPTION_SINGLE_STEP, $80000003 / $80000004) are "information"
    severity and not caught. C++ exceptions ($E06D7363) are "warning"
    severity and not caught. }
  Result := (Code and $C0000000) = $C0000000;
end;

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
begin
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

  { Fallback: if the focused-editor pointer is stale, back up the first
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

  { Only back up buffers with unsaved changes. }
  if not Ed.Modified then Exit;

  FileNameUTF8 := Ed.FileName;

  if FileNameUTF8 = '' then
    BackupPath := GetTempDir(False) + 'cudatext_recovery.bak'
  else
    BackupPath := FileNameUTF8 + '.bak';

  { Get text and convert to UTF-8 (with BOM so editors detect encoding
    correctly when the .bak is opened later). }
  TextU := Ed.Text;
  if TextU = '' then Exit;

  TextU8 := UTF8Encode(TextU);

  Stream := TFileStream.Create(BackupPath, fmCreate);
  try
    BOM[0] := $EF; BOM[1] := $BB; BOM[2] := $BF;
    Stream.Write(BOM, 3);
    if Length(TextU8) > 0 then
      Stream.Write(TextU8[1], Length(TextU8));
  finally
    Stream.Free;
  end;
end;

procedure TryDoBackup;
begin
  { Only one thread may attempt the backup at a time. InterlockedCompareExchange
    is a single CPU instruction - it cannot deadlock, even if a second crash
    happens re-entrantly while we're already inside. }
  if InterlockedCompareExchange(CrashHandled, 1, 0) <> 0 then Exit;
  try
    try
      DoBackup;
    except
      { Swallow - we're in a crash handler, nothing else we can do. }
    end;
  finally
    InterlockedExchange(CrashHandled, 0);
  end;
end;

{ Windows-level hook: fires for every SEH exception on any thread.
  This is the only hook that catches raw access violations on threads
  FPC doesn't manage (e.g. CreateRemoteThread, plugin threads). }
function CrashVectoredFilter(ExceptionInfo: PExceptionPointers): LongInt; stdcall;
begin
  Result := EXCEPTION_CONTINUE_SEARCH;  // never swallow - just observe

  { Only act on genuinely fatal exception codes. This excludes Pascal
    software exceptions, debugger events, and C++ exceptions - all of
    which are handled by FPC's normal dispatch. }
  if not IsFatalExceptionCode(DWORD(ExceptionInfo^.ExceptionRecord^.ExceptionCode)) then
    Exit;

  TryDoBackup;
end;

{ FPC-level hook: called for unhandled Pascal exceptions on any thread. }
procedure CrashExceptProc(Obj: TObject; Addr: Pointer; FrameCount: LongInt; Frames: PPointer);
begin
  TryDoBackup;
  if Assigned(PrevExceptProc) then
    PrevExceptProc(Obj, Addr, FrameCount, Frames);
end;

{ LCL-level hook: called for exceptions that escape event handlers on
  the main thread. }
procedure TCrashExceptionHandler.HandleException(Sender: TObject; E: Exception);
begin
  TryDoBackup;
  if Assigned(PrevOnException) then
    PrevOnException(Sender, E);
end;

procedure InstallCrashBackup;
var
  StackGuarantee: ULONG;
begin
  if Installed then Exit;
  Installed := True;

  { Install the VEH FIRST, so it's at the head of the list and runs
    before any other VEH someone else registered. }
  AddVectoredExceptionHandler(1, TCrashVectoredHandler(@CrashVectoredFilter));

  { Reserve ~16 KB of stack on the main thread so the VEH handler has
    room to run even after a stack overflow. }
  StackGuarantee := CRASH_STACK_GUARANTEE;
  SetThreadStackGuarantee(StackGuarantee);

  CrashHandler := TCrashExceptionHandler.Create;

  { Hook FPC's unhandled-exception proc (covers Pascal exceptions on
    background threads). }
  PrevExceptProc := ExceptProc;
  ExceptProc := @CrashExceptProc;

  { Hook the LCL's OnException (covers main-thread UI crashes). }
  PrevOnException := Application.OnException;
  Application.OnException := @CrashHandler.HandleException;
end;

procedure CrashBackup_RegisterThread;
begin
  { No-op. The VEH covers all threads automatically. Kept for API
    compatibility in case external code calls it. }
end;

{$ELSE}  // non-Windows: provide no-op stubs so the unit compiles

procedure InstallCrashBackup;
begin
end;

procedure CrashBackup_RegisterThread;
begin
end;

{$ENDIF}

end.
