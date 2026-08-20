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

{ Compare two line arrays and return difflib-compatible opcodes. }
function DoDiffLines(
  const ALinesA, ALinesB: array of string;
  AAlgo: Integer;
  AFlags: Integer
): TDiffOpcodeArray;

{ Compare two LF-separated text blocks. Splits each text on #10 and
  keeps the line terminators attached (matches difflib keepends=True
  behavior). The last line keeps its terminator if present; if absent,
  it's still emitted as a separate line. }
function DoDiffText(
  const ATextA, ATextB: string;
  AAlgo: Integer;
  AFlags: Integer
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
  AFlags: Integer
): TDiffOpcodeArray;

{ Split a string on #10 keeping the terminator attached. Useful for
  callers who want to pre-split text once and reuse the line array
  across multiple DoDiffLines calls. }
function SplitLinesKeepEnds(const AText: string): TStringArray;

implementation

{ Free Pascal on 64-bit evaluates 32-bit arithmetic in 64-bit signed
  and then range-checks the assignment back to the 32-bit variable.
  This means Cardinal wraparound (djb2 in HashLine, Knuth mix in
  HashSeq) trips ERangeError under RANGECHECKS ON — not EIntOverflow,
  since the 64-bit intermediate never overflows. The Int64-to-Integer
  narrowing in SnakeX/SnakeY/RecNext/RecPtr/RecCnt is also
  range-checked. Those sites disable RANGECHECKS locally below via
  PUSH/POP blocks. The Myers V arrays use raw PInteger/PInt64 offsets,
  which are never range-checked, so they need no directive.
  OVERFLOWCHECKS is left at the project default everywhere — nothing
  in this unit needs it off. }

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
    avoid repeated heap allocation. Uses raw pointers (PInteger / PInt64)
    for the V arrays instead of dynamic arrays — raw pointer indexing
    is never range-checked, which eliminates per-access bounds-check
    overhead (26.6s on the 3MB HTML test with checked arrays). The
    pointer is adjusted by OffsetK so that negative k indices work
    without bounds checks, exactly like LGenerics' LcsMyersImpl does
    with PSizeInt. }
  TMyersState = record
    SeqA, SeqB: PLineSequence;

    // V arrays — allocated once at top level, accessed via pointers.
    FwdXBuf: array of Integer;   // raw storage
    BwdXBuf: array of Integer;
    FwdSnakeBuf: array of Int64;
    BwdSnakeBuf: array of Int64;
    FwdX: PInteger;    // pointer into FwdXBuf, adjusted by OffsetK
    BwdX: PInteger;    // pointer into BwdXBuf, adjusted by OffsetK
    FwdSnake: PInt64;  // pointer into FwdSnakeBuf, adjusted by OffsetK
    BwdSnake: PInt64;  // pointer into BwdSnakeBuf, adjusted by OffsetK
    OffsetK: Integer;

    BeginA, EndA, BeginB, EndB: Integer;
    MinK, MaxK: Integer;
    FwdMiddleK, BwdMiddleK: Integer;
    FwdBeginK, FwdEndK: Integer;
    BwdBeginK, BwdEndK: Integer;

    MiddleEdit: TDiffEdit;
    BigSnake: Boolean;  { Set when a snake > SNAKE_LIMIT is found }
  end;

  { Result of discard_confusing_lines preprocessing for one side.
    FDiscarded[I] is True when line (ARegionBegin + I) was discarded
    (matches nothing in the other file, or matches too many lines and
    survived the provisional-cancel rules).
    FKeptIdx[J] gives the offset (relative to ARegionBegin) of the J-th
    kept line, for J in [0..FKeptCount-1]. Used to translate virtual
    indices back to real ones after Myers runs on the kept subset. }
  TDiscardMap = record
    FDiscarded: array of Boolean;
    FKeptIdx: array of Integer;
    FKeptCount: Integer;
    FRegionLen: Integer;
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

{$PUSH}
{$RANGECHECKS OFF}  { Cardinal(AY) cast can be out of Integer range;
                       Int64-to-Integer narrowing in SnakeX/SnakeY. }
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
{$POP}

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

{ djb2 hash of a line's bytes. Matches JGit's RawTextComparator.hashRegion.
  Uses Cardinal (unsigned 32-bit) for the accumulator because the hash
  is designed to wrap around. }
{$PUSH}
{$RANGECHECKS OFF}  { Cardinal wraparound on the djb2 accumulator: the
                       64-bit intermediate range-checks against
                       Cardinal's range on assignment back to H. }
function HashLine(const ALine: string): Integer;
var
  S: AnsiString;
  I, Len: Integer;
  H: Cardinal;
begin
  S := AnsiString(ALine);
  Len := Length(S);
  H := DJB2_SEED;
  for I := 1 to Len do
    H := ((H shl 5) + H) + Ord(S[I]);
  Result := Integer(H);
end;
{$POP}

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
var
  PA, PB: PAnsiChar;
  Len, I: Integer;
begin
  // CRITICAL: hash check FIRST (fast integer compare), then string equality
  // to verify the match. A hash collision without this check produces a
  // silently wrong diff which is nearly impossible to debug later.
  if FHashes[AIdxThis] <> AOther.FHashes[AIdxOther] then
    Exit(False);
  if FHasNormalization then
    Exit(FNormalized[AIdxThis] = AOther.FNormalized[AIdxOther]);
  // Fast pointer-based string comparison instead of Pascal's AnsiString
  // comparison. Pascal's string = operator does a call to fpc_AnsStr_Compare
  // which has overhead. Pointer comparison with MoveCompare is faster
  // for the hot path (called billions of times in the Myers snake loops).
  PA := Pointer(FLines[AIdxThis]);
  PB := Pointer(AOther.FLines[AIdxOther]);
  if PA = PB then
    Exit(True);  // same pointer (e.g. comparing a sequence with itself)
  Len := Length(FLines[AIdxThis]);
  if Len <> Length(AOther.FLines[AIdxOther]) then
    Exit(False);
  if Len = 0 then
    Exit(True);
  // Compare 4 bytes at a time using PInteger
  I := 0;
  while I + 4 <= Len do
  begin
    if PInteger(PA + I)^ <> PInteger(PB + I)^ then
      Exit(False);
    Inc(I, 4);
  end;
  // Compare remaining bytes
  while I < Len do
  begin
    if PA[I] <> PB[I] then
      Exit(False);
    Inc(I);
  end;
  Result := True;
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

function MyersDiffCore(
  out AEdits: TDiffEditList;
  const ASeqA, ASeqB: TLineSequence;
  ARegion: TDiffEdit
): Boolean; forward;

function MyersDiffNonCommon(
  out AEdits: TDiffEditList;
  const ASeqA, ASeqB: TLineSequence;
  ARegion: TDiffEdit
): Boolean; forward;

function HistogramDiffNonCommon(
  out AEdits: TDiffEditList;
  const ASeqA, ASeqB: TLineSequence;
  ARegion: TDiffEdit
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

const
  { GNU diffutils constants (analyze.c):
    SNAKE_LIMIT: Snakes bigger than this are considered "big" and
      trigger the big_snake early-termination heuristic.
    TOO_EXPENSIVE_FLOOR: Minimum value for the too_expensive threshold. }
  SNAKE_LIMIT = 20;
  TOO_EXPENSIVE_FLOOR = 4096;

{ Create a middle edit from forward and backward snake endpoints.
  When the forward path meets the backward path on a diagonal, the
  condition is NewX >= BwdX[K] (or LeftEnd >= BwdX[K-1] etc.). The
  >= means forward X may strictly exceed backward X — in that case
  the edit would be (BeginA=X1, EndA=X2) with X1 > X2, which is
  invalid (negative-length range). EditsToOpcodes then walks the
  edit list expecting BeginA <= EndA, and an inverted edit produces
  wrong opcodes that visibly drift in side-by-side rendering.

  JGit handles this in EditPaths.makeEdit() by clamping:
    if x1 > x2: x1 = x2
    if y1 > y2: y1 = y2
  which collapses the overshoot to a zero-length edit on that axis.
  This is the same clamp, ported faithfully. }
function MakeMiddleEdit(AFwdSnake, ABwdSnake: Int64): TDiffEdit; inline;
var
  X1, X2, Y1, Y2: Integer;
begin
  X1 := SnakeX(AFwdSnake);
  X2 := SnakeX(ABwdSnake);
  Y1 := SnakeY(AFwdSnake);
  Y2 := SnakeY(ABwdSnake);
  if X1 > X2 then X1 := X2;
  if Y1 > Y2 then Y1 := Y2;
  Result := TDiffEdit.Create(X1, X2, Y1, Y2);
end;

function ForwardSnake(var AState: TMyersState; AK, AX: Integer): Integer; inline;
var
  X, Y, SnakeLen: Integer;
  SeqA, SeqB: PLineSequence;
begin
  SeqA := AState.SeqA;
  SeqB := AState.SeqB;
  X := AX;
  Y := AK + X;
  SnakeLen := 0;
  while (X < AState.EndA) and (Y < AState.EndB) and
        SeqA^.EqualsAt(X, SeqB^, Y) do
  begin
    Inc(X);
    Inc(Y);
    Inc(SnakeLen);
  end;
  if SnakeLen > SNAKE_LIMIT then
    AState.BigSnake := True;
  Result := X;
end;

function BackwardSnake(var AState: TMyersState; AK, AX: Integer): Integer; inline;
var
  X, Y, SnakeLen: Integer;
  SeqA, SeqB: PLineSequence;
begin
  SeqA := AState.SeqA;
  SeqB := AState.SeqB;
  X := AX;
  Y := AK + X;
  SnakeLen := 0;
  while (X > AState.BeginA) and (Y > AState.BeginB) and
        SeqA^.EqualsAt(X - 1, SeqB^, Y - 1) do
  begin
    Dec(X);
    Dec(Y);
    Inc(SnakeLen);
  end;
  if SnakeLen > SNAKE_LIMIT then
    AState.BigSnake := True;
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
  Returns True if the forward and backward fronts meet (middle snake found).
  Uses pointer arithmetic (PInteger/PInt64) for V array access — no bounds
  checking needed because the arrays are sized (2*MaxSize+1) at the top
  level, which is always sufficient for any sub-region's k range. }
function ForwardCalculate(var AState: TMyersState; AD: Integer): Boolean;
var
  K, I, Left, Right, NewX: Integer;
  LeftEnd, RightEnd: Integer;
  LeftSnake, RightSnake, NewSnake: Int64;
  PrevBeginK, PrevEndK: Integer;
  FwdX: PInteger;
  FwdSnake: PInt64;
  BwdX: PInteger;
  BwdSnake: PInt64;
begin
  Result := False;
  PrevBeginK := AState.FwdBeginK;
  PrevEndK := AState.FwdEndK;
  AState.FwdBeginK := ForceKIntoRange(AState.FwdMiddleK - AD, AState.MinK, AState.MaxK);
  AState.FwdEndK := ForceKIntoRange(AState.FwdMiddleK + AD, AState.MinK, AState.MaxK);

  // Cache pointers in locals for faster access in the loop.
  FwdX := AState.FwdX;
  FwdSnake := AState.FwdSnake;
  BwdX := AState.BwdX;
  BwdSnake := AState.BwdSnake;

  K := AState.FwdEndK;
  while K >= AState.FwdBeginK do
  begin
    Left := -1;
    Right := -1;
    LeftSnake := -1;
    RightSnake := -1;

    if K > PrevBeginK then
    begin
      Left := FwdX[K - 1];
      LeftEnd := ForwardSnake(AState, K - 1, Left);
      if Left <> LeftEnd then
        LeftSnake := PackSnake(LeftEnd, (K - 1) + LeftEnd)
      else
        LeftSnake := FwdSnake[K - 1];
      if (K - 1 >= AState.BwdBeginK) and (K - 1 <= AState.BwdEndK) and
         (((AD - 1 + (K - 1) - AState.BwdMiddleK) mod 2) = 0) and
         (LeftEnd >= BwdX[K - 1]) then
      begin
        AState.MiddleEdit := MakeMiddleEdit(LeftSnake, BwdSnake[K - 1]);
        Exit(True);
      end;
      Left := LeftEnd;
    end;

    if K < PrevEndK then
    begin
      Right := FwdX[K + 1];
      RightEnd := ForwardSnake(AState, K + 1, Right);
      if Right <> RightEnd then
        RightSnake := PackSnake(RightEnd, (K + 1) + RightEnd)
      else
        RightSnake := FwdSnake[K + 1];
      if (K + 1 >= AState.BwdBeginK) and (K + 1 <= AState.BwdEndK) and
         (((AD - 1 + (K + 1) - AState.BwdMiddleK) mod 2) = 0) and
         (RightEnd >= BwdX[K + 1]) then
      begin
        AState.MiddleEdit := MakeMiddleEdit(RightSnake, BwdSnake[K + 1]);
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
       (((AD - 1 + K - AState.BwdMiddleK) mod 2) = 0) and
       (NewX >= BwdX[K]) then
    begin
      AState.MiddleEdit := MakeMiddleEdit(NewSnake, BwdSnake[K]);
      Exit(True);
    end;

    if (NewX >= AState.EndA) or ((K + NewX) >= AState.EndB) then
    begin
      if K > AState.BwdMiddleK then
        AState.MaxK := K
      else
        AState.MinK := K;
    end;

    FwdX[K] := NewX;
    FwdSnake[K] := NewSnake;

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
  FwdX: PInteger;
  FwdSnake: PInt64;
  BwdX: PInteger;
  BwdSnake: PInt64;
begin
  Result := False;
  PrevBeginK := AState.BwdBeginK;
  PrevEndK := AState.BwdEndK;
  AState.BwdBeginK := ForceKIntoRange(AState.BwdMiddleK - AD, AState.MinK, AState.MaxK);
  AState.BwdEndK := ForceKIntoRange(AState.BwdMiddleK + AD, AState.MinK, AState.MaxK);

  // Cache pointers in locals for faster access in the loop.
  FwdX := AState.FwdX;
  FwdSnake := AState.FwdSnake;
  BwdX := AState.BwdX;
  BwdSnake := AState.BwdSnake;

  K := AState.BwdEndK;
  while K >= AState.BwdBeginK do
  begin
    Left := -1;
    Right := -1;
    LeftSnake := -1;
    RightSnake := -1;

    if K > PrevBeginK then
    begin
      Left := BwdX[K - 1];
      LeftEnd := BackwardSnake(AState, K - 1, Left);
      if Left <> LeftEnd then
        LeftSnake := PackSnake(LeftEnd, (K - 1) + LeftEnd)
      else
        LeftSnake := BwdSnake[K - 1];
      if (K - 1 >= AState.FwdBeginK) and (K - 1 <= AState.FwdEndK) and
         (((AD + (K - 1) - AState.FwdMiddleK) mod 2) = 0) and
         (LeftEnd <= FwdX[K - 1]) then
      begin
        AState.MiddleEdit := MakeMiddleEdit(FwdSnake[K - 1], LeftSnake);
        Exit(True);
      end;
      Left := LeftEnd - 1;
    end;

    if K < PrevEndK then
    begin
      Right := BwdX[K + 1];
      RightEnd := BackwardSnake(AState, K + 1, Right);
      if Right <> RightEnd then
        RightSnake := PackSnake(RightEnd, (K + 1) + RightEnd)
      else
        RightSnake := BwdSnake[K + 1];
      if (K + 1 >= AState.FwdBeginK) and (K + 1 <= AState.FwdEndK) and
         (((AD + (K + 1) - AState.FwdMiddleK) mod 2) = 0) and
         (RightEnd <= FwdX[K + 1]) then
      begin
        AState.MiddleEdit := MakeMiddleEdit(FwdSnake[K + 1], RightSnake);
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
       (NewX <= FwdX[K]) then
    begin
      AState.MiddleEdit := MakeMiddleEdit(FwdSnake[K], NewSnake);
      Exit(True);
    end;

    if (NewX <= AState.BeginA) or ((K + NewX) <= AState.BeginB) then
    begin
      if K > AState.FwdMiddleK then
        AState.MaxK := K
      else
        AState.MinK := K;
    end;

    BwdX[K] := NewX;
    BwdSnake[K] := NewSnake;

    Dec(K, 2);
  end;
end;

{ Myers O(ND) diff with linear-space middle-snake optimization.
  Port of JGit's MyersDiff.java (Myers 1986 + Myers-Miller 1988
  divide-and-conquer).

  Additional optimizations ported from GNU diffutils (WinMerge's
  default diff engine, analyze.c):
  - TOO_EXPENSIVE heuristic: caps the D-loop at max(4096, sqrt(N)).
    When exceeded, picks the best forward/backward diagonal found so
    far as the split point, producing a suboptimal but good enough
    result. Makes the algorithm O(N*sqrt(N)) instead of O(N*D) for
    files with large edit distance.
  - big_snake heuristic: when c > 200 and a snake > 20 lines was
    found, checks if any diagonal has made progress >> cost. If so,
    returns that diagonal as the split point. Makes the algorithm
    O(N) for files with constant small density of changes.
  - discard_confusing_lines (analyze.c lines 414-614): preprocesses
    both sequences to remove lines that obviously don't match (nmatch
    == 0) or that match too many lines (nmatch > sqrt(N)*5, marked
    "provisionally discardable"). Myers then runs on the smaller
    "undiscarded" subset, with discarded lines emitted as standalone
    INSERT/DELETE edits. Provides huge speedups on files with many
    unique lines (e.g. log files with timestamps) by avoiding the
    O(N*D) trap entirely.

  Not ported from GNU diffutils:
  - shift_boundaries: adjusts boundaries for prettier output. The
    Differ plugin does its own opcode realignment.

  TextDiff's PushDiff/PopDiff pattern replaces recursion with an
  explicit heap-allocated work stack to prevent stack overflow.
  Pointer arithmetic (PInteger adjusted by OffsetK) eliminates
  bounds-checking overhead. }
type
  TDiffWorkItem = record
    BeginA, EndA, BeginB, EndB: Integer;
  end;
  TDiffWorkStack = array of TDiffWorkItem;

{ ---------- discard_confusing_lines (port of analyze.c) ---------- }
{
  Direct port of WinMerge/GNU diffutils analyze.c:discard_confusing_lines
  (lines 414-614). Builds equivalence classes for lines in both sequences
  within the region, counts how many lines of each side fall into each
  class, then marks lines as discardable when they match 0 lines on the
  other side, or as "provisionally discardable" when they match too many
  (nmatch > sqrt(N)*5).

  The provisional-discard run rules (analyze.c lines 483-593) are ported
  verbatim — they cancel provisional discards in subruns that don't meet
  length/position thresholds, preventing the algorithm from discarding
  useful context lines.

  Output: ADiscardA / ADiscardB describe which lines were discarded and
  provide the virtual->real index mapping for the kept lines.
}

type
  { Hash map entry for equivalence class lookup. One per line in both
    sequences within the region. Chains via Next for hash-bucket collision
    resolution. }
  TEquivEntry = record
    Hash: Integer;
    Side: Byte;        // 0 = A, 1 = B
    LocalIdx: Integer; // offset within the side's region (0..Len-1)
    EquivClass: Integer;
    Next: Integer;     // index of next entry in same hash bucket, -1 if none
  end;

{ Compute log2(table size) for a power-of-2 table. Used to derive the
  Knuth-mix shift count from the bucket count. }
function EquivTableBits(ATableSize: Integer): Integer;
var
  B: Integer;
begin
  B := 0;
  while (1 shl B) < ATableSize do
    Inc(B);
  Result := B;
end;

{ Build equivalence-class assignments for both sides of a region.
  EquivsA[i] / EquivsB[i] get the class ID for the i-th line in each
  side's region (i is a 0-based offset from ARegion.BeginA/BeginB).
  Returns EquivMax = one more than the largest class ID used.

  Lines that compare equal across sides get the same class ID; lines
  with the same hash but different content get different class IDs
  (verified via EqualsAt to avoid hash-collision false matches). }
{$PUSH}
{$RANGECHECKS OFF}  { Cardinal*Cardinal Knuth mix wraps on assignment. }
procedure BuildEquivClasses(
  const ASeqA, ASeqB: TLineSequence;
  ARegion: TDiffEdit;
  var AEquivsA: array of Integer;
  var AEquivsB: array of Integer;
  var AEquivMax: Integer);
var
  LenA, LenB, Total, I, J, Hash, Bucket, ClassId, TableSize, Mask, EntryIdx: Integer;
  Entries: array of TEquivEntry;
  Buckets: array of Integer;
  TBits: Integer;
  MatchFound: Boolean;
begin
  LenA := ARegion.LengthA;
  LenB := ARegion.LengthB;
  Total := LenA + LenB;
  // Caller pre-allocates AEquivsA / AEquivsB to LenA / LenB.
  if Total = 0 then
  begin
    AEquivMax := 1;
    Exit;
  end;

  // Size the hash table to next power of 2 >= 2*Total (load factor ~0.5).
  TableSize := 16;
  while TableSize < Total * 2 do
    TableSize := TableSize shl 1;
  Mask := TableSize - 1;
  TBits := EquivTableBits(TableSize);
  SetLength(Buckets, TableSize);
  for I := 0 to TableSize - 1 do
    Buckets[I] := -1;

  // Allocate one entry per line in both sequences.
  SetLength(Entries, Total);
  EntryIdx := 0;

  // Fill entries for side A.
  for I := 0 to LenA - 1 do
  begin
    Hash := ASeqA.HashAt(ARegion.BeginA + I);
    Entries[EntryIdx].Hash := Hash;
    Entries[EntryIdx].Side := 0;
    Entries[EntryIdx].LocalIdx := I;
    Entries[EntryIdx].EquivClass := -1;
    Bucket := (Cardinal(Hash) * $9e370001) shr (32 - TBits);
    Bucket := Bucket and Mask;
    Entries[EntryIdx].Next := Buckets[Bucket];
    Buckets[Bucket] := EntryIdx;
    Inc(EntryIdx);
  end;

  // Fill entries for side B.
  for I := 0 to LenB - 1 do
  begin
    Hash := ASeqB.HashAt(ARegion.BeginB + I);
    Entries[EntryIdx].Hash := Hash;
    Entries[EntryIdx].Side := 1;
    Entries[EntryIdx].LocalIdx := I;
    Entries[EntryIdx].EquivClass := -1;
    Bucket := (Cardinal(Hash) * $9e370001) shr (32 - TBits);
    Bucket := Bucket and Mask;
    Entries[EntryIdx].Next := Buckets[Bucket];
    Buckets[Bucket] := EntryIdx;
    Inc(EntryIdx);
  end;

  // Walk all entries, assigning equivalence classes.
  // Class 0 is reserved for "no match" (a line whose equivs[i] == 0 is
  // always discarded because nmatch == 0 — see analyze.c line 473).
  ClassId := 1;
  for I := 0 to Total - 1 do
  begin
    if Entries[I].EquivClass <> -1 then
      Continue;

    // Start a new equivalence class.
    Entries[I].EquivClass := ClassId;

    // Walk the hash bucket chain to find same-hash entries and verify
    // content equality. Same-hash different-content entries will fail
    // the EqualsAt check and remain unassigned — they get their own
    // class when their outer-loop iteration arrives.
    Bucket := (Cardinal(Entries[I].Hash) * $9e370001) shr (32 - TBits);
    Bucket := Bucket and Mask;
    J := Buckets[Bucket];
    while J <> -1 do
    begin
      if (J <> I) and (Entries[J].EquivClass = -1) and
         (Entries[J].Hash = Entries[I].Hash) then
      begin
        // Verify content equality.
        if (Entries[I].Side = 0) and (Entries[J].Side = 0) then
          MatchFound := ASeqA.EqualsAt(
            ARegion.BeginA + Entries[I].LocalIdx,
            ASeqA, ARegion.BeginA + Entries[J].LocalIdx)
        else if (Entries[I].Side = 1) and (Entries[J].Side = 1) then
          MatchFound := ASeqB.EqualsAt(
            ARegion.BeginB + Entries[I].LocalIdx,
            ASeqB, ARegion.BeginB + Entries[J].LocalIdx)
        else if Entries[I].Side = 0 then
          // I in A, J in B
          MatchFound := ASeqA.EqualsAt(
            ARegion.BeginA + Entries[I].LocalIdx,
            ASeqB, ARegion.BeginB + Entries[J].LocalIdx)
        else
          // I in B, J in A
          MatchFound := ASeqA.EqualsAt(
            ARegion.BeginA + Entries[J].LocalIdx,
            ASeqB, ARegion.BeginB + Entries[I].LocalIdx);
        if MatchFound then
          Entries[J].EquivClass := ClassId;
      end;
      J := Entries[J].Next;
    end;

    Inc(ClassId);
  end;

  // Emit equivs arrays.
  for I := 0 to Total - 1 do
  begin
    if Entries[I].Side = 0 then
      AEquivsA[Entries[I].LocalIdx] := Entries[I].EquivClass
    else
      AEquivsB[Entries[I].LocalIdx] := Entries[I].EquivClass;
  end;

  AEquivMax := ClassId;
end;
{$POP}

{ Apply the provisional-discard run rules (analyze.c lines 483-593).
  Walks the discards[] array (0=keep, 1=discard, 2=provisional) and
  cancels provisional discards that don't meet the run-length thresholds.
  Mutates ADiscards in place. }
procedure CancelProvisionalRuns(var ADiscards: array of Byte; AEnd: Integer);
var
  I, J, Length_, Provisional, Minimum, Tem, Consec: Integer;
begin
  I := 0;
  while I < AEnd do
  begin
    // Standalone provisionals (not in a run with nonprovisionals) get cancelled.
    if ADiscards[I] = 2 then
    begin
      ADiscards[I] := 0;
      Inc(I);
      Continue;
    end;
    if ADiscards[I] = 0 then
    begin
      Inc(I);
      Continue;
    end;

    // Found a nonprovisional discard (value 1) at I.
    // Find end of run; count provisionals.
    J := I;
    Provisional := 0;
    while (J < AEnd) and (ADiscards[J] <> 0) do
    begin
      if ADiscards[J] = 2 then
        Inc(Provisional);
      Inc(J);
    end;

    // Cancel provisional discards at end of run.
    while (J > I) and (ADiscards[J - 1] = 2) do
    begin
      Dec(J);
      ADiscards[J] := 0;
      Dec(Provisional);
    end;

    Length_ := J - I;

    // If 1/4 of the run is provisional, cancel all provisionals in the run.
    if Provisional * 4 > Length_ then
    begin
      while J > I do
      begin
        Dec(J);
        if ADiscards[J] = 2 then
          ADiscards[J] := 0;
      end;
    end
    else
    begin
      // MINIMUM = approximate sqrt(Length/4) + 1.
      // A subrun of two or more provisionals can stand when LENGTH >= 16.
      // A subrun of 4 or more can stand when LENGTH >= 64.
      Minimum := 1;
      Tem := Length_ div 4;
      while Tem > 0 do
      begin
        Tem := Tem shr 2;
        if Tem > 0 then
          Minimum := Minimum * 2;
      end;
      Inc(Minimum);

      // Cancel any subrun of MINIMUM or more provisionals within the run.
      Consec := 0;
      J := 0;
      while J < Length_ do
      begin
        if ADiscards[I + J] <> 2 then
          Consec := 0
        else
        begin
          Inc(Consec);
          if Minimum = Consec then
            // Back up to start of subrun, to revert it all.
            J := J - Consec
          else if Minimum < Consec then
            ADiscards[I + J] := 0;
        end;
        Inc(J);
      end;

      // Scan from beginning of run: cancel provisionals until we find
      // 3+ nonprovisionals in a row, or until the first nonprovisional
      // at least 8 lines in. Until that point, cancel any provisionals.
      Consec := 0;
      for J := 0 to Length_ - 1 do
      begin
        if (J >= 8) and (ADiscards[I + J] = 1) then
          Break;
        if ADiscards[I + J] = 2 then
        begin
          Consec := 0;
          ADiscards[I + J] := 0;
        end
        else if ADiscards[I + J] = 0 then
          Consec := 0
        else
          Inc(Consec);
        if Consec = 3 then
          Break;
      end;

      // I advances to the last line of the run.
      I := I + Length_ - 1;

      // Same scan, from end backwards.
      Consec := 0;
      for J := 0 to Length_ - 1 do
      begin
        if (J >= 8) and (ADiscards[I - J] = 1) then
          Break;
        if ADiscards[I - J] = 2 then
        begin
          Consec := 0;
          ADiscards[I - J] := 0;
        end
        else if ADiscards[I - J] = 0 then
          Consec := 0
        else
          Inc(Consec);
        if Consec = 3 then
          Break;
      end;
    end;

    Inc(I);
  end;
end;

{ Port of analyze.c:discard_confusing_lines (lines 414-614).
  Produces ADiscardA / ADiscardB describing which lines were discarded
  and the virtual->real index mapping for kept lines. }
procedure DiscardConfusingLines(
  const ASeqA, ASeqB: TLineSequence;
  ARegion: TDiffEdit;
  out ADiscardA, ADiscardB: TDiscardMap);
var
  EquivsA, EquivsB: array of Integer;
  EquivMax, I, J, LenA, LenB, Many, Tem: Integer;
  EquivCountA, EquivCountB: array of Integer;
  DiscardedA, DiscardedB: array of Byte;  // 0=keep, 1=discard, 2=provisional
begin
  LenA := ARegion.LengthA;
  LenB := ARegion.LengthB;
  SetLength(ADiscardA.FDiscarded, LenA);
  SetLength(ADiscardA.FKeptIdx, LenA);
  ADiscardA.FKeptCount := 0;
  ADiscardA.FRegionLen := LenA;
  SetLength(ADiscardB.FDiscarded, LenB);
  SetLength(ADiscardB.FKeptIdx, LenB);
  ADiscardB.FKeptCount := 0;
  ADiscardB.FRegionLen := LenB;

  if (LenA = 0) or (LenB = 0) then
  begin
    // Nothing to discard when one side is empty — keep everything.
    for I := 0 to LenA - 1 do
    begin
      ADiscardA.FDiscarded[I] := False;
      ADiscardA.FKeptIdx[I] := I;
    end;
    ADiscardA.FKeptCount := LenA;
    for I := 0 to LenB - 1 do
    begin
      ADiscardB.FDiscarded[I] := False;
      ADiscardB.FKeptIdx[I] := I;
    end;
    ADiscardB.FKeptCount := LenB;
    Exit;
  end;

  SetLength(EquivsA, LenA);
  SetLength(EquivsB, LenB);
  BuildEquivClasses(ASeqA, ASeqB, ARegion, EquivsA, EquivsB, EquivMax);

  // equiv_count[F][I] = # lines in file F with equivalence class I.
  SetLength(EquivCountA, EquivMax);
  SetLength(EquivCountB, EquivMax);
  for I := 0 to EquivMax - 1 do
  begin
    EquivCountA[I] := 0;
    EquivCountB[I] := 0;
  end;
  for I := 0 to LenA - 1 do
    Inc(EquivCountA[EquivsA[I]]);
  for I := 0 to LenB - 1 do
    Inc(EquivCountB[EquivsB[I]]);

  SetLength(DiscardedA, LenA);
  SetLength(DiscardedB, LenB);
  for I := 0 to LenA - 1 do
    DiscardedA[I] := 0;
  for I := 0 to LenB - 1 do
    DiscardedB[I] := 0;

  // Mark discardable lines on side A. For each line in A, look at the
  // count of matching lines in B (via the shared equiv class).
  // MANY = 5 * approximate sqrt(LenA/64) — threshold for "too many matches".
  Many := 5;
  Tem := LenA div 64;
  while Tem > 0 do
  begin
    Tem := Tem shr 2;
    if Tem > 0 then
      Many := Many * 2;
  end;
  for I := 0 to LenA - 1 do
  begin
    if EquivsA[I] = 0 then
      Continue;
    J := EquivCountB[EquivsA[I]];
    if J = 0 then
      DiscardedA[I] := 1
    else if J > Many then
      DiscardedA[I] := 2;
  end;

  // Side B.
  Many := 5;
  Tem := LenB div 64;
  while Tem > 0 do
  begin
    Tem := Tem shr 2;
    if Tem > 0 then
      Many := Many * 2;
  end;
  for I := 0 to LenB - 1 do
  begin
    if EquivsB[I] = 0 then
      Continue;
    J := EquivCountA[EquivsB[I]];
    if J = 0 then
      DiscardedB[I] := 1
    else if J > Many then
      DiscardedB[I] := 2;
  end;

  // Apply provisional-cancel run rules.
  CancelProvisionalRuns(DiscardedA, LenA);
  CancelProvisionalRuns(DiscardedB, LenB);

  // Actually discard: build kept-index arrays.
  J := 0;
  for I := 0 to LenA - 1 do
  begin
    if DiscardedA[I] = 0 then
    begin
      ADiscardA.FDiscarded[I] := False;
      ADiscardA.FKeptIdx[J] := I;
      Inc(J);
    end
    else
      ADiscardA.FDiscarded[I] := True;
  end;
  ADiscardA.FKeptCount := J;

  J := 0;
  for I := 0 to LenB - 1 do
  begin
    if DiscardedB[I] = 0 then
    begin
      ADiscardB.FDiscarded[I] := False;
      ADiscardB.FKeptIdx[J] := I;
      Inc(J);
    end
    else
      ADiscardB.FDiscarded[I] := True;
  end;
  ADiscardB.FKeptCount := J;
end;

{ Build a virtual TLineSequence containing only the kept lines from
  ASource[ABegin..ABegin+ADiscard.FRegionLen). Reuses hashes and
  normalized copies from ASource so no rehashing is needed. }
procedure BuildVirtualSequence(
  const ASource: TLineSequence;
  ABegin: Integer;
  const ADiscard: TDiscardMap;
  out AVirt: TLineSequence);
var
  I, RealIdx: Integer;
begin
  AVirt.FHasNormalization := ASource.FHasNormalization;
  SetLength(AVirt.FLines, ADiscard.FKeptCount);
  if AVirt.FHasNormalization then
    SetLength(AVirt.FNormalized, ADiscard.FKeptCount)
  else
    AVirt.FNormalized := nil;
  SetLength(AVirt.FHashes, ADiscard.FKeptCount);
  for I := 0 to ADiscard.FKeptCount - 1 do
  begin
    RealIdx := ABegin + ADiscard.FKeptIdx[I];
    AVirt.FLines[I] := ASource.FLines[RealIdx];
    if AVirt.FHasNormalization then
      AVirt.FNormalized[I] := ASource.FNormalized[RealIdx];
    AVirt.FHashes[I] := ASource.FHashes[RealIdx];
  end;
end;


function MyersDiffCore(
  out AEdits: TDiffEditList;
  const ASeqA, ASeqB: TLineSequence;
  ARegion: TDiffEdit
): Boolean;
var
  State: TMyersState;
  MaxSize: Integer;
  WorkStack: TDiffWorkStack;
  WorkCount: Integer;
  Item: TDiffWorkItem;
  Edit: TDiffEdit;
  K, X, D: Integer;
  Found: Boolean;
  TooExpensive: Integer;
  BigSnake: Boolean;
  FwdX, BwdX: PInteger;
  FwdSnake, BwdSnake: PInt64;
  BestVal, BestX, TmpX, TmpY, TmpD: Integer;
  FxyBest, FxBest, BxyBest, BxBest: Integer;

  procedure PushWork(ABeginA, AEndA, ABeginB, AEndB: Integer);
  begin
    if WorkCount >= Length(WorkStack) then
      SetLength(WorkStack, MaxI(Length(WorkStack) * 2, WorkCount + 64));
    WorkStack[WorkCount].BeginA := ABeginA;
    WorkStack[WorkCount].EndA := AEndA;
    WorkStack[WorkCount].BeginB := ABeginB;
    WorkStack[WorkCount].EndB := AEndB;
    Inc(WorkCount);
  end;

begin
  Result := True;
  AEdits.Init;

  State.SeqA := @ASeqA;
  State.SeqB := @ASeqB;

  MaxSize := ARegion.LengthA + ARegion.LengthB;
  if MaxSize = 0 then
    Exit;

  { Compute TOO_EXPENSIVE threshold (GNU diffutils analyze.c line 958):
    approximate square root of input size, bounded below by 4096.
    This caps the D-loop to prevent O(N*D) blowup on files with
    large edit distance. }
  TooExpensive := 1;
  TmpX := MaxSize;
  while TmpX > 0 do
  begin
    TooExpensive := TooExpensive shl 1;
    TmpX := TmpX shr 2;
  end;
  if TooExpensive < TOO_EXPENSIVE_FLOOR then
    TooExpensive := TOO_EXPENSIVE_FLOOR;
  State.OffsetK := MaxSize;
  // Allocate V arrays once at top level. Size is 2*MaxSize+1, which is
  // always sufficient for any sub-region's k range (k is in [-MaxSize, +MaxSize]).
  // Using pointer arithmetic (adjusted by OffsetK) eliminates bounds-checking
  // overhead — direct memory access like LGenerics' LcsMyersImpl.
  SetLength(State.FwdXBuf, 2 * MaxSize + 1);
  SetLength(State.BwdXBuf, 2 * MaxSize + 1);
  SetLength(State.FwdSnakeBuf, 2 * MaxSize + 1);
  SetLength(State.BwdSnakeBuf, 2 * MaxSize + 1);
  // Set pointers to the middle of each buffer, so Ptr[K] works for
  // any K in [-MaxSize, +MaxSize] without bounds checking.
  State.FwdX := PInteger(@State.FwdXBuf[0]) + State.OffsetK;
  State.BwdX := PInteger(@State.BwdXBuf[0]) + State.OffsetK;
  State.FwdSnake := PInt64(@State.FwdSnakeBuf[0]) + State.OffsetK;
  State.BwdSnake := PInt64(@State.BwdSnakeBuf[0]) + State.OffsetK;

  // Initialize the work stack with the top-level region.
  SetLength(WorkStack, 64);
  WorkCount := 0;
  PushWork(ARegion.BeginA, ARegion.EndA, ARegion.BeginB, ARegion.EndB);

  // Process work items from the stack. This replaces the recursive
  // CalculateEdits calls — the "stack" is now on the heap, so it can
  // grow to any size without overflowing the call stack.
  // Safety limit: the work stack can never have more items than the
  // total number of lines (each item represents at least 1 line). If
  // it exceeds that, something is wrong — bail out to prevent an
  // infinite loop from hanging CudaText.
  while (WorkCount > 0) and (WorkCount <= MaxSize + 1) do
  begin
    Dec(WorkCount);
    Item := WorkStack[WorkCount];

    // Base case: one side empty → emit as a single edit.
    if (Item.BeginA >= Item.EndA) or (Item.BeginB >= Item.EndB) then
    begin
      if (Item.BeginA < Item.EndA) or (Item.BeginB < Item.EndB) then
        AEdits.Add(TDiffEdit.Create(Item.BeginA, Item.EndA, Item.BeginB, Item.EndB));
      Continue;
    end;

    State.BeginA := Item.BeginA;
    State.EndA := Item.EndA;
    State.BeginB := Item.BeginB;
    State.EndB := Item.EndB;

    // Strip common prefix.
    K := Item.BeginB - Item.BeginA;
    X := ForwardSnake(State, K, Item.BeginA);
    State.BeginA := X;
    State.BeginB := K + X;

    // Strip common suffix.
    K := Item.EndB - Item.EndA;
    X := BackwardSnake(State, K, Item.EndA);
    State.EndA := X;
    State.EndB := K + X;

    // After trimming, check if either side is empty. This is the same
    // check TextDiff does (Diff_NP.pas line 365-380): if len1=0, emit
    // as add; if len2=0, emit as delete. Without this check, the k range
    // computation below produces invalid values (MinK > MaxK) which
    // causes ForceKIntoRange to return garbage, leading to an infinite
    // loop in the work stack.
    if (State.BeginA >= State.EndA) or (State.BeginB >= State.EndB) then
    begin
      if (State.BeginA < State.EndA) or (State.BeginB < State.EndB) then
        AEdits.Add(TDiffEdit.Create(State.BeginA, State.EndA,
          State.BeginB, State.EndB));
      Continue;
    end;

    State.MinK := State.BeginB - State.EndA;
    State.MaxK := State.EndB - State.BeginA;
    State.FwdMiddleK := State.BeginB - State.BeginA;
    State.BwdMiddleK := State.EndB - State.EndA;
    State.FwdBeginK := State.FwdMiddleK;
    State.FwdEndK := State.FwdMiddleK;
    State.BwdBeginK := State.BwdMiddleK;
    State.BwdEndK := State.BwdMiddleK;

    State.FwdX[State.FwdMiddleK] := State.BeginA;
    State.FwdSnake[State.FwdMiddleK] :=
      PackSnake(State.BeginA, State.FwdMiddleK + State.BeginA);
    State.BwdX[State.BwdMiddleK] := State.EndA;
    State.BwdSnake[State.BwdMiddleK] :=
      PackSnake(State.EndA, State.BwdMiddleK + State.EndA);

    // Find the middle snake with GNU diffutils heuristics.
    Edit := TDiffEdit.Create(0, 0, 0, 0);
    Found := False;
    BigSnake := False;
    D := 1;
    while (D <= MaxSize) and not Found do
    begin
      { Track big_snake: ForwardCalculate and BackwardCalculate
        set BigSnake when a snake > SNAKE_LIMIT is found. We pass
        it by reference via the State record. }
      State.BigSnake := False;

      if ForwardCalculate(State, D) or BackwardCalculate(State, D) then
      begin
        Edit := State.MiddleEdit;
        Found := True;
      end
      else
      begin
        if State.BigSnake then
          BigSnake := True;

        { GNU diffutils big_snake heuristic (analyze.c line 200):
          When c > 200 and a big snake was found, check if any
          diagonal has made progress >> cost. If so, return that
          diagonal as the split point. This makes the algorithm
          linear for files with constant small density of changes. }
        if (D > 200) and BigSnake then
        begin
          { Check forward diagonals for best progress }
          FwdX := State.FwdX;
          FwdSnake := State.FwdSnake;
          BestVal := 0;
          BestX := 0;
          K := State.FwdEndK;
          while K >= State.FwdBeginK do
          begin
            TmpX := FwdX[K];
            TmpY := TmpX - K;
            TmpD := K - State.FwdMiddleK;
            if TmpD < 0 then TmpD := -TmpD;
            { v = (x - xoff) * 2 - dd = progress * 2 - diagonal_distance }
            X := (TmpX - State.BeginA) * 2 - TmpD;
            if (X > 12 * (D + TmpD)) and
               (X > BestVal) and
               (State.BeginA + SNAKE_LIMIT <= TmpX) and
               (TmpX < State.EndA) and
               (State.BeginB + SNAKE_LIMIT <= TmpY) and
               (TmpY < State.EndB) then
            begin
              { Verify it ends with a significant snake }
              TmpD := 0;
              while (TmpD < SNAKE_LIMIT) and
                    (TmpX - TmpD - 1 >= State.BeginA) and
                    (TmpY - TmpD - 1 >= State.BeginB) and
                    ASeqA.EqualsAt(TmpX - TmpD - 1, ASeqB, TmpY - TmpD - 1) do
                Inc(TmpD);
              if TmpD >= SNAKE_LIMIT then
              begin
                BestVal := X;
                BestX := TmpX;
              end;
            end;
            Dec(K, 2);
          end;
          if BestVal > 0 then
          begin
            Edit := TDiffEdit.Create(BestX, BestX, BestX - (BestX - State.BeginA + State.BeginB), BestX - (BestX - State.BeginA + State.BeginB));
            { Simplify: just use the point as a zero-length edit }
            Edit.BeginA := BestX;
            Edit.EndA := BestX;
            Edit.BeginB := BestX - (State.FwdMiddleK);
            Edit.EndB := Edit.BeginB;
            Found := True;
            Break;
          end;

          { Check backward diagonals for best progress }
          BwdX := State.BwdX;
          BwdSnake := State.BwdSnake;
          BestVal := 0;
          BestX := 0;
          K := State.BwdEndK;
          while K >= State.BwdBeginK do
          begin
            TmpX := BwdX[K];
            TmpY := TmpX - K;
            TmpD := K - State.BwdMiddleK;
            if TmpD < 0 then TmpD := -TmpD;
            { v = (xlim - x) * 2 + dd }
            X := (State.EndA - TmpX) * 2 + TmpD;
            if (X > 12 * (D + TmpD)) and
               (X > BestVal) and
               (State.BeginA < TmpX) and
               (TmpX <= State.EndA - SNAKE_LIMIT) and
               (State.BeginB < TmpY) and
               (TmpY <= State.EndB - SNAKE_LIMIT) then
            begin
              TmpD := 0;
              while (TmpD < SNAKE_LIMIT - 1) and
                    (TmpX + TmpD < State.EndA) and
                    (TmpY + TmpD < State.EndB) and
                    ASeqA.EqualsAt(TmpX + TmpD, ASeqB, TmpY + TmpD) do
                Inc(TmpD);
              if TmpD >= SNAKE_LIMIT - 1 then
              begin
                BestVal := X;
                BestX := TmpX;
              end;
            end;
            Dec(K, 2);
          end;
          if BestVal > 0 then
          begin
            Edit.BeginA := BestX;
            Edit.EndA := BestX;
            Edit.BeginB := BestX - (State.BwdMiddleK);
            Edit.EndB := Edit.BeginB;
            Found := True;
            Break;
          end;
        end;

        { GNU diffutils TOO_EXPENSIVE heuristic (analyze.c line 277):
          When cost exceeds the threshold, give up on finding the
          optimal split and pick the best forward/backward diagonal
          found so far. This produces a suboptimal but good enough
          result, preventing O(N*D) blowup. }
        if D >= TooExpensive then
        begin
          { Find forward diagonal that maximizes X + Y }
          FwdX := State.FwdX;
          FxyBest := -1;
          FxBest := 0;
          K := State.FwdEndK;
          while K >= State.FwdBeginK do
          begin
            TmpX := FwdX[K];
            if TmpX > State.EndA then TmpX := State.EndA;
            TmpY := TmpX - K;
            if TmpY > State.EndB then
            begin
              TmpX := State.EndB + K;
              TmpY := State.EndB;
            end;
            if TmpX + TmpY > FxyBest then
            begin
              FxyBest := TmpX + TmpY;
              FxBest := TmpX;
            end;
            Dec(K, 2);
          end;

          { Find backward diagonal that minimizes X + Y }
          BwdX := State.BwdX;
          BxyBest := MaxInt;
          BxBest := 0;
          K := State.BwdEndK;
          while K >= State.BwdBeginK do
          begin
            TmpX := BwdX[K];
            if TmpX < State.BeginA then TmpX := State.BeginA;
            TmpY := TmpX - K;
            if TmpY < State.BeginB then
            begin
              TmpX := State.BeginB + K;
              TmpY := State.BeginB;
            end;
            if TmpX + TmpY < BxyBest then
            begin
              BxyBest := TmpX + TmpY;
              BxBest := TmpX;
            end;
            Dec(K, 2);
          end;

          { Use the better of the two diagonals (GNU diffutils line 315) }
          if (State.EndA + State.EndB) - BxyBest < FxyBest - (State.BeginA + State.BeginB) then
          begin
            Edit.BeginA := BxBest;
            Edit.EndA := BxBest;
            Edit.BeginB := BxyBest - BxBest;
            Edit.EndB := Edit.BeginB;
          end
          else
          begin
            Edit.BeginA := FxBest;
            Edit.EndA := FxBest;
            Edit.BeginB := FxyBest - FxBest;
            Edit.EndB := Edit.BeginB;
          end;
          Found := True;
          Break;
        end;

        Inc(D);
      end;
    end;

    if not Found then
      Continue;

    // Push the "after" half onto the stack (processed later — LIFO).
    if (Item.EndA > Edit.EndA) or (Item.EndB > Edit.EndB) then
    begin
      K := Edit.EndB - Edit.EndA;
      X := ForwardSnake(State, K, Edit.EndA);
      PushWork(X, Item.EndA, K + X, Item.EndB);
    end;

    // Emit the middle edit itself.
    if not Edit.IsEmpty then
      AEdits.Add(Edit);

    // Push the "before" half onto the stack (processed next — LIFO).
    if (Item.BeginA < Edit.BeginA) or (Item.BeginB < Edit.BeginB) then
    begin
      K := Edit.BeginB - Edit.BeginA;
      X := BackwardSnake(State, K, Edit.BeginA);
      PushWork(Item.BeginA, X, Item.BeginB, K + X);
    end;
  end;

  // The explicit-stack (LIFO) processing emits edits out of positional
  // order. Sort by BeginA (then BeginB) so EditsToOpcodes can walk them
  // in order. This is the same approach TextDiff uses — its PushDiff/
  // PopDiff loop also produces out-of-order edits that are sorted by
  // position at the end.
  if AEdits.Count > 1 then
  begin
    // Simple insertion sort — edit count is typically small (O(D) where
    // D is the edit distance, not O(N)). For very large edit counts,
    // could switch to quicksort, but insertion sort is cache-friendly
    // and fast for small arrays.
    for K := 1 to AEdits.Count - 1 do
    begin
      Edit := AEdits.Items[K];
      D := K - 1;
      while (D >= 0) and
            ((AEdits.Items[D].BeginA > Edit.BeginA) or
             ((AEdits.Items[D].BeginA = Edit.BeginA) and
              (AEdits.Items[D].BeginB > Edit.BeginB))) do
      begin
        AEdits.Items[D + 1] := AEdits.Items[D];
        Dec(D);
      end;
      AEdits.Items[D + 1] := Edit;
    end;
  end;
end;

{ MyersDiffNonCommon: entry point for Myers diff with discard_confusing_lines
  preprocessing.

  This wrapper decides whether to apply discard_confusing_lines (analyze.c
  line 942) before running MyersDiffCore. The discard step removes lines
  that obviously don't match (nmatch == 0) or that match too many lines
  (provisionally discardable), reducing the input size for Myers and
  avoiding the O(N*D) trap on files with many unique lines (e.g. log
  files with timestamps that change on every line).

  Threshold: only apply discard when the region has >= 256 lines on
  either side. Below that, the overhead of building equiv classes and
  virtual sequences outweighs the benefit, and Myers is fast enough.

  After Myers runs on the virtual (kept) sequences, the resulting edits
  are translated back to real line indices, and discarded lines are
  emitted as standalone INSERT (side B) / DELETE (side A) edits. The
  final edit list is then sorted by BeginA/BeginB for EditsToOpcodes. }
function MyersDiffNonCommon(
  out AEdits: TDiffEditList;
  const ASeqA, ASeqB: TLineSequence;
  ARegion: TDiffEdit
): Boolean;
const
  { Below this threshold, skip discard preprocessing — Myers is fast
    enough on small inputs and the equiv-class overhead isn't worth it. }
  DISCARD_MIN_LINES = 256;
var
  DiscardA, DiscardB: TDiscardMap;
  VirtSeqA, VirtSeqB: TLineSequence;
  VirtRegion: TDiffEdit;
  VirtEdits: TDiffEditList;
  UseDiscard: Boolean;
  I, J: Integer;
  LenA, LenB: Integer;
  Edit: TDiffEdit;
  ChangedA, ChangedB: array of Boolean;
  IA, IB, StartA, StartB: Integer;
  RealBegin, RealEnd: Integer;
begin
  Result := True;
  AEdits.Init;
  LenA := ARegion.LengthA;
  LenB := ARegion.LengthB;

  // Decide whether to apply discard_confusing_lines preprocessing.
  UseDiscard := (LenA >= DISCARD_MIN_LINES) or
                (LenB >= DISCARD_MIN_LINES);

  if not UseDiscard then
  begin
    // Small input — run Myers directly on the original sequences.
    Exit(MyersDiffCore(AEdits, ASeqA, ASeqB, ARegion));
  end;

  // Run discard_confusing_lines on both sides.
  DiscardConfusingLines(ASeqA, ASeqB, ARegion, DiscardA, DiscardB);

  // If discard didn't remove anything, skip the virtual-sequence path.
  if (DiscardA.FKeptCount = ARegion.LengthA) and
     (DiscardB.FKeptCount = ARegion.LengthB) then
  begin
    Exit(MyersDiffCore(AEdits, ASeqA, ASeqB, ARegion));
  end;

  // Build virtual sequences containing only kept lines.
  BuildVirtualSequence(ASeqA, ARegion.BeginA, DiscardA, VirtSeqA);
  BuildVirtualSequence(ASeqB, ARegion.BeginB, DiscardB, VirtSeqB);

  // Handle degenerate cases where one side is entirely discarded.
  if (VirtSeqA.Size = 0) and (VirtSeqB.Size = 0) then
  begin
    // Both sides entirely discarded — entire region is a REPLACE.
    AEdits.Add(ARegion);
    Exit;
  end;

  if VirtSeqA.Size = 0 then
  begin
    // All of A was discarded. Run Myers on B's kept lines vs nothing
    // isn't useful — just emit: kept B lines as INSERT, discarded A
    // lines as DELETE. But wait, the kept B lines might still match
    // discarded A lines (rare but possible). For correctness, fall
    // back to core on the original sequences.
    Exit(MyersDiffCore(AEdits, ASeqA, ASeqB, ARegion));
  end;
  if VirtSeqB.Size = 0 then
  begin
    Exit(MyersDiffCore(AEdits, ASeqA, ASeqB, ARegion));
  end;

  // Run Myers on the virtual sequences.
  VirtRegion := TDiffEdit.Create(0, VirtSeqA.Size, 0, VirtSeqB.Size);
  VirtEdits.Init;
  MyersDiffCore(VirtEdits, VirtSeqA, VirtSeqB, VirtRegion);

  // Translate virtual edits back to real line indices using the
  // build_script approach from GNU diffutils (analyze.c line 793).
  //
  // Build changedA[] / changedB[] boolean arrays (indexed by real offset
  // within the region). Mark:
  //   - Discarded lines as changed (they're standalone INSERT/DELETE)
  //   - Virtual edit lines as changed (mapped back via FKeptIdx)
  // Then walk both arrays in lock-step, grouping consecutive changed
  // lines into TDiffEdit records. Unchanged lines on both sides become
  // EQUAL gaps (handled by EditsToOpcodes).
  SetLength(ChangedA, LenA + 1);  // +1 for sentinel
  SetLength(ChangedB, LenB + 1);
  for I := 0 to LenA do ChangedA[I] := False;
  for I := 0 to LenB do ChangedB[I] := False;

  // Mark discarded lines as changed.
  for I := 0 to LenA - 1 do
    if DiscardA.FDiscarded[I] then
      ChangedA[I] := True;
  for I := 0 to LenB - 1 do
    if DiscardB.FDiscarded[I] then
      ChangedB[I] := True;

  // Mark virtual edit lines as changed (map virtual indices back to real).
  for I := 0 to VirtEdits.Count - 1 do
  begin
    Edit := VirtEdits.Items[I];
    // A side: map virtual [BeginA, EndA) to real offsets.
    if Edit.BeginA < Edit.EndA then
    begin
      RealBegin := DiscardA.FKeptIdx[Edit.BeginA];
      RealEnd := DiscardA.FKeptIdx[Edit.EndA - 1] + 1;
      for J := RealBegin to RealEnd - 1 do
        ChangedA[J] := True;
    end;
    // B side: map virtual [BeginB, EndB) to real offsets.
    if Edit.BeginB < Edit.EndB then
    begin
      RealBegin := DiscardB.FKeptIdx[Edit.BeginB];
      RealEnd := DiscardB.FKeptIdx[Edit.EndB - 1] + 1;
      for J := RealBegin to RealEnd - 1 do
        ChangedB[J] := True;
    end;
  end;

  // Walk changedA[] and changedB[] in lock-step, emitting TDiffEdit
  // records for runs of changed lines. This is a direct port of
  // build_script (analyze.c line 793).
  IA := 0;
  IB := 0;
  while (IA < LenA) or (IB < LenB) do
  begin
    if ChangedA[IA] or ChangedB[IB] then
    begin
      StartA := IA;
      StartB := IB;
      while ChangedA[IA] do Inc(IA);
      while ChangedB[IB] do Inc(IB);
      AEdits.Add(TDiffEdit.Create(
        ARegion.BeginA + StartA, ARegion.BeginA + IA,
        ARegion.BeginB + StartB, ARegion.BeginB + IB));
    end;
    if IA < LenA then Inc(IA);
    if IB < LenB then Inc(IB);
  end;
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

{$PUSH}
{$RANGECHECKS OFF}  { Cardinal*Cardinal Knuth multiplicative mix wraps
                       on the assignment to Mixed. }
function THistogramIndex.HashSeq(ASeq: PLineSequence; AIdx: Integer): Integer;
var
  RawHash: Integer;
  Mixed: Cardinal;
begin
  RawHash := ASeq^.HashAt(AIdx);
  Mixed := Cardinal(RawHash) * HASH_MIX_CONSTANT;
  Result := Integer(Mixed shr FKeyShift);
end;
{$POP}

class function THistogramIndex.RecCreate(ANext, APtr, ACnt: Integer): Int64;
begin
  Result := (Int64(ANext) shl REC_NEXT_SHIFT) or
            (Int64(APtr) shl REC_PTR_SHIFT) or
            Int64(ACnt);
end;

{$PUSH}
{$RANGECHECKS OFF}  { Int64-to-Integer narrowing on the return. }
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
{$POP}

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
  BPtr, NewBPtr: Integer;
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
  // Safety: if TryLongestCommonSequence ever returns a value <= BPtr
  // (doesn't advance), force advance to prevent infinite loop.
  while BPtr < FRegion.EndB do
  begin
    NewBPtr := TryLongestCommonSequence(BPtr);
    if NewBPtr <= BPtr then
      BPtr := BPtr + 1
    else
      BPtr := NewBPtr;
  end;

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
  ARegion: TDiffEdit
): Boolean;
var
  Queue: TDiffEditList;

  procedure DiffReplace(const ARegion: TDiffEdit);
  var
    Index: THistogramIndex;
    Lcs: TDiffEdit;
  begin
    Index.Init(HISTOGRAM_MAX_CHAIN_LENGTH, @ASeqA, @ASeqB, ARegion);
    Lcs := Index.FindLongestCommonSequence;

    if Index.FFallback then
    begin
      // Fallback to Myers on this region.
      MyersDiffNonCommon(AEdits, ASeqA, ASeqB, ARegion);
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
  AEdits.Init;
  Queue.Init;

  DiffReplace(ARegion);
  while Queue.Count > 0 do
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
  AFlags: Integer
): TDiffOpcodeArray;
var
  SeqA, SeqB: TLineSequence;
  Region, Reduced: TDiffEdit;
  Edits: TDiffEditList;
  RegionType: TDiffEditType;
begin
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
            MyersDiffNonCommon(Edits, SeqA, SeqB, Reduced);
          DIFF_ALGO_HISTOGRAM:
            HistogramDiffNonCommon(Edits, SeqA, SeqB, Reduced);
          else
            raise EArgumentException.Create('Unknown diff algorithm');
        end;
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
  AFlags: Integer
): TDiffOpcodeArray;
var
  LinesA, LinesB: TStringArray;
begin
  LinesA := SplitLinesKeepEnds(ATextA);
  LinesB := SplitLinesKeepEnds(ATextB);
  Result := DoDiffLines(LinesA, LinesB, AAlgo, AFlags);
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
  Count, Cap: Integer;
  C: AnsiChar;
begin
  SetLength(ATokens, 0);
  S := AnsiString(AText);
  N := Length(S);
  if N = 0 then
    Exit;

  // Start with a small capacity and grow as needed (doubling).
  // Avoids pre-allocating N TToken records (where N = byte length),
  // which for very long lines (e.g. 80KB) would allocate 80K+ records
  // (1.2MB+) and zero-fill them, even though the actual token count
  // is typically 5-10x smaller (words are multi-char). The growable
  // approach allocates only what's needed.
  Cap := 256;
  if Cap > N then Cap := N;
  SetLength(ATokens, Cap);
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

    // Grow the array if needed (amortized O(1) append).
    if Count >= Cap then
    begin
      Cap := Cap * 2;
      SetLength(ATokens, Cap);
    end;

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

function DoDiffChars(
  const ATextA, ATextB: string;
  AFlags: Integer
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

  // Step 0: Early byte-length bail-out BEFORE tokenizing.
  // Tokenize() pre-allocates N TToken records (where N = byte length
  // of the string). For very long lines (e.g. 100KB+ minified JS),
  // this would allocate 100K+ records (1.6MB+) and create 100K+
  // string copies via Copy(), only to immediately bail out at the
  // 20480-word check below. The repeated allocate→fill→free cycle
  // across many line pairs causes heap fragmentation and eventually
  // EAccessViolation. Checking byte length first avoids the massive
  // allocation entirely.
  //
  // Threshold: 100KB. Average token length is 3-5 bytes (words are
  // 3-10 chars, punctuation is 1 char), so 100KB ≈ 20K-33K tokens,
  // which is right around the 20480-word limit. Lines longer than
  // this almost never benefit from word-level char-diff (the diff
  // is too complex to be visually useful).
  if (Length(ATextA) > 100000) or (Length(ATextB) > 100000) then
  begin
    SetLength(Result, 1);
    Result[0].Tag := DIFF_TAG_REPLACE;
    Result[0].I1 := 0;
    Result[0].I2 := Length(ATextA);
    Result[0].J1 := 0;
    Result[0].J2 := Length(ATextB);
    Exit;
  end;

  // Step 1: tokenize both strings into words.
  Tokenize(ATextA, TokensA);
  Tokenize(ATextB, TokensB);

  // Step 2: WinMerge's size limit (stringdiffs.cpp line 398).
  // If either word array exceeds the token limit, skip word-level
  // diff and mark the entire line as one diff span. This prevents
  // pathological slowdowns on extremely long lines (e.g. minified JS).
  // WinMerge uses 20480 on 64-bit and 2048 on 32-bit (the O(NP)
  // algorithm allocates int[M+N+3] arrays — on 32-bit, 2048 keeps
  // the address space safe). We match that per-platform threshold.
  {$IFDEF CPU64}
  if (Length(TokensA) > 20480) or (Length(TokensB) > 20480) then
  {$ELSE}
  if (Length(TokensA) > 2048) or (Length(TokensB) > 2048) then
  {$ENDIF}
  begin
    SetLength(Result, 1);
    Result[0].Tag := DIFF_TAG_REPLACE;
    Result[0].I1 := 0;
    Result[0].I2 := Length(ATextA);
    Result[0].J1 := 0;
    Result[0].J2 := Length(ATextB);
    Exit;
  end;

  // Step 3: run word-level diff using Myers with pointer arithmetic.
  // Myers O(ND) with the pointer-arity + explicit-stack optimizations
  // is fast for typical word counts (10-1000 words per line).
  // For very long lines (5000+ words), Myers may be slower than O(NP),
  // but the size limit above caps the worst case.
  WordsA := TokensToStrings(TokensA);
  WordsB := TokensToStrings(TokensB);
  WordOpcodes := DoDiffLines(WordsA, WordsB, DIFF_ALGO_MYERS, AFlags);

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

    // Bounds-check the word indices against the token arrays. The diff
    // algorithm should always produce valid indices; this clamp is
    // defence-in-depth so a bug in the algorithm produces an empty
    // word range instead of an ERangeError or wrong memory being
    // read.
    if WAStart < 0 then WAStart := 0;
    if WAEnd > Length(TokensA) then WAEnd := Length(TokensA);
    if WAStart > WAEnd then WAStart := WAEnd;
    if WBStart < 0 then WBStart := 0;
    if WBEnd > Length(TokensB) then WBEnd := Length(TokensB);
    if WBStart > WBEnd then WBStart := WBEnd;

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
