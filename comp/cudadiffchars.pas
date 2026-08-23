(*
  CudaDiffChars — Char-level diff engine (WinMerge stringdiffs port).

  Ported from:
    https://github.com/WinMerge/winmerge/tree/v2.16.58/Src/stringdiffs.cpp
    https://github.com/WinMerge/winmerge/tree/v2.16.58/Src/stringdiffs.h
    https://github.com/WinMerge/winmerge/tree/v2.16.58/Src/stringdiffsi.h
    https://github.com/WinMerge/winmerge/tree/v2.16.58/Src/CompareOptions.h
    https://github.com/WinMerge/winmerge/tree/v2.16.58/Externals/crystaledit/editlib/utils/ctchar.h

  Pinned tag: v2.16.58
  License: BSD-3-Clause (WinMerge is GPL, but stringdiffs is distributed
  under the same license — see WinMerge source for details).

  ----------------------------------------------------------------
  What this unit provides
  ----------------------------------------------------------------
  Public API (called by formmain_py_api.inc):

    type
      TDiffOpcode = record Tag, I1, I2, J1, J2: Integer; end;
      TDiffOpcodeArray = array of TDiffOpcode;
      TCodePoint = UInt32;
      TCodePointArray = array of UInt32;

    function UTF8ToUTF32(const S: string): TCodePointArray;
    function DoDiffChars(const ATextA, ATextB: string;
                        AFlags: Integer): TDiffOpcodeArray;

  ----------------------------------------------------------------
  Source files ported
  ----------------------------------------------------------------
    WinMerge file                              | Pascal counterpart
    -------------------------------------------|---------------------------
    Src/stringdiffs.h                          | TEolCompareMode, Twdiff
    Src/stringdiffsi.h                         | TStringDiff, TWord, dl* word-class
    Src/stringdiffs.cpp:ComputeWordDiffs (2-string) | ComputeWordDiffs
    Src/stringdiffs.cpp:stringdiffs ctor       | TStringDiff.Create
    Src/stringdiffs.cpp:BuildWordDiffList      | TStringDiff.BuildWordDiffList
    Src/stringdiffs.cpp:BuildWordDiffList_DP   | TStringDiff.BuildWordDiffList_DP
    Src/stringdiffs.cpp:onp                    | TStringDiff.onp
    Src/stringdiffs.cpp:snake                  | TStringDiff.snake
    Src/stringdiffs.cpp:AreWordsSame           | TStringDiff.AreWordsSame
    Src/stringdiffs.cpp:Hash                   | TStringDiff.Hash (diffutils rolling hash)
    Src/stringdiffs.cpp:BuildWordsArray         | TStringDiff.BuildWordsArray
    Src/stringdiffs.cpp:PopulateDiffs          | TStringDiff.PopulateDiffs
    Src/stringdiffs.cpp:ComputeByteDiff         | TStringDiff.ComputeByteDiff
    Src/stringdiffs.cpp:wordLevelToByteLevel    | TStringDiff.wordLevelToByteLevel
    Src/stringdiffs.cpp:isSafeWhitespace        | isSafeWhitespace
    Src/stringdiffs.cpp:isWordBreak             | isWordBreak
    Src/stringdiffs.cpp:Init/SetBreakChars      | const BreakChars (fixed to default)
    Src/stringdiffs.cpp:matchchar               | matchchar
    Src/CompareOptions.h:WhitespaceIgnoreChoices | WHITESPACE_* constants
    Externals/crystaledit/editlib/utils/ctchar.h | tc_* helper functions (ASCII only)
    Externals/crystaledit/editlib/utils/icu.hpp | NOT PORTED (see G10)

  ----------------------------------------------------------------
  Documented divergences from WinMerge
  ----------------------------------------------------------------
  1. Encoding (G4): WinMerge uses std::wstring (UTF-16 wchar_t) with
     surrogate pairs. The Pascal port uses TCodePointArray (UTF-32 UInt32),
     where each element is one code point (no surrogate pairs). This
     matches Python str indexing. Astral characters (emoji, rare CJK)
     are 1 element in Pascal vs 2 in WinMerge.

  2. ICU grapheme break iterator (G10): WinMerge uses
     ICUBreakIterator::getCharacterBreakIterator() to advance one grapheme
     cluster per iteration (handling combining marks, ZWJ sequences, and
     surrogate pairs). The Pascal port uses simple code-point iteration
     (Inc(i)) because we operate on UTF-32 arrays — each UInt32 is one
     code point. Surrogate pairs are handled (1 element). Combining marks
     and ZWJ sequences are NOT merged — each code point is a separate unit.
     For typical source code (ASCII), this is invisible. For text with
     combining marks (NFD accented Latin, Devanagari), the tokenization
     may differ from WinMerge.
     Reason: Avoiding ICU dependency (~30MB, CudaText doesn't link it).

  3. tc::totlower (G26): WinMerge uses Unicode-aware towlower for
     case-insensitive comparison. The Pascal port uses ASCII-only tolower
     on code points in the 0x00-0x7F range, pass-through above 0x7F.
     Matches the DIF_TEXTS convention from cudadiff.pas phase 1 G5.
     For typical source code (ASCII identifiers), no difference. For
     non-ASCII text (Turkish İ, German ß), behavior differs.

  4. tc::istspace (G30): WinMerge uses Unicode-aware iswspace. The Pascal
     port uses ASCII whitespace only: \r, \n, \t, space (0x20). Unicode
     whitespace (U+00A0, U+2007) is NOT treated as whitespace. Matches
     cudadiff.pas convention.

  5. isWordBreak for non-ASCII (G29): WinMerge uses Win32 GetStringTypeW
     (CT_CTYPE1 with C1_UPPER|C1_LOWER|C1_DIGIT) to classify non-ASCII
     chars. The Pascal port treats all non-ASCII code points as "break"
     (each is its own token). This is correct for CJK (which WinMerge
     also breaks on), but may differ for accented Latin letters (which
     WinMerge would classify as letters and NOT break).
     Reason: Avoiding the Win32/ICU dependency. For typical source code,
     no difference.

  6. GetStringTypeW for non-ASCII letters/digits (G29): WinMerge's
     isWordBreak returns false for non-ASCII letters (so they're treated
     as word chars). The Pascal port returns true for all non-ASCII
     (treats each as its own token). This means WinMerge would group
     "café" as one word token, while the Pascal port would split it
     into "caf" + "é" (because é is non-ASCII → break). For source code
     without non-ASCII identifiers, no difference.

  7. tc::istdigit (G26): WinMerge uses Unicode-aware iswdigit. The
     Pascal port uses ASCII digit check (0x30..0x39). Non-ASCII digits
     (Arabic-Indic, Devanagari) are NOT treated as digits. Matches
     cudadiff.pas convention.

  8. ComputeByteDiff (G11): WinMerge uses 4 ICU break iterators for
     forward/reverse cursors. The Pascal port uses simple two-pointer
     scan on TCodePointArray (Inc/Dec index). Each comparison is one
     code point vs one code point — no grapheme awareness.

  9. m_matchblock (stringdiffsi.h:120): WinMerge has a m_matchblock flag
     that's hardcoded to true. The Pascal port drops the flag (always
     treats it as true). This matches WinMerge's default behavior.

  10. Compare() function (G8): WinMerge has a strdiff::Compare() method
      used for 3-way merge predicate. The Pascal port does NOT port it —
      DoDiffChars only needs ComputeWordDiffs. Skip.

  11. Compiler mode (G9, G12): CudaText is compiled with -Cr -Co (range +
      overflow checks). The diffutils rolling hash (HASH macro) intentionally
      wraps on overflow — we wrap the affected code in $PUSH/$R-/$Q-...$POP.

  12. 3-way diff (Diff3.h): WinMerge's ComputeWordDiffs(int nFiles, ...)
      supports 3-way merge. The Pascal port only supports 2-way diff
      (DoDiffChars takes exactly two strings). The 3-way code path
      (Comp02Functor, Make3wayDiff) is NOT ported — DoDiffChars only
      takes 2 strings.

  13. EOL_AS_SPACE mode (G5): WinMerge's EOL_AS_SPACE mode is NEVER used
      by DoDiffChars (only EOL_STRICT and EOL_IGNORE are reachable from
      the DIFF_IGN_EOL flag). The Pascal port keeps the enum value for
      completeness but the code path is exercised only when an internal
      caller sets EOL_AS_SPACE — which never happens via DoDiffChars.

  14. DIFF_IGN_BLANK_LINES (G7): Silently ignored at char-level. Blank
      lines are a line-level concept. DoDiffChars accepts the bit but
      doesn't use it.

  15. DIFF_IGN_WHITESPACE_EOL / DIFF_IGN_WHITESPACE_BEGINNING (G5): Both
      map to WHITESPACE_IGNORE_CHANGE at char-level (trailing/leading ws
      is a line-level concept).

  16. BREAK_CHARS (G6): Fixed to the WinMerge default ",.;:" — the
      SetBreakChars API is not exposed via diff_proc.

  17. Fix WinMerge Hash bug: WinMerge's Hash() does `h += HASH(h, ch)`
      which is `h := h + (ch + ROL(h, 7))`. The first iteration with h=0
      gives `h := 0 + (ch + ROL(0, 7)) = ch`. Subsequent iterations
      accumulate. We replicate this exactly (see comment in Hash() impl).
*)

unit CudaDiffChars;

{$mode objfpc}{$H+}
{$ModeSwitch advancedrecords}

interface

uses
  Classes, SysUtils, DateUtils;

{ Opcode tag values — must match proc_py_const.pas DIFF_TAG_*.
  We use integer literals directly (G13: do NOT redefine DIFF_TAG_*
  in cudadiff.pas/cudadiffchars.pas). Private aliases below for readability. }
const
  cTagEqual   = 0;  // DIFF_TAG_EQUAL
  cTagDelete  = 1;  // DIFF_TAG_DELETE
  cTagInsert  = 2;  // DIFF_TAG_INSERT
  cTagReplace = 3;  // DIFF_TAG_REPLACE

  { DIFF_IGN_* flag values — must match proc_py_const.pas exactly.
    Defined privately here because cudadiffchars.pas is standalone
    (does NOT `uses CudaDiff` or proc_py_const). Using integer literals
    directly in the flag-mapping code is cleaner — no risk of drift. }
  DIFF_IGN_CASE_Private                 = 1;
  DIFF_IGN_WHITESPACE_Private           = 2;
  DIFF_IGN_WHITESPACE_CHANGE_Private    = 4;
  DIFF_IGN_WHITESPACE_EOL_Private       = 8;
  DIFF_IGN_WHITESPACE_BEGINNING_Private = 16;
  DIFF_IGN_BLANK_LINES_Private          = 32;
  DIFF_IGN_EOL_Private                  = 64;
  DIFF_IGN_NUMBERS_Private               = 128;

  { Word-class constants — ported from stringdiffsi.h:22-29.
    Note: WinMerge Pascal-cases these as enum values; we use lowercase
    constants matching WinMerge's C names (dlword, dlspace, ...). }
  dlword   = 0;
  dlspace  = 1;
  dleol    = 2;
  dlbreak  = 3;
  dlnumber = 4;

  { WhitespaceIgnoreChoices — ported from CompareOptions.h:22-27. }
  WHITESPACE_COMPARE_ALL  = 0;
  WHITESPACE_IGNORE_CHANGE = 1;
  WHITESPACE_IGNORE_ALL    = 2;

  { EolCompareMode — ported from stringdiffs.h:15. }
  EOL_STRICT   = 0;
  EOL_IGNORE   = 1;
  EOL_AS_SPACE = 2;

  { Timeout for ONP — ported from stringdiffs.cpp:25. }
  TimeoutMilliSeconds = 500;

  { Token count size guard — ported from stringdiffs.cpp:397-401.
    On Win64, WinMerge uses 20480. We use 20480 on all platforms
    (Pascal on modern systems is essentially 64-bit). }
  MAX_TOKEN_COUNT = 20480;

  { Default break chars — ported from stringdiffs.cpp:24.
    Fixed to ",.;:" — SetBreakChars API not exposed via diff_proc.
    Declared as a function because FPC doesn't allow typed const arrays of
    a type defined later in the same const block. }

type
  { Ported from stringdiffs.h:15 — EolCompareMode enum. }
  TEolCompareMode = (eolStrict = EOL_STRICT, eolIgnore = EOL_IGNORE, eolAsSpace = EOL_AS_SPACE);

  { Public opcode type. Same layout as CudaDiff.TDiffOpcode but a
    SEPARATE Pascal type (G14) — the two units must not alias. }
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

  { Ported from stringdiffsi.h:63-70 — the word struct.
    start/end are CODE POINT indices into the original TCodePointArray.
    end is INCLUSIVE (matches WinMerge's `end+1-start` length formula).
    hash is the diffutils rolling hash of the word's code points.
    bBreak is the word class (dlword/dlspace/dleol/dlbreak/dlnumber). }
  TWord = record
    start: Integer;
    end_: Integer;   // 'end' is a Pascal keyword
    hash: Cardinal;
    bBreak: Integer; // 0=word, -1=whitespace, -2=empty, 1=breakWord, dl* values
    function Length_: Integer; inline;
  end;
  TWordArray = array of TWord;

  { Ported from stringdiffs.h:18-33 — wdiff struct (2-way only).
    WinMerge has begin[3]/end[3] for 3-way merge; we use [0..1] only.
    end[i] is INCLUSIVE — empty side encoded as end[i] = begin[i] - 1. }
  Twdiff = record
    begin_: array[0..1] of Integer;
    end_: array[0..1] of Integer;
    op: Integer;  // always -1 (unused by stringdiffs)
    constructor Create(s1, e1, s2, e2: Integer);
  end;
  TwdiffArray = array of Twdiff;

  { Internal: edit script element used by onp().
    Ported from the local struct EditScriptElem in stringdiffs.cpp:630.
    - op: '+' (insert) or '-' (delete) — the operation that led to this diagonal
    - neq: number of '=' (matches) preceding this op on this path
    - pk: previous diagonal k (the diagonal we came from)
    - pi: previous index into es[pk] (the EditScriptElem we came from) }
  TEditScriptElem = record
    op: AnsiChar;  // '+' or '-'
    neq: Integer;
    pk: Integer;
    pi: Integer;
  end;
  TEditScriptElemArray = array of TEditScriptElem;
  TEditScriptElemMatrix = array of TEditScriptElemArray;  // indexed by [esBase + k]

  { Ported from stringdiffsi.h:46-127 — the stringdiffs class.
    Holds together data needed to implement ComputeWordDiffs.
    We use a class (not unit-level functions) to match WinMerge's
    structure exactly. The constructor takes references to the two
    strings (TCodePointArrays) and the options. }
  TStringDiff = class
  private
    FStr1: TCodePointArray;
    FStr2: TCodePointArray;
    FWhitespace: Integer;
    FBreakType: Integer;
    FCaseSensitive: Boolean;
    FEolMode: TEolCompareMode;
    FIgnoreNumbers: Boolean;
    FMatchBlock: Boolean;
    FPDiffs: ^TwdiffArray;     // pointer to caller's array (we Append to it)
    FWords1: TWordArray;
    FWords2: TWordArray;
    FWdiffs: TwdiffArray;
    { FEdscript is filled by onp() and read by BuildWordDiffList_DP().
      Equivalent to the C++ `std::vector<char> edscript` passed by reference. }
    FEdscript: array of Char;

    { Ported from stringdiffs.cpp:554-613 — AreWordsSame.
      Checks if two words are considered equal under the current options. }
    function AreWordsSame(const word1, word2: TWord): Boolean;

    { Ported from stringdiffsi.h:85-88 — IsSpace inline. }
    function IsSpace(const w: TWord): Boolean; inline;
    { Ported from stringdiffsi.h:92-95 — IsNumber inline. }
    function IsNumber(const w: TWord): Boolean; inline;
    { Ported from stringdiffsi.h:99-102 — IsEOL inline. }
    function IsEOL(const w: TWord): Boolean; inline;

    { Ported from stringdiffs.cpp:420-482 — BuildWordsArray.
      Splits a TCodePointArray into tokens. }
    function BuildWordsArray(const S: TCodePointArray): TWordArray;

    { Ported from stringdiffs.cpp:519-549 — Hash (diffutils rolling hash).
      HASH(h, c) := c + ROL(h, 7). Wraps on overflow intentionally. }
    function Hash(const S: TCodePointArray; begin_, end_: Integer; h: Cardinal): Cardinal;

    { Ported from stringdiffs.cpp:292-385 — BuildWordDiffList_DP.
      Runs ONP and walks the edit script to build the wdiff list. }
    function BuildWordDiffList_DP: Boolean;

    { Ported from stringdiffs.cpp:618-730 — onp (O(NP) Sequence Comparison).
      Sun Wu, Udi Manber, Gene Myers (1990).
      Returns edit distance D (>=0) or -1 on timeout.
      Fills edscript with the post-processed edit script alphabet:
      '=' (match), '-' (delete), '+' (insert), '!' (replace). }
    function onp: Integer;

    { Ported from stringdiffs.cpp:732-749 — snake (diagonal extension).
      Advances while words match, returns the new y position. }
    function snake(k, y, M, N: Integer; exchanged: Boolean): Integer;

    { Ported from stringdiffs.cpp:489-517 — PopulateDiffs.
      Coalesces adjacent wdiffs where end[i]+1 == next.begin[i] on BOTH sides. }
    procedure PopulateDiffs;

    { Ported from stringdiffs.cpp:853-1074 — ComputeByteDiff.
      Refines a word-level diff down to character level using a two-pointer
      scan (forward + reverse). }
    procedure ComputeByteDiff(const str1, str2: TCodePointArray;
      casitive: Boolean; xwhite: Integer;
      var begin0, begin1, end0, end1: Integer; equal: Boolean);

    { Ported from stringdiffs.cpp:1083-1113 — wordLevelToByteLevel.
      Refines each wdiff down to character level by calling ComputeByteDiff
      on the substring. }
    procedure wordLevelToByteLevel;
  public
    { Ported from stringdiffs.cpp:237-250 — constructor. }
    constructor Create(const str1, str2: TCodePointArray;
      case_sensitive: Boolean; eol_mode: TEolCompareMode;
      whitespace: Integer; ignore_numbers: Boolean; breakType: Integer;
      var pDiffs: TwdiffArray);

    { Ported from stringdiffs.cpp:390-415 — BuildWordDiffList.
      Top-level entry: build word arrays, run ONP, fall back to single
      wdiff on size guard or timeout. }
    procedure BuildWordDiffList;

    { Ported from stringdiffs.cpp:1083-1113 — wordLevelToByteLevel wrapper. }
    procedure wordLevelToByteLevelWrapper;

    { Ported from stringdiffs.cpp:489-517 — PopulateDiffs wrapper. }
    procedure PopulateDiffsWrapper;
  end;

{ Public API — ported from stringdiffs.cpp:54-60 (the 2-string overload).
  Takes two TCodePointArrays (already converted from UTF-8 via UTF8ToUTF32)
  and returns a list of wdiffs (differences only, after coalescing). }
function ComputeWordDiffs(const str1, str2: TCodePointArray;
  case_sensitive: Boolean; eol_mode: TEolCompareMode;
  whitespace: Integer; ignore_numbers: Boolean;
  breakType: Integer; byte_level: Boolean): TwdiffArray;

{ Convert a UTF-8 Pascal string to a UTF-32 code point array.
  (Already implemented in phase 1 stub — kept verbatim.) }
function UTF8ToUTF32(const S: string): TCodePointArray;

{ Char-level diff entry point — called by formmain_py_api.inc.
  Replaces the phase 1 stub body with the real WinMerge port. }
function DoDiffChars(const ATextA, ATextB: string; AFlags: Integer): TDiffOpcodeArray;

implementation

const
  { Default break chars — ported from stringdiffs.cpp:24.
    Fixed to ",.;:" — SetBreakChars API not exposed via diff_proc.
    Referenced directly by isWordBreak() below. }
  BreakCharsDefault: array[0..3] of TCodePoint = (Ord(','), Ord('.'), Ord(';'), Ord(':'));

{ Helper: max of two integers. Avoids pulling in Math unit. }
function MaxIntOf(a, b: Integer): Integer; inline;
begin
  if a > b then Result := a else Result := b;
end;

{ Helper: append an edit script element to es[k].
  Ported from the lambda addEditScriptElem in stringdiffs.cpp:634-650.
  Computes the new element from fp[k-1] and fp[k+1], then appends. }
procedure AddEditScriptElem(var es: TEditScriptElemMatrix; esBase: Integer;
  const fp: array of Integer; fpBase: Integer; k: Integer;
  out newElem: TEditScriptElem);
begin
  if fp[fpBase + k - 1] + 1 > fp[fpBase + k + 1] then
  begin
    newElem.op := '+';
    newElem.neq := fp[fpBase + k] - (fp[fpBase + k - 1] + 1);
    newElem.pk := k - 1;
  end
  else
  begin
    newElem.op := '-';
    newElem.neq := fp[fpBase + k] - fp[fpBase + k + 1];
    newElem.pk := k + 1;
  end;
  newElem.pi := Length(es[esBase + newElem.pk]) - 1;
  es[esBase + k] := Concat(es[esBase + k], [newElem]);
end;

{ ------------------------------------------------------------------
  Helper functions — ported from ctchar.h.
  WinMerge uses Unicode-aware versions (iswspace, towlower, iswdigit).
  The Pascal port uses ASCII-only versions (matching DIF_TEXTS
  convention from cudadiff.pas phase 1 G5/G26/G30). }
function tc_istspace(ch: TCodePoint): Boolean; inline;
begin
  // ASCII whitespace: \t (0x09), \n (0x0A), \v (0x0B), \f (0x0C), \r (0x0D), space (0x20).
  // Matches iswspace minus Unicode whitespace (U+00A0, U+2007, etc.).
  Result := (ch = $09) or (ch = $0A) or (ch = $0B) or (ch = $0C) or
            (ch = $0D) or (ch = $20);
end;

function tc_istdigit(ch: TCodePoint): Boolean; inline;
begin
  // ASCII digit only: 0-9 (0x30..0x39). Matches iswdigit minus non-ASCII digits.
  Result := (ch >= $30) and (ch <= $39);
end;

function tc_totlower(ch: TCodePoint): TCodePoint; inline;
begin
  // ASCII-only tolower: A-Z (0x41..0x5A) -> a-z (0x61..0x7A).
  // Above 0x7F: pass through unchanged (Unicode case folding NOT performed).
  if (ch >= $41) and (ch <= $5A) then
    Result := ch or $20
  else
    Result := ch;
end;

function tc_istalnum(ch: TCodePoint): Boolean; inline;
begin
  // ASCII alphanumeric: 0-9, A-Z, a-z.
  Result := ((ch >= $30) and (ch <= $39)) or
            ((ch >= $41) and (ch <= $5A)) or
            ((ch >= $61) and (ch <= $7A));
end;

{ Ported from stringdiffs.cpp:770-778 — IsLeadByte.
  In WinMerge's UNICODE build, this always returns false.
  The Pascal port always returns false (UTF-32 has no lead bytes). }
function IsLeadByte(ch: TCodePoint): Boolean; inline;
begin
  Result := False;
end;

{ Ported from stringdiffs.cpp:783-787 — isSafeWhitespace.
  Whitespace except CR/LF and lead bytes.
  DIVERGENCE: WinMerge uses iswspace (Unicode-aware). We use ASCII-only
  tc_istspace. See G29/G30. }
function isSafeWhitespace(ch: TCodePoint): Boolean; inline;
begin
  Result := tc_istspace(ch) and (not IsLeadByte(ch)) and (ch <> $0D) and (ch <> $0A);
end;

{ Ported from stringdiffs.cpp:792-826 — isWordBreak.
  Returns true if the code point at S[index] is a word-break character.
  - ASCII + breakType=0: never break (return false)
  - ASCII + breakType≠0: break if char is in BreakChars
  - Non-ASCII: WinMerge uses GetStringTypeW (C1_UPPER|C1_LOWER|C1_DIGIT).
    Pascal port treats ALL non-ASCII as break (each is its own token).
    See G29 divergence #6. }
function isWordBreak(breakType: Integer; const S: TCodePointArray; index: Integer): Boolean;
var
  ch: TCodePoint;
  i: Integer;
begin
  ch := S[index];
  if ch < $100 then  // ASCII range (matches WinMerge's `(ch & 0xff00) == 0`)
  begin
    if breakType = 0 then
      Exit(False);
    for i := 0 to High(BreakCharsDefault) do
      if ch = BreakCharsDefault[i] then
        Exit(True);
    Exit(False);
  end
  else
  begin
    // DIVERGENCE: WinMerge uses GetStringTypeW to classify non-ASCII as
    // upper/lower/digit (and only breaks on others). We treat all
    // non-ASCII as break (each is its own token). This is correct for CJK
    // and symbols (which WinMerge also breaks on), but differs for
    // accented Latin letters (WinMerge: letter → no break; us: break).
    Exit(True);
  end;
end;

{ Ported from stringdiffs.cpp:756-767 — matchchar.
  Compare two code point sequences for equality (case-sensitive or insensitive).
  In WinMerge this is on wchar_t*; here it's on TCodePointArray slices. }
function matchchar(const S1: TCodePointArray; off1: Integer;
  const S2: TCodePointArray; off2: Integer;
  len: Integer; casitive: Boolean): Boolean;
var
  i: Integer;
begin
  if casitive then
  begin
    for i := 0 to len - 1 do
      if S1[off1 + i] <> S2[off2 + i] then
        Exit(False);
  end
  else
  begin
    for i := 0 to len - 1 do
      if tc_totlower(S1[off1 + i]) <> tc_totlower(S2[off2 + i]) then
        Exit(False);
  end;
  Result := True;
end;

{ Ported from stringdiffs.cpp:834-840 — AdvanceOverWhitespace.
  Advance py over safe whitespace until non-whitespace or beyond end. }
procedure AdvanceOverWhitespace(var py: Integer; endIdx: Integer;
  const S: TCodePointArray);
begin
  while (py <= endIdx) and isSafeWhitespace(S[py]) do
    Inc(py);
end;

{ ------------------------------------------------------------------
  TWord methods
  ------------------------------------------------------------------ }

function TWord.Length_: Integer;
{ Ported from stringdiffsi.h:69 — word::length().
  end+1-start (inclusive end → half-open length). }
begin
  Result := end_ + 1 - start;
end;

{ ------------------------------------------------------------------
  Twdiff methods
  ------------------------------------------------------------------ }

constructor Twdiff.Create(s1, e1, s2, e2: Integer);
{ Ported from stringdiffs.h:22-32 — wdiff constructor.
  Matches WinMerge's "if s>e then e:=s-1" empty-side encoding. }
begin
  if s1 > e1 then e1 := s1 - 1;
  if s2 > e2 then e2 := s2 - 1;
  begin_[0] := s1;
  end_[0] := e1;
  begin_[1] := s2;
  end_[1] := e2;
  op := -1;
end;

{ ------------------------------------------------------------------
  TStringDiff methods
  ------------------------------------------------------------------ }

constructor TStringDiff.Create(const str1, str2: TCodePointArray;
  case_sensitive: Boolean; eol_mode: TEolCompareMode;
  whitespace: Integer; ignore_numbers: Boolean; breakType: Integer;
  var pDiffs: TwdiffArray);
{ Ported from stringdiffs.cpp:237-250 — constructor.
  Simply loads all members from arguments.
  m_matchblock is hardcoded to true (matches WinMerge's default). }
begin
  inherited Create;
  FStr1 := str1;
  FStr2 := str2;
  FWhitespace := whitespace;
  FBreakType := breakType;
  FCaseSensitive := case_sensitive;
  FEolMode := eol_mode;
  FIgnoreNumbers := ignore_numbers;
  FMatchBlock := True;  // Change to false to get word to word compare
  FPDiffs := @pDiffs;
end;

function TStringDiff.IsSpace(const w: TWord): Boolean;
begin
  Result := (w.bBreak = dlspace);
end;

function TStringDiff.IsNumber(const w: TWord): Boolean;
begin
  Result := (w.bBreak = dlnumber);
end;

function TStringDiff.IsEOL(const w: TWord): Boolean;
begin
  Result := (w.bBreak = dleol);
end;

{ Ported from stringdiffs.cpp:519-549 — Hash.
  Diffutils rolling hash: HASH(h, c) := c + ROL(h, 7), then h += HASH(h, c).
  Per WinMerge's source: `h += HASH(h, ch)` means
    temp := ch + ROL(h, 7); h := h + temp;
  Wraps on overflow intentionally — use $PUSH/$R-/$Q-.
  The hash is used ONLY as a fast pre-filter in AreWordsSame; collisions
  are tolerated (authoritative check is the char-by-char compare). }
function TStringDiff.Hash(const S: TCodePointArray; begin_, end_: Integer; h: Cardinal): Cardinal;
{$PUSH}{$R-}{$Q-}
var
  i: Integer;
  ch: Cardinal;
  tmp: Cardinal;
begin
  if FCaseSensitive then
  begin
    for i := begin_ to end_ do
    begin
      ch := S[i];
      // HASH(h, c) = c + ROL(h, 7) = c + ((h shl 7) or (h shr 25))
      tmp := ch + ((h shl 7) or (h shr 25));
      h := h + tmp;
    end;
  end
  else
  begin
    for i := begin_ to end_ do
    begin
      ch := tc_totlower(S[i]);
      tmp := ch + ((h shl 7) or (h shr 25));
      h := h + tmp;
    end;
  end;
  Result := h;
end;
{$POP}

{ Ported from stringdiffs.cpp:554-613 — AreWordsSame.
  Check word equality with options.
  Order: whitespace shortcuts → number shortcuts → EOL shortcuts → hash pre-filter → char-by-char. }
function TStringDiff.AreWordsSame(const word1, word2: TWord): Boolean;
var
  length_: Integer;
  i: Integer;
begin
  { Whitespace shortcuts. }
  if FWhitespace <> WHITESPACE_COMPARE_ALL then
  begin
    if IsSpace(word1) and IsSpace(word2) then
      Exit(True);
  end;

  { Number shortcuts. }
  if FIgnoreNumbers then
  begin
    // WinMerge checks tc::istdigit(m_str1[word1.start]).
    // We use tc_istdigit on the first code point of each word.
    if (word1.start < Length(FStr1)) and (word2.start < Length(FStr2)) then
      if tc_istdigit(FStr1[word1.start]) and tc_istdigit(FStr2[word2.start]) then
        Exit(True);
  end;

  { EOL shortcuts. }
  if FEolMode = eolIgnore then
  begin
    if IsEOL(word1) and IsEOL(word2) then
      Exit(True);
  end
  else if FEolMode = eolAsSpace then
  begin
    { EOL_AS_SPACE mode: normalize EOL to space and compare as space.
      We never use eolAsSpace via DoDiffChars, but port the logic for
      completeness. WinMerge replaces "\r\n" with " " in both wordstrs
      and compares. We approximate by treating any space-or-EOL word as
      equal to any other space-or-EOL word. }
    if IsSpace(word1) and IsSpace(word2) then
      Exit(True);
    { Fall through to char-by-char for non-space words. }
  end;

  { Hash pre-filter (fast inequality check). }
  if word1.hash <> word2.hash then
    Exit(False);

  { Length check (code-point count). }
  length_ := word1.Length_;
  if length_ <> word2.Length_ then
    Exit(False);

  { Char-by-char compare. }
  if FCaseSensitive then
  begin
    for i := 0 to length_ - 1 do
      if FStr1[word1.start + i] <> FStr2[word2.start + i] then
        Exit(False);
  end
  else
  begin
    for i := 0 to length_ - 1 do
      if tc_totlower(FStr1[word1.start + i]) <> tc_totlower(FStr2[word2.start + i]) then
        Exit(False);
  end;
  Result := True;
end;

{ Ported from stringdiffs.cpp:420-482 — BuildWordsArray.
  Splits a TCodePointArray into tokens per the WinMerge tokenizer rules.

  DIVERGENCE (G10): WinMerge uses ICUBreakIterator::getCharacterBreakIterator()
  to advance one grapheme cluster per iteration (handling combining marks,
  surrogate pairs, ZWJ sequences). The Pascal port uses simple code-point
  iteration (Inc(i)) because we operate on UTF-32 arrays — each UInt32 is
  one code point. Surrogate pairs are handled (1 element in UTF-32).
  Combining marks and ZWJ sequences are NOT merged (each code point is a
  separate unit). For typical source code (ASCII), this is invisible.

  Rules (per G6):
  1. '\r' or '\n' → dlEol (or dlSpace when eol_mode = eolAsSpace)
  2. isSafeWhitespace(ch) → dlSpace
  3. isWordBreak(breakType, str, i) → dlBreak (punctuation)
  4. ignore_numbers and tc::istdigit(ch) → dlNumber
  5. otherwise → dlWord (default)

  Boundary rule: a new token starts when i > 0 AND any of:
    - break_type != prev_break_type (class change)
    - break_type == dlBreak (every punct char is its own token)
    - prev_break_type == dlEol and not (str[i-1]=='\r' and ch=='\n')
      (CRLF stays together as one token)

  Sentinel: a dummy word(0, -1, 0, 0) is prepended at index 0.
  Real tokens start at index 1. The 1-based indexing is used by onp/snake. }
function TStringDiff.BuildWordsArray(const S: TCodePointArray): TWordArray;
var
  i, begin_: Integer;
  break_type, prev_break_type: Integer;
  ch: TCodePoint;
  iLen: Integer;
  count: Integer;
begin
  iLen := Length(S);
  if iLen = 0 then
  begin
    { Both empty: just the dummy sentinel. }
    SetLength(Result, 1);
    Result[0].start := 0;
    Result[0].end_ := -1;
    Result[0].bBreak := 0;
    Result[0].hash := 0;
    Exit;
  end;

  { Pre-allocate up-front (O(N)) and trim at the end.
    Worst case is 1 token per code point + 1 dummy sentinel + 1 final
    token = iLen + 2 slots. The previous version used `Concat` per token
    which is O(N^2) on long lines because Concat reallocates + copies
    the whole array each time. This mirrors the optimisation used in
    agent2's BuildWordsArray while preserving Agent1's EOL_AS_SPACE
    branch (which agent2 omits). }
  SetLength(Result, iLen + 2);
  count := 1;  // index 0 is reserved for the dummy sentinel
  Result[0].start := 0;
  Result[0].end_ := -1;
  Result[0].bBreak := 0;
  Result[0].hash := 0;

  i := 0;
  begin_ := 0;
  prev_break_type := 0;

  while i < iLen do
  begin
    break_type := dlword;
    ch := S[i];

    { Classify the current code point. }
    if (ch = $0D) or (ch = $0A) then
    begin
      if FEolMode = eolAsSpace then
        break_type := dlspace
      else
        break_type := dleol;
    end
    else if isSafeWhitespace(ch) then
    begin
      break_type := dlspace;
    end
    else if isWordBreak(FBreakType, S, i) then
    begin
      break_type := dlbreak;
    end
    else if FIgnoreNumbers and tc_istdigit(ch) then
    begin
      break_type := dlnumber;
    end;

    { Boundary check: start a new token if class changed, or this is a
      break char, or the previous was EOL but not part of a CRLF pair. }
    if (i > 0) and (
      (break_type <> prev_break_type) or
      (break_type = dlbreak) or
      ((prev_break_type = dleol) and not ((S[i-1] = $0D) and (ch = $0A)))
    ) then
    begin
      Result[count].start := begin_;
      Result[count].end_ := i - 1;
      Result[count].bBreak := prev_break_type;
      Result[count].hash := Hash(S, begin_, i - 1, 0);
      Inc(count);
      begin_ := i;
    end;

    { Advance one code point (replaces ICU pIterChar->next()).
      Special case for EOL_AS_SPACE mode: skip consecutive whitespace/EOL. }
    if (FEolMode = eolAsSpace) and (break_type = dlspace) then
    begin
      while i < iLen do
      begin
        ch := S[i];
        if (ch <> $0D) and (ch <> $0A) and (not isSafeWhitespace(ch)) then
          Break;
        Inc(i);
      end;
      // pIterChar->preceding(i) — no-op in our model (we just continue from i)
    end
    else
    begin
      Inc(i);
    end;

    prev_break_type := break_type;
  end;

  { Final token. }
  Result[count].start := begin_;
  Result[count].end_ := i - 1;
  Result[count].bBreak := break_type;
  Result[count].hash := Hash(S, begin_, i - 1, 0);
  Inc(count);

  { Trim to actual size. }
  SetLength(Result, count);
end;

{ Ported from stringdiffs.cpp:732-749 — snake (diagonal extension).
  Advances while words match. Returns the new y position.

  In WinMerge's ONP formulation:
    - x, y are positions in the two word arrays (1-based via m_words1[x+1])
    - exchanged = true means M > N, so the arrays are conceptually swapped
    - When exchanged: m_words1[y+1] vs m_words2[x+1] (note the swap)
    - When not exchanged: m_words1[x+1] vs m_words2[y+1] }
function TStringDiff.snake(k, y, M, N: Integer; exchanged: Boolean): Integer;
var
  x: Integer;
begin
  x := y - k;
  if exchanged then
  begin
    while (x < M) and (y < N) and AreWordsSame(FWords1[y + 1], FWords2[x + 1]) do
    begin
      Inc(x);
      Inc(y);
    end;
  end
  else
  begin
    while (x < M) and (y < N) and AreWordsSame(FWords1[x + 1], FWords2[y + 1]) do
    begin
      Inc(x);
      Inc(y);
    end;
  end;
  Result := y;
end;

{ Ported from stringdiffs.cpp:618-730 — onp (O(NP) Sequence Comparison).
  Sun Wu, Udi Manber, Gene Myers (1990).

  Algorithm overview:
    - M, N are the sizes of the two word arrays (minus 1 for the sentinel).
    - If M > N, swap so M <= N (the "exchanged" flag tracks this).
    - DELTA = N - M.
    - fp[k] = furthest point on diagonal k (y-coordinate).
    - Iterate p = 0, 1, 2, ... until fp[DELTA] = N.
    - For each p, sweep k from -p to DELTA-1, then DELTA+p down to DELTA+1,
      then k = DELTA. Update fp[k] = snake(k, max(fp[k-1]+1, fp[k+1])).
    - Build the edit script by walking back from es[DELTA][last].
    - Post-process the script: collapse "+-" and "-+" pairs into "!" (replace).

  Returns edit distance D (>=0) or -1 on timeout.
  Fills FEdscript member with the post-processed script alphabet. }
function TStringDiff.onp: Integer;
var
  M, N: Integer;
  exchanged: Boolean;
  DELTA: Integer;
  fp: array of Integer;
  fpBase: Integer;  // index 0 of fp maps to k = -(M+1)
  es: TEditScriptElemMatrix;
  esBase: Integer;
  p, k: Integer;
  count: Integer;
  COUNTMAX: Integer;
  startTime: TDateTime;
  ses: array of Char;
  i, j: Integer;
  D: Integer;
  nIdx: Integer;
  ch: Char;
  is_plus: Boolean;
  c: Char;
  cnt: Integer;
  esi: TEditScriptElem;
  newElem: TEditScriptElem;
  nextExpected: Char;
begin
  startTime := Now;

  M := Length(FWords1) - 1;
  N := Length(FWords2) - 1;
  exchanged := (M > N);
  if exchanged then
  begin
    i := M; M := N; N := i;
  end;

  { Allocate fp with indices from -(M+1) to (N+1).
    Total size: (M+1) + 1 + (N+1) = M + N + 3.
    fpBase = M+1 (so fp[fpBase + (-(M+1))] = fp[0] corresponds to k=-(M+1)). }
  SetLength(fp, (M+1) + 1 + (N+1));
  fpBase := M + 1;

  { Allocate es (edit script history per diagonal).
    Each es[k] is a TEditScriptElemArray (dynamic array). }
  SetLength(es, (M+1) + 1 + (N+1));
  esBase := M + 1;

  DELTA := N - M;

  { Initialize fp to -1 for all k. }
  for k := -(M+1) to (N+1) do
    fp[fpBase + k] := -1;

  p := -1;
  count := 0;
  COUNTMAX := 100000;
  repeat
    Inc(p);

    { Forward sweep: k from -p to DELTA-1. }
    for k := -p to DELTA - 1 do
    begin
      fp[fpBase + k] := snake(k, MaxIntOf(fp[fpBase + k - 1] + 1, fp[fpBase + k + 1]), M, N, exchanged);
      AddEditScriptElem(es, esBase, fp, fpBase, k, newElem);
      Inc(count);
    end;

    { Reverse sweep: k from DELTA+p down to DELTA+1. }
    for k := DELTA + p downto DELTA + 1 do
    begin
      fp[fpBase + k] := snake(k, MaxIntOf(fp[fpBase + k - 1] + 1, fp[fpBase + k + 1]), M, N, exchanged);
      AddEditScriptElem(es, esBase, fp, fpBase, k, newElem);
      Inc(count);
    end;

    { Center diagonal: k = DELTA. }
    k := DELTA;
    fp[fpBase + k] := snake(k, MaxIntOf(fp[fpBase + k - 1] + 1, fp[fpBase + k + 1]), M, N, exchanged);
    AddEditScriptElem(es, esBase, fp, fpBase, k, newElem);
    Inc(count);

    { Timeout check. }
    if count > COUNTMAX then
    begin
      count := 0;
      if MilliSecondsBetween(Now, startTime) > TimeoutMilliSeconds then
      begin
        Result := -1;
        Exit;
      end;
    end;
  until fp[fpBase + k] = N;

  { Build the edit script by walking back from es[DELTA][last]. }
  SetLength(ses, 0);
  k := DELTA;
  i := High(es[esBase + DELTA]);  // last index
  while i >= 0 do
  begin
    esi := es[esBase + k][i];
    for j := 0 to esi.neq - 1 do
      ses := Concat(ses, [Char('=')]);
    ses := Concat(ses, [Char(esi.op)]);
    i := esi.pi;
    k := esi.pk;
  end;
  { Reverse ses. }
  for i := 0 to (Length(ses) div 2) - 1 do
  begin
    c := ses[i];
    ses[i] := ses[Length(ses) - 1 - i];
    ses[Length(ses) - 1 - i] := c;
  end;

  { Post-process: collapse "+-" and "-+" pairs into "!" (replace).
    Walk ses from index 1 (skip the leading '=' padding).
    WinMerge iterates n from 1 to cnt-1, looking at ses[n] and ses[n+1].

    C++ logic (WinMerge stringdiffs.cpp:707-724):
      Walk ses from index 1; for each ses[n], if it's a '+' or '-':
        - If the next char is the complementary op ('-' after '+', or '+'
          after '-'), collapse them into '!' (replace) and skip next.
        - Otherwise, the char becomes '+' (insert) or '-' (delete) based
          on (exchanged XOR is_plus): if they're equal, '+'; else '-'.
      Otherwise (ses[n] is '='), emit '='.
      D counts the number of edits (1 per collapsed pair, 1 per single + or -). }
  SetLength(FEdscript, Length(ses));
  D := 0;
  nIdx := 1;
  cnt := Length(ses);
  i := 0;  // FEdscript write index
  while nIdx < cnt do
  begin
    c := '!';
    ch := ses[nIdx];
    is_plus := (ch = '+');
    if is_plus or (ch = '-') then
    begin
      if is_plus then
        nextExpected := '-'
      else
        nextExpected := '+';

      if (nIdx <> (cnt - 1)) and (ses[nIdx + 1] = nextExpected) then
      begin
        { Collapse "+-" or "-+" pair into "!" (replace). }
        Inc(nIdx);
      end
      else
      begin
        { Single '+' or '-'.
          C++: c = "+-"[exchanged == is_plus]
          "+-"[0] = '+', "+-"[1] = '-'.
          exchanged==is_plus true → index 1 → '-'
          exchanged==is_plus false → index 0 → '+'
          So: if exchanged == is_plus → '-'; else → '+'. }
        if exchanged = is_plus then
          c := '-'
        else
          c := '+';
      end;
      Inc(D);
    end
    else
      c := '=';

    FEdscript[i] := c;
    Inc(i);
    Inc(nIdx);
  end;
  { Trim FEdscript to actual size. }
  SetLength(FEdscript, i);

  Result := D;
end;

{ Ported from stringdiffs.cpp:292-385 — BuildWordDiffList_DP.
  Runs ONP and walks the edit script (stored in FEdscript) to build the wdiff list. }
function TStringDiff.BuildWordDiffList_DP: Boolean;
var
  D: Integer;
  i, j, k: Integer;
  s1, e1, s2, e2: Integer;
begin
  SetLength(FEdscript, 0);
  D := onp;
  if D < 0 then
    Exit(False);

  i := 1;  // 1-based because words[0] is the dummy sentinel
  j := 1;
  for k := 0 to High(FEdscript) do
  begin
    if FEdscript[k] = '-' then
    begin
      if FWhitespace = WHITESPACE_IGNORE_ALL then
      begin
        if IsSpace(FWords1[i]) then
        begin
          Inc(i);
          Continue;
        end;
      end;
      if FIgnoreNumbers and IsNumber(FWords1[i]) then
      begin
        Inc(i);
        Continue;
      end;

      s1 := FWords1[i].start;
      e1 := FWords1[i].end_;
      s2 := FWords2[j-1].end_ + 1;
      e2 := s2 - 1;
      FWdiffs := Concat(FWdiffs, [Twdiff.Create(s1, e1, s2, e2)]);
      Inc(i);
    end
    else if FEdscript[k] = '+' then
    begin
      if FWhitespace = WHITESPACE_IGNORE_ALL then
      begin
        if IsSpace(FWords2[j]) then
        begin
          Inc(j);
          Continue;
        end;
      end;
      if FIgnoreNumbers and IsNumber(FWords2[j]) then
      begin
        Inc(j);
        Continue;
      end;

      s1 := FWords1[i-1].end_ + 1;
      e1 := s1 - 1;
      s2 := FWords2[j].start;
      e2 := FWords2[j].end_;
      FWdiffs := Concat(FWdiffs, [Twdiff.Create(s1, e1, s2, e2)]);
      Inc(j);
    end
    else if FEdscript[k] = '!' then
    begin
      if (FWhitespace = WHITESPACE_IGNORE_CHANGE) or (FWhitespace = WHITESPACE_IGNORE_ALL) then
      begin
        if IsSpace(FWords1[i]) and IsSpace(FWords2[j]) then
        begin
          Inc(i); Inc(j);
          Continue;
        end;
      end;
      if FIgnoreNumbers and IsNumber(FWords1[i]) and IsNumber(FWords2[j]) then
      begin
        Inc(i); Inc(j);
        Continue;
      end;

      s1 := FWords1[i].start;
      e1 := FWords1[i].end_;
      s2 := FWords2[j].start;
      e2 := FWords2[j].end_;
      FWdiffs := Concat(FWdiffs, [Twdiff.Create(s1, e1, s2, e2)]);
      Inc(i); Inc(j);
    end
    else  // '='
    begin
      Inc(i); Inc(j);
    end;
  end;
  Result := True;
end;

{ Ported from stringdiffs.cpp:390-415 — BuildWordDiffList.
  Top-level entry: build word arrays, run ONP, fall back to single wdiff
  on size guard or timeout.

  DIVERGENCE: WinMerge's ONP has a latent bug when M=0 or N=0 (one side
  has only the dummy sentinel word). The edscript will contain '-' ops
  that try to access m_words1[1] which is out of bounds. C++ doesn't
  check bounds so it reads garbage. We guard against this by special-casing
  the M=0 or N=0 scenarios BEFORE calling ONP:
    - If both sides have only dummies → no diff, exit.
    - If side 1 is empty → emit single INSERT wdiff covering all of side 2.
    - If side 2 is empty → emit single DELETE wdiff covering all of side 1. }
procedure TStringDiff.BuildWordDiffList;
var
  succeeded: Boolean;
  s1, e1, s2, e2: Integer;
begin
  FWords1 := BuildWordsArray(FStr1);
  FWords2 := BuildWordsArray(FStr2);

  { DIVERGENCE guard: handle empty-side cases that ONP can't handle safely.
    WinMerge would access out-of-bounds memory here; we emit the correct
    single-sided wdiff instead. }
  if (Length(FWords1) <= 1) and (Length(FWords2) <= 1) then
  begin
    { Both sides empty (or just dummies) — no diff. }
    Exit;
  end;
  if Length(FWords1) <= 1 then
  begin
    { Side 1 is empty — entire side 2 is an insertion.
      wdiff(begin[0]=0, end[0]=-1, begin[1]=words2[1].start, end[1]=words2[last].end). }
    s1 := 0;
    e1 := -1;  // empty side encoding
    s2 := FWords2[1].start;
    e2 := FWords2[Length(FWords2) - 1].end_;
    SetLength(FWdiffs, 1);
    FWdiffs[0] := Twdiff.Create(s1, e1, s2, e2);
    Exit;
  end;
  if Length(FWords2) <= 1 then
  begin
    { Side 2 is empty — entire side 1 is a deletion. }
    s1 := FWords1[1].start;
    e1 := FWords1[Length(FWords1) - 1].end_;
    s2 := 0;
    e2 := -1;  // empty side encoding
    SetLength(FWdiffs, 1);
    FWdiffs[0] := Twdiff.Create(s1, e1, s2, e2);
    Exit;
  end;

  succeeded := False;
  { Size guard: bail if either word list has >= MAX_TOKEN_COUNT tokens. }
  if (Length(FWords1) < MAX_TOKEN_COUNT) and (Length(FWords2) < MAX_TOKEN_COUNT) then
  begin
    succeeded := BuildWordDiffList_DP;
  end;

  if not succeeded then
  begin
    { Bail out: emit a single wdiff covering the entire line. }
    s1 := FWords1[0].start;
    e1 := FWords1[Length(FWords1) - 1].end_;
    s2 := FWords2[0].start;
    e2 := FWords2[Length(FWords2) - 1].end_;
    SetLength(FWdiffs, 1);
    FWdiffs[0] := Twdiff.Create(s1, e1, s2, e2);
    Exit;
  end;
end;

{ Ported from stringdiffs.cpp:489-517 — PopulateDiffs.
  Coalesces adjacent wdiffs where end[i]+1 == next.begin[i] on BOTH sides. }
procedure TStringDiff.PopulateDiffs;
var
  i: Integer;
  skipIt: Boolean;
begin
  for i := 0 to High(FWdiffs) do
  begin
    skipIt := False;
    if i + 1 < Length(FWdiffs) then
    begin
      if (FWdiffs[i].end_[0] + 1 = FWdiffs[i+1].begin_[0]) and
         (FWdiffs[i].end_[1] + 1 = FWdiffs[i+1].begin_[1]) then
      begin
        { Diff i and i+1 are contiguous. Combine them into i+1 and skip i. }
        FWdiffs[i+1].begin_[0] := FWdiffs[i].begin_[0];
        FWdiffs[i+1].begin_[1] := FWdiffs[i].begin_[1];
        skipIt := True;
      end;
    end;
    if not skipIt then
    begin
      { Append to caller's pDiffs list. }
      FPDiffs^ := Concat(FPDiffs^, [FWdiffs[i]]);
    end;
  end;
end;

{ Ported from stringdiffs.cpp:853-1074 — ComputeByteDiff.
  Refines a word-level diff down to character level using a two-pointer
  scan (forward + reverse) on the substring.

  DIVERGENCE (G11): WinMerge uses 4 ICU break iterators for forward/reverse
  cursors. We use simple two-pointer scan on TCodePointArray (Inc/Dec
  index). Each comparison is one code point vs one code point — no grapheme
  awareness. See G10 for divergence rationale.

  begin_/end_ arrays are [0]=side1, [1]=side2.
  Convention: begin[i] = -1 means "no visible diff on side i".
  end[i] is INCLUSIVE (matches WinMerge's encoding). }
procedure TStringDiff.ComputeByteDiff(const str1, str2: TCodePointArray;
  casitive: Boolean; xwhite: Integer;
  var begin0, begin1, end0, end1: Integer; equal: Boolean);
var
  len1, len2: Integer;
  py1, py2: Integer;
  pen1, pen2: Integer;
  pz1, pz2: Integer;
  glyphlenz1, glyphlenz2: Integer;
  py1next, py2next: Integer;
  glyphleny1, glyphleny2: Integer;
begin
  { Initialize to sane values. }
  begin0 := 0; begin1 := 0; end0 := 0; end1 := 0;

  len1 := Length(str1);
  len2 := Length(str2);

  if (len1 = 0) or (len2 = 0) then
  begin
    if len1 = len2 then
    begin
      { Both empty — no diff. }
      begin0 := -1; begin1 := -1; end0 := -1; end1 := -1;
    end
    else
    begin
      { One side empty — entire other side is the diff. }
      end0 := len1 - 1;
      end1 := len2 - 1;
    end;
    Exit;
  end;

  { Cursors from front. }
  py1 := 0;
  py2 := 0;
  { Cursors from back (point to last valid code point). }
  pen1 := len1 - 1;
  pen2 := len2 - 1;
  glyphlenz1 := 1;  // Each code point is 1 unit (no surrogate pairs in UTF-32)
  glyphlenz2 := 1;

  if xwhite <> WHITESPACE_COMPARE_ALL then
  begin
    { Ignore leading and trailing whitespace by advancing py1/py2 and
      retreating pen1/pen2. }
    while (py1 < pen1) and isSafeWhitespace(str1[py1]) do
      Inc(py1);
    while (py2 < pen2) and isSafeWhitespace(str2[py2]) do
      Inc(py2);

    while (pen1 > py1) and isSafeWhitespace(str1[pen1]) do
      Dec(pen1);
    while (pen2 > py2) and isSafeWhitespace(str2[pen2]) do
      Dec(pen2);
  end;

  { Check for exception of empty string on one side.
    In that case display all as a diff. }
  if (not equal) and (
    (((py1 = pen1) and isSafeWhitespace(str1[pen1])) or
     ((py2 = pen2) and isSafeWhitespace(str2[pen2])))
  ) then
  begin
    begin0 := 0;
    begin1 := 0;
    end0 := len1 - 1;
    end1 := len2 - 1;
    Exit;
  end;

  { Advance over matching beginnings of lines. }
  while True do
  begin
    { Check if either side finished. }
    if (py1 > pen1) and (py2 > pen2) then
    begin
      begin0 := -1; begin1 := -1; end0 := -1; end1 := -1;
      Break;
    end;
    if (py1 > pen1) or (py2 > pen2) then
      Break;

    { Handle whitespace logic. }
    if (xwhite <> WHITESPACE_COMPARE_ALL) and (py1 <= pen1) and isSafeWhitespace(str1[py1]) then
    begin
      if (xwhite = WHITESPACE_IGNORE_CHANGE) and not isSafeWhitespace(str2[py2]) then
        Break;  // py1 is white but py2 is not — not skippable
      AdvanceOverWhitespace(py1, pen1, str1);
      AdvanceOverWhitespace(py2, pen2, str2);
      Continue;
    end;
    if (xwhite <> WHITESPACE_COMPARE_ALL) and (py2 <= pen2) and isSafeWhitespace(str2[py2]) then
    begin
      if (xwhite = WHITESPACE_IGNORE_CHANGE) and not isSafeWhitespace(str1[py1]) then
        Break;
      AdvanceOverWhitespace(py1, pen1, str1);
      AdvanceOverWhitespace(py2, pen2, str2);
      Continue;
    end;

    { Compare current code points. glyph length is always 1 in UTF-32. }
    glyphleny1 := 1;
    glyphleny2 := 1;
    if (glyphleny1 <> glyphleny2) or (not matchchar(str1, py1, str2, py2, glyphleny1, casitive)) then
      Break;
    Inc(py1);
    Inc(py2);
  end;

  { Store forward results. }
  begin0 := py1;
  begin1 := py2;

  { Reverse scan. }
  pz1 := pen1;
  pz2 := pen2;

  while True do
  begin
    if (pz1 < py1) and (pz2 < py2) then
    begin
      begin0 := -1; begin1 := -1; end0 := -1; end1 := -1;
      Break;
    end;
    if (pz1 < py1) or (pz2 < py2) then
      Break;

    if (xwhite <> WHITESPACE_COMPARE_ALL) and (pz1 > py1) and isSafeWhitespace(str1[pz1]) then
    begin
      if (xwhite = WHITESPACE_IGNORE_CHANGE) and not isSafeWhitespace(str2[pz2]) then
        Break;
      while (pz1 > py1) and isSafeWhitespace(str1[pz1]) do
        Dec(pz1);
      while (pz2 > py2) and isSafeWhitespace(str2[pz2]) do
        Dec(pz2);
      Continue;
    end;
    if (xwhite <> WHITESPACE_COMPARE_ALL) and (pz2 > py2) and isSafeWhitespace(str2[pz2]) then
    begin
      if (xwhite = WHITESPACE_IGNORE_CHANGE) then
        Break;
      while (pz2 > py2) and isSafeWhitespace(str2[pz2]) do
        Dec(pz2);
      Continue;
    end;

    if (glyphlenz1 <> glyphlenz2) or (not matchchar(str1, pz1, str2, pz2, glyphlenz1, casitive)) then
      Break;
    Dec(pz1);
    Dec(pz2);
  end;

  { Store reverse results. end[i] = pz[i] + glyphlenz[i] - 1 (inclusive).
    In UTF-32, glyphlenz is always 1, so end[i] = pz[i]. }
  if begin0 <> -1 then  // Only update if forward scan found a diff
  begin
    end0 := pz1;
    end1 := pz2;

    { Check if difference region was empty. }
    if (begin0 = end0 + 1) and (begin1 = end1 + 1) then
      begin0 := -1;  // no diff
  end;
end;

{ Ported from stringdiffs.cpp:1083-1113 — wordLevelToByteLevel.
  For each wdiff, extract the substring and call ComputeByteDiff to
  refine down to character level. Adjusts the wdiff's begin/end in place. }
procedure TStringDiff.wordLevelToByteLevel;
var
  i: Integer;
  diff: Twdiff;
  str1_2, str2_2: TCodePointArray;
  begin0, begin1, end0, end1: Integer;
  len1, len2: Integer;
begin
  for i := 0 to High(FWdiffs) do
  begin
    diff := FWdiffs[i];

    { Extract substrings [diff.begin[0] .. diff.end[0]] and [diff.begin[1] .. diff.end[1]].
      Inclusive ranges. If begin > end (empty side), extract empty. }
    len1 := diff.end_[0] - diff.begin_[0] + 1;
    if len1 < 0 then len1 := 0;
    len2 := diff.end_[1] - diff.begin_[1] + 1;
    if len2 < 0 then len2 := 0;

    SetLength(str1_2, len1);
    if len1 > 0 then
      Move(FStr1[diff.begin_[0]], str1_2[0], len1 * SizeOf(TCodePoint));

    SetLength(str2_2, len2);
    if len2 > 0 then
      Move(FStr2[diff.begin_[1]], str2_2[0], len2 * SizeOf(TCodePoint));

    ComputeByteDiff(str1_2, str2_2, FCaseSensitive, FWhitespace,
      begin0, begin1, end0, end1, False);

    { Adjust diff.begin[0] and diff.end[0]. }
    if begin0 = -1 then
    begin
      { No visible diff on side1. }
      FWdiffs[i].end_[0] := FWdiffs[i].begin_[0] - 1;
    end
    else
    begin
      FWdiffs[i].end_[0] := FWdiffs[i].begin_[0] + end0;
      FWdiffs[i].begin_[0] := FWdiffs[i].begin_[0] + begin0;
    end;

    { Adjust diff.begin[1] and diff.end[1]. }
    if begin1 = -1 then
    begin
      FWdiffs[i].end_[1] := FWdiffs[i].begin_[1] - 1;
    end
    else
    begin
      FWdiffs[i].end_[1] := FWdiffs[i].begin_[1] + end1;
      FWdiffs[i].begin_[1] := FWdiffs[i].begin_[1] + begin1;
    end;
  end;
end;

procedure TStringDiff.wordLevelToByteLevelWrapper;
begin
  wordLevelToByteLevel;
end;

procedure TStringDiff.PopulateDiffsWrapper;
begin
  PopulateDiffs;
end;

{ ------------------------------------------------------------------
  Public API — ComputeWordDiffs (2-string overload).
  Ported from stringdiffs.cpp:54-60 (which delegates to the nFiles=2
  branch of the nFiles overload at lines 93-111).
  ------------------------------------------------------------------ }
function ComputeWordDiffs(const str1, str2: TCodePointArray;
  case_sensitive: Boolean; eol_mode: TEolCompareMode;
  whitespace: Integer; ignore_numbers: Boolean;
  breakType: Integer; byte_level: Boolean): TwdiffArray;
var
  sdiffs: TStringDiff;
begin
  Result := nil;  // silence "managed type not initialized" warning
  SetLength(Result, 0);
  sdiffs := TStringDiff.Create(str1, str2, case_sensitive, eol_mode,
    whitespace, ignore_numbers, breakType, Result);
  try
    { Hash all words in both lines and then compare them word by word
      storing differences into m_wdiffs. }
    sdiffs.BuildWordDiffList;

    if byte_level then
      sdiffs.wordLevelToByteLevel;

    { Now copy m_wdiffs into caller-supplied m_pDiffs (coalescing adjacents
      if possible). }
    sdiffs.PopulateDiffs;
  finally
    sdiffs.Free;
  end;
end;

{ ------------------------------------------------------------------
  UTF8ToUTF32 — already implemented in phase 1 stub. Kept verbatim.
  ------------------------------------------------------------------ }
function UTF8ToUTF32(const S: string): TCodePointArray;
var
  n, i, outCount: Integer;
  raw: PByte;
  cp: UInt32;
  b1, b2, b3, b4: Byte;
  tempOut: array of UInt32;
begin
  Result := nil;  // silence "managed type not initialized" warning
  n := Length(S);
  if n = 0 then
  begin
    SetLength(Result, 0);
    Exit;
  end;

  raw := PByte(Pointer(S));
  SetLength(tempOut, n);
  outCount := 0;

  i := 0;
  while i < n do
  begin
    b1 := raw[i];
    Inc(i);

    if b1 < $80 then
    begin
      cp := b1;
    end
    else if (b1 and $E0) = $C0 then
    begin
      if i >= n then
        raise EArgumentException.Create('UTF8ToUTF32: truncated 2-byte UTF-8 sequence');
      b2 := raw[i];
      Inc(i);
      if (b2 and $C0) <> $80 then
        raise EArgumentException.Create('UTF8ToUTF32: invalid continuation byte (2-byte seq)');
      cp := ((UInt32(b1) and $1F) shl 6) or (UInt32(b2) and $3F);
      if cp < $80 then
        raise EArgumentException.Create('UTF8ToUTF32: overlong 2-byte UTF-8 sequence');
    end
    else if (b1 and $F0) = $E0 then
    begin
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
      if cp < $800 then
        raise EArgumentException.Create('UTF8ToUTF32: overlong 3-byte UTF-8 sequence');
      if (cp >= $D800) and (cp <= $DFFF) then
        raise EArgumentException.Create('UTF8ToUTF32: UTF-16 surrogate code point in UTF-8');
    end
    else if (b1 and $F8) = $F0 then
    begin
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
      if cp < $10000 then
        raise EArgumentException.Create('UTF8ToUTF32: overlong 4-byte UTF-8 sequence');
      if cp > $10FFFF then
        raise EArgumentException.Create('UTF8ToUTF32: code point exceeds U+10FFFF');
    end
    else
    begin
      raise EArgumentException.Create('UTF8ToUTF32: invalid UTF-8 lead byte');
    end;

    tempOut[outCount] := cp;
    Inc(outCount);
  end;

  SetLength(Result, outCount);
  if outCount > 0 then
    Move(tempOut[0], Result[0], outCount * SizeOf(TCodePoint));
end;

{ ------------------------------------------------------------------
  WdiffsToOpcodes — convert WinMerge wdiff list to difflib opcodes.
  Ported conceptually from G3: WinMerge returns wdiff list (differences
  only); difflib requires equal regions synthesized.
  ------------------------------------------------------------------ }
function WdiffsToOpcodes(const diffs: TwdiffArray; sizeA, sizeB: Integer): TDiffOpcodeArray;
var
  i: Integer;
  posA, posB: Integer;
  raw: TDiffOpcodeArray;
  rawCount: Integer;
  op: TDiffOpcode;
  side1Empty, side2Empty: Boolean;
  d: Twdiff;
begin
  Result := nil;  // silence "managed type not initialized" warning
  SetLength(raw, Length(diffs) * 2 + 1);
  rawCount := 0;

  posA := 0;
  posB := 0;
  for i := 0 to High(diffs) do
  begin
    d := diffs[i];

    { Synthesize EQUAL/REPLACE/INSERT/DELETE for the gap before this diff.
      DIVERGENCE: When whitespace-ignore flags are active, the gap between
      two wdiffs may have different lengths on side 1 and side 2 (because
      whitespace tokens were skipped on one side but not the other).
      difflib requires 'equal' opcodes to have i2-i1 == j2-j1. If the gap
      lengths differ, we emit REPLACE (or INSERT/DELETE if one side is empty)
      instead of EQUAL — this preserves the difflib contract while remaining
      faithful to the WinMerge word-level diff (which considers these regions
      "matched" under the ignore rules, but they're not byte-for-byte equal). }
    if (posA < d.begin_[0]) or (posB < d.begin_[1]) then
    begin
      if (d.begin_[0] - posA) = (d.begin_[1] - posB) then
      begin
        { Gap lengths match — emit EQUAL. }
        op.Tag := cTagEqual;
      end
      else if (d.begin_[0] > posA) and (d.begin_[1] > posB) then
      begin
        { Both sides non-empty but different lengths — emit REPLACE. }
        op.Tag := cTagReplace;
      end
      else if (d.begin_[0] > posA) then
      begin
        { Only side 1 has content — emit DELETE. }
        op.Tag := cTagDelete;
      end
      else
      begin
        { Only side 2 has content — emit INSERT. }
        op.Tag := cTagInsert;
      end;
      op.I1 := posA;
      op.I2 := d.begin_[0];
      op.J1 := posB;
      op.J2 := d.begin_[1];
      raw[rawCount] := op;
      Inc(rawCount);
    end;

    { Determine empty sides (WinMerge encodes empty as end = begin - 1). }
    side1Empty := (d.end_[0] < d.begin_[0]);
    side2Empty := (d.end_[1] < d.begin_[1]);

    if side1Empty and (not side2Empty) then
    begin
      { Pure insertion. }
      op.Tag := cTagInsert;
      op.I1 := d.begin_[0];
      op.I2 := d.begin_[0];  // empty on side 1
      op.J1 := d.begin_[1];
      op.J2 := d.end_[1] + 1;  // +1: WinMerge inclusive → difflib half-open
    end
    else if side2Empty and (not side1Empty) then
    begin
      { Pure deletion. }
      op.Tag := cTagDelete;
      op.I1 := d.begin_[0];
      op.I2 := d.end_[0] + 1;
      op.J1 := d.begin_[1];
      op.J2 := d.begin_[1];  // empty on side 2
    end
    else if (not side1Empty) and (not side2Empty) then
    begin
      { Replace. }
      op.Tag := cTagReplace;
      op.I1 := d.begin_[0];
      op.I2 := d.end_[0] + 1;
      op.J1 := d.begin_[1];
      op.J2 := d.end_[1] + 1;
    end
    else
    begin
      { Both sides empty — skip (shouldn't happen after PopulateDiffs). }
      Continue;
    end;

    raw[rawCount] := op;
    Inc(rawCount);

    posA := d.end_[0] + 1;
    posB := d.end_[1] + 1;
  end;

  { Final gap (trailing equal region).
    DIVERGENCE: Same as above — if gap lengths differ due to whitespace
    skipping, emit REPLACE/INSERT/DELETE instead of EQUAL. }
  if (posA < sizeA) or (posB < sizeB) then
  begin
    if (sizeA - posA) = (sizeB - posB) then
      op.Tag := cTagEqual
    else if (sizeA > posA) and (sizeB > posB) then
      op.Tag := cTagReplace
    else if (sizeA > posA) then
      op.Tag := cTagDelete
    else
      op.Tag := cTagInsert;
    op.I1 := posA;
    op.I2 := sizeA;
    op.J1 := posB;
    op.J2 := sizeB;
    raw[rawCount] := op;
    Inc(rawCount);
  end;

  SetLength(Result, rawCount);
  if rawCount > 0 then
    Move(raw[0], Result[0], rawCount * SizeOf(TDiffOpcode));
end;

{ ------------------------------------------------------------------
  DoDiffChars — public entry point.
  Replaces the phase 1 stub body with the real WinMerge port.
  ------------------------------------------------------------------ }
function DoDiffChars(const ATextA, ATextB: string; AFlags: Integer): TDiffOpcodeArray;
var
  CPA, CPB: TCodePointArray;
  CaseSensitive: Boolean;
  EolMode: TEolCompareMode;
  Whitespace: Integer;
  IgnoreNumbers: Boolean;
  BreakType: Integer;
  ByteLevel: Boolean;
  Diffs: TwdiffArray;
begin
  Result := nil;  // silence "managed type not initialized" warning

  CPA := UTF8ToUTF32(ATextA);
  CPB := UTF8ToUTF32(ATextB);

  { G16: both empty → [] (matches difflib). }
  if (Length(CPA) = 0) and (Length(CPB) = 0) then
  begin
    SetLength(Result, 0);
    Exit;
  end;

  { Map DIFF_IGN_* flags to WinMerge options (see G5). }
  CaseSensitive := (AFlags and 1) = 0;                // DIFF_IGN_CASE = 1
  IgnoreNumbers := (AFlags and 128) <> 0;             // DIFF_IGN_NUMBERS = 128

  if (AFlags and 64) <> 0 then                         // DIFF_IGN_EOL = 64
    EolMode := eolIgnore
  else
    EolMode := eolStrict;
  { EOL_AS_SPACE is never used via DoDiffChars — only EOL_STRICT and EOL_IGNORE. }

  { Whitespace flag precedence (G5):
    DIFF_IGN_WHITESPACE (2) wins → WHITESPACE_IGNORE_ALL
    else if any of (4, 8, 16) set → WHITESPACE_IGNORE_CHANGE
    else → WHITESPACE_COMPARE_ALL }
  if (AFlags and 2) <> 0 then                          // DIFF_IGN_WHITESPACE
    Whitespace := WHITESPACE_IGNORE_ALL
  else if (AFlags and (4 or 8 or 16)) <> 0 then        // CHANGE / EOL / BEGINNING
    Whitespace := WHITESPACE_IGNORE_CHANGE
  else
    Whitespace := WHITESPACE_COMPARE_ALL;

  { DIFF_IGN_BLANK_LINES (32) is silently ignored at char-level (G7). }

  BreakType := 1;    { always break on punctuation — matches Differ plugin expectations }
  ByteLevel := True; { always refine to char level — Differ plugin uses char-level highlights }

  { Call the ported WinMerge engine. }
  Diffs := ComputeWordDiffs(CPA, CPB, CaseSensitive, EolMode, Whitespace,
    IgnoreNumbers, BreakType, ByteLevel);

  { Convert wdiff list → difflib opcodes (see G3). }
  Result := WdiffsToOpcodes(Diffs, Length(CPA), Length(CPB));
end;

end.
