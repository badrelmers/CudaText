{
  proc_crashbackup
  -----------------
  Crash backup for CudaText on Windows, with diagnostic logging.

  Writes a step-by-step log to %TEMP%\cudatext_crash.log so we can see
  exactly where (and whether) the hooks fire. The log uses ONLY Win32
  API calls (no FPC heap operations) so it works even when the FPC heap
  is corrupted.
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

var
  CrashHandler: TCrashExceptionHandler = nil;
  PrevExceptProc: TExceptProc = nil;
  PrevOnException: TExceptionEvent = nil;
  CrashHandled: LongInt = 0;
  Installed: Boolean = False;
  LogPath: UnicodeString = '';

{ ---------- Diagnostic logging (WinAPI only, no FPC heap) ---------- }

procedure InitLogPath;
var
  PathBuf: array[0..MAX_PATH] of WideChar;
  PathLen: Integer;
begin
  PathLen := GetTempPathW(MAX_PATH, @PathBuf[0]);
  if PathLen = 0 then Exit;
  SetString(LogPath, PChar(@PathBuf[0]), PathLen);
  LogPath := LogPath + 'cudatext_crash.log';
end;

procedure LogLine(const S: AnsiString);
var
  FileHandle: THandle;
  BytesWritten: DWORD;
  LineEnd: AnsiString;
begin
  if LogPath = '' then Exit;

  FileHandle := CreateFileW(PWideChar(LogPath),
    FILE_APPEND_DATA, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
    OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if FileHandle = INVALID_HANDLE_VALUE then Exit;

  LineEnd := #13#10;
  if Length(S) > 0 then
    WriteFile(FileHandle, S[1], Length(S), BytesWritten, nil);
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

  Ed := nil;
  LogStep('  [step] AppCodetreeState.Editor ptr = ' + IntToHex(PtrUInt(AppCodetreeState.Editor), 16));
  for i := 0 to AppFrameList1.Count - 1 do
  begin
    Frame := TEditorFrame(AppFrameList1.Items[i]);
    if Frame = nil then Continue;
    if (Frame.Ed1 = AppCodetreeState.Editor) or
       (Frame.Ed2 = AppCodetreeState.Editor) then
    begin
      Ed := TATSynEdit(AppCodetreeState.Editor);
      LogStep('  [step] Found focused editor at frame index ' + IntToStr(i));
      Break;
    end;
  end;

  if Ed = nil then
  begin
    LogStep('  [step] Focused editor not found, using fallback');
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

  LogStep('  [step] Found editor, Ed1 ptr = ' + IntToHex(PtrUInt(Ed), 16));
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

  InitLogPath;
  LogStep('=== InstallCrashBackup starting ===');
  LogStep('Log path = ' + AnsiString(LogPath));

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
  LogStep('ExceptProc hooked, prev = ' + IntToHex(PtrUInt(@PrevExceptProc), 16));

  LogStep('Hooking Application.OnException...');
  PrevOnException := Application.OnException;
  Application.OnException := @CrashHandler.HandleException;
  LogStep('OnException hooked');

  LogStep('=== InstallCrashBackup complete ===');
end;

procedure CrashBackup_RegisterThread;
begin
end;

initialization
  { Initialize the log path as early as possible so we can confirm the
    unit is being loaded at all. }
  InitLogPath;
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
