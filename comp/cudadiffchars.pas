(*
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.

Copyright (c) 2026 CudaText project contributors

Implements the character-level diff backend for CudaText: a port of
WinMerge's stringdiffs.cpp.

Algorithm: tokenize both strings into "words" (identifiers, whitespace,
individual punctuation), run word-level Myers diff (copied from the
line diff unit, including big_snake and TOO_EXPENSIVE heuristics),
then refine each non-equal word region to exact byte boundaries with
prefix/suffix trimming.

This unit is FULLY STANDALONE. The Myers implementation is a direct
copy of the one in cudadiff.pas, with types renamed to avoid collisions.

Public entry point:
  - DoDiffChars: compares two strings at character granularity, returns
    difflib-style opcodes (5-tuples: tag, i1, i2, j1, j2).
*)
unit CudaDiffChars;

{$mode objfpc}{$H+}
{$ModeSwitch advancedrecords}

interface

const
  { Algorithm selectors (duplicated from CudaDiff for independence). }
  DIFF_ALGO_MYERS     = 0;
  DIFF_ALGO_HISTOGRAM = 1;

  { Bitmask flags (duplicated from CudaDiff for independence). }
  DIFF_IGN_NONE                 = 0;
  DIFF_IGN_CASE                 = 1;
  DIFF_IGN_WHITESPACE           = 2;
  DIFF_IGN_WHITESPACE_CHANGE    = 4;
  DIFF_IGN_WHITESPACE_EOL       = 8;
  DIFF_IGN_WHITESPACE_BEGINNING = 16;
  DIFF_IGN_BLANK_LINES          = 32;
  DIFF_IGN_EOL                  = 64;
  DIFF_IGN_NUMBERS              = 128;

  { Opcode tag values (duplicated from CudaDiff for independence). }
  DIFF_TAG_EQUAL   = 0;
  DIFF_TAG_DELETE  = 1;
  DIFF_TAG_INSERT  = 2;
  DIFF_TAG_REPLACE = 3;

type
  TStringArray = array of string;

  { A single difflib-compatible opcode (duplicated from CudaDiff). }
  TDiffOpcode = record
    Tag: Integer;
    I1, I2, J1, J2: Integer;
  end;
  TDiffOpcodeArray = array of TDiffOpcode;

{ Compare two strings at character granularity. Returns char-level
  opcodes (tag, a_start, a_end, b_start, b_end) where offsets are
  character positions into ATextA / ATextB. Same difflib format as
  DoDiffLines, just at character instead of line granularity.

  Uses the WinMerge approach: tokenize both strings into words
  (identifiers, whitespace, individual punctuation), run word-level
  Myers diff, then refine each non-equal word region to exact byte
  boundaries with prefix/suffix trimming.

  AFlags supports the same DIFF_IGN_xxx options as line diff. }
function DoDiffChars(
  const ATextA, ATextB: string;
  AFlags: Integer
): TDiffOpcodeArray;

implementation

uses
  SysUtils;

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

type
  TCharEditType = (cetInsert, cetDelete, cetReplace, cetEmpty);

  { A modified region between two sequences. Mirrors JGit's Edit class.
    All indices are 0-based, half-open [begin, end). Mutable by design
    (the algorithms adjust begin/end in place during prefix/suffix trim
    and edit normalization). }
  TCharEdit = record
    BeginA, EndA, BeginB, EndB: Integer;
    function GetType: TCharEditType;
    function IsEmpty: Boolean;
    function LengthA: Integer;
    function LengthB: Integer;
    procedure Shift(AAmount: Integer);
    class function Create(AAs, AAe, ABs, ABe: Integer): TCharEdit; static;
    function Before(const ACut: TCharEdit): TCharEdit;
    function After(const ACut: TCharEdit): TCharEdit;
  end;

  { Growable dynamic array of TCharEdit. Append is amortized O(1). }
  TCharEditList = record
    FItems: array of TCharEdit;
    FCount: Integer;
    procedure Init;
    procedure Add(const AEdit: TCharEdit);
    function GetItem(AIndex: Integer): TCharEdit;
    procedure SetItem(AIndex: Integer; const AEdit: TCharEdit);
    function Count: Integer;
    property Items[AIndex: Integer]: TCharEdit read GetItem write SetItem;
  end;

  PWordSequence = ^TWordSequence;

  { Wraps an array of lines together with their pre-computed hashes and
    (optionally) normalized copies used for ignore-flag matching.
    When AFlags = 0, FNormalized is empty and hashing/equality use the
    original lines directly (saves memory in the common case). }
  TWordSequence = record
    FLines: TStringArray;
    FNormalized: TStringArray;  // empty if no ignore flags
    FHashes: array of Integer;
    FHasNormalization: Boolean;
    procedure Init(const ALines: array of string; AFlags: Integer);
    function EqualsAt(AIdxThis: Integer; const AOther: TWordSequence; AIdxOther: Integer): Boolean;
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
  TCharMyersState = record
    SeqA, SeqB: PWordSequence;

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

    MiddleEdit: TCharEdit;
    BigSnake: Boolean;  { Set when a snake > SNAKE_LIMIT is found }
  end;

{ ---------- TCharEdit ---------- }

function TCharEdit.GetType: TCharEditType;
begin
  if BeginA < EndA then
  begin
    if BeginB < EndB then
      Exit(cetReplace);
    Exit(cetDelete);
  end;
  if BeginB < EndB then
    Exit(cetInsert);
  Result := cetEmpty;
end;

function TCharEdit.IsEmpty: Boolean;
begin
  Result := (BeginA = EndA) and (BeginB = EndB);
end;

function TCharEdit.LengthA: Integer;
begin
  Result := EndA - BeginA;
end;

function TCharEdit.LengthB: Integer;
begin
  Result := EndB - BeginB;
end;

procedure TCharEdit.Shift(AAmount: Integer);
begin
  Inc(BeginA, AAmount);
  Inc(EndA, AAmount);
  Inc(BeginB, AAmount);
  Inc(EndB, AAmount);
end;

class function TCharEdit.Create(AAs, AAe, ABs, ABe: Integer): TCharEdit;
begin
  Result.BeginA := AAs;
  Result.EndA := AAe;
  Result.BeginB := ABs;
  Result.EndB := ABe;
end;

function TCharEdit.Before(const ACut: TCharEdit): TCharEdit;
begin
  Result := TCharEdit.Create(BeginA, ACut.BeginA, BeginB, ACut.BeginB);
end;

function TCharEdit.After(const ACut: TCharEdit): TCharEdit;
begin
  Result := TCharEdit.Create(ACut.EndA, EndA, ACut.EndB, EndB);
end;


{ ---------- TCharEditList ---------- }

procedure TCharEditList.Init;
begin
  FItems := nil;
  FCount := 0;
end;

procedure TCharEditList.Add(const AEdit: TCharEdit);
var
  NewCap, I: Integer;
  NewItems: array of TCharEdit;
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

function TCharEditList.GetItem(AIndex: Integer): TCharEdit;
begin
  Result := FItems[AIndex];
end;

procedure TCharEditList.SetItem(AIndex: Integer; const AEdit: TCharEdit);
begin
  FItems[AIndex] := AEdit;
end;

function TCharEditList.Count: Integer;
begin
  Result := FCount;
end;


{ djb2 hash of a line's bytes. Matches JGit's RawTextComparator.hashRegion.
  Uses Cardinal (unsigned 32-bit) for the accumulator because the hash
  is designed to wrap around. }
const
  { Initial djb2 hash seed. Same as JGit's RawTextComparator. }
  DJB2_SEED = 5381;

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


{ ---------- TWordSequence ---------- }

procedure TWordSequence.Init(const ALines: array of string; AFlags: Integer);
var
  I, N: Integer;
begin
  N := Length(ALines);
  SetLength(FLines, N);
  FHasNormalization := False;
  FNormalized := nil;
  SetLength(FHashes, N);
  for I := 0 to N - 1 do
  begin
    FLines[I] := ALines[I];
    FHashes[I] := HashLine(ALines[I]);
  end;
end;

function TWordSequence.EqualsAt(AIdxThis: Integer;
  const AOther: TWordSequence; AIdxOther: Integer): Boolean;
var
  PA, PB: PAnsiChar;
  Len, I: Integer;
begin
  // CRITICAL: hash check FIRST (fast integer compare), then string equality
  // to verify the match. A hash collision without this check produces a
  // silently wrong diff which is nearly impossible to debug later.
  if FHashes[AIdxThis] <> AOther.FHashes[AIdxOther] then
    Exit(False);
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

function TWordSequence.HashAt(AIdx: Integer): Integer;
begin
  Result := FHashes[AIdx];
end;

function TWordSequence.Size: Integer;
begin
  Result := Length(FLines);
end;


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
function MakeMiddleEdit(AFwdSnake, ABwdSnake: Int64): TCharEdit; inline;
var
  X1, X2, Y1, Y2: Integer;
begin
  X1 := SnakeX(AFwdSnake);
  X2 := SnakeX(ABwdSnake);
  Y1 := SnakeY(AFwdSnake);
  Y2 := SnakeY(ABwdSnake);
  if X1 > X2 then X1 := X2;
  if Y1 > Y2 then Y1 := Y2;
  Result := TCharEdit.Create(X1, X2, Y1, Y2);
end;

function ForwardSnake(var AState: TCharMyersState; AK, AX: Integer): Integer; inline;
var
  X, Y, SnakeLen: Integer;
  SeqA, SeqB: PWordSequence;
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

function BackwardSnake(var AState: TCharMyersState; AK, AX: Integer): Integer; inline;
var
  X, Y, SnakeLen: Integer;
  SeqA, SeqB: PWordSequence;
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
function ForwardCalculate(var AState: TCharMyersState; AD: Integer): Boolean;
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
function BackwardCalculate(var AState: TCharMyersState; AD: Integer): Boolean;
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

type
  TCharWorkItem = record
    BeginA, EndA, BeginB, EndB: Integer;
  end;
  TCharWorkStack = array of TCharWorkItem;


function MyersDiffCore(
  out AEdits: TCharEditList;
  const ASeqA, ASeqB: TWordSequence;
  ARegion: TCharEdit
): Boolean;
var
  State: TCharMyersState;
  MaxSize: Integer;
  WorkStack: TCharWorkStack;
  WorkCount: Integer;
  Item: TCharWorkItem;
  Edit: TCharEdit;
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
        AEdits.Add(TCharEdit.Create(Item.BeginA, Item.EndA, Item.BeginB, Item.EndB));
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
        AEdits.Add(TCharEdit.Create(State.BeginA, State.EndA,
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
    Edit := TCharEdit.Create(0, 0, 0, 0);
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
            Edit := TCharEdit.Create(BestX, BestX, BestX - (BestX - State.BeginA + State.BeginB), BestX - (BestX - State.BeginA + State.BeginB));
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

function ReduceCommonStartEnd(
  const ASeqA, ASeqB: TWordSequence;
  AEdit: TCharEdit
): TCharEdit;
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
procedure NormalizeEdits(var AEdits: TCharEditList;
  const ASeqA, ASeqB: TWordSequence);
var
  I: Integer;
  Cur, Prev: TCharEdit;
  MaxA, MaxB: Integer;
  T: TCharEditType;
begin
  if AEdits.Count = 0 then Exit;
  Prev := TCharEdit.Create(0, 0, 0, 0);
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

    if T = cetInsert then
    begin
      while (Cur.EndA < MaxA) and (Cur.EndB < MaxB) and
            ASeqB.EqualsAt(Cur.BeginB, ASeqB, Cur.EndB) do
        Cur.Shift(1);
    end
    else if T = cetDelete then
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
function EditsToOpcodes(const AEdits: TCharEditList;
  ALenA, ALenB: Integer): TDiffOpcodeArray;
var
  Result_: TDiffOpcodeArray;
  ResultCount: Integer;
  PrevEndA, PrevEndB: Integer;
  I: Integer;
  E: TCharEdit;
  T: TCharEditType;

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
      cetInsert:  Emit(DIFF_TAG_INSERT,  E.BeginA, E.EndA, E.BeginB, E.EndB);
      cetDelete:  Emit(DIFF_TAG_DELETE,  E.BeginA, E.EndA, E.BeginB, E.EndB);
      cetReplace: Emit(DIFF_TAG_REPLACE, E.BeginA, E.EndA, E.BeginB, E.EndB);
      cetEmpty:   ;
    end;

    PrevEndA := E.EndA;
    PrevEndB := E.EndB;
  end;

  if (PrevEndA < ALenA) or (PrevEndB < ALenB) then
    Emit(DIFF_TAG_EQUAL, PrevEndA, ALenA, PrevEndB, ALenB);

  SetLength(Result_, ResultCount);
  Result := Result_;
end;

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

{ ---------- DoDiffChars: the public entry point ---------- }

function DoDiffChars(
  const ATextA, ATextB: string;
  AFlags: Integer
): TDiffOpcodeArray;
var
  TokensA, TokensB: TTokenArray;
  WordsA, WordsB: TStringArray;
  SeqA, SeqB: TWordSequence;
  WordOpcodes: TDiffOpcodeArray;
  Edits: TCharEditList;
  Edit: TCharEdit;
  I: Integer;
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
  SeqA.Init(WordsA, 0);
  SeqB.Init(WordsB, 0);
  Edit.BeginA := 0;
  Edit.EndA := SeqA.Size;
  Edit.BeginB := 0;
  Edit.EndB := SeqB.Size;
  Edit := ReduceCommonStartEnd(SeqA, SeqB, Edit);
  MyersDiffCore(Edits, SeqA, SeqB, Edit);
  NormalizeEdits(Edits, SeqA, SeqB);
  WordOpcodes := EditsToOpcodes(Edits, SeqA.Size, SeqB.Size);

  StrA := AnsiString(ATextA);
  StrB := AnsiString(ATextB);

  // Step 3: convert word-level opcodes to char-level opcodes.
  // For 'equal' opcodes, map word boundaries to char offsets directly.
  // For non-equal opcodes, refine with byte-level prefix/suffix trim.
  SetLength(Result_, MaxI(16, Length(WordOpcodes)));
  ResultCount := 0;

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
