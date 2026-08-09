(*
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.

Copyright (c) 2026 CudaText project contributors

Implements the diff_proc backend for CudaText: a native Free Pascal
port of Eclipse JGit's MyersDiff (linear-space, middle-snake) and
HistogramDiff (with max_chain_length=64 and Myers fallback).

The algorithms are ports of the public JGit code
(https://github.com/eclipse-jgit/jgit, BSD-3-Clause / EDL-1.0),
re-implemented in Object Pascal. The behavior is intended to match
`git diff --myers` and `git diff --histogram` for typical inputs.

Public entry points:
  - DoDiffLines: compares two arrays of strings, returns difflib-style
    opcodes (5-tuples: tag, i1, i2, j1, j2) where tag is an integer
    enum that the caller can map to 'equal'/'delete'/'insert'/'replace'.
  - DoDiffText: same but accepts two LF-separated strings; splits them
    into lines internally.

The opcode format matches Python's difflib.SequenceMatcher.get_opcodes()
exactly so the result can be returned to Python plugins with no
adaptation layer.
*)
unit CudaDiff;

{$mode objfpc}{$H+}
{$ModeSwitch advancedrecords}

interface

const
  { Algorithm selectors for DoDiffLines / DoDiffText. }
  DIFF_ALGO_MYERS     = 0;
  DIFF_ALGO_HISTOGRAM = 1;

  { Bitmask flags for DoDiffLines / DoDiffText. Combine with 'or'. }
  DIFF_IGN_NONE                 = 0;
  DIFF_IGN_CASE                 = 1;      // case-insensitive
  DIFF_IGN_WHITESPACE           = 2;      // all whitespace ignored
  DIFF_IGN_WHITESPACE_CHANGE    = 4;      // runs equal, presence matters
  DIFF_IGN_WHITESPACE_EOL       = 8;      // trailing whitespace
  DIFF_IGN_WHITESPACE_BEGINNING = 16;     // leading whitespace
  DIFF_IGN_BLANK_LINES          = 32;     // blank lines ignored for matching
  DIFF_IGN_EOL                  = 64;     // CR/LF vs LF treated equal
  DIFF_IGN_NUMBERS              = 128;    // digit runs treated as equal

  { Opcode tag values returned in TDiffOpcode.Tag.
    These are integers internally; the Python wrapper converts them
    to the lowercase strings 'equal'/'delete'/'insert'/'replace'
    expected by difflib.SequenceMatcher.get_opcodes(). }
  DIFF_TAG_EQUAL   = 0;
  DIFF_TAG_DELETE  = 1;
  DIFF_TAG_INSERT  = 2;
  DIFF_TAG_REPLACE = 3;

type
  TStringArray = array of string;

  { A single difflib-compatible opcode.
    Tag is one of DIFF_TAG_*; (I1, I2) is a half-open range into the
    first sequence and (J1, J2) into the second. Adjacent opcodes
    share boundaries; the first starts at (0, 0); the last ends at
    (Len(A), Len(B)). }
  TDiffOpcode = record
    Tag: Integer;
    I1, I2, J1, J2: Integer;
  end;
  TDiffOpcodeArray = array of TDiffOpcode;

  { Cancellation callback. Return True to abort the diff.
    UserData is passed through unchanged from the caller. }
  TDiffCancelFunc = function(AUserData: Pointer): Boolean;

{ Compare two line arrays and return difflib-compatible opcodes.
  If ACancelled is True on return, the result is empty and meaningless.
  ACancelFunc is invoked periodically (every ~4K inner-loop iterations
  and at every recursion level) to keep the UI responsive on huge files. }
function DoDiffLines(
  const ALinesA, ALinesB: array of string;
  AAlgo: Integer;
  AFlags: Integer;
  ACancelFunc: TDiffCancelFunc;
  ACancelData: Pointer;
  out ACancelled: Boolean
): TDiffOpcodeArray;

{ Compare two LF-separated text blocks. Splits each text on #10 and
  keeps the line terminators attached (matches difflib keepends=True
  behavior). The last line keeps its terminator if present; if absent,
  it's still emitted as a separate line. }
function DoDiffText(
  const ATextA, ATextB: string;
  AAlgo: Integer;
  AFlags: Integer;
  ACancelFunc: TDiffCancelFunc;
  ACancelData: Pointer;
  out ACancelled: Boolean
): TDiffOpcodeArray;

{ Compare two strings at character granularity. Returns char-level
  opcodes (tag, a_start, a_end, b_start, b_end) where offsets are
  character positions into ATextA / ATextB. Same difflib format as
  DoDiffLines, just at character instead of line granularity.

  Internally uses the WinMerge approach: tokenize both strings into
  words (identifiers, whitespace, individual punctuation), run word-
  level Myers diff, then refine each non-equal word region to exact
  byte boundaries with prefix/suffix trimming. This is dramatically
  faster than running Myers directly on characters for long lines
  (words are more unique than characters, so O(ND) is much smaller).

  AAlgo is ignored for DIF_CHARS — char diff always uses word-Myers +
  byte-trim. AFlags supports the same DIFF_IGN_* options as line diff. }
function DoDiffChars(
  const ATextA, ATextB: string;
  AFlags: Integer;
  ACancelFunc: TDiffCancelFunc;
  ACancelData: Pointer;
  out ACancelled: Boolean
): TDiffOpcodeArray;

{ Split a string on #10 keeping the terminator attached. Useful for
  callers who want to pre-split text once and reuse the line array
  across multiple DoDiffLines calls. }
function SplitLinesKeepEnds(const AText: string): TStringArray;

implementation

uses
  SysUtils;

const
  { Histogram chain-length cutoff. Matches JGit's default and Git's
    xhistogram.c index->max_chain_length = 64. When a hash bucket in
    sequence A exceeds this many distinct elements, the histogram
    algorithm gives up on the region and falls back to Myers. }
  HISTOGRAM_MAX_CHAIN_LENGTH = 64;

  { Bit-packing constants for histogram records (mirrors JGit's
    HistogramDiffIndex.java). Fields are packed into an Int64:
      bits 36..63 : index of next record in same hash chain (REC_NEXT)
      bits  8..35 : first element index in A (REC_PTR, 28 bits)
      bits  0..7  : occurrence count, capped at 255 (REC_CNT)
    The 28-bit pointer limits sequences to 2^28 - 1 = 268,435,455
    elements, same as JGit. }
  REC_NEXT_SHIFT = 36;
  REC_PTR_SHIFT  = 8;
  REC_PTR_MASK   = (1 shl 28) - 1;
  REC_CNT_MASK   = (1 shl 8) - 1;
  MAX_PTR        = REC_PTR_MASK;
  MAX_CNT        = (1 shl 8) - 1;

  { Knuth's multiplicative hash constant, used to mix hash bits before
    taking the table index (same value JGit uses: 0x9e370001).
    Typed as Cardinal to ensure 32-bit unsigned multiplication. }
  HASH_MIX_CONSTANT: Cardinal = $9e370001;

  { Initial djb2 hash seed. Same as JGit's RawTextComparator. }
  DJB2_SEED = 5381;

type
  TDiffEditType = (detInsert, detDelete, detReplace, detEmpty);

  { A modified region between two sequences. Mirrors JGit's Edit class.
    All indices are 0-based, half-open [begin, end). Mutable by design
    (the algorithms adjust begin/end in place during prefix/suffix trim
    and edit normalization). }
  TDiffEdit = record
    BeginA, EndA, BeginB, EndB: Integer;
    function GetType: TDiffEditType;
    function IsEmpty: Boolean;
    function LengthA: Integer;
    function LengthB: Integer;
    procedure Shift(AAmount: Integer);
    class function Create(AAs, AAe, ABs, ABe: Integer): TDiffEdit; static;
    function Before(const ACut: TDiffEdit): TDiffEdit;
    function After(const ACut: TDiffEdit): TDiffEdit;
  end;

  { Growable dynamic array of TDiffEdit. Append is amortized O(1). }
  TDiffEditList = record
    FItems: array of TDiffEdit;
    FCount: Integer;
    procedure Init;
    procedure Add(const AEdit: TDiffEdit);
    function GetItem(AIndex: Integer): TDiffEdit;
    procedure SetItem(AIndex: Integer; const AEdit: TDiffEdit);
    function Count: Integer;
    property Items[AIndex: Integer]: TDiffEdit read GetItem write SetItem;
  end;

  PLineSequence = ^TLineSequence;

  { Wraps an array of lines together with their pre-computed hashes and
    (optionally) normalized copies used for ignore-flag matching.
    When AFlags = 0, FNormalized is empty and hashing/equality use the
    original lines directly (saves memory in the common case). }
  TLineSequence = record
    FLines: TStringArray;
    FNormalized: TStringArray;  // empty if no ignore flags
    FHashes: array of Integer;
    FHasNormalization: Boolean;
    procedure Init(const ALines: array of string; AFlags: Integer);
    function EqualsAt(AIdxThis: Integer; const AOther: TLineSequence; AIdxOther: Integer): Boolean;
    function HashAt(AIdx: Integer): Integer;
    function Size: Integer;
  end;

  { Scratch state for MyersDiff, reused across recursion levels to
    avoid repeated heap allocation. }
  TMyersState = record
    SeqA, SeqB: PLineSequence;
    CancelFunc: TDiffCancelFunc;
    CancelData: Pointer;
    Cancelled: Pointer;        // ^Boolean

    FwdX: array of Integer;
    FwdSnake: array of Int64;
    BwdX: array of Integer;
    BwdSnake: array of Int64;
    OffsetK: Integer;

    BeginA, EndA, BeginB, EndB: Integer;
    MinK, MaxK: Integer;
    FwdMiddleK, BwdMiddleK: Integer;
    FwdBeginK, FwdEndK: Integer;
    BwdBeginK, BwdEndK: Integer;

    MiddleEdit: TDiffEdit;
  end;

  { HistogramDiff per-region scratch. }
  THistogramIndex = record
    FMaxChainLength: Integer;
    FSeqA, FSeqB: PLineSequence;
    FRegion: TDiffEdit;
    FTable: array of Integer;
    FKeyShift: Integer;
    FRecs: array of Int64;
    FRecCnt: Integer;
    FNext: array of Integer;
    FRecIdx: array of Integer;
    FPtrShift: Integer;
    FLcs: TDiffEdit;
    FCnt: Integer;
    FHasCommon: Boolean;
    FFallback: Boolean;        // True if scanA exceeded chain length or LCS search exhausted

    procedure Init(AMaxChainLength: Integer; ASeqA, ASeqB: PLineSequence; ARegion: TDiffEdit);
    function FindLongestCommonSequence: TDiffEdit;
    function ScanA: Boolean;
    function TryLongestCommonSequence(ABPtr: Integer): Integer;
    function HashSeq(ASeq: PLineSequence; AIdx: Integer): Integer;
    class function RecCreate(ANext, APtr, ACnt: Integer): Int64; static;
    class function RecNext(ARec: Int64): Integer; static;
    class function RecPtr(ARec: Int64): Integer; static;
    class function RecCnt(ARec: Int64): Integer; static;
    class function TableBits(ASz: Integer): Integer; static;
  end;

{ ---------- Utility functions ---------- }

function MaxI(A, B: Integer): Integer; inline;
begin
  if A > B then Result := A else Result := B;
end;

function MinI(A, B: Integer): Integer; inline;
begin
  if A < B then Result := A else Result := B;
end;

function IsWhitespaceByte(C: AnsiChar): Boolean; inline;
begin
  Result := (C = ' ') or (C = #9) or (C = #10) or (C = #13);
end;

function IsCancelled(ACancelFunc: TDiffCancelFunc; ACancelData: Pointer): Boolean; inline;
begin
  if Assigned(ACancelFunc) then
    Result := ACancelFunc(ACancelData)
  else
    Result := False;
end;

function PackSnake(AX, AY: Integer): Int64; inline;
begin
  Result := (Int64(AX) shl 32) or Int64(Cardinal(AY));
end;

function SnakeX(ASnake: Int64): Integer; inline;
begin
  Result := Int64(ASnake) shr 32;
end;

function SnakeY(ASnake: Int64): Integer; inline;
begin
  Result := Integer(Cardinal(Int64(ASnake) and $FFFFFFFF));
end;

function VIndex(AOffsetK, AK: Integer): Integer; inline;
begin
  Result := AK + AOffsetK;
end;

{ ---------- TDiffEdit ---------- }

function TDiffEdit.GetType: TDiffEditType;
begin
  if BeginA < EndA then
  begin
    if BeginB < EndB then
      Exit(detReplace);
    Exit(detDelete);
  end;
  if BeginB < EndB then
    Exit(detInsert);
  Result := detEmpty;
end;

function TDiffEdit.IsEmpty: Boolean;
begin
  Result := (BeginA = EndA) and (BeginB = EndB);
end;

function TDiffEdit.LengthA: Integer;
begin
  Result := EndA - BeginA;
end;

function TDiffEdit.LengthB: Integer;
begin
  Result := EndB - BeginB;
end;

procedure TDiffEdit.Shift(AAmount: Integer);
begin
  Inc(BeginA, AAmount);
  Inc(EndA, AAmount);
  Inc(BeginB, AAmount);
  Inc(EndB, AAmount);
end;

class function TDiffEdit.Create(AAs, AAe, ABs, ABe: Integer): TDiffEdit;
begin
  Result.BeginA := AAs;
  Result.EndA := AAe;
  Result.BeginB := ABs;
  Result.EndB := ABe;
end;

function TDiffEdit.Before(const ACut: TDiffEdit): TDiffEdit;
begin
  Result := TDiffEdit.Create(BeginA, ACut.BeginA, BeginB, ACut.BeginB);
end;

function TDiffEdit.After(const ACut: TDiffEdit): TDiffEdit;
begin
  Result := TDiffEdit.Create(ACut.EndA, EndA, ACut.EndB, EndB);
end;

{ ---------- TDiffEditList ---------- }

procedure TDiffEditList.Init;
begin
  FItems := nil;
  FCount := 0;
end;

procedure TDiffEditList.Add(const AEdit: TDiffEdit);
var
  NewCap, I: Integer;
  NewItems: array of TDiffEdit;
begin
  if FCount = Length(FItems) then
  begin
    if Length(FItems) = 0 then
      NewCap := 16
    else
      NewCap := Length(FItems) * 2;
    SetLength(NewItems, NewCap);
    for I := 0 to FCount - 1 do
      NewItems[I] := FItems[I];
    FItems := NewItems;
  end;
  FItems[FCount] := AEdit;
  Inc(FCount);
end;

function TDiffEditList.GetItem(AIndex: Integer): TDiffEdit;
begin
  Result := FItems[AIndex];
end;

procedure TDiffEditList.SetItem(AIndex: Integer; const AEdit: TDiffEdit);
begin
  FItems[AIndex] := AEdit;
end;

function TDiffEditList.Count: Integer;
begin
  Result := FCount;
end;

{ ---------- Line normalization ---------- }

{ Apply ignore-flag normalization to a single line.
  Returns the normalized form used for both hashing and equality.
  If AFlags = 0, returns the original line unchanged (caller skips
  normalization entirely in that case). }
function NormalizeLine(const ALine: string; AFlags: Integer): string;
var
  InStr, OutStr: AnsiString;
  I, Len: Integer;
  C: AnsiChar;
  LastWasWS, SawNonWS: Boolean;
begin
  if AFlags = 0 then
    Exit(ALine);

  InStr := AnsiString(ALine);
  Len := Length(InStr);

  // DIFF_IGN_EOL: strip any combination of trailing CR/LF.
  if (AFlags and DIFF_IGN_EOL) <> 0 then
    while (Len > 0) and ((InStr[Len] = #10) or (InStr[Len] = #13)) do
      Dec(Len);

  // DIFF_IGN_WHITESPACE_EOL: strip trailing whitespace.
  if (AFlags and DIFF_IGN_WHITESPACE_EOL) <> 0 then
    while (Len > 0) and IsWhitespaceByte(InStr[Len]) do
      Dec(Len);

  // Start index for output scan (after optional leading-whitespace strip).
  I := 1;
  if (AFlags and DIFF_IGN_WHITESPACE_BEGINNING) <> 0 then
    while (I <= Len) and IsWhitespaceByte(InStr[I]) do
      Inc(I);

  OutStr := '';
  LastWasWS := False;
  SawNonWS := False;

  if (AFlags and DIFF_IGN_WHITESPACE) <> 0 then
  begin
    // Drop all whitespace entirely.
    while I <= Len do
    begin
      C := InStr[I];
      if not IsWhitespaceByte(C) then
      begin
        OutStr := OutStr + C;
        SawNonWS := True;
      end;
      Inc(I);
    end;
  end
  else if (AFlags and DIFF_IGN_WHITESPACE_CHANGE) <> 0 then
  begin
    // Collapse runs of whitespace to a single space.
    while I <= Len do
    begin
      C := InStr[I];
      if IsWhitespaceByte(C) then
      begin
        if not LastWasWS then
        begin
          OutStr := OutStr + ' ';
          LastWasWS := True;
        end;
      end
      else
      begin
        OutStr := OutStr + C;
        LastWasWS := False;
        SawNonWS := True;
      end;
      Inc(I);
    end;
    // Trim the trailing single space if added.
    if (Length(OutStr) > 0) and (OutStr[Length(OutStr)] = ' ') then
      SetLength(OutStr, Length(OutStr) - 1);
  end
  else
  begin
    // Copy remaining bytes verbatim.
    while I <= Len do
    begin
      OutStr := OutStr + InStr[I];
      Inc(I);
    end;
    SawNonWS := Length(OutStr) > 0;
  end;

  // DIFF_IGN_BLANK_LINES: blank lines normalize to empty string.
  if (AFlags and DIFF_IGN_BLANK_LINES) <> 0 then
    if not SawNonWS then
      OutStr := '';

  // DIFF_IGN_CASE: ASCII lowercase (sufficient for typical diff use).
  if (AFlags and DIFF_IGN_CASE) <> 0 then
    OutStr := AnsiLowerCase(OutStr);

  // DIFF_IGN_NUMBERS: replace each digit run with a single '0' so
  // "v1.2.3" matches "v1.2.4" but not "v1.20.3". Useful for logs
  // with timestamps / counters that change between versions.
  if (AFlags and DIFF_IGN_NUMBERS) <> 0 then
  begin
    InStr := OutStr;
    OutStr := '';
    I := 1;
    Len := Length(InStr);
    while I <= Len do
    begin
      if (InStr[I] >= '0') and (InStr[I] <= '9') then
      begin
        OutStr := OutStr + '0';
        while (I <= Len) and (InStr[I] >= '0') and (InStr[I] <= '9') do
          Inc(I);
      end
      else
      begin
        OutStr := OutStr + InStr[I];
        Inc(I);
      end;
    end;
  end;

  Result := string(OutStr);
end;

{ djb2 hash of a line's bytes. Matches JGit's RawTextComparator.hashRegion. }
function HashLine(const ALine: string): Integer;
var
  S: AnsiString;
  I, Len: Integer;
  H: Integer;
begin
  S := AnsiString(ALine);
  Len := Length(S);
  H := DJB2_SEED;
  for I := 1 to Len do
    H := ((H shl 5) + H) + Ord(S[I]);
  Result := H;
end;

{ ---------- TLineSequence ---------- }

procedure TLineSequence.Init(const ALines: array of string; AFlags: Integer);
var
  I, N: Integer;
begin
  N := Length(ALines);
  SetLength(FLines, N);
  FHasNormalization := (AFlags <> 0);
  if FHasNormalization then
    SetLength(FNormalized, N)
  else
    FNormalized := nil;
  SetLength(FHashes, N);
  for I := 0 to N - 1 do
  begin
    FLines[I] := ALines[I];
    if FHasNormalization then
    begin
      FNormalized[I] := NormalizeLine(ALines[I], AFlags);
      FHashes[I] := HashLine(FNormalized[I]);
    end
    else
      FHashes[I] := HashLine(ALines[I]);
  end;
end;

function TLineSequence.EqualsAt(AIdxThis: Integer;
  const AOther: TLineSequence; AIdxOther: Integer): Boolean;
begin
  // CRITICAL: hash check FIRST (fast integer compare), then string equality
  // to verify the match. A hash collision without this check produces a
  // silently wrong diff which is nearly impossible to debug later.
  if FHashes[AIdxThis] <> AOther.FHashes[AIdxOther] then
    Exit(False);
  if FHasNormalization then
    Exit(FNormalized[AIdxThis] = AOther.FNormalized[AIdxOther]);
  Exit(FLines[AIdxThis] = AOther.FLines[AIdxOther]);
end;

function TLineSequence.HashAt(AIdx: Integer): Integer;
begin
  Result := FHashes[AIdx];
end;

function TLineSequence.Size: Integer;
begin
  Result := Length(FLines);
end;

{ ---------- Forward declarations for diff algorithms ---------- }

function MyersDiffNonCommon(
  out AEdits: TDiffEditList;
  const ASeqA, ASeqB: TLineSequence;
  ARegion: TDiffEdit;
  ACancelFunc: TDiffCancelFunc;
  ACancelData: Pointer;
  var ACancelled: Boolean
): Boolean; forward;

function HistogramDiffNonCommon(
  out AEdits: TDiffEditList;
  const ASeqA, ASeqB: TLineSequence;
  ARegion: TDiffEdit;
  ACancelFunc: TDiffCancelFunc;
  ACancelData: Pointer;
  var ACancelled: Boolean
): Boolean; forward;

function ReduceCommonStartEnd(
  const ASeqA, ASeqB: TLineSequence;
  AEdit: TDiffEdit
): TDiffEdit; forward;

procedure NormalizeEdits(var AEdits: TDiffEditList;
  const ASeqA, ASeqB: TLineSequence); forward;

function EditsToOpcodes(const AEdits: TDiffEditList;
  ALenA, ALenB: Integer): TDiffOpcodeArray; forward;

{ ---------- MyersDiff (linear-space, middle snake) ---------- }
{
  Port of JGit's MyersDiff.java. The algorithm computes the shortest
  edit script by simultaneously extending forward D-paths from the
  top-left and backward D-paths from the bottom-right until the two
  fronts meet on a middle snake. Recursion on the two halves gives
  the full edit list with O(N) space (vs O(N*D) for naive Myers).
}

function ForwardSnake(const AState: TMyersState; AK, AX: Integer): Integer; inline;
var
  X, Y: Integer;
  SeqA, SeqB: PLineSequence;
begin
  SeqA := AState.SeqA;
  SeqB := AState.SeqB;
  X := AX;
  Y := AK + X;
  while (X < AState.EndA) and (Y < AState.EndB) and
        SeqA^.EqualsAt(X, SeqB^, Y) do
  begin
    Inc(X);
    Inc(Y);
  end;
  Result := X;
end;

function BackwardSnake(const AState: TMyersState; AK, AX: Integer): Integer; inline;
var
  X, Y: Integer;
  SeqA, SeqB: PLineSequence;
begin
  SeqA := AState.SeqA;
  SeqB := AState.SeqB;
  X := AX;
  Y := AK + X;
  while (X > AState.BeginA) and (Y > AState.BeginB) and
        SeqA^.EqualsAt(X - 1, SeqB^, Y - 1) do
  begin
    Dec(X);
    Dec(Y);
  end;
  Result := X;
end;

function ForceKIntoRange(AK, AMinK, AMaxK: Integer): Integer; inline;
begin
  if AK < AMinK then
    Exit(AMinK + ((AK xor AMinK) and 1))
  else if AK > AMaxK then
    Exit(AMaxK - ((AK xor AMaxK) and 1));
  Result := AK;
end;

{ Forward EditPaths: extend forward D-paths by one step.
  Returns True if the forward and backward fronts meet (middle snake found). }
function ForwardCalculate(var AState: TMyersState; AD: Integer): Boolean;
var
  K, I, Left, Right, NewX: Integer;
  LeftEnd, RightEnd: Integer;
  LeftSnake, RightSnake, NewSnake: Int64;
  PrevBeginK, PrevEndK: Integer;
begin
  Result := False;
  PrevBeginK := AState.FwdBeginK;
  PrevEndK := AState.FwdEndK;
  AState.FwdBeginK := ForceKIntoRange(AState.FwdMiddleK - AD, AState.MinK, AState.MaxK);
  AState.FwdEndK := ForceKIntoRange(AState.FwdMiddleK + AD, AState.MinK, AState.MaxK);

  K := AState.FwdEndK;
  while K >= AState.FwdBeginK do
  begin
    Left := -1;
    Right := -1;
    LeftSnake := -1;
    RightSnake := -1;

    if K > PrevBeginK then
    begin
      I := VIndex(AState.OffsetK, K - 1);
      Left := AState.FwdX[I];
      LeftEnd := ForwardSnake(AState, K - 1, Left);
      if Left <> LeftEnd then
        LeftSnake := PackSnake(LeftEnd, (K - 1) + LeftEnd)
      else
        LeftSnake := AState.FwdSnake[I];
      if (K - 1 >= AState.BwdBeginK) and (K - 1 <= AState.BwdEndK) and
         (((AD - 1 + (K - 1) - AState.BwdMiddleK) mod 2) = 0) and
         (LeftEnd >= AState.BwdX[VIndex(AState.OffsetK, K - 1)]) then
      begin
        AState.MiddleEdit := TDiffEdit.Create(
          SnakeX(LeftSnake), SnakeX(AState.BwdSnake[VIndex(AState.OffsetK, K - 1)]),
          SnakeY(LeftSnake), SnakeY(AState.BwdSnake[VIndex(AState.OffsetK, K - 1)])
        );
        Exit(True);
      end;
      Left := LeftEnd;
    end;

    if K < PrevEndK then
    begin
      I := VIndex(AState.OffsetK, K + 1);
      Right := AState.FwdX[I];
      RightEnd := ForwardSnake(AState, K + 1, Right);
      if Right <> RightEnd then
        RightSnake := PackSnake(RightEnd, (K + 1) + RightEnd)
      else
        RightSnake := AState.FwdSnake[I];
      if (K + 1 >= AState.BwdBeginK) and (K + 1 <= AState.BwdEndK) and
         (((AD - 1 + (K + 1) - AState.BwdMiddleK) mod 2) = 0) and
         (RightEnd >= AState.BwdX[VIndex(AState.OffsetK, K + 1)]) then
      begin
        AState.MiddleEdit := TDiffEdit.Create(
          SnakeX(RightSnake), SnakeX(AState.BwdSnake[VIndex(AState.OffsetK, K + 1)]),
          SnakeY(RightSnake), SnakeY(AState.BwdSnake[VIndex(AState.OffsetK, K + 1)])
        );
        Exit(True);
      end;
      Right := RightEnd + 1;
    end;

    if (K >= PrevEndK) or ((K > PrevBeginK) and (Left > Right)) then
    begin
      NewX := Left;
      NewSnake := LeftSnake;
    end
    else
    begin
      NewX := Right;
      NewSnake := RightSnake;
    end;

    if (K >= AState.BwdBeginK) and (K <= AState.BwdEndK) and
       (((AD + K - AState.BwdMiddleK) mod 2) = 0) and
       (NewX >= AState.BwdX[VIndex(AState.OffsetK, K)]) then
    begin
      AState.MiddleEdit := TDiffEdit.Create(
        SnakeX(NewSnake), SnakeX(AState.BwdSnake[VIndex(AState.OffsetK, K)]),
        SnakeY(NewSnake), SnakeY(AState.BwdSnake[VIndex(AState.OffsetK, K)])
      );
      Exit(True);
    end;

    if (NewX >= AState.EndA) or ((K + NewX) >= AState.EndB) then
    begin
      if K > AState.BwdMiddleK then
        AState.MaxK := K
      else
        AState.MinK := K;
    end;

    AState.FwdX[VIndex(AState.OffsetK, K)] := NewX;
    AState.FwdSnake[VIndex(AState.OffsetK, K)] := NewSnake;

    Dec(K, 2);
  end;
end;

{ Backward EditPaths: extend backward D-paths by one step.
  Returns True if the forward and backward fronts meet (middle snake found). }
function BackwardCalculate(var AState: TMyersState; AD: Integer): Boolean;
var
  K, I, Left, Right, NewX: Integer;
  LeftEnd, RightEnd: Integer;
  LeftSnake, RightSnake, NewSnake: Int64;
  PrevBeginK, PrevEndK: Integer;
begin
  Result := False;
  PrevBeginK := AState.BwdBeginK;
  PrevEndK := AState.BwdEndK;
  AState.BwdBeginK := ForceKIntoRange(AState.BwdMiddleK - AD, AState.MinK, AState.MaxK);
  AState.BwdEndK := ForceKIntoRange(AState.BwdMiddleK + AD, AState.MinK, AState.MaxK);

  K := AState.BwdEndK;
  while K >= AState.BwdBeginK do
  begin
    Left := -1;
    Right := -1;
    LeftSnake := -1;
    RightSnake := -1;

    if K > PrevBeginK then
    begin
      I := VIndex(AState.OffsetK, K - 1);
      Left := AState.BwdX[I];
      LeftEnd := BackwardSnake(AState, K - 1, Left);
      if Left <> LeftEnd then
        LeftSnake := PackSnake(LeftEnd, (K - 1) + LeftEnd)
      else
        LeftSnake := AState.BwdSnake[I];
      if (K - 1 >= AState.FwdBeginK) and (K - 1 <= AState.FwdEndK) and
         (((AD + (K - 1) - AState.FwdMiddleK) mod 2) = 0) and
         (LeftEnd <= AState.FwdX[VIndex(AState.OffsetK, K - 1)]) then
      begin
        AState.MiddleEdit := TDiffEdit.Create(
          SnakeX(AState.FwdSnake[VIndex(AState.OffsetK, K - 1)]), SnakeX(LeftSnake),
          SnakeY(AState.FwdSnake[VIndex(AState.OffsetK, K - 1)]), SnakeY(LeftSnake)
        );
        Exit(True);
      end;
      Left := LeftEnd - 1;
    end;

    if K < PrevEndK then
    begin
      I := VIndex(AState.OffsetK, K + 1);
      Right := AState.BwdX[I];
      RightEnd := BackwardSnake(AState, K + 1, Right);
      if Right <> RightEnd then
        RightSnake := PackSnake(RightEnd, (K + 1) + RightEnd)
      else
        RightSnake := AState.BwdSnake[I];
      if (K + 1 >= AState.FwdBeginK) and (K + 1 <= AState.FwdEndK) and
         (((AD + (K + 1) - AState.FwdMiddleK) mod 2) = 0) and
         (RightEnd <= AState.FwdX[VIndex(AState.OffsetK, K + 1)]) then
      begin
        AState.MiddleEdit := TDiffEdit.Create(
          SnakeX(AState.FwdSnake[VIndex(AState.OffsetK, K + 1)]), SnakeX(RightSnake),
          SnakeY(AState.FwdSnake[VIndex(AState.OffsetK, K + 1)]), SnakeY(RightSnake)
        );
        Exit(True);
      end;
      Right := RightEnd;
    end;

    if (K >= PrevEndK) or ((K > PrevBeginK) and (Left < Right)) then
    begin
      NewX := Left;
      NewSnake := LeftSnake;
    end
    else
    begin
      NewX := Right;
      NewSnake := RightSnake;
    end;

    if (K >= AState.FwdBeginK) and (K <= AState.FwdEndK) and
       (((AD + K - AState.FwdMiddleK) mod 2) = 0) and
       (NewX <= AState.FwdX[VIndex(AState.OffsetK, K)]) then
    begin
      AState.MiddleEdit := TDiffEdit.Create(
        SnakeX(AState.FwdSnake[VIndex(AState.OffsetK, K)]), SnakeX(NewSnake),
        SnakeY(AState.FwdSnake[VIndex(AState.OffsetK, K)]), SnakeY(NewSnake)
      );
      Exit(True);
    end;

    if (NewX <= AState.BeginA) or ((K + NewX) <= AState.BeginB) then
    begin
      if K > AState.FwdMiddleK then
        AState.MaxK := K
      else
        AState.MinK := K;
    end;

    AState.BwdX[VIndex(AState.OffsetK, K)] := NewX;
    AState.BwdSnake[VIndex(AState.OffsetK, K)] := NewSnake;

    Dec(K, 2);
  end;
end;

function MyersDiffNonCommon(
  out AEdits: TDiffEditList;
  const ASeqA, ASeqB: TLineSequence;
  ARegion: TDiffEdit;
  ACancelFunc: TDiffCancelFunc;
  ACancelData: Pointer;
  var ACancelled: Boolean
): Boolean;
var
  State: TMyersState;
  MaxSize: Integer;

  procedure CalculateEdits(ABeginA, AEndA, ABeginB, AEndB: Integer);
  var
    Edit: TDiffEdit;
    K, X, D: Integer;
    Found: Boolean;
  begin
    if ACancelled then Exit;
    if IsCancelled(ACancelFunc, ACancelData) then
    begin
      ACancelled := True;
      Exit;
    end;

    if (ABeginA >= AEndA) or (ABeginB >= AEndB) then
    begin
      if (ABeginA < AEndA) or (ABeginB < AEndB) then
        AEdits.Add(TDiffEdit.Create(ABeginA, AEndA, ABeginB, AEndB));
      Exit;
    end;

    State.BeginA := ABeginA;
    State.EndA := AEndA;
    State.BeginB := ABeginB;
    State.EndB := AEndB;

    K := ABeginB - ABeginA;
    X := ForwardSnake(State, K, ABeginA);
    State.BeginA := X;
    State.BeginB := K + X;

    K := AEndB - AEndA;
    X := BackwardSnake(State, K, AEndA);
    State.EndA := X;
    State.EndB := K + X;

    if (State.BeginA >= State.EndA) and (State.BeginB >= State.EndB) then
      Exit;

    State.MinK := State.BeginB - State.EndA;
    State.MaxK := State.EndB - State.BeginA;
    State.FwdMiddleK := State.BeginB - State.BeginA;
    State.BwdMiddleK := State.EndB - State.EndA;
    State.FwdBeginK := State.FwdMiddleK;
    State.FwdEndK := State.FwdMiddleK;
    State.BwdBeginK := State.BwdMiddleK;
    State.BwdEndK := State.BwdMiddleK;

    State.FwdX[VIndex(State.OffsetK, State.FwdMiddleK)] := State.BeginA;
    State.FwdSnake[VIndex(State.OffsetK, State.FwdMiddleK)] :=
      PackSnake(State.BeginA, State.FwdMiddleK + State.BeginA);
    State.BwdX[VIndex(State.OffsetK, State.BwdMiddleK)] := State.EndA;
    State.BwdSnake[VIndex(State.OffsetK, State.BwdMiddleK)] :=
      PackSnake(State.EndA, State.BwdMiddleK + State.EndA);

    Edit := TDiffEdit.Create(0, 0, 0, 0);
    Found := False;
    D := 1;
    while (D < High(Integer)) and not Found do
    begin
      if (D and $3FF) = 0 then
        if IsCancelled(ACancelFunc, ACancelData) then
        begin
          ACancelled := True;
          Exit;
        end;
      if ForwardCalculate(State, D) or BackwardCalculate(State, D) then
      begin
        Edit := State.MiddleEdit;
        Found := True;
      end
      else
        Inc(D);
    end;

    if not Found then
      Exit; // safety; shouldn't happen

    if (ABeginA < Edit.BeginA) or (ABeginB < Edit.BeginB) then
    begin
      K := Edit.BeginB - Edit.BeginA;
      X := BackwardSnake(State, K, Edit.BeginA);
      CalculateEdits(ABeginA, X, ABeginB, K + X);
    end;

    if not Edit.IsEmpty then
      AEdits.Add(Edit);

    if (AEndA > Edit.EndA) or (AEndB > Edit.EndB) then
    begin
      K := Edit.EndB - Edit.EndA;
      X := ForwardSnake(State, K, Edit.EndA);
      CalculateEdits(X, AEndA, K + X, AEndB);
    end;
  end;

begin
  Result := True;
  ACancelled := False;
  AEdits.Init;

  State.SeqA := @ASeqA;
  State.SeqB := @ASeqB;
  State.CancelFunc := ACancelFunc;
  State.CancelData := ACancelData;
  State.Cancelled := @ACancelled;

  MaxSize := ARegion.LengthA + ARegion.LengthB;
  if MaxSize = 0 then
    Exit;
  State.OffsetK := MaxSize;
  SetLength(State.FwdX, 2 * MaxSize + 1);
  SetLength(State.FwdSnake, 2 * MaxSize + 1);
  SetLength(State.BwdX, 2 * MaxSize + 1);
  SetLength(State.BwdSnake, 2 * MaxSize + 1);

  CalculateEdits(ARegion.BeginA, ARegion.EndA, ARegion.BeginB, ARegion.EndB);
end;

{ ---------- HistogramDiff ---------- }
{
  Port of JGit's HistogramDiff.java + HistogramDiffIndex.java.
  Builds an occurrence-count histogram of A's elements, then walks B
  looking for the longest common subsequence with the lowest occurrence
  count. When a hash bucket exceeds max_chain_length distinct elements,
  gives up on the region and falls back to Myers.
}

procedure THistogramIndex.Init(AMaxChainLength: Integer; ASeqA, ASeqB: PLineSequence; ARegion: TDiffEdit);
var
  Sz, Bits: Integer;
begin
  FMaxChainLength := AMaxChainLength;
  FSeqA := ASeqA;
  FSeqB := ASeqB;
  FRegion := ARegion;
  if ARegion.EndA >= MAX_PTR then
    raise EArgumentException.Create('Sequence too large for diff algorithm');
  Sz := ARegion.LengthA;
  Bits := TableBits(Sz);
  SetLength(FTable, 1 shl Bits);
  FKeyShift := 32 - Bits;
  FPtrShift := ARegion.BeginA;
  if Sz > 0 then
  begin
    SetLength(FRecs, MaxI(4, Sz shr 3));
    SetLength(FNext, Sz);
    SetLength(FRecIdx, Sz);
  end
  else
  begin
    SetLength(FRecs, 4);
    FNext := nil;
    FRecIdx := nil;
  end;
  FRecCnt := 0;
  FLcs := TDiffEdit.Create(0, 0, 0, 0);
  FCnt := FMaxChainLength + 1;
  FHasCommon := False;
  FFallback := False;
end;

function THistogramIndex.HashSeq(ASeq: PLineSequence; AIdx: Integer): Integer;
var
  RawHash: Integer;
  Mixed: Cardinal;
begin
  RawHash := ASeq^.HashAt(AIdx);
  // Force 32-bit wraparound: assign to Cardinal variable first, which
  // truncates the product to 32 bits before the right-shift.
  Mixed := Cardinal(RawHash) * HASH_MIX_CONSTANT;
  Result := Integer(Mixed shr FKeyShift);
end;

class function THistogramIndex.RecCreate(ANext, APtr, ACnt: Integer): Int64;
begin
  Result := (Int64(ANext) shl REC_NEXT_SHIFT) or
            (Int64(APtr) shl REC_PTR_SHIFT) or
            Int64(ACnt);
end;

class function THistogramIndex.RecNext(ARec: Int64): Integer;
begin
  Result := Int64(ARec) shr REC_NEXT_SHIFT;
end;

class function THistogramIndex.RecPtr(ARec: Int64): Integer;
begin
  Result := (Int64(ARec) shr REC_PTR_SHIFT) and REC_PTR_MASK;
end;

class function THistogramIndex.RecCnt(ARec: Int64): Integer;
begin
  Result := Int64(ARec) and REC_CNT_MASK;
end;

class function THistogramIndex.TableBits(ASz: Integer): Integer;
var
  Bits: Integer;
begin
  if ASz <= 0 then
    Exit(1);
  Bits := 0;
  while (1 shl Bits) < ASz do
    Inc(Bits);
  if Bits = 0 then
    Bits := 1;
  if (1 shl Bits) < ASz then
    Inc(Bits);
  Result := Bits;
end;

function THistogramIndex.ScanA: Boolean;
var
  Ptr, TIdx, RIdx, ChainLen, NewCnt: Integer;
  Rec: Int64;
  SeqA: PLineSequence;
  FoundExisting: Boolean;
begin
  Result := False;
  SeqA := FSeqA;
  Ptr := FRegion.EndA - 1;
  while Ptr >= FRegion.BeginA do
  begin
    TIdx := HashSeq(FSeqA, Ptr);
    ChainLen := 0;
    RIdx := FTable[TIdx];
    FoundExisting := False;
    while RIdx <> 0 do
    begin
      Rec := FRecs[RIdx];
      if SeqA^.EqualsAt(RecPtr(Rec), SeqA^, Ptr) then
      begin
        NewCnt := RecCnt(Rec) + 1;
        if NewCnt > MAX_CNT then
          NewCnt := MAX_CNT;
        FRecs[RIdx] := RecCreate(RecNext(Rec), Ptr, NewCnt);
        FNext[Ptr - FPtrShift] := RecPtr(Rec);
        FRecIdx[Ptr - FPtrShift] := RIdx;
        FoundExisting := True;
        Break;
      end;
      RIdx := RecNext(Rec);
      Inc(ChainLen);
    end;

    if FoundExisting then
    begin
      Dec(Ptr);
      Continue;
    end;

    if ChainLen = FMaxChainLength then
      Exit(False);

    Inc(FRecCnt);
    RIdx := FRecCnt;
    if RIdx >= Length(FRecs) then
      SetLength(FRecs, MaxI(Length(FRecs) * 2, RIdx + 1));

    FRecs[RIdx] := RecCreate(FTable[TIdx], Ptr, 1);
    FRecIdx[Ptr - FPtrShift] := RIdx;
    FTable[TIdx] := RIdx;

    Dec(Ptr);
  end;
  Result := True;
end;

function THistogramIndex.TryLongestCommonSequence(ABPtr: Integer): Integer;
var
  BNext, RIdx, As_, Bs, Ae, Be, Rc, Np: Integer;
  Rec: Int64;
  SeqA, SeqB: PLineSequence;
  Done: Boolean;
begin
  SeqA := FSeqA;
  SeqB := FSeqB;
  BNext := ABPtr + 1;
  RIdx := FTable[HashSeq(FSeqB, ABPtr)];
  while RIdx <> 0 do
  begin
    Rec := FRecs[RIdx];

    if RecCnt(Rec) > FCnt then
    begin
      if not FHasCommon then
        FHasCommon := SeqA^.EqualsAt(RecPtr(Rec), SeqB^, ABPtr);
      RIdx := RecNext(Rec);
      Continue;
    end;

    As_ := RecPtr(Rec);
    if not SeqA^.EqualsAt(As_, SeqB^, ABPtr) then
    begin
      RIdx := RecNext(Rec);
      Continue;
    end;

    FHasCommon := True;
    Done := False;
    while not Done do
    begin
      Np := FNext[As_ - FPtrShift];
      Bs := ABPtr;
      Ae := As_ + 1;
      Be := Bs + 1;
      Rc := RecCnt(Rec);

      while (FRegion.BeginA < As_) and (FRegion.BeginB < Bs) and
            SeqA^.EqualsAt(As_ - 1, SeqB^, Bs - 1) do
      begin
        Dec(As_);
        Dec(Bs);
        if Rc > 1 then
          Rc := MinI(Rc, RecCnt(FRecs[FRecIdx[As_ - FPtrShift]]));
      end;

      while (Ae < FRegion.EndA) and (Be < FRegion.EndB) and
            SeqA^.EqualsAt(Ae, SeqB^, Be) do
      begin
        if Rc > 1 then
          Rc := MinI(Rc, RecCnt(FRecs[FRecIdx[Ae - FPtrShift]]));
        Inc(Ae);
        Inc(Be);
      end;

      if BNext < Be then
        BNext := Be;

      if (FLcs.LengthA < (Ae - As_)) or (Rc < FCnt) then
      begin
        FLcs.BeginA := As_;
        FLcs.BeginB := Bs;
        FLcs.EndA := Ae;
        FLcs.EndB := Be;
        FCnt := Rc;
      end;

      if Np = 0 then
        Done := True
      else
      begin
        while Np < Ae do
        begin
          Np := FNext[Np - FPtrShift];
          if Np = 0 then
            Break;
        end;
        if Np = 0 then
          Done := True
        else
          As_ := Np;
      end;
    end;

    RIdx := RecNext(Rec);
  end;
  Result := BNext;
end;

function THistogramIndex.FindLongestCommonSequence: TDiffEdit;
var
  BPtr: Integer;
begin
  if not ScanA then
  begin
    // Chain exceeded in A — caller must fall back to Myers.
    FFallback := True;
    Exit(TDiffEdit.Create(0, 0, 0, 0));
  end;

  FLcs := TDiffEdit.Create(0, 0, 0, 0);
  FCnt := FMaxChainLength + 1;

  BPtr := FRegion.BeginB;
  while BPtr < FRegion.EndB do
    BPtr := TryLongestCommonSequence(BPtr);

  // If common elements exist but all have occurrence count > max_chain_length,
  // fall back to Myers. JGit signals this by returning null; we use FFallback.
  if FHasCommon and (FMaxChainLength < FCnt) then
  begin
    FFallback := True;
    Exit(TDiffEdit.Create(0, 0, 0, 0));
  end;
  Result := FLcs;
end;

{ HistogramDiff driver. Mirrors JGit's HistogramDiff.State.diffRegion. }
function HistogramDiffNonCommon(
  out AEdits: TDiffEditList;
  const ASeqA, ASeqB: TLineSequence;
  ARegion: TDiffEdit;
  ACancelFunc: TDiffCancelFunc;
  ACancelData: Pointer;
  var ACancelled: Boolean
): Boolean;
var
  Queue: TDiffEditList;

  procedure DiffReplace(const ARegion: TDiffEdit);
  var
    Index: THistogramIndex;
    Lcs: TDiffEdit;
  begin
    if ACancelled then Exit;
    if IsCancelled(ACancelFunc, ACancelData) then
    begin
      ACancelled := True;
      Exit;
    end;
    Index.Init(HISTOGRAM_MAX_CHAIN_LENGTH, @ASeqA, @ASeqB, ARegion);
    Lcs := Index.FindLongestCommonSequence;

    if Index.FFallback then
    begin
      // Fallback to Myers on this region.
      MyersDiffNonCommon(AEdits, ASeqA, ASeqB, ARegion,
        ACancelFunc, ACancelData, ACancelled);
    end
    else if Lcs.IsEmpty then
    begin
      // No common element at all in this region: emit as a single REPLACE.
      AEdits.Add(ARegion);
    end
    else
    begin
      // Split region around LCS, queue the before/after parts for further
      // processing. Queue order: after first, then before — so we pop
      // before first (LIFO), matching JGit's processing order.
      Queue.Add(ARegion.After(Lcs));
      Queue.Add(ARegion.Before(Lcs));
    end;
  end;

  procedure DiffQueueItem(const ARegion: TDiffEdit);
  var
    T: TDiffEditType;
  begin
    T := ARegion.GetType;
    case T of
      detInsert, detDelete:
        AEdits.Add(ARegion);
      detReplace:
        if (ARegion.LengthA = 1) and (ARegion.LengthB = 1) then
          AEdits.Add(ARegion)
        else
          DiffReplace(ARegion);
      detEmpty:
        ; // skip
    end;
  end;

var
  E: TDiffEdit;
begin
  Result := True;
  ACancelled := False;
  AEdits.Init;
  Queue.Init;

  DiffReplace(ARegion);
  while (Queue.Count > 0) and not ACancelled do
  begin
    E := Queue.FItems[Queue.FCount - 1];
    Dec(Queue.FCount);
    DiffQueueItem(E);
  end;
end;

{ ---------- Common preprocessing ---------- }

function ReduceCommonStartEnd(
  const ASeqA, ASeqB: TLineSequence;
  AEdit: TDiffEdit
): TDiffEdit;
begin
  Result := AEdit;
  while (Result.BeginA < Result.EndA) and (Result.BeginB < Result.EndB) and
        ASeqA.EqualsAt(Result.BeginA, ASeqB, Result.BeginB) do
  begin
    Inc(Result.BeginA);
    Inc(Result.BeginB);
  end;
  while (Result.BeginA < Result.EndA) and (Result.BeginB < Result.EndB) and
        ASeqA.EqualsAt(Result.EndA - 1, ASeqB, Result.EndB - 1) do
  begin
    Dec(Result.EndA);
    Dec(Result.EndB);
  end;
end;

{ JGit's normalize pass: shift pure INSERT/DELETE edits to their latest
  possible position. Produces consistent diff output regardless of
  which path the algorithm took through ties. }
procedure NormalizeEdits(var AEdits: TDiffEditList;
  const ASeqA, ASeqB: TLineSequence);
var
  I: Integer;
  Cur, Prev: TDiffEdit;
  MaxA, MaxB: Integer;
  T: TDiffEditType;
begin
  if AEdits.Count = 0 then Exit;
  Prev := TDiffEdit.Create(0, 0, 0, 0);
  for I := AEdits.Count - 1 downto 0 do
  begin
    Cur := AEdits.Items[I];
    T := Cur.GetType;
    if I = AEdits.Count - 1 then
    begin
      MaxA := ASeqA.Size;
      MaxB := ASeqB.Size;
    end
    else
    begin
      MaxA := Prev.BeginA;
      MaxB := Prev.BeginB;
    end;

    if T = detInsert then
    begin
      while (Cur.EndA < MaxA) and (Cur.EndB < MaxB) and
            ASeqB.EqualsAt(Cur.BeginB, ASeqB, Cur.EndB) do
        Cur.Shift(1);
    end
    else if T = detDelete then
    begin
      while (Cur.EndA < MaxA) and (Cur.EndB < MaxB) and
            ASeqA.EqualsAt(Cur.BeginA, ASeqA, Cur.EndA) do
        Cur.Shift(1);
    end;
    AEdits.Items[I] := Cur;
    Prev := Cur;
  end;
end;

{ Convert an edit list to difflib-compatible opcodes.
  Walks the edit list in order, emitting 'equal' opcodes for the
  common regions between edits and the appropriate tag for each edit. }
function EditsToOpcodes(const AEdits: TDiffEditList;
  ALenA, ALenB: Integer): TDiffOpcodeArray;
var
  Result_: TDiffOpcodeArray;
  ResultCount: Integer;
  PrevEndA, PrevEndB: Integer;
  I: Integer;
  E: TDiffEdit;
  T: TDiffEditType;

  procedure Emit(ATag: Integer; AI1, AI2, AJ1, AJ2: Integer);
  begin
    if ResultCount >= Length(Result_) then
      SetLength(Result_, MaxI(Length(Result_) * 2, ResultCount + 16));
    Result_[ResultCount].Tag := ATag;
    Result_[ResultCount].I1 := AI1;
    Result_[ResultCount].I2 := AI2;
    Result_[ResultCount].J1 := AJ1;
    Result_[ResultCount].J2 := AJ2;
    Inc(ResultCount);
  end;

begin
  SetLength(Result_, MaxI(16, AEdits.Count + 1));
  ResultCount := 0;
  PrevEndA := 0;
  PrevEndB := 0;

  for I := 0 to AEdits.Count - 1 do
  begin
    E := AEdits.Items[I];
    if (E.BeginA > PrevEndA) or (E.BeginB > PrevEndB) then
      Emit(DIFF_TAG_EQUAL, PrevEndA, E.BeginA, PrevEndB, E.BeginB);

    T := E.GetType;
    case T of
      detInsert:  Emit(DIFF_TAG_INSERT,  E.BeginA, E.EndA, E.BeginB, E.EndB);
      detDelete:  Emit(DIFF_TAG_DELETE,  E.BeginA, E.EndA, E.BeginB, E.EndB);
      detReplace: Emit(DIFF_TAG_REPLACE, E.BeginA, E.EndA, E.BeginB, E.EndB);
      detEmpty:   ;
    end;

    PrevEndA := E.EndA;
    PrevEndB := E.EndB;
  end;

  if (PrevEndA < ALenA) or (PrevEndB < ALenB) then
    Emit(DIFF_TAG_EQUAL, PrevEndA, ALenA, PrevEndB, ALenB);

  SetLength(Result_, ResultCount);
  Result := Result_;
end;

{ ---------- Public entry points ---------- }

function DoDiffLines(
  const ALinesA, ALinesB: array of string;
  AAlgo: Integer;
  AFlags: Integer;
  ACancelFunc: TDiffCancelFunc;
  ACancelData: Pointer;
  out ACancelled: Boolean
): TDiffOpcodeArray;
var
  SeqA, SeqB: TLineSequence;
  Region, Reduced: TDiffEdit;
  Edits: TDiffEditList;
  RegionType: TDiffEditType;
begin
  ACancelled := False;
  SetLength(Result, 0);

  SeqA.Init(ALinesA, AFlags);
  SeqB.Init(ALinesB, AFlags);

  Region := TDiffEdit.Create(0, SeqA.Size, 0, SeqB.Size);
  Reduced := ReduceCommonStartEnd(SeqA, SeqB, Region);
  RegionType := Reduced.GetType;

  case RegionType of
    detEmpty:
      Edits.Init;
    detInsert, detDelete:
    begin
      Edits.Init;
      Edits.Add(Reduced);
    end;
    detReplace:
    begin
      if (Reduced.LengthA = 1) and (Reduced.LengthB = 1) then
      begin
        Edits.Init;
        Edits.Add(Reduced);
      end
      else
      begin
        case AAlgo of
          DIFF_ALGO_MYERS:
            MyersDiffNonCommon(Edits, SeqA, SeqB, Reduced,
              ACancelFunc, ACancelData, ACancelled);
          DIFF_ALGO_HISTOGRAM:
            HistogramDiffNonCommon(Edits, SeqA, SeqB, Reduced,
              ACancelFunc, ACancelData, ACancelled);
          else
            raise EArgumentException.Create('Unknown diff algorithm');
        end;
        if ACancelled then
          Exit;
      end;
    end;
  end;

  NormalizeEdits(Edits, SeqA, SeqB);
  Result := EditsToOpcodes(Edits, SeqA.Size, SeqB.Size);
end;

function SplitLinesKeepEnds(const AText: string): TStringArray;
var
  S: AnsiString;
  I, Start, N, Count: Integer;
begin
  SetLength(Result, 0);
  S := AnsiString(AText);
  N := Length(S);
  if N = 0 then
    Exit;

  Count := 1;
  for I := 1 to N do
    if S[I] = #10 then
      Inc(Count);
  SetLength(Result, Count);

  Count := 0;
  Start := 1;
  I := 1;
  while I <= N do
  begin
    if S[I] = #10 then
    begin
      Result[Count] := string(Copy(S, Start, I - Start + 1));
      Inc(Count);
      Start := I + 1;
    end;
    Inc(I);
  end;
  if Start <= N then
  begin
    Result[Count] := string(Copy(S, Start, N - Start + 1));
    Inc(Count);
  end;
  // If the text ended with #10, Count is one less than allocated.
  SetLength(Result, Count);
end;

function DoDiffText(
  const ATextA, ATextB: string;
  AAlgo: Integer;
  AFlags: Integer;
  ACancelFunc: TDiffCancelFunc;
  ACancelData: Pointer;
  out ACancelled: Boolean
): TDiffOpcodeArray;
var
  LinesA, LinesB: TStringArray;
begin
  LinesA := SplitLinesKeepEnds(ATextA);
  LinesB := SplitLinesKeepEnds(ATextB);
  Result := DoDiffLines(LinesA, LinesB, AAlgo, AFlags,
    ACancelFunc, ACancelData, ACancelled);
end;

{ ---------- Character-level diff (DIF_CHARS) ---------- }
{
  Port of WinMerge's stringdiffs.cpp + the plugin's char_diff.py.

  Algorithm:
    1. Tokenize both strings into "words" using the regex
       \w+|\s+|[^\w\s]  (identifiers, whitespace, individual punctuation).
       Words are more unique than individual characters, so word-level
       Myers O(ND) is much smaller than char-level Myers for long lines.
    2. Run MyersDiff (the existing line-level algorithm) on the word
       arrays. The algorithm is generic over any hashable sequence.
    3. For each word-level opcode:
       - 'equal': emit as char-level 'equal' using the token offsets.
       - 'delete'/'insert'/'replace': refine to exact byte boundaries
         using prefix/suffix trimming (compute the common prefix and
         suffix of the two substrings, mark the middle as changed).
    4. Merge adjacent opcodes of the same tag (the byte-trim step can
       produce consecutive 'equal' or 'replace' opcodes that should
       be merged for a clean difflib-style output).
}

type
  { Token from the word tokenizer. Stores the token text (for hashing
    and equality) and the character offset where it starts in the
    original string (for mapping word-level opcodes back to char positions). }
  TToken = record
    Text: string;
    StartOffset: Integer;  // 0-based char offset into the original string
    Length: Integer;       // character length of this token
  end;
  TTokenArray = array of TToken;

{ Check if a character is a "word" character (letter, digit, underscore).
  Matches the \w class in Python's regex engine for ASCII. }
function IsWordChar(C: AnsiChar): Boolean; inline;
begin
  Result := ((C >= 'A') and (C <= 'Z')) or
            ((C >= 'a') and (C <= 'z')) or
            ((C >= '0') and (C <= '9')) or
            (C = '_');
end;

{ Tokenize a string into words, whitespace runs, and individual punctuation
  characters. Port of char_diff.py's _tokenize() which uses the regex
  \w+|\s+|[^\w\s]. Produces the same tokenization as WinMerge's
  BuildWordsArray (which uses ICU break iterators — close enough for
  diff purposes; the exact tokenization only affects which boundaries
  Myers can find, not the correctness of the diff).

  Also returns the character offset of each token in the original string
  so we can map word-level opcodes back to character positions. }
procedure Tokenize(const AText: string; out ATokens: TTokenArray);
var
  S: AnsiString;
  N, I, TokenStart, TokenLen: Integer;
  Count: Integer;
  C: AnsiChar;
begin
  SetLength(ATokens, 0);
  S := AnsiString(AText);
  N := Length(S);
  if N = 0 then
    Exit;

  // Pre-count tokens to size the array in one allocation.
  // Worst case: every char is its own token (all punctuation).
  SetLength(ATokens, N);
  Count := 0;

  I := 1;
  while I <= N do
  begin
    C := S[I];
    TokenStart := I;
    if IsWordChar(C) then
    begin
      // \w+ — run of word characters
      while (I <= N) and IsWordChar(S[I]) do
        Inc(I);
    end
    else if IsWhitespaceByte(C) then
    begin
      // \s+ — run of whitespace
      while (I <= N) and IsWhitespaceByte(S[I]) do
        Inc(I);
    end
    else
    begin
      // [^\w\s] — single punctuation character
      Inc(I);
    end;
    TokenLen := I - TokenStart;
    ATokens[Count].Text := string(Copy(S, TokenStart, TokenLen));
    // StartOffset is 0-based into the original string; S is 1-based.
    ATokens[Count].StartOffset := TokenStart - 1;
    ATokens[Count].Length := TokenLen;
    Inc(Count);
  end;
  SetLength(ATokens, Count);
end;

{ Build a TStringArray from tokens (for passing to DoDiffLines which
  works on string arrays). }
function TokensToStrings(const ATokens: TTokenArray): TStringArray;
var
  I: Integer;
begin
  SetLength(Result, Length(ATokens));
  for I := 0 to High(ATokens) do
    Result[I] := ATokens[I].Text;
end;

{ Compute the common prefix length of two string slices.
  Port of char_diff.py's _compute_byte_diff prefix portion. }
function CommonPrefixLen(const AText: string; AStartA: Integer;
  const BText: string; AStartB: Integer; AMaxLen: Integer): Integer;
var
  SA, SB: AnsiString;
  I: Integer;
begin
  SA := AnsiString(AText);
  SB := AnsiString(BText);
  // AStartA/AStartB are 0-based; SA/SB are 1-based.
  Result := 0;
  while (Result < AMaxLen) and
        (SA[AStartA + 1 + Result] = SB[AStartB + 1 + Result]) do
    Inc(Result);
end;

{ Compute the common suffix length of two string slices.
  Port of char_diff.py's _compute_byte_diff suffix portion. }
function CommonSuffixLen(const AText: string; AStartA, ALenA: Integer;
  const BText: string; AStartB, ALenB: Integer; AMaxLen: Integer): Integer;
var
  SA, SB: AnsiString;
begin
  SA := AnsiString(AText);
  SB := AnsiString(BText);
  Result := 0;
  while (Result < AMaxLen) and
        (SA[AStartA + ALenA - Result] = SB[AStartB + ALenB - Result]) do
    Inc(Result);
end;

function DoDiffChars(
  const ATextA, ATextB: string;
  AFlags: Integer;
  ACancelFunc: TDiffCancelFunc;
  ACancelData: Pointer;
  out ACancelled: Boolean
): TDiffOpcodeArray;
var
  TokensA, TokensB: TTokenArray;
  WordsA, WordsB: TStringArray;
  WordOpcodes: TDiffOpcodeArray;
  I, J: Integer;
  Tag: Integer;
  WAStart, WAEnd, WBStart, WBEnd: Integer;  // word-level ranges
  CAStart, CAEnd, CBStart, CBEnd: Integer;  // char-level ranges
  StrA, StrB: AnsiString;
  PrefixLen, SuffixLen: Integer;
  MinLen: Integer;
  InnerLenA, InnerLenB: Integer;
  InnerStartA, InnerStartB: Integer;
  Result_: TDiffOpcodeArray;
  ResultCount: Integer;
  LastTag: Integer;

  procedure Emit(ATag: Integer; AA1, AA2, AB1, AB2: Integer);
  begin
    // Merge with previous opcode if same tag and adjacent.
    // The byte-trim step can produce consecutive 'equal' or 'replace'
    // opcodes that should be merged for clean difflib-style output.
    if (ResultCount > 0) and (Result_[ResultCount - 1].Tag = ATag) and
       (Result_[ResultCount - 1].I2 = AA1) and
       (Result_[ResultCount - 1].J2 = AB1) then
    begin
      Result_[ResultCount - 1].I2 := AA2;
      Result_[ResultCount - 1].J2 := AB2;
    end
    else
    begin
      if ResultCount >= Length(Result_) then
        SetLength(Result_, MaxI(Length(Result_) * 2, ResultCount + 16));
      Result_[ResultCount].Tag := ATag;
      Result_[ResultCount].I1 := AA1;
      Result_[ResultCount].I2 := AA2;
      Result_[ResultCount].J1 := AB1;
      Result_[ResultCount].J2 := AB2;
      Inc(ResultCount);
    end;
  end;

begin
  ACancelled := False;
  SetLength(Result, 0);

  // Fast path: identical strings produce a single 'equal' opcode.
  if ATextA = ATextB then
  begin
    if (ATextA <> '') or (ATextB <> '') then
    begin
      SetLength(Result, 1);
      Result[0].Tag := DIFF_TAG_EQUAL;
      Result[0].I1 := 0;
      Result[0].I2 := Length(ATextA);
      Result[0].J1 := 0;
      Result[0].J2 := Length(ATextB);
    end;
    Exit;
  end;

  // Fast path: one side empty -> single insert or delete.
  if ATextA = '' then
  begin
    SetLength(Result, 1);
    Result[0].Tag := DIFF_TAG_INSERT;
    Result[0].I1 := 0;
    Result[0].I2 := 0;
    Result[0].J1 := 0;
    Result[0].J2 := Length(ATextB);
    Exit;
  end;
  if ATextB = '' then
  begin
    SetLength(Result, 1);
    Result[0].Tag := DIFF_TAG_DELETE;
    Result[0].I1 := 0;
    Result[0].I2 := Length(ATextA);
    Result[0].J1 := 0;
    Result[0].J2 := 0;
    Exit;
  end;

  // Step 1: tokenize both strings into words.
  Tokenize(ATextA, TokensA);
  Tokenize(ATextB, TokensB);

  // Step 2: run word-level Myers diff. We reuse DoDiffLines by passing
  // the word arrays as if they were line arrays. The algorithm doesn't
  // care whether the "lines" are actual lines or words.
  WordsA := TokensToStrings(TokensA);
  WordsB := TokensToStrings(TokensB);
  WordOpcodes := DoDiffLines(WordsA, WordsB, DIFF_ALGO_MYERS, AFlags,
    ACancelFunc, ACancelData, ACancelled);
  if ACancelled then
    Exit;

  StrA := AnsiString(ATextA);
  StrB := AnsiString(ATextB);

  // Step 3: convert word-level opcodes to char-level opcodes.
  // For 'equal' opcodes, map word boundaries to char offsets directly.
  // For non-equal opcodes, refine with byte-level prefix/suffix trim.
  SetLength(Result_, MaxI(16, Length(WordOpcodes)));
  ResultCount := 0;
  LastTag := -1;

  for I := 0 to High(WordOpcodes) do
  begin
    Tag := WordOpcodes[I].Tag;
    WAStart := WordOpcodes[I].I1;
    WAEnd := WordOpcodes[I].I2;
    WBStart := WordOpcodes[I].J1;
    WBEnd := WordOpcodes[I].J2;

    if Tag = DIFF_TAG_EQUAL then
    begin
      // Word range is identical in both — emit as char-level 'equal'.
      // Char start = first token's StartOffset.
      // Char end = last token's StartOffset + last token's Length.
      if (WAEnd > WAStart) and (WBEnd > WBStart) then
      begin
        CAStart := TokensA[WAStart].StartOffset;
        CAEnd := TokensA[WAEnd - 1].StartOffset + TokensA[WAEnd - 1].Length;
        CBStart := TokensB[WBStart].StartOffset;
        CBEnd := TokensB[WBEnd - 1].StartOffset + TokensB[WBEnd - 1].Length;
        Emit(DIFF_TAG_EQUAL, CAStart, CAEnd, CBStart, CBEnd);
      end;
    end
    else
    begin
      // Non-equal word range: refine to byte boundaries.
      // Get the char range covered by this word opcode.
      if WAEnd > WAStart then
      begin
        CAStart := TokensA[WAStart].StartOffset;
        CAEnd := TokensA[WAEnd - 1].StartOffset + TokensA[WAEnd - 1].Length;
      end
      else
      begin
        // No A tokens in this range — insert at the boundary.
        // Use the char offset of the token BEFORE the insert point,
        // or 0 if inserting at the very start.
        if WAStart > 0 then
          CAStart := TokensA[WAStart - 1].StartOffset + TokensA[WAStart - 1].Length
        else
          CAStart := 0;
        CAEnd := CAStart;
      end;
      if WBEnd > WBStart then
      begin
        CBStart := TokensB[WBStart].StartOffset;
        CBEnd := TokensB[WBEnd - 1].StartOffset + TokensB[WBEnd - 1].Length;
      end
      else
      begin
        if WBStart > 0 then
          CBStart := TokensB[WBStart - 1].StartOffset + TokensB[WBStart - 1].Length
        else
          CBStart := 0;
        CBEnd := CBStart;
      end;

      InnerLenA := CAEnd - CAStart;
      InnerLenB := CBEnd - CBStart;

      if (InnerLenA = 0) and (InnerLenB = 0) then
        Continue; // nothing to emit

      // Compute common prefix.
      if (InnerLenA > 0) and (InnerLenB > 0) then
      begin
        MinLen := MinI(InnerLenA, InnerLenB);
        PrefixLen := 0;
        while (PrefixLen < MinLen) and
              (StrA[CAStart + 1 + PrefixLen] = StrB[CBStart + 1 + PrefixLen]) do
          Inc(PrefixLen);
      end
      else
        PrefixLen := 0;

      // Compute common suffix.
      if (InnerLenA > PrefixLen) and (InnerLenB > PrefixLen) then
      begin
        MinLen := MinI(InnerLenA - PrefixLen, InnerLenB - PrefixLen);
        SuffixLen := 0;
        while (SuffixLen < MinLen) and
              (StrA[CAEnd - SuffixLen] = StrB[CBEnd - SuffixLen]) do
          Inc(SuffixLen);
      end
      else
        SuffixLen := 0;

      // Emit equal prefix (if any).
      if PrefixLen > 0 then
        Emit(DIFF_TAG_EQUAL,
             CAStart, CAStart + PrefixLen,
             CBStart, CBStart + PrefixLen);

      // Emit the changed middle region (if any).
      InnerStartA := CAStart + PrefixLen;
      InnerStartB := CBStart + PrefixLen;
      if (InnerLenA - PrefixLen - SuffixLen > 0) and
         (InnerLenB - PrefixLen - SuffixLen > 0) then
        Emit(DIFF_TAG_REPLACE,
             InnerStartA, CAEnd - SuffixLen,
             InnerStartB, CBEnd - SuffixLen)
      else if (InnerLenA - PrefixLen - SuffixLen > 0) then
        Emit(DIFF_TAG_DELETE,
             InnerStartA, CAEnd - SuffixLen,
             InnerStartB, CBEnd - SuffixLen)
      else if (InnerLenB - PrefixLen - SuffixLen > 0) then
        Emit(DIFF_TAG_INSERT,
             InnerStartA, CAEnd - SuffixLen,
             InnerStartB, CBEnd - SuffixLen);

      // Emit equal suffix (if any).
      if SuffixLen > 0 then
        Emit(DIFF_TAG_EQUAL,
             CAEnd - SuffixLen, CAEnd,
             CBEnd - SuffixLen, CBEnd);
    end;
  end;

  SetLength(Result_, ResultCount);
  Result := Result_;
end;

end.
