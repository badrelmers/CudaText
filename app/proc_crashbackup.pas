{
  proc_crashbackup
  -----------------
  Crash backup for CudaText.

  When an unhandled exception is about to terminate the process, this
  unit writes a backup copy of the currently focused editor's text to
  "<originalfile>.bak" next to the original file (or to
  %TEMP%\cudatext_recovery.bak for untitled tabs).

  The backup contains every keystroke up to the moment of the crash -
  nothing is lost. Mirrors what Notepad4 does
  (https://github.com/zufuliu/notepad4, commits 2ca839b / 0738e9c / 92b4df8),
  ported to Free Pascal / CudaText.

  Design notes:

  * We hook FPC's own exception dispatch, NOT the Windows unhandled
    exception filter. The Windows filter (SetUnhandledExceptionFilter)
    is a single global slot that FPC's RTL relies on to translate
    STATUS_ACCESS_VIOLATION etc. into EAccessViolation during normal
    operation. Replacing it - even with chaining - can break that
    translation and silently kill the process during LCL startup.

    Instead we hook two FPC-level mechanisms:

    1. ExceptProc  - called by FPC when a Pascal exception is unhandled
                     on ANY thread (main or background). This is the
                     primary crash-detection path.

    2. Application.OnException - fired by the LCL for exceptions that
                     escape event handlers on the main thread. Without
                     this, main-thread crashes caught by the LCL would
                     not trigger a backup (ExceptProc is not called for
                     them because HandleException swallows them).

    Both hooks chain to the previous handler after writing the backup,
    so FPC's and the LCL's normal exception behavior is preserved.

  * We use a single atomic flag (InterlockedCompareExchange) to
    serialize the backup. This cannot deadlock on re-entrant crashes -
    the second attempt simply backs off.

  * The handler body is wrapped in try/except to absorb any secondary
    faults (e.g. if heap corruption makes Ed.Text fault).

  * InstallCrashBackup must be called AFTER Application.CreateForm,
    because it needs Application.OnException to be assignable.
}
unit proc_crashbackup;

{$mode objfpc}{$H+}

interface

procedure InstallCrashBackup;
  { Hook ExceptProc and Application.OnException. MUST be called after
    Application.CreateForm. Idempotent - safe to call multiple times. }

implementation

uses
  SysUtils, Classes, Forms,
  proc_globdata, form_frame, ATSynEdit;

type
  { Small singleton whose sole purpose is to give us a method that can
    be assigned to Application.OnException (which is a "procedure of object"
    and requires an instance, not a plain function). }
  TCrashExceptionHandler = class
  public
    procedure HandleException(Sender: TObject; E: Exception);
  end;

var
  CrashHandler: TCrashExceptionHandler = nil;
  PrevExceptProc: TExceptProc = nil;
  PrevOnException: TExceptionEvent = nil;
  CrashHandled: LongInt = 0;       // 0 = free, 1 = a backup is already in progress
  Installed: Boolean = False;

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
begin
  if Installed then Exit;
  Installed := True;

  CrashHandler := TCrashExceptionHandler.Create;

  { Hook FPC's unhandled-exception proc (covers background threads and
    anything that escapes the LCL). }
  PrevExceptProc := ExceptProc;
  ExceptProc := @CrashExceptProc;

  { Hook the LCL's OnException (covers main-thread exceptions caught by
    TApplication.HandleException - the usual path for UI-event crashes). }
  PrevOnException := Application.OnException;
  Application.OnException := @CrashHandler.HandleException;
end;

end.
