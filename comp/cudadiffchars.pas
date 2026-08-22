(*
  CudaDiffChars — Char-level diff engine (stub for Phase 1).

  This unit is a STUB. It implements the infrastructure needed to satisfy
  the diff_proc(DIF_CHARS, ...) API contract: it accepts two strings,
  converts them to UTF-32 code point arrays (the encoding the future
  WinMerge stringdiffs port will use), and returns a single REPLACE opcode
  covering the entire input (or [] if both inputs are empty).

  The real char-diff implementation (ported from WinMerge's stringdiffs.cpp)
  will be added in a later phase. The conversion infrastructure
  (TCodePoint, TCodePointArray, UTF8ToUTF32) is in place now so the future
  port just needs to plug in the tokenizer + Myers-on-code-points algorithm.

  ----------------------------------------------------------------
  Encoding decision: UTF-32 (not UTF-8)
  ----------------------------------------------------------------
  Why UTF-32 instead of UTF-8 bytes (like CudaDiff.pas uses)?

  1. Index alignment: array[i] in Pascal UTF-32 = str[i] in Python (both
     are code point indices). No translation needed at exit.

  2. WinMerge compatibility: WinMerge's stringdiffs.cpp uses wchar_t
     (UTF-16). UTF-32 is the natural Pascal equivalent — each array
     element is one code point, like wchar_t but without surrogate-pair
     complexity. Porting stringdiffs to UTF-32 is cleaner than porting
     to UTF-8 (which would require byte-walking logic for every
     comparison).

  3. Random access: UTF-32 allows O(1) random access by code point.
     UTF-8 requires O(N) walks. WinMerge's stringdiffs does token
     classification by examining individual characters — UTF-32 makes
     this trivial.

  4. Memory: 4 bytes per code point. For a 100k-char line (the Differ
     plugin's bail-out limit), that's 400KB. Acceptable — char-diff
     processes one line pair at a time, memory is freed between calls.

  5. Astral characters: UTF-32 handles emoji, rare CJK, and other
     supplementary-plane characters as single elements. UTF-16 would
     require surrogate-pair handling; UTF-8 would require 4-byte
     sequence handling. UTF-32 has neither problem.

  The conversion happens ONCE at entry, via UTF8ToUTF32(). The diff
  algorithm operates on TCodePointArray. Output indices are Length(array)
  — directly correct, no translation.

  This applies to BOTH this stub and the future WinMerge port. The stub
  establishes the UTF-32 conversion infrastructure now, so the real
  implementation just plugs in the tokenizer + Myers on code points.

  For DIF_TEXTS: this is NOT an issue. DIF_TEXTS indices are LINE
  indices (encoding-agnostic — line count is the same regardless of
  encoding). cudadiff.pas stays UTF-8 bytes (matching JGit). Only
  this unit (cudadiffchars.pas) uses UTF-32.

  ----------------------------------------------------------------
  Standalone — zero dependencies on CudaDiff
  ----------------------------------------------------------------
  Per G14/G15/G27, this unit must be completely standalone:
  - Does NOT `uses CudaDiff;`
  - Defines its own TDiffOpcode and TDiffOpcodeArray (same layout as
    CudaDiff.TDiffOpcode but a SEPARATE Pascal type — must not alias).
  - Does NOT define DIFF_TAG_* constants (those are in proc_py_const.pas).
    Uses integer literals 0/1/2/3 when filling the Tag field, with
    private aliases below for readability.
  - Does NOT define TStringArray (no public function uses it).

  The formmain_py_api.inc accesses these types as
  CudaDiffChars.TDiffOpcodeArray — distinct from CudaDiff.TDiffOpcodeArray.

  ----------------------------------------------------------------
  Future port — WinMerge stringdiffs
  ----------------------------------------------------------------
  The real implementation will port WinMerge's Src/stringdiffs.cpp. The
  plan (G15) describes the encoding/infrastructure contract this stub
  satisfies; the future port will replace DoDiffChars with a real
  tokenizer + Myers-on-code-points implementation, reusing UTF8ToUTF32
  for input conversion.

  WinMerge's stringdiffs.cpp uses wchar_t (UTF-16) internally. Porting
  to UTF-32 (UInt32 code points) is cleaner — each array element is one
  code point, no surrogate pairs to worry about.
*)

unit CudaDiffChars;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

{ Opcode tag values — must match proc_py_const.pas DIFF_TAG_*.
  We use integer literals directly (G13: do NOT redefine DIFF_TAG_*
  in cudadiff.pas/cudadiffchars.pas). Private aliases below for readability. }
const
  cTagEqual   = 0;  // DIFF_TAG_EQUAL
  cTagDelete  = 1;  // DIFF_TAG_DELETE
  cTagInsert  = 2;  // DIFF_TAG_INSERT
  cTagReplace = 3;  // DIFF_TAG_REPLACE

type
  { Public opcode type. Same layout as CudaDiff.TDiffOpcode but a
    SEPARATE Pascal type (G14) — the two units must not alias.
    formmain_py_api.inc accesses them as CudaDiffChars.TDiffOpcodeArray
    vs. CudaDiff.TDiffOpcodeArray. }
  TDiffOpcode = record
    Tag: Integer;   // 0=equal, 1=delete, 2=insert, 3=replace
    I1, I2, J1, J2: Integer;
  end;
  TDiffOpcodeArray = array of TDiffOpcode;

  { One Unicode code point. UTF-32 = 4 bytes per code point.
    Matches WinMerge's wchar_t in semantic role, but uses 4 bytes
    instead of 2 to avoid surrogate-pair complexity for astral
    characters (emoji, rare CJK). }
  TCodePoint = UInt32;
  TCodePointArray = array of TCodePoint;

{ Convert a UTF-8 Pascal string (AnsiString under objfpc mode with $H+)
  to a UTF-32 code point array.

  - Correctly handles 1/2/3/4-byte UTF-8 sequences.
  - Rejects invalid UTF-8 by raising EArgumentException
    (the API wrapper in formmain_py_api.inc catches exceptions and
    returns None to Python, which the Differ plugin handles by
    falling back to a single REPLACE).
  - Returns empty array for empty input.

  Future WinMerge port: this function becomes the entry point that
  feeds code points into the stringdiffs tokenizer. The tokenizer
  will iterate the resulting TCodePointArray to classify tokens
  (word, whitespace, punctuation), then Myers-diff the token lists. }
function UTF8ToUTF32(const S: string): TCodePointArray;

{ Char-level diff entry point — called by formmain_py_api.inc.

  Stub behavior:
    - Both inputs empty -> return [] (matches difflib: [] for both-empty)
    - Otherwise -> return a single REPLACE opcode with I2 = code point
      count of A, J2 = code point count of B.

  AFlags is accepted but ignored (stub has no comparison logic to
  apply flags to). When the real char-diff is implemented later, flags
  will be respected (case/whitespace/numbers in the same way as
  DIF_TEXTS, but applied per code point rather than per byte).

  The stub must NOT crash on:
    - Empty strings -> UTF8ToUTF32 returns []
    - Identical strings -> still returns REPLACE (stub doesn't compare)
    - Very long strings (>100k chars — the Differ plugin bails out before
      calling for longer, but be defensive: 400KB allocation for 100k
      chars is fine)
    - Strings with embedded \0 (valid UTF-8, just U+0000 code point)
    - Strings with astral characters (emoji, 4-byte UTF-8 sequences)
    - Invalid UTF-8 -> raise EArgumentException (caller handles via
      try/except)

  Note: This exception is NOT caught inside this unit. It propagates
  up to formmain_py_api.inc's try/except wrapper, which logs the error
  and returns None to Python. The Differ plugin handles None by
  falling back to a single REPLACE. This matches the exception-handling
  policy in G23 (do NOT catch exceptions inside the diff unit — let
  them propagate so the wrapper can log them). }
function DoDiffChars(const ATextA, ATextB: string; AFlags: Integer): TDiffOpcodeArray;

implementation

function UTF8ToUTF32(const S: string): TCodePointArray;
{ Convert UTF-8 Pascal string to a UTF-32 code point array.

  UTF-8 encoding rules (from RFC 3629):
    1 byte:  0xxxxxxx                            -> U+0000..U+007F
    2 bytes: 110xxxxx 10xxxxxx                   -> U+0080..U+07FF
    3 bytes: 1110xxxx 10xxxxxx 10xxxxxx          -> U+0800..U+FFFF
    4 bytes: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx -> U+10000..U+10FFFF

  This function:
    - Decodes each UTF-8 sequence into a single UInt32 code point.
    - Validates sequences (correct lead byte, correct continuation bytes,
      no overlong encodings, no code points > U+10FFFF).
    - Allocates the output array up-front (worst case: 1 code point per
      byte, so Length(S) entries) and trims at the end.
    - Returns empty array for empty input.

  DIVERGENCE NOTE: This function does NOT exist in JGit (JGit operates
  on byte arrays, not code points). It's part of the future WinMerge
  stringdiffs port infrastructure (G15). }
var
  n, i, outCount: Integer;
  raw: PByte;
  cp: UInt32;
  b1, b2, b3, b4: Byte;
  tempOut: array of UInt32;
begin
  n := Length(S);
  if n = 0 then
  begin
    Result := nil;
    SetLength(Result, 0);
    Exit;
  end;

  raw := PByte(Pointer(S));
  // Worst case: 1 code point per byte (pure ASCII). +1 for safety.
  SetLength(tempOut, n);
  outCount := 0;

  i := 0;
  while i < n do
  begin
    b1 := raw[i];
    Inc(i);

    if b1 < $80 then
    begin
      // 1-byte sequence: U+0000..U+007F.
      cp := b1;
    end
    else if (b1 and $E0) = $C0 then
    begin
      // 2-byte sequence: U+0080..U+07FF.
      if i >= n then
        raise EArgumentException.Create('UTF8ToUTF32: truncated 2-byte UTF-8 sequence');
      b2 := raw[i];
      Inc(i);
      if (b2 and $C0) <> $80 then
        raise EArgumentException.Create('UTF8ToUTF32: invalid continuation byte (2-byte seq)');
      cp := ((UInt32(b1) and $1F) shl 6) or (UInt32(b2) and $3F);
      // Overlong check: minimum 2-byte encoding is U+0080.
      if cp < $80 then
        raise EArgumentException.Create('UTF8ToUTF32: overlong 2-byte UTF-8 sequence');
    end
    else if (b1 and $F0) = $E0 then
    begin
      // 3-byte sequence: U+0800..U+FFFF.
      if i + 1 >= n then
        raise EArgumentException.Create('UTF8ToUTF32: truncated 3-byte UTF-8 sequence');
      b2 := raw[i];
      b3 := raw[i + 1];
      Inc(i, 2);
      if (b2 and $C0) <> $80 then
        raise EArgumentException.Create('UTF8ToUTF32: invalid continuation byte (3-byte seq, byte 2)');
      if (b3 and $C0) <> $80 then
        raise EArgumentException.Create('UTF8ToUTF32: invalid continuation byte (3-byte seq, byte 3)');
      cp := ((UInt32(b1) and $0F) shl 12)
         or ((UInt32(b2) and $3F) shl 6)
         or (UInt32(b3) and $3F);
      // Overlong check: minimum 3-byte encoding is U+0800.
      if cp < $800 then
        raise EArgumentException.Create('UTF8ToUTF32: overlong 3-byte UTF-8 sequence');
      // Surrogates (U+D800..U+DFFF) are not valid code points in UTF-8.
      if (cp >= $D800) and (cp <= $DFFF) then
        raise EArgumentException.Create('UTF8ToUTF32: UTF-16 surrogate code point in UTF-8');
    end
    else if (b1 and $F8) = $F0 then
    begin
      // 4-byte sequence: U+10000..U+10FFFF.
      if i + 2 >= n then
        raise EArgumentException.Create('UTF8ToUTF32: truncated 4-byte UTF-8 sequence');
      b2 := raw[i];
      b3 := raw[i + 1];
      b4 := raw[i + 2];
      Inc(i, 3);
      if (b2 and $C0) <> $80 then
        raise EArgumentException.Create('UTF8ToUTF32: invalid continuation byte (4-byte seq, byte 2)');
      if (b3 and $C0) <> $80 then
        raise EArgumentException.Create('UTF8ToUTF32: invalid continuation byte (4-byte seq, byte 3)');
      if (b4 and $C0) <> $80 then
        raise EArgumentException.Create('UTF8ToUTF32: invalid continuation byte (4-byte seq, byte 4)');
      cp := ((UInt32(b1) and $07) shl 18)
         or ((UInt32(b2) and $3F) shl 12)
         or ((UInt32(b3) and $3F) shl 6)
         or (UInt32(b4) and $3F);
      // Overlong check: minimum 4-byte encoding is U+10000.
      if cp < $10000 then
        raise EArgumentException.Create('UTF8ToUTF32: overlong 4-byte UTF-8 sequence');
      // Maximum valid Unicode code point is U+10FFFF.
      if cp > $10FFFF then
        raise EArgumentException.Create('UTF8ToUTF32: code point exceeds U+10FFFF');
    end
    else
    begin
      // Invalid lead byte: $80-$BF (continuation byte with no preceding lead),
      // $F8-$FF (would be 5+ byte sequence, not valid in UTF-8).
      raise EArgumentException.Create('UTF8ToUTF32: invalid UTF-8 lead byte');
    end;

    tempOut[outCount] := cp;
    Inc(outCount);
  end;

  // Copy to result of exact size.
  SetLength(Result, outCount);
  if outCount > 0 then
    Move(tempOut[0], Result[0], outCount * SizeOf(TCodePoint));
end;

function DoDiffChars(const ATextA, ATextB: string; AFlags: Integer): TDiffOpcodeArray;
{ Stub implementation per G15. Converts inputs to UTF-32 (to validate
  the input and exercise the conversion infrastructure), then returns
  a single REPLACE opcode covering everything (or [] if both empty). }
var
  CPA, CPB: TCodePointArray;
begin
  Result := nil;  // silence "managed type not initialized" warning

  CPA := UTF8ToUTF32(ATextA);
  CPB := UTF8ToUTF32(ATextB);

  if (Length(CPA) = 0) and (Length(CPB) = 0) then
  begin
    SetLength(Result, 0);  // matches difflib: [] for both-empty
    Exit;
  end;

  SetLength(Result, 1);
  Result[0].Tag := cTagReplace;  // DIFF_TAG_REPLACE
  Result[0].I1 := 0;
  Result[0].I2 := Length(CPA);   // code point count, not byte count
  Result[0].J1 := 0;
  Result[0].J2 := Length(CPB);
end;

end.
