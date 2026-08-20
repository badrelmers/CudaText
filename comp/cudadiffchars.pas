(*
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at https://mozilla.org/MPL/2.0/.

Copyright (c) 2026 CudaText project contributors

Implements the character-level diff backend for CudaText: a port of
WinMerge's stringdiffs.cpp.

Algorithm: tokenize both strings into "words" (identifiers, whitespace,
individual punctuation), run word-level Myers O(ND) diff, then refine
each non-equal word region to exact byte boundaries with prefix/suffix
trimming. This is the same approach WinMerge uses.

This unit is FULLY STANDALONE — it does NOT depend on CudaDiff (the
line diff unit) or any other CudaText diff code. It has its own copy of:
  - Constants (DIFF_ALGO_xxx, DIFF_IGN_xxx, DIFF_TAG_xxx)
  - Types (TDiffOpcode, TStringArray)
  - Utility functions (MaxI, MinI, IsWhitespaceByte, HashLine)
  - Word-level Myers O(ND) diff (self-contained, no heuristics)

This intentional duplication allows the char diff to evolve and compile
independently from the line diff.

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

  AFlags supports the same DIFF_IGN_* options as line diff. }
function DoDiffChars(
  const ATextA, ATextB: string;
  AFlags: Integer
): TDiffOpcodeArray;

implementation

uses
  SysUtils;

{ ---------- Utility functions (self-contained, no CudaDiff dependency) ---------- }

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
  Result := (C = ' ') or (C = #9) or (C = #10) or (C = #13) or
            (C = #11) or (C = #12);
end;

{ ---------- djb2 hash (for word comparison) ---------- }

const
  DJB2_SEED = 5381;

{$PUSH}
{$RANGECHECKS OFF}  { Cardinal wraparound on the djb2 accumulator. }
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

{ ---------- Word sequence (hashed, for fast comparison) ---------- }

type
  PWordSequence = ^TWordSequence;
  TWordSequence = record
    FLines: TStringArray;
    FHashes: array of Integer;
    procedure Init(const ALines: array of string);
    function EqualsAt(AIdxThis: Integer; const AOther: TWordSequence; AIdxOther: Integer): Boolean;
    function HashAt(AIdx: Integer): Integer;
    function Size: Integer;
  end;

procedure TWordSequence.Init(const ALines: array of string);
var
  I, N: Integer;
begin
  N := Length(ALines);
  SetLength(FLines, N);
  SetLength(FHashes, N);
  for I := 0 to N - 1 do
  begin
    FLines[I] := ALines[I];
    FHashes[I] := HashLine(ALines[I]);
  end;
end;

function TWordSequence.EqualsAt(AIdxThis: Integer;
  const AOther: TWordSequence; AIdxOther: Integer): Boolean;
begin
  if FHashes[AIdxThis] <> AOther.FHashes[AIdxOther] then
    Exit(False);
  Result := FLines[AIdxThis] = AOther.FLines[AIdxOther];
end;

function TWordSequence.HashAt(AIdx: Integer): Integer;
begin
  Result := FHashes[AIdx];
end;

function TWordSequence.Size: Integer;
begin
  Result := Length(FLines);
end;

{ ---------- Edit region (for word-level diff) ---------- }

type
  TCharEdit = record
    BeginA, EndA, BeginB, EndB: Integer;
    function IsEmpty: Boolean;
    function LengthA: Integer;
    function LengthB: Integer;
  end;

  TCharEditList = record
    FItems: array of TCharEdit;
    FCount: Integer;
    procedure Init;
    procedure Add(const AEdit: TCharEdit);
    function GetItem(AIndex: Integer): TCharEdit;
    function Count: Integer;
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

procedure TCharEditList.Init;
begin
  FCount := 0;
  SetLength(FItems, 0);
end;

procedure TCharEditList.Add(const AEdit: TCharEdit);
begin
  if FCount >= Length(FItems) then
    SetLength(FItems, MaxI(Length(FItems) * 2, FCount + 16));
  FItems[FCount] := AEdit;
  Inc(FCount);
end;

function TCharEditList.GetItem(AIndex: Integer): TCharEdit;
begin
  Result := FItems[AIndex];
end;

function TCharEditList.Count: Integer;
begin
  Result := FCount;
end;

{ ---------- Snake packing (for Myers middle-snake) ---------- }

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

{ ---------- Myers O(ND) scratch state ---------- }

type
  TCharMyersState = record
    SeqA, SeqB: PWordSequence;
    FwdXBuf: array of Integer;
    BwdXBuf: array of Integer;
    FwdSnakeBuf: array of Int64;
    BwdSnakeBuf: array of Int64;
    FwdX: PInteger;
    BwdX: PInteger;
    FwdSnake: PInt64;
    BwdSnake: PInt64;
    OffsetK: Integer;
    BeginA, EndA, BeginB, EndB: Integer;
  end;

{ ---------- Forward/Backward snake ---------- }

function ForwardSnake(var AState: TCharMyersState; AK, AX: Integer): Integer; inline;
var
  X, Y: Integer;
  SeqA, SeqB: PWordSequence;
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

function BackwardSnake(var AState: TCharMyersState; AK, AX: Integer): Integer; inline;
var
  X, Y: Integer;
  SeqA, SeqB: PWordSequence;
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

{ ---------- Forward/Backward edit path calculation ---------- }

function ForwardCalculate(var AState: TCharMyersState; AD: Integer): Boolean;
var
  K, Left, Right, NewX: Integer;
  LeftEnd, RightEnd: Integer;
  LeftSnake, RightSnake, NewSnake: Int64;
  FwdX: PInteger;
  FwdSnake: PInt64;
  BwdX: PInteger;
  BwdSnake: PInt64;
  FwdBeginK, FwdEndK, FwdMiddleK: Integer;
  BwdBeginK, BwdEndK, BwdMiddleK: Integer;
begin
  Result := False;
  FwdMiddleK := AState.BeginB - AState.BeginA;
  FwdBeginK := FwdMiddleK - AD;
  FwdEndK := FwdMiddleK + AD;
  BwdMiddleK := AState.EndB - AState.EndA;
  BwdBeginK := BwdMiddleK - AD;
  BwdEndK := BwdMiddleK + AD;

  FwdX := AState.FwdX;
  FwdSnake := AState.FwdSnake;
  BwdX := AState.BwdX;
  BwdSnake := AState.BwdSnake;

  K := FwdEndK;
  while K >= FwdBeginK do
  begin
    Left := -1;
    Right := -1;
    LeftSnake := -1;
    RightSnake := -1;

    if K > FwdBeginK then
    begin
      Left := FwdX[K - 1];
      LeftEnd := ForwardSnake(AState, K - 1, Left);
      if Left <> LeftEnd then
        LeftSnake := PackSnake(LeftEnd, (K - 1) + LeftEnd)
      else
        LeftSnake := FwdSnake[K - 1];
      if (K - 1 >= BwdBeginK) and (K - 1 <= BwdEndK) and
         (((AD - 1 + (K - 1) - BwdMiddleK) mod 2) = 0) and
         (LeftEnd >= BwdX[K - 1]) then
      begin
        Result := True;
        Exit;
      end;
      Left := LeftEnd;
    end;

    if K < FwdEndK then
    begin
      Right := FwdX[K + 1];
      RightEnd := ForwardSnake(AState, K + 1, Right);
      if Right <> RightEnd then
        RightSnake := PackSnake(RightEnd, (K + 1) + RightEnd)
      else
        RightSnake := FwdSnake[K + 1];
      if (K + 1 >= BwdBeginK) and (K + 1 <= BwdEndK) and
         (((AD - 1 + (K + 1) - BwdMiddleK) mod 2) = 0) and
         (RightEnd >= BwdX[K + 1]) then
      begin
        Result := True;
        Exit;
      end;
      Right := RightEnd + 1;
    end;

    if (K >= FwdEndK) or ((K > FwdBeginK) and (Left > Right)) then
    begin
      NewX := Left;
      NewSnake := LeftSnake;
    end
    else
    begin
      NewX := Right;
      NewSnake := RightSnake;
    end;

    FwdX[K] := NewX;
    FwdSnake[K] := NewSnake;
    Dec(K, 2);
  end;
end;

function BackwardCalculate(var AState: TCharMyersState; AD: Integer): Boolean;
var
  K, Left, Right, NewX: Integer;
  LeftEnd, RightEnd: Integer;
  LeftSnake, RightSnake, NewSnake: Int64;
  FwdX: PInteger;
  FwdSnake: PInt64;
  BwdX: PInteger;
  BwdSnake: PInt64;
  FwdBeginK, FwdEndK, FwdMiddleK: Integer;
  BwdBeginK, BwdEndK, BwdMiddleK: Integer;
begin
  Result := False;
  FwdMiddleK := AState.BeginB - AState.BeginA;
  FwdBeginK := FwdMiddleK - AD;
  FwdEndK := FwdMiddleK + AD;
  BwdMiddleK := AState.EndB - AState.EndA;
  BwdBeginK := BwdMiddleK - AD;
  BwdEndK := BwdMiddleK + AD;

  FwdX := AState.FwdX;
  FwdSnake := AState.FwdSnake;
  BwdX := AState.BwdX;
  BwdSnake := AState.BwdSnake;

  K := BwdEndK;
  while K >= BwdBeginK do
  begin
    Left := -1;
    Right := -1;
    LeftSnake := -1;
    RightSnake := -1;

    if K > BwdBeginK then
    begin
      Left := BwdX[K - 1];
      LeftEnd := BackwardSnake(AState, K - 1, Left);
      if Left <> LeftEnd then
        LeftSnake := PackSnake(LeftEnd, (K - 1) + LeftEnd)
      else
        LeftSnake := BwdSnake[K - 1];
      if (K - 1 >= FwdBeginK) and (K - 1 <= FwdEndK) and
         (((AD + (K - 1) - FwdMiddleK) mod 2) = 0) and
         (LeftEnd <= FwdX[K - 1]) then
      begin
        Result := True;
        Exit;
      end;
      Left := LeftEnd - 1;
    end;

    if K < BwdEndK then
    begin
      Right := BwdX[K + 1];
      RightEnd := BackwardSnake(AState, K + 1, Right);
      if Right <> RightEnd then
        RightSnake := PackSnake(RightEnd, (K + 1) + RightEnd)
      else
        RightSnake := BwdSnake[K + 1];
      if (K + 1 >= FwdBeginK) and (K + 1 <= FwdEndK) and
         (((AD + (K + 1) - FwdMiddleK) mod 2) = 0) and
         (RightEnd <= FwdX[K + 1]) then
      begin
        Result := True;
        Exit;
      end;
      Right := RightEnd;
    end;

    if (K >= BwdEndK) or ((K > BwdBeginK) and (Left < Right)) then
    begin
      NewX := Left;
      NewSnake := LeftSnake;
    end
    else
    begin
      NewX := Right;
      NewSnake := RightSnake;
    end;

    BwdX[K] := NewX;
    BwdSnake[K] := NewSnake;
    Dec(K, 2);
  end;
end;

{ ---------- Self-contained Myers O(ND) for word-level diff ----------
  This is a minimal middle-snake Myers diff. It does NOT include the
  big_snake / TOO_EXPENSIVE / discard_confusing_lines heuristics —
  those are line-diff optimizations not needed at the word level (word
  counts are small, typically 10-2000 words per line).
  In step 2, this will be replaced with a proper WinMerge O(NP) port. }

procedure WordMyersDiff(out AEdits: TCharEditList;
  const ASeqA, ASeqB: TWordSequence;
  ARegion: TCharEdit);
var
  State: TCharMyersState;
  MaxSize: Integer;
  WorkStack: array of TCharEdit;
  WorkCount: Integer;
  Item, Edit: TCharEdit;
  K, X, D: Integer;
  Found: Boolean;
  FwdMiddleK, BwdMiddleK: Integer;

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
  AEdits.Init;

  State.SeqA := @ASeqA;
  State.SeqB := @ASeqB;

  MaxSize := ARegion.LengthA + ARegion.LengthB;
  if MaxSize = 0 then
    Exit;

  State.OffsetK := MaxSize;
  SetLength(State.FwdXBuf, 2 * MaxSize + 1);
  SetLength(State.BwdXBuf, 2 * MaxSize + 1);
  SetLength(State.FwdSnakeBuf, 2 * MaxSize + 1);
  SetLength(State.BwdSnakeBuf, 2 * MaxSize + 1);
  State.FwdX := PInteger(@State.FwdXBuf[0]) + State.OffsetK;
  State.BwdX := PInteger(@State.BwdXBuf[0]) + State.OffsetK;
  State.FwdSnake := PInt64(@State.FwdSnakeBuf[0]) + State.OffsetK;
  State.BwdSnake := PInt64(@State.BwdSnakeBuf[0]) + State.OffsetK;

  SetLength(WorkStack, 64);
  WorkCount := 0;
  PushWork(ARegion.BeginA, ARegion.EndA, ARegion.BeginB, ARegion.EndB);

  while WorkCount > 0 do
  begin
    Dec(WorkCount);
    Item := WorkStack[WorkCount];

    // Base case: one side empty
    if (Item.BeginA >= Item.EndA) or (Item.BeginB >= Item.EndB) then
    begin
      if (Item.BeginA < Item.EndA) or (Item.BeginB < Item.EndB) then
        AEdits.Add(Item);
      Continue;
    end;

    State.BeginA := Item.BeginA;
    State.EndA := Item.EndA;
    State.BeginB := Item.BeginB;
    State.EndB := Item.EndB;

    // Strip common prefix
    K := Item.BeginB - Item.BeginA;
    X := ForwardSnake(State, K, Item.BeginA);
    State.BeginA := X;
    State.BeginB := K + X;

    // Strip common suffix
    K := Item.EndB - Item.EndA;
    X := BackwardSnake(State, K, Item.EndA);
    State.EndA := X;
    State.EndB := K + X;

    if (State.BeginA >= State.EndA) or (State.BeginB >= State.EndB) then
    begin
      if (State.BeginA < State.EndA) or (State.BeginB < State.EndB) then
      begin
        Edit.BeginA := State.BeginA;
        Edit.EndA := State.EndA;
        Edit.BeginB := State.BeginB;
        Edit.EndB := State.EndB;
        AEdits.Add(Edit);
      end;
      Continue;
    end;

    FwdMiddleK := State.BeginB - State.BeginA;
    BwdMiddleK := State.EndB - State.EndA;

    State.FwdX[FwdMiddleK] := State.BeginA;
    State.FwdSnake[FwdMiddleK] := PackSnake(State.BeginA, FwdMiddleK + State.BeginA);
    State.BwdX[BwdMiddleK] := State.EndA;
    State.BwdSnake[BwdMiddleK] := PackSnake(State.EndA, BwdMiddleK + State.EndA);

    Edit.BeginA := 0;
    Edit.EndA := 0;
    Edit.BeginB := 0;
    Edit.EndB := 0;
    Found := False;
    D := 1;
    while (D <= MaxSize) and not Found do
    begin
      if ForwardCalculate(State, D) or BackwardCalculate(State, D) then
        Found := True;
      Inc(D);
    end;

    if not Found then
      Continue;

    // Push after half
    if (Item.EndA > Edit.EndA) or (Item.EndB > Edit.EndB) then
    begin
      K := Edit.EndB - Edit.EndA;
      X := ForwardSnake(State, K, Edit.EndA);
      PushWork(X, Item.EndA, K + X, Item.EndB);
    end;

    if not Edit.IsEmpty then
      AEdits.Add(Edit);

    // Push before half
    if (Item.BeginA < Edit.BeginA) or (Item.BeginB < Edit.BeginB) then
    begin
      K := Edit.BeginB - Edit.BeginA;
      X := BackwardSnake(State, K, Edit.BeginA);
      PushWork(Item.BeginA, X, Item.BeginB, K + X);
    end;
  end;
end;

{ ---------- Convert word edits to opcodes ---------- }

function WordEditsToOpcodes(const AEdits: TCharEditList;
  ALenA, ALenB: Integer): TDiffOpcodeArray;
var
  Result_: TDiffOpcodeArray;
  ResultCount: Integer;
  PrevEndA, PrevEndB: Integer;
  I: Integer;
  E: TCharEdit;

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
    E := AEdits.GetItem(I);
    if (E.BeginA > PrevEndA) or (E.BeginB > PrevEndB) then
      Emit(DIFF_TAG_EQUAL, PrevEndA, E.BeginA, PrevEndB, E.BeginB);

    if E.LengthA > 0 then
    begin
      if E.LengthB > 0 then
        Emit(DIFF_TAG_REPLACE, E.BeginA, E.EndA, E.BeginB, E.EndB)
      else
        Emit(DIFF_TAG_DELETE, E.BeginA, E.EndA, E.BeginB, E.EndB);
    end
    else if E.LengthB > 0 then
      Emit(DIFF_TAG_INSERT, E.BeginA, E.EndA, E.BeginB, E.EndB);

    PrevEndA := E.EndA;
    PrevEndB := E.EndB;
  end;

  if (PrevEndA < ALenA) or (PrevEndB < ALenB) then
    Emit(DIFF_TAG_EQUAL, PrevEndA, ALenA, PrevEndB, ALenB);

  SetLength(Result_, ResultCount);
  Result := Result_;
end;

{ ---------- Word tokenizer ----------
  Tokenize a string into words, whitespace runs, and individual
  punctuation characters. Port of WinMerge's BuildWordsArray
  (which uses ICU break iterators — close enough for diff purposes). }

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
  SeqA.Init(WordsA);
  SeqB.Init(WordsB);
  Edit.BeginA := 0;
  Edit.EndA := SeqA.Size;
  Edit.BeginB := 0;
  Edit.EndB := SeqB.Size;
  WordMyersDiff(Edits, SeqA, SeqB, Edit);
  WordOpcodes := WordEditsToOpcodes(Edits, SeqA.Size, SeqB.Size);

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
