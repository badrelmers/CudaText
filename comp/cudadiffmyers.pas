(*
  CudaDiff — Free Pascal port of WinMerge's bundled GNU diffutils 2.7
  Myers line-diff engine.

  Ported from (pinned tag v2.16.58):
    https://github.com/WinMerge/winmerge/blob/v2.16.58/Src/diffutils/src/analyze.c
    https://github.com/WinMerge/winmerge/blob/v2.16.58/Src/diffutils/src/diff.h
    https://github.com/WinMerge/winmerge/blob/v2.16.58/Src/diffutils/src/io.c
    https://github.com/WinMerge/winmerge/blob/v2.16.58/Src/diffutils/src/util.c
    https://github.com/WinMerge/winmerge/blob/v2.16.58/Src/diffutils/src/system.h

  The Myers core (analyze.c:diag + compareseq) was originally described in:
    "An O(ND) Difference Algorithm and its Variations", Eugene Myers,
    Algorithmica 1(2):251-266, 1986, section 4.2.

  Unless the --minimal option is specified, this code uses the TOO_EXPENSIVE
  heuristic, by Paul Eggert, to limit the cost to O(N**1.5 log N) at the price
  of producing suboptimal output for large inputs with many differences.
  Related algorithms are surveyed by Alfred V. Aho in section 6.3 of
  'Algorithms for Finding Patterns in Strings', Handbook of Theoretical
  Computer Science (Jan Van Leeuwen, ed.), Vol. A, Algorithms and Complexity,
  Elsevier/MIT Press, 1990, pp. 255--300.

  License: GPL-2.0-or-later (same as GNU diffutils 2.7, as bundled by WinMerge
  under /Src/diffutils/). The WinMerge port keeps the original COPYING file.

  ----------------------------------------------------------------
  What this unit provides
  ----------------------------------------------------------------
  Public types/functions consumed by formmain_py_api.inc:

    type
      TDiffOpcode = record
        Tag: Integer;   // 0=equal, 1=delete, 2=insert, 3=replace
                         // (matches DIFF_TAG_* in proc_py_const.pas —
                         //  those constants are NOT redefined here, see G13)
        I1, I2, J1, J2: Integer;
      end;
      TDiffOpcodeArray = array of TDiffOpcode;

    function DoDiffTexts(const ATextA, ATextB: string;
                        AAlgo: Integer;
                        AFlags: Integer): TDiffOpcodeArray;

  The AAlgo parameter is ACCEPTED but IGNORED — there is only one algorithm
  now (GNU diffutils Myers with Eggert heuristic). DIFF_ALGO_HISTOGRAM (1)
  is silently mapped to Myers (see plan G5, G31). Document this divergence
  at the top of DoDiffTexts.

  ----------------------------------------------------------------
  Source files ported
  ----------------------------------------------------------------
    Diffutils file                           | Pascal counterpart
  ------------------------------------------|---------------------------
    analyze.c: diag (lines 110-332)          | Diag
    analyze.c: compareseq (lines 348-400)    | CompareSeq
    analyze.c: discard_confusing_lines       | DiscardConfusingLines
              (lines 414-614)                |
    analyze.c: shift_boundaries              | ShiftBoundaries
              (lines 628-726)                |
    analyze.c: add_change (lines 736-750)   | AddChange
    analyze.c: build_script (lines 792-821) | BuildScript
    analyze.c: diff_2_files (lines 838-1119) | Diff2Files
    diff.h: struct change (lines 224-235)   | TChange
    diff.h: struct file_data (lines 241-307)| TFileData (simplified — G8)
    diff.h: struct partition (analyze.c:63) | TDiagPartition
    io.c: find_and_hash_each_line            | FindAndHashEachLine
       (lines 261-488)                       |
    io.c: find_identical_ends (lines 728-965)| FindIdenticalEnds
    io.c: prepare_text_end (lines 498-722)  | PrepareTextEnd (simplified — G8)
    io.c: HASH/ROL macros (lines 24-29)     | HashByte
    io.c: ISWSPACE (lines 253-257)          | IsWSpace
    io.c: read_files (lines 1012-1137)      | (replaced by Diff2Files)
    util.c: line_cmp (lines 298-511)        | LineCmp
    util.c: analyze_hunk (lines 798-874)     | AnalyzeHunk
    util.c: is_blank_line (lines 772-783)   | IsBlankLine
    util.c: iseolch (lines 767-770)         | IsEolCh
    util.c: translate_line_number            | (not needed — G3 mapping)
              (lines 733-737)                |
    system.h: INT_MAX, CHAR_BIT, UINT_BIT,  | constants
              TAB_WIDTH, HUGE, FSIZE         |
    CompareOptions.cpp: SetToDiffUtils()     | InitContext (flag mapping, G5)
              (lines 132-179)                |

  ----------------------------------------------------------------
  Documented divergences from diffutils
  ----------------------------------------------------------------
  1. State encapsulation (G11): GNU diffutils uses thread-local statics
     (DECL_TLS) for all globals (xvec, yvec, fdiag, bdiag, too_expensive,
     no_discards, inhibit, heuristic, files[2], and the io.c equivs hash
     state). The Pascal port encapsulates all state in a TDiffContext record
     passed to each function. This is cleaner, avoids threadvar overhead,
     and makes the code reentrant.

  2. file_data simplification (G8): GNU diffutils' file_data has many fields
     for file I/O, binary detection, Unicode transcoding, and EOL
     statistics. The Pascal port receives already-decoded UTF-8 strings, so
     file I/O (sip/slurp/read_files), Unicode transcoding
     (prepare_text_end's UCS-2/UCS-4 branches), BOM detection, binary
     detection (binary_file_p), and EOL statistics (count_crlfs, count_crs,
     count_lfs, count_zeros) are omitted. The line-splitting logic (scan
     for \n, \r\n, \r) and the EOL-normalization (for ignore_eol_diff) are
     preserved.

  3. No prefix-line recording in linbuf: GNU diffutils records the
     identical-prefix lines in linbuf (offset by linbuf_base) for output
     formatting (-D option). The Pascal port does not record prefix lines
     (they are not needed for the diff algorithm — only for output). The
     prefix_lines count is still tracked for the opcode conversion (G3).

  4. No moved-block detection (G36.3): The match0/match1 fields of TChange
     are always -1. WinMerge's moved_block_analysis() is a separate post-
     processing pass that we don't need for basic line diff.

  5. No 3-way diff (G36.4): Only 2-way. WinMerge's ComputeWordDiffs(nStrings=3,
     ...) overload is not ported.

  6. Whole-file in memory (G36.5): Like the previous JGit port, the diffutils
     port loads the entire file into memory. For 200MB+ files, this may
     cause memory pressure.

  7. Output not guaranteed minimal (G36.1): The Eggert heuristic trades
     optimality for speed. Two correct ports may produce different (both
     valid) hunk boundaries. This is by design.

  8. heuristic = 1 always (G36.2): The --minimal path (no_discards = 1) is
     never used. WinMerge hardcodes heuristic = 1, no_discards = 0,
     inhibit = 0.

  9. Compiler mode (G9, G12): CudaText is compiled with -Cr -Co (range +
     overflow checks). The HASH macro and the changed_flag sentinel
     arithmetic intentionally use unsigned wraparound and negative indexing,
     so we wrap the affected code in $PUSH/$R-/$Q-...$POP.

  10. DIFF_IGN_WHITESPACE_EOL / DIFF_IGN_WHITESPACE_BEGINNING (G5): Both
      map to diffutils' ignore_space_change_flag. GNU diffutils has no
      separate leading/trailing mode — ignore_space_change handles both.

  11. DIFF_IGN_CASE (G6): ASCII-only tolower per byte (matching WinMerge
      io.c:348 behavior), NOT Unicode case folding. Bytes 0x80-0xFF pass
      through unchanged.

  12. DIFF_IGN_EOL (G29): EOL normalization happens before hashing (in
      PrepareTextEnd), mapping \r\n → \n and lone \r → \n. This makes
      ignore_eol_diff work correctly with the rolling hash (otherwise \r\n
      vs \n would produce different hashes and never reach line_cmp).

  13. DIFF_IGN_BLANK_LINES (G7): Implemented as a post-diff hunk-suppression
      pass. After BuildScript, each change is checked via AnalyzeHunk. If
      trivial (all deleted+inserted lines are blank), the change is marked
      trivial=1. In ChangesToOpcodes, trivial changes are suppressed (not
      emitted as delete/insert/replace); the surrounding equal regions are
      merged to maintain difflib invariants.

  14. UTF-8 byte-level (G4): Pascal string under objfpc{$H+} is AnsiString
      containing UTF-8 bytes. This matches diffutils' char* semantics 1:1.
      All byte-level operations work on raw UTF-8 bytes. No
      UnicodeString/WideString/UnicodeLowerCase anywhere in this unit.

  15. DIFF_ALGO_HISTOGRAM (1) silently mapped to Myers (G31): There is
      only one algorithm now. The Differ plugin currently passes algo=1
      by default; this is now equivalent to algo=0. The output may differ
      slightly from the previous JGit Histogram port (patience-like
      anchoring on unique lines is replaced by Myers output), but is still
      valid difflib opcodes.
*)

unit CudaDiffMyers;

{$mode objfpc}{$H+}
{$ModeSwitch advancedrecords}

interface

uses
  Classes, SysUtils;

{ The DIFF_IGN_* / DIFF_ALGO_* / DIFF_TAG_* constants are defined in
  proc_py_const.pas. We do NOT redefine them here (G13). formmain_py_api.inc
  pulls them in via its own uses clause. Inside this unit we use the integer
  literals directly, with private aliases below for readability. }

const
  { Algorithm selectors — must match proc_py_const.pas DIFF_ALGO_* }
  cAlgoMyers     = 0;
  cAlgoHistogram = 1;

  { Ignore flags — must match proc_py_const.pas DIFF_IGN_* }
  cIgnCase                 = 1;      // DIFF_IGN_CASE
  cIgnWhitespace           = 2;      // DIFF_IGN_WHITESPACE
  cIgnWhitespaceChange     = 4;      // DIFF_IGN_WHITESPACE_CHANGE
  cIgnWhitespaceEol        = 8;      // DIFF_IGN_WHITESPACE_EOL
  cIgnWhitespaceBeginning  = 16;     // DIFF_IGN_WHITESPACE_BEGINNING
  cIgnBlankLines           = 32;     // DIFF_IGN_BLANK_LINES
  cIgnEol                  = 64;     // DIFF_IGN_EOL
  cIgnNumbers              = 128;    // DIFF_IGN_NUMBERS

  { Opcode tag values — must match proc_py_const.pas DIFF_TAG_* }
  cTagEqual   = 0;
  cTagDelete  = 1;
  cTagInsert  = 2;
  cTagReplace = 3;

  { SNAKE_LIMIT from analyze.c:61 — snakes longer than this are "big"
    (Eggert big_snake heuristic, G20). }
  cSnakeLimit = 20;

  { INT_MAX from system.h:155 — used by diag's backward search. }
  cIntMax = 2147483647;

type
  { Public opcode type. Same layout as CudaDiffChars.TDiffOpcode but a
    SEPARATE Pascal type (G14) — the two units must not alias. }
  TDiffOpcode = record
    Tag: Integer;   // 0=equal, 1=delete, 2=insert, 3=replace
    I1, I2, J1, J2: Integer;
  end;
  TDiffOpcodeArray = array of TDiffOpcode;

  { Forward declarations }
  PChange = ^TChange;

  { ----------------------------------------------------------------
    TChange — ported from diff.h:224-235 struct change
    ----------------------------------------------------------------
    The result of comparison is an "edit script": a chain of TChange records.
    Each TChange represents one place where some lines are deleted and some
    are inserted.

    Line0/Line1 are 0-based INTERNAL line indices (relative to the
    differing region, after the identical prefix is trimmed). To get actual
    file line numbers, add PrefixLines (see G3 / translate_line_number).

    If Deleted = 0, then Line0 is the line before which the insertion was
    done; vice versa for Inserted and Line1. }
  TChange = record
    Link: PChange;          // Next change in list (forward order from build_script)
    Inserted: Integer;       // # lines of file 1 changed here
    Deleted: Integer;       // # lines of file 0 changed here
    Line0: Integer;         // Line number of 1st deleted line (0-based, internal)
    Line1: Integer;         // Line number of 1st inserted line (0-based, internal)
    Ignore: Byte;           // Flag used in context.c (unused by WinMerge UI)
    Trivial: Byte;          // 1 if change is trivial (ignored blanks/filtered)
    Match0: Integer;        // Moved-block: side0 matching line for line 1 (-1)
    Match1: Integer;        // Moved-block: side1 matching line for line 0 (-1)
  end;

  { ----------------------------------------------------------------
    TFileData — ported from diff.h:241-307 struct file_data
    ----------------------------------------------------------------
    DIVERGENCE (G8): Simplified for in-memory string input. GNU diffutils'
    file I/O (sip/slurp/read_files), Unicode transcoding (prepare_text_end
    UCS-2/UCS-4 branches), BOM detection, binary detection, and EOL
    statistics are omitted because CudaText's API receives already-decoded
    UTF-8 strings. The line-splitting logic (scan for \n, \r\n, \r) and the
    EOL-normalization (for ignore_eol_diff) are preserved.

    Indexing convention: linbuf[0] = first DIFFERING line (after the
    identical prefix). Prefix lines are NOT recorded. Linbuf has
    BufferedLines + suffix_lines + 1 entries (the +1 is the bufend sentinel
    at linbuf[ValidLines]). }
  TFileData = record
    Buffer: PByte;            // Raw UTF-8 bytes (private mutable copy)
    BufferedChars: Integer;   // Byte count
    Linbuf: array of PByte;   // Line start pointers (linbuf[0] = first differing line)
    BufferedLines: Integer;   // Count of differing lines (between prefix and suffix)
    ValidLines: Integer;      // Count of differing + suffix lines
    Equivs: array of Integer; // Equivalence class per line (indexed by internal line)
    Undiscarded: array of Integer; // Equivs with junk squeezed out
    Realindexes: array of Integer; // Virtual→real line number map
    NondiscardedLines: Integer;     // Count of non-discarded lines
    ChangedFlag: PByte;       // Output: 1 = line changed (WITH sentinels — G9)
    PrefixLines: Integer;     // Count of identical prefix lines
    MissingNewline: Integer;  // 1 if file doesn't end with newline
    EquivMax: Integer;        // 1 + max equivalence value used (shared with sibling)
    PrefixEnd: PByte;         // Pointer to end of identical prefix
    SuffixBegin: PByte;        // Pointer to start of identical suffix
    OwnBuffer: PByte;         // Original allocation for Buffer (for freeing)
  end;

  { ----------------------------------------------------------------
    TDiagPartition — ported from analyze.c:63-68 struct partition
    ---------------------------------------------------------------- }
  TDiagPartition = record
    Xmid, Ymid: Integer;     // Midpoints of this partition
    LoMinimal: Integer;      // Nonzero if low half will be analyzed minimally
    HiMinimal: Integer;      // Likewise for high half
  end;

  { ----------------------------------------------------------------
    TEquivClass — ported from io.c:53-59 struct equivclass
    ----------------------------------------------------------------
    Lines are put into equivalence classes (of lines that match in line_cmp).
    Each class is represented by one of these records while classes are
    being computed. Afterward each class is represented by a number. }
  TEquivClass = record
    Next: Integer;           // Next item in this bucket (index into Equivs[])
    Hash: Cardinal;          // Hash of lines in this class
    Line: PByte;             // A line that fits this class
    Length: Integer;         // The length of that line
  end;

  { ----------------------------------------------------------------
    TDiffContext — encapsulates diffutils thread-local globals (G11 Option 2)
    ----------------------------------------------------------------
    DIVERGENCE: GNU diffutils uses thread-local statics (DECL_TLS) for all
    globals. The Pascal port encapsulates all state in a TDiffContext record
    passed to each function. This is cleaner, avoids threadvar overhead, and
    makes the code reentrant. }
  TDiffContext = record
    Files: array[0..1] of TFileData;
    Xvec: PInteger;           // Pointer into Files[0].Undiscarded
    Yvec: PInteger;           // Pointer into Files[1].Undiscarded
    Fdiag: PInteger;          // Forward diagonal search vector
    Bdiag: PInteger;          // Backward diagonal search vector
    TooExpensive: Integer;    // Edit-script cost cutoff (Eggert heuristic, G20)
    NoDiscards: Integer;      // Disables discard_confusing_lines (always 0)
    Inhibit: Integer;         // Disables shift_boundaries (always 0)
    Heuristic: Integer;       // Enables Eggert heuristics (always 1)

    { Flag mapping (G5) — DIFF_IGN_* → diffutils globals }
    IgnoreCaseFlag: Integer;
    IgnoreAllSpaceFlag: Integer;
    IgnoreSpaceChangeFlag: Integer;
    IgnoreBlankLinesFlag: Integer;
    IgnoreEolDiff: Integer;
    IgnoreNumbersFlag: Integer;
    IgnoreSomeChanges: Integer;
    LengthVaries: Integer;

    { Equivs hash-table state (io.c:62-77) — used during FindAndHashEachLine
      for both files, then released. }
    Buckets: array of Integer;     // Hash table: array of bucket head indices
    NBuckets: Integer;
    EquivsClasses: array of TEquivClass; // Array of equiv classes
    EquivsIndex: Integer;          // Index of first free element in EquivsClasses
    EquivsAlloc: Integer;          // Number of elements allocated in EquivsClasses

    { Owned memory for cleanup (allocated via GetMem, freed in FreeContext) }
    FdiagAlloc: PInteger;     // Original allocation for Fdiag/Bdiag
    ChangedFlagAlloc: PByte;  // Original allocation for ChangedFlag (sentinel base)
  end;

function DoDiffTexts(const ATextA, ATextB: string; AAlgo: Integer; AFlags: Integer): TDiffOpcodeArray;

implementation

{ ==================================================================
  Section 1: Byte-level helpers (io.c, util.c)
  ==================================================================

  These mirror the C macros/inline functions used throughout the hashing and
  comparison code. They are byte-level (not Unicode) by design — diffutils
  operates on char* and Pascal strings under objfpc{$H+} are AnsiString
  containing UTF-8 bytes (G4). }

{ ISWSPACE — ported from io.c:253-257 (also util.c:288-292)
  ASCII-only: space (0x20) and tab (0x09) only.
  NOT \r/\n/\v/\f — those are handled by the line-splitting loop and iseolch. }
function IsWSpace(c: Byte): Boolean; inline;
begin
  Result := (c = $20) or (c = $09);
end;

{ iseolch — ported from util.c:767-770
  Returns true for \n (0x0A) and \r (0x0D). }
function IsEolCh(c: Byte): Boolean; inline;
begin
  Result := (c = $0A) or (c = $0D);
end;

{ is_blank_line — ported from util.c:772-783
  Returns 1 if the line [pch, limit) is blank: contains only spaces, tabs,
  and is terminated by \n or \r (or end of buffer). }
function IsBlankLine(pch: PByte; limit: PByte): Boolean;
begin
  while pch < limit do
  begin
    if (pch^ = $0A) or (pch^ = $0D) then
      Break;
    if (pch^ <> $20) and (pch^ <> $09) then
      Exit(False);
    Inc(pch);
  end;
  Exit(True);
end;

{ ASCII-only isupper — matches WinMerge io.c:348 `isupper(c)` on 0x00-0x7F.
  Bytes 0x80-0xFF pass through unchanged (matches WinMerge's locale-dependent
  behavior for the high byte range, consistent across locales). }
function IsAsciiUpper(c: Byte): Boolean; inline;
begin
  Result := (c >= $41) and (c <= $5A);  // 'A'..'Z'
end;

{ ASCII-only tolower — matches WinMerge io.c:348 `isupper(c) ? tolower(c) : c`.
  NOT Unicode case folding (G6). }
function ToAsciiLower(c: Byte): Byte; inline;
begin
  if (c >= $41) and (c <= $5A) then
    Result := c + $20  // 'A'..'Z' -> 'a'..'z'
  else
    Result := c;
end;

{ ASCII-only isdigit — matches WinMerge io.c:307 `isdigit(c)`.
  Only ASCII [0-9] counts; non-ASCII digits are NOT skipped. }
function IsAsciiDigit(c: Byte): Boolean; inline;
begin
  Result := (c >= $30) and (c <= $39);  // '0'..'9'
end;

{ HASH macro — ported from io.c:24-29
  Per-byte: h := (c) + ROL(h, 7). Wraps on overflow intentionally (G10).
  Use Cardinal (unsigned 32-bit) to match `unsigned int` in C. }
{$PUSH}{$R-}{$Q-}
function HashByte(h: Cardinal; c: Byte): Cardinal; inline;
begin
  Result := Cardinal(c) + ((h shl 7) or (h shr 25));
end;
{$POP}

{ ==================================================================
  Section 2: Memory helpers (util.c)
  ================================================================== }

{ xmalloc — ported from util.c:878-895. Pascal's GetMem already raises
  EOutOfMemory on failure, so we don't need the explicit fatal() call. }
function XGetMem(size: PtrInt): Pointer;
begin
  if size = 0 then
    size := 1;
  Result := GetMem(size);
  FillChar(Result^, size, 0);
end;

{ xrealloc — ported from util.c:899-916. Pascal's ReallocMemory already
  handles size=0 and EOutOfMemory on failure. We zero the new bytes. }
function XReallocMem(old: Pointer; oldSize, newSize: PtrInt): Pointer;
begin
  if newSize = 0 then
    newSize := 1;
  Result := ReallocMemory(old, newSize);
  if Result = nil then
    Result := GetMem(newSize);
  if newSize > oldSize then
    FillChar((Result + oldSize)^, newSize - oldSize, 0);
end;

{ ==================================================================
  Section 3: Context initialization and cleanup
  ================================================================== }

{ InitContext — flag mapping (G5), based on
  WinMerge CompareOptions.cpp:132-179 DiffutilsOptions::SetToDiffUtils().

  Maps DIFF_IGN_* bitmask → diffutils globals. Computes derived flags
  (ignore_some_changes, length_varies). Hardcodes WinMerge's fixed values
  (heuristic=1, no_discards=0, inhibit=0). }
procedure InitContext(out Ctx: TDiffContext; AFlags: Integer);
begin
  FillChar(Ctx, SizeOf(Ctx), 0);

  { Whitespace precedence (G30):
    - DIFF_IGN_WHITESPACE (2) wins → ignore_all_space_flag = 1, ignore_space_change_flag = 0
    - Else if any of (4, 8, 16) set → ignore_space_change_flag = 1, ignore_all_space_flag = 0
    - Else → both 0 }
  if (AFlags and cIgnWhitespace) <> 0 then
  begin
    Ctx.IgnoreAllSpaceFlag := 1;
    Ctx.IgnoreSpaceChangeFlag := 0;
  end
  else if (AFlags and (cIgnWhitespaceChange or cIgnWhitespaceEol or cIgnWhitespaceBeginning)) <> 0 then
  begin
    Ctx.IgnoreAllSpaceFlag := 0;
    Ctx.IgnoreSpaceChangeFlag := 1;
  end
  else
  begin
    Ctx.IgnoreAllSpaceFlag := 0;
    Ctx.IgnoreSpaceChangeFlag := 0;
  end;

  { Direct flag mappings (G5) }
  if (AFlags and cIgnCase) <> 0 then
    Ctx.IgnoreCaseFlag := 1;
  if (AFlags and cIgnNumbers) <> 0 then
    Ctx.IgnoreNumbersFlag := 1;
  if (AFlags and cIgnEol) <> 0 then
    Ctx.IgnoreEolDiff := 1;
  if (AFlags and cIgnBlankLines) <> 0 then
    Ctx.IgnoreBlankLinesFlag := 1;

  { Derived flags (G5) }
  Ctx.IgnoreSomeChanges := 0;
  if (Ctx.IgnoreCaseFlag <> 0) or (Ctx.IgnoreSpaceChangeFlag <> 0) or
     (Ctx.IgnoreAllSpaceFlag <> 0) or (Ctx.IgnoreEolDiff <> 0) or
     (Ctx.IgnoreNumbersFlag <> 0) then
    Ctx.IgnoreSomeChanges := 1;

  Ctx.LengthVaries := 0;
  if (Ctx.IgnoreAllSpaceFlag <> 0) or (Ctx.IgnoreSpaceChangeFlag <> 0) then
    Ctx.LengthVaries := 1;

  { Fixed values (WinMerge hardcodes these, G5) }
  Ctx.Heuristic := 1;       // Eggert heuristic ALWAYS ON — the performance key
  Ctx.NoDiscards := 0;      // Enable discard_confusing_lines (performance)
  Ctx.Inhibit := 0;          // Enable shift_boundaries
end;

{ FreeContext — release all per-call allocations. Called at the end of
  DoDiffTexts. The Pascal dynamic arrays (Linbuf, Equivs, Undiscarded,
  Realindexes, Buckets, EquivsClasses) are reference-counted and freed
  automatically when Ctx goes out of scope, but the GetMem'd buffers
  (Buffer, ChangedFlag, Fdiag/Bdiag) need explicit FreeMem. }
procedure FreeContext(var Ctx: TDiffContext);
var
  F: Integer;
begin
  for F := 0 to 1 do
  begin
    if Ctx.Files[F].OwnBuffer <> nil then
    begin
      FreeMem(Ctx.Files[F].OwnBuffer);
      Ctx.Files[F].OwnBuffer := nil;
      Ctx.Files[F].Buffer := nil;
    end;
  end;
  if Ctx.ChangedFlagAlloc <> nil then
  begin
    FreeMem(Ctx.ChangedFlagAlloc);
    Ctx.ChangedFlagAlloc := nil;
    Ctx.Files[0].ChangedFlag := nil;
    Ctx.Files[1].ChangedFlag := nil;
  end;
  if Ctx.FdiagAlloc <> nil then
  begin
    FreeMem(Ctx.FdiagAlloc);
    Ctx.FdiagAlloc := nil;
    Ctx.Fdiag := nil;
    Ctx.Bdiag := nil;
  end;
  { Dynamic arrays are freed automatically when Ctx goes out of scope, but
    we clear them to be safe. }
  SetLength(Ctx.Buckets, 0);
  SetLength(Ctx.EquivsClasses, 0);
  for F := 0 to 1 do
  begin
    SetLength(Ctx.Files[F].Linbuf, 0);
    SetLength(Ctx.Files[F].Equivs, 0);
    SetLength(Ctx.Files[F].Undiscarded, 0);
    SetLength(Ctx.Files[F].Realindexes, 0);
  end;
end;

{ ==================================================================
  Section 4: File loading and prepare_text_end (io.c)
  ================================================================== }

{ LoadFile — replaces io.c sip+slurp+prepare_text_end for the Pascal port.
  Makes a private mutable copy of the input string, applies EOL
  normalization (for ignore_eol_diff), appends a trailing \n if missing,
  and stores the result in Ctx.Files[Idx].

  DIVERGENCE (G8): GNU diffutils reads from a file descriptor and builds
  the buffer via sip+slurp+prepare_text_end, with BOM detection and
  Unicode transcoding. The Pascal port receives an already-decoded UTF-8
  string, so file I/O and Unicode transcoding are omitted. The
  line-splitting logic (scan for \n, \r\n, \r) is preserved in
  FindIdenticalEnds and FindAndHashEachLine. }
procedure LoadFile(out Ctx: TDiffContext; Idx: Integer; const Text: string);
var
  SrcLen: Integer;
  Src: PByte;
  Buf: PByte;
  BufLen: Integer;
  F: ^TFileData;
  R, W: PByte;
  EndPtr: PByte;
begin
  F := @Ctx.Files[Idx];

  SrcLen := Length(Text);
  if SrcLen > 0 then
    Src := PByte(Text)
  else
    Src := nil;

  { Allocate a private mutable copy with room for:
    - The original bytes
    - A possible appended \n (for missing_newline)
    - EOL normalization shrinkage (no extra room needed — output <= input)
    - A 4-byte zero sentinel word at the end (for find_identical_ends'
      word-at-a-time comparison — we use byte comparison, but the sentinel
      also guards find_and_hash_each_line's p[0]/p[1] lookahead) }
  Buf := GetMem(SrcLen + 8);
  FillChar(Buf^, SrcLen + 8, 0);
  if SrcLen > 0 then
    Move(Src^, Buf^, SrcLen);
  BufLen := SrcLen;

  F^.OwnBuffer := Buf;
  F^.Buffer := Buf;
  F^.BufferedChars := BufLen;

  { prepare_text_end (io.c:498-722) — simplified for in-memory UTF-8 input.

    Step 1: If buffer doesn't end in \n or \r, append \n (and remember
    missing_newline). This is needed so the line-splitting loop in
    find_and_hash_each_line can find a terminator for the last line. }
  if (BufLen = 0) or ((Buf[BufLen - 1] <> $0A) and (Buf[BufLen - 1] <> $0D)) then
  begin
    Buf[BufLen] := $0A;
    Inc(BufLen);
    F^.MissingNewline := 1;
  end
  else
    F^.MissingNewline := 0;

  { Step 2: If ignore_eol_diff, normalize EOL: \r\n → \n, lone \r → \n.
    This is done in-place forward (write pointer never exceeds read pointer,
    so it's safe). Without this normalization, \r\n vs \n would produce
    different rolling hashes and never reach line_cmp — making ignore_eol_diff
    ineffective (G29 divergence). }
  if Ctx.IgnoreEolDiff <> 0 then
  begin
    { EOL normalization: \r\n becomes \n (one byte), lone \r becomes \n,
      \n stays \n. We do this in-place; the buffer length may shrink. }
    R := Buf;
    W := Buf;
    EndPtr := Buf + BufLen;
    while R < EndPtr do
    begin
      if R^ = $0D then  { \r }
      begin
        W^ := $0A;     { write \n }
        Inc(W);
        Inc(R);
        if (R < EndPtr) and (R^ = $0A) then  { \r\n }
          Inc(R);  { skip the \n (already wrote one \n for the \r) }
      end
      else
      begin
        W^ := R^;
        Inc(W);
        Inc(R);
      end;
    end;
    BufLen := W - Buf;
  end;

  { Step 3: Zero 4 bytes at the end (sentinel word — io.c:720).
    find_identical_ends' word-at-a-time comparison reads past the buffer end
    by 1 word; we use byte comparison instead, but the zero sentinel also
    guards find_and_hash_each_line's p[0]/p[1] lookahead at the last byte. }
  FillChar((Buf + BufLen)^, 4, 0);

  F^.Buffer := Buf;
  F^.BufferedChars := BufLen;
end;

{ ==================================================================
  Section 5: FindIdenticalEnds (io.c:728-965)
  ==================================================================

  Given two file_data objects, find the identical prefixes and suffixes.
  Sets Files[f].PrefixEnd, Files[f].SuffixBegin, Files[f].PrefixLines.

  DIVERGENCE: We do NOT record prefix lines in linbuf (they are not needed
  for the diff algorithm — only for output formatting). The prefix_lines
  count is still tracked for the opcode conversion (G3). The C code uses
  word-at-a-time comparison for speed; we use byte comparison (simpler,
  avoids the sentinel insertion trick). }
procedure FindIdenticalEnds(var Ctx: TDiffContext);
var
  Buf0, Buf1: PByte;
  N0, N1: Integer;
  P0, P1: PByte;
  PrefixEnd0, PrefixEnd1: PByte;
  SuffixBegin0, SuffixBegin1: PByte;
  End0, Beg0: PByte;
  I: Integer;
  LineStart: Boolean;
  PrefixLines: Integer;
  MissingNl0, MissingNl1: Integer;
begin
  Buf0 := Ctx.Files[0].Buffer;
  Buf1 := Ctx.Files[1].Buffer;
  N0 := Ctx.Files[0].BufferedChars;
  N1 := Ctx.Files[1].BufferedChars;
  MissingNl0 := Ctx.Files[0].MissingNewline;
  MissingNl1 := Ctx.Files[1].MissingNewline;

  { Find identical prefix: walk forward until bytes differ (or end of buffer).

    DIVERGENCE: The C code uses word-at-a-time comparison with end sentinels
    for speed (io.c:783-794). We use byte comparison — simpler, avoids the
    sentinel insertion trick, and is fast enough on modern CPUs. }

  P0 := Buf0;
  P1 := Buf1;
  while (P0 < Buf0 + N0) and (P1 < Buf1 + N1) and (P0^ = P1^) do
  begin
    Inc(P0);
    Inc(P1);
  end;

  { Don't mistakenly count missing newline as part of prefix (io.c:796-801).
    If one file ends in a missing newline and the other doesn't, and the
    prefix scan reached the end of one file, we need to back up one byte
    so the missing-newline file's last char is part of the differing region. }
  if ((Buf0 + N0 - MissingNl0 < P0) <> (Buf1 + N1 - MissingNl1 < P1)) then
  begin
    Dec(P0);
    Dec(P1);
  end;

  { Skip back to last line-beginning in the prefix (io.c:810-822).
    horizon_lines = 0 for us (WinMerge hardcodes), so we don't subtract
    any extra lines. }
  while P0 <> Buf0 do
  begin
    LineStart := False;
    if (P0 - 1)^ = $0A then  // \n
      LineStart := True;
    { only count \r if not followed by a \n on either side }
    if ((P0 - 1)^ = $0D) and (P0^ <> $0A) and (P1^ <> $0A) then  // lone \r
      LineStart := True;
    if LineStart then
      Break;
    Dec(P0);
    Dec(P1);
  end;

  PrefixEnd0 := P0;
  PrefixEnd1 := P1;

  { Find identical suffix: walk backward from end until bytes differ
    (io.c:828-866). horizon_lines = 0 for us. }
  P0 := Buf0 + N0;
  P1 := Buf1 + N1;

  { For the missing-newline case, we only do the suffix scan if both files
    have the same missing-newline status (io.c:834-835). Otherwise the
    "extra" \n in one file would mismatch and the suffix would be empty. }
  if (MissingNl0 = MissingNl1) then
  begin
    End0 := P0;  { Addr of last char in file 0 }

    { beg0 = prefix_end0 + max(0, n0 - n1) — the limit for the backward scan }
    if N0 < N1 then
      Beg0 := PrefixEnd0
    else
      Beg0 := PrefixEnd0 + (N0 - N1);

    { Scan back until chars don't match or we reach beg0 }
    while P0 <> Beg0 do
    begin
      if (P0 - 1)^ <> (P1 - 1)^ then
      begin
        Inc(P0);  { Point at the first char of the matching suffix }
        Inc(P1);
        Beg0 := P0;
        Break;
      end;
      Dec(P0);
      Dec(P1);
    end;

    { Are we at a line-beginning in both files? If not, add the rest of this
      line to the main body. Discard up to HORIZON_LINES lines from the
      identical suffix. Also, discard one extra line, because
      shift_boundaries may need it. (io.c:854-863) }
    I := 1;  { horizon_lines + adjustment }
    if (Buf0 = P0) or ((P0 - 1)^ = $0A) or
       (((P0 - 1)^ = $0D) and (P0^ <> $0A)) then
    begin
      if (Buf1 = P1) or ((P1 - 1)^ = $0A) or
         (((P1 - 1)^ = $0D) and (P1^ <> $0A)) then
      begin
        { Both at line start — adjustment = 0 }
        I := 0;
      end;
    end;

    while (I > 0) and (P0 <> End0) do
    begin
      { Advance p0 to next line: scan until \n or lone \r }
      while (P0 < End0) and (P0^ <> $0A) and
            not ((P0^ = $0D) and ((P0 + 1)^ <> $0A)) do
        Inc(P0);
      { Skip the terminator }
      if P0 < End0 then
        Inc(P0);
      Dec(I);
    end;

    { Adjust p1 to match p0's advancement }
    P1 := P1 + (P0 - Beg0);
  end;

  SuffixBegin0 := P0;
  SuffixBegin1 := P1;

  { Count the number of lines in the prefix (for the opcode conversion).
    The prefix is byte-identical in both files, so prefix_lines[0] ==
    prefix_lines[1]. We count by walking through file 0's prefix. }
  PrefixLines := 0;
  P0 := Buf0;
  while P0 <> PrefixEnd0 do
  begin
    Inc(PrefixLines);
    { Advance past this line's terminator }
    while True do
    begin
      if P0^ = $0A then
      begin
        Inc(P0);
        Break;
      end;
      if (P0^ = $0D) and ((P0 + 1 = PrefixEnd0) or ((P0 + 1)^ <> $0A)) then
      begin
        Inc(P0);
        Break;
      end;
      Inc(P0);
    end;
  end;

  Ctx.Files[0].PrefixEnd := PrefixEnd0;
  Ctx.Files[1].PrefixEnd := PrefixEnd1;
  Ctx.Files[0].SuffixBegin := SuffixBegin0;
  Ctx.Files[1].SuffixBegin := SuffixBegin1;
  Ctx.Files[0].PrefixLines := PrefixLines;
  Ctx.Files[1].PrefixLines := PrefixLines;
end;

{ ==================================================================
  Section 6: LineCmp (util.c:298-511)
  ==================================================================

  Compare two lines according to the command line options.
  Returns 0 if equal, 1 if different (like memcmp).

  The C version has complex backtracking logic for the
  ignore_space_change_flag case. We port it faithfully. }
function LineCmp(var Ctx: TDiffContext; s1: PByte; len1: Integer; s2: PByte; len2: Integer): Integer;
var
  t1, t2: PByte;
  c1, c2: Byte;
  IgnoreFlags: Boolean;
begin
  { Fast path: exact identity (util.c:309) }
  if (len1 = len2) and (len1 > 0) and CompareMem(s1, s2, len1) then
    Exit(0);
  if (len1 = len2) and (len1 = 0) then
    Exit(0);

  IgnoreFlags := (Ctx.IgnoreCaseFlag <> 0) or (Ctx.IgnoreSpaceChangeFlag <> 0) or
                 (Ctx.IgnoreAllSpaceFlag <> 0) or (Ctx.IgnoreEolDiff <> 0) or
                 (Ctx.IgnoreNumbersFlag <> 0);

  if not IgnoreFlags then
    Exit(1);

  t1 := s1;
  t2 := s2;

  while True do
  begin
    { Read c1 from t1 (or 0 if past end) }
    if (t1 - s1) < len1 then
    begin
      c1 := t1^;
      Inc(t1);
    end
    else
      c1 := 0;

    { Read c2 from t2 (or 0 if past end) }
    if (t2 - s2) < len2 then
    begin
      c2 := t2^;
      Inc(t2);
    end
    else
      c2 := 0;

    { Test for exact char equality first (common case) }
    if c1 <> c2 then
    begin
      { Ignore horizontal whitespace if -b or -w (util.c:341-368, 369-450) }

      if Ctx.IgnoreAllSpaceFlag <> 0 then
      begin
        { For -w, just skip past any whitespace in c1 }
        while IsWSpace(c1) do
        begin
          if (t1 - s1) < len1 then
          begin
            c1 := t1^;
            Inc(t1);
          end
          else
          begin
            c1 := 0;
            Break;
          end;
        end;
        { And in c2 }
        while IsWSpace(c2) do
        begin
          if (t2 - s2) < len2 then
          begin
            c2 := t2^;
            Inc(t2);
          end
          else
          begin
            c2 := 0;
            Break;
          end;
        end;
      end
      else if Ctx.IgnoreSpaceChangeFlag <> 0 then
      begin
        { For -b, collapse whitespace runs to single space (util.c:369-450) }
        if IsWSpace(c1) then
        begin
          c1 := $20;  { ' ' }
          { Skip to end of whitespace sequence }
          while ((t1 - s1) < len1) and IsWSpace(t1^) do
            Inc(t1);
          { If c1 is whitespace and c2 is end of line, advance c1 }
          if (c2 = $0D) or (c2 = $0A) then
          begin
            if (t1 - s1) < len1 then
            begin
              c1 := t1^;
              Inc(t1);
            end
            else
              c1 := 0;
          end;
        end;

        if IsWSpace(c2) then
        begin
          c2 := $20;  { ' ' }
          while ((t2 - s2) < len2) and IsWSpace(t2^) do
            Inc(t2);
          if (c1 = $0D) or (c1 = $0A) then
          begin
            if (t2 - s2) < len2 then
            begin
              c2 := t2^;
              Inc(t2);
            end
            else
              c2 := 0;
          end;
        end;

        { Whitespace at end of line matches end of file (util.c:418-424) }
        if c1 <> c2 then
        begin
          if (c1 = $20) and (c2 = 0) then
            c2 := $20
          else if (c2 = $20) and (c1 = 0) then
            c1 := $20;
        end;

        { Backtracking for "cat and" vs "cat  and" (util.c:426-449) }
        if c1 <> c2 then
        begin
          if (c2 = $20) and (c1 <> 0) and (c1 <> $0A) and (c1 <> $0D) and
             (s1 + 1 < t1) and IsWSpace((t1 - 2)^) then
          begin
            Dec(t1);
            Continue;
          end;
          if (c1 = $20) and (c2 <> 0) and (c2 <> $0A) and (c2 <> $0D) and
             (s2 + 1 < t2) and IsWSpace((t2 - 2)^) then
          begin
            Dec(t2);
            Continue;
          end;
        end;
      end;

      { Ignore numbers (util.c:452-479) }
      if Ctx.IgnoreNumbersFlag <> 0 then
      begin
        while IsAsciiDigit(c1) do
        begin
          if (t1 - s1) < len1 then
          begin
            c1 := t1^;
            Inc(t1);
          end
          else
          begin
            c1 := 0;
            Break;
          end;
        end;
        while IsAsciiDigit(c2) do
        begin
          if (t2 - s2) < len2 then
          begin
            c2 := t2^;
            Inc(t2);
          end
          else
          begin
            c2 := 0;
            Break;
          end;
        end;
      end;

      { Upcase all letters if -i (util.c:483-489) }
      if Ctx.IgnoreCaseFlag <> 0 then
      begin
        if IsAsciiUpper(c1) then
          c1 := ToAsciiLower(c1);
        if IsAsciiUpper(c2) then
          c2 := ToAsciiLower(c2);
      end;

      { Ignore EOL differences (util.c:491-497)
        If c1 is \r, treat as end-of-string (c1 := 0).
        Else if c2 is \r, treat as end-of-string (c2 := 0). }
      if Ctx.IgnoreEolDiff <> 0 then
      begin
        if c1 = $0D then
          c1 := 0
        else if c2 = $0D then
          c2 := 0;
      end;

      if c1 <> c2 then
        Exit(1);
    end;

    { If we got here, c1 == c2 }
    if c1 = 0 then
      Exit(0);
  end;

  { Should not reach here, but for safety }
  Result := 0;
end;

{ ==================================================================
  Section 7: FindAndHashEachLine (io.c:261-488)
  ==================================================================

  Split the file into lines, simultaneously computing the equivalence class
  for each line. The 6-branch ignore-flag hashing tree (io.c:302-398) is
  ported faithfully — each branch contains an optional ignore_numbers_flag
  check.

  DIVERGENCE (G8): We don't have the linbuf_base offset trick (we don't
  record prefix lines). linbuf[0] = first differing line. }
procedure FindAndHashEachLine(var Ctx: TDiffContext; Idx: Integer);
var
  F: ^TFileData;
  P, Ip: PByte;
  BufEnd, SuffixBegin: PByte;
  IncompleteTail: PByte;
  H: Cardinal;
  C: Byte;
  Line, AllocLines: Integer;
  BucketIdx: Integer;
  LineLen: Integer;
  I: Integer;
  Varies: Integer;
  OldCap: Integer;
  Cureqs: array of Integer;
  Eqs: array of TEquivClass;
  EqsIndex, EqsAlloc: Integer;
  NBuckets: Integer;
  Buckets: array of Integer;
begin
  F := @Ctx.Files[Idx];

  { Initialize per-file state }
  Line := 0;
  AllocLines := 64;  { Initial capacity hint for linbuf }
  SetLength(F^.Linbuf, AllocLines);
  SetLength(Cureqs, AllocLines);
  SetLength(F^.Equivs, AllocLines);

  { Cache global state in local vars (io.c:270-285) }
  Eqs := Ctx.EquivsClasses;       { Shared between both files }
  EqsIndex := Ctx.EquivsIndex;
  EqsAlloc := Ctx.EquivsAlloc;
  NBuckets := Ctx.NBuckets;
  Buckets := Ctx.Buckets;

  SuffixBegin := F^.SuffixBegin;
  BufEnd := F^.Buffer + F^.BufferedChars;
  IncompleteTail := nil;
  if (F^.MissingNewline <> 0) then
    IncompleteTail := BufEnd;  { ROBUST_OUTPUT_STYLE is always true for us }
  Varies := Ctx.LengthVaries;

  P := F^.PrefixEnd;

  { Main hashing loop: walk from prefix_end to suffix_begin, hashing each
    line and recording linbuf/equivs entries (io.c:289-444). }
  while P < SuffixBegin do
  begin
    Ip := P;

    { Compute the equivalence class (hash) for this line (io.c:295-398).
      The 6-branch ignore-flag tree is ported faithfully:
        if ignore_case_flag:
          if ignore_all_space_flag:        branch A (io.c:304-311)
          else if ignore_space_change_flag: branch B (io.c:312-341)
          else:                            branch C (io.c:342-349)
        else:
          if ignore_all_space_flag:        branch D (io.c:353-361)
          else if ignore_space_change_flag: branch E (io.c:362-389)
          else:                            branch F (io.c:390-397)
      Each branch contains an optional ignore_numbers_flag check.

      Line termination (io.c:305/314/343/354/364/391): the loop stops
      after consuming '\n' or a LONE '\r' (C = \r and the NEXT byte is
      NOT \n). A '\r' that is followed by '\n' is hashed as a normal
      byte and the '\n' then ends the line, so a CRLF pair terminates
      exactly one line and the terminator stays inside the line
      (keepends), matching TRawText.Create in cudadiffhistogram.pas. }
    H := 0;
    if Ctx.IgnoreCaseFlag <> 0 then
    begin
      if Ctx.IgnoreAllSpaceFlag <> 0 then
      begin
        { Branch A: ignore_case + ignore_all_space (io.c:304-311) }
        while True do
        begin
          C := P^; Inc(P);
          if (C = $0A) or ((C = $0D) and (P^ <> $0A)) then Break;
          if (Ctx.IgnoreNumbersFlag <> 0) and IsAsciiDigit(C) then
            Continue;
          if not IsWSpace(C) then
            H := HashByte(H, ToAsciiLower(C));
        end;
      end
      else if Ctx.IgnoreSpaceChangeFlag <> 0 then
      begin
        { Branch B: ignore_case + ignore_space_change (io.c:312-341) }
        while True do
        begin
          C := P^; Inc(P);
          if (C = $0A) or ((C = $0D) and (P^ <> $0A)) then Break;
          if IsWSpace(C) then
          begin
            { skip whitespace after whitespace (io.c:318-320) }
            while True do
            begin
              C := P^; Inc(P);
              if not IsWSpace(C) then Break;
            end;
            if C = $0A then
              Break  { never hash trailing \n — exit outer hashing loop }
            else if C <> $0D then
              H := HashByte(H, $20);  { runs of ws hashed as one space }
          end;
          { c is now the first non-space. }
          if (Ctx.IgnoreNumbersFlag <> 0) and IsAsciiDigit(C) then
            Continue;
          { c can be a \r (CR) if !ignore_eol_diff }
          H := HashByte(H, ToAsciiLower(C));
          if (C = $0D) and (P^ <> $0A) then
            Break;  { lone \r — exit outer hashing loop }
        end;
      end
      else
      begin
        { Branch C: ignore_case only (io.c:342-349) }
        while True do
        begin
          C := P^; Inc(P);
          if (C = $0A) or ((C = $0D) and (P^ <> $0A)) then Break;
          if (Ctx.IgnoreNumbersFlag <> 0) and IsAsciiDigit(C) then
            Continue;
          H := HashByte(H, ToAsciiLower(C));
        end;
      end;
    end
    else
    begin
      if Ctx.IgnoreAllSpaceFlag <> 0 then
      begin
        { Branch D: ignore_all_space only (io.c:353-361) }
        while True do
        begin
          C := P^; Inc(P);
          if (C = $0A) or ((C = $0D) and (P^ <> $0A)) then Break;
          if (Ctx.IgnoreNumbersFlag <> 0) and IsAsciiDigit(C) then
            Continue;
          if not IsWSpace(C) then
            H := HashByte(H, C);
        end;
      end
      else if Ctx.IgnoreSpaceChangeFlag <> 0 then
      begin
        { Branch E: ignore_space_change only (io.c:362-389) }
        while True do
        begin
          C := P^; Inc(P);
          if (C = $0A) or ((C = $0D) and (P^ <> $0A)) then Break;
          if IsWSpace(C) then
          begin
            { skip whitespace after whitespace (io.c:368-370) }
            while True do
            begin
              C := P^; Inc(P);
              if not IsWSpace(C) then Break;
            end;
            if C = $0A then
              Break  { never hash trailing \n — exit outer hashing loop }
            else if C <> $0D then
              H := HashByte(H, $20);  { runs of ws hashed as one space }
          end;
          { c is now the first non-space. }
          if (Ctx.IgnoreNumbersFlag <> 0) and IsAsciiDigit(C) then
            Continue;
          { c can be a \r (CR) if !ignore_eol_diff }
          H := HashByte(H, C);
          if (C = $0D) and (P^ <> $0A) then
            Break;  { lone \r — exit outer hashing loop }
        end;
      end
      else
      begin
        { Branch F: no ignore flags (io.c:390-397) }
        while True do
        begin
          C := P^; Inc(P);
          if (C = $0A) or ((C = $0D) and (P^ <> $0A)) then Break;
          if (Ctx.IgnoreNumbersFlag <> 0) and IsAsciiDigit(C) then
            Continue;
          H := HashByte(H, C);
        end;
      end;
    end;

    { Find or create the equivalence class for this line (io.c:401-428) }
    BucketIdx := Integer(H mod Cardinal(NBuckets));
    LineLen := (P - Ip) - (Ord(P = IncompleteTail));

    I := Buckets[BucketIdx];
    while True do
    begin
      if I = 0 then
      begin
        { Create a new equivalence class in this bucket (io.c:406-421) }
        I := EqsIndex;
        Inc(EqsIndex);
        if I = EqsAlloc then
        begin
          { Grow Eqs array — inline (was nested GrowEqs) }
          OldCap := Length(Eqs);
          if OldCap = 0 then
            OldCap := 16;
          while OldCap < (EqsAlloc * 2) do
            OldCap := OldCap * 2;
          SetLength(Eqs, OldCap);
          EqsAlloc := OldCap;
        end;
        Eqs[I].Next := Buckets[BucketIdx];
        Eqs[I].Hash := H;
        Eqs[I].Line := Ip;
        Eqs[I].Length := LineLen;
        Buckets[BucketIdx] := I;
        Break;
      end;
      { Reuse existing class if hash matches, length matches (or varies),
        and line_cmp returns 0 (io.c:424-428) }
      if (Eqs[I].Hash = H) and
         ((Eqs[I].Length = LineLen) or (Varies <> 0)) and
         (LineCmp(Ctx, Eqs[I].Line, Eqs[I].Length, Ip, LineLen) = 0) then
        Break;
      I := Eqs[I].Next;
    end;

    { Maybe increase the size of the line table (io.c:431-440) }
    if Line = AllocLines then
    begin
      AllocLines := AllocLines * 2;
      { Grow Linbuf — inline (was nested GrowLinbuf) }
      OldCap := Length(F^.Linbuf);
      if OldCap = 0 then
        OldCap := 16;
      while OldCap < AllocLines do
        OldCap := OldCap * 2;
      SetLength(F^.Linbuf, OldCap);
      SetLength(Cureqs, AllocLines);
      SetLength(F^.Equivs, AllocLines);
    end;

    F^.Linbuf[Line] := Ip;
    Cureqs[Line] := I;
    Inc(Line);
  end;

  F^.BufferedLines := Line;

  { Suffix loop: record linbuf entries for suffix lines, until p reaches
    bufend (io.c:448-478). no_diff_means_no_output = 0 for us, so the
    `context <= i && no_diff_means_no_output` break never fires. }
  while True do
  begin
    if Line = AllocLines then
    begin
      AllocLines := AllocLines * 2;
      { Grow Linbuf — inline (was nested GrowLinbuf) }
      OldCap := Length(F^.Linbuf);
      if OldCap = 0 then
        OldCap := 16;
      while OldCap < AllocLines do
        OldCap := OldCap * 2;
      SetLength(F^.Linbuf, OldCap);
      SetLength(Cureqs, AllocLines);
      SetLength(F^.Equivs, AllocLines);
    end;
    F^.Linbuf[Line] := P;
    if P = BufEnd then
    begin
      if P = IncompleteTail then
        F^.Linbuf[Line] := P - 1;
      Break;
    end;
    Inc(Line);
    { Advance p to next line (io.c:475-477): scan until '\n' or a LONE '\r'
      (a '\r' followed by '\n' is passed over — the '\n' then stops the
      scan), then skip the terminator byte. CRLF is consumed as ONE
      terminator, matching the main hashing loop above. }
    while (P^ <> $0A) and not ((P^ = $0D) and ((P + 1)^ <> $0A)) do
      Inc(P);
    Inc(P);
  end;

  { Done with cache in local variables (io.c:480-487) }
  F^.ValidLines := Line;
  F^.Equivs := Copy(Cureqs, 0, Line);

  { Write back shared state (io.c:485-487) }
  Ctx.EquivsClasses := Eqs;
  Ctx.EquivsIndex := EqsIndex;
  Ctx.EquivsAlloc := EqsAlloc;
  Ctx.NBuckets := NBuckets;
  Ctx.Buckets := Buckets;
end;

{ ==================================================================
  Section 8: DiscardConfusingLines (analyze.c:414-614)
  ==================================================================

  Discard lines from one file that have no matches in the other file.
  A line which is discarded will not be considered by the actual comparison
  algorithm; it will be as if that line were not in the file. The file's
  `realindexes` table maps virtual line numbers (which don't count the
  discarded lines) into real line numbers.

  When we discard a line, we also mark it as a deletion or insertion so
  that it will be printed in the output.

  Hirschberg-Style Junk Discard — this is the single biggest performance
  lever (G19). Without it, the Myers search operates on the full input.
  With it, noise lines (blank lines, braces, common boilerplate) are
  pre-marked as changed and excluded from the O(ND) search. }
procedure DiscardConfusingLines(var Ctx: TDiffContext);
var
  F, I: Integer;
  Discarded: array of Byte;
  EquivCount: array of Integer;
  Counts: PInteger;
  Equivs: PInteger;
  End_: Integer;
  Many, Tem: Cardinal;
  NMatch: Integer;
  J, Length_: Integer;
  Provisional: Integer;
  Consec, Minimum: Cardinal;
  EquivMax: Integer;
begin
  { Allocate Undiscarded and Realindexes for both files (analyze.c:423-429) }
  SetLength(Ctx.Files[0].Undiscarded, Ctx.Files[0].BufferedLines);
  SetLength(Ctx.Files[1].Undiscarded, Ctx.Files[1].BufferedLines);
  SetLength(Ctx.Files[0].Realindexes, Ctx.Files[0].BufferedLines);
  SetLength(Ctx.Files[1].Realindexes, Ctx.Files[1].BufferedLines);

  { Set up equiv_count[F][I] as the number of lines in file F that fall in
    equivalence class I (analyze.c:431-442). EquivMax is shared between
    both files. }
  EquivMax := Ctx.Files[0].EquivMax;
  if Ctx.Files[1].EquivMax > EquivMax then
    EquivMax := Ctx.Files[1].EquivMax;
  SetLength(EquivCount, EquivMax * 2);
  for I := 0 to EquivMax * 2 - 1 do
    EquivCount[I] := 0;
  for I := 0 to Ctx.Files[0].BufferedLines - 1 do
    Inc(EquivCount[Ctx.Files[0].Equivs[I]]);
  for I := 0 to Ctx.Files[1].BufferedLines - 1 do
    Inc(EquivCount[EquivMax + Ctx.Files[1].Equivs[I]]);

  { Set up tables of which lines are going to be discarded (analyze.c:446-451) }
  SetLength(Discarded, Ctx.Files[0].BufferedLines + Ctx.Files[1].BufferedLines);
  for I := 0 to Length(Discarded) - 1 do
    Discarded[I] := 0;

  { Mark to be discarded each line that matches no line of the other file.
    If a line matches many lines, mark it as provisionally discardable
    (analyze.c:456-481). }
  for F := 0 to 1 do
  begin
    End_ := Ctx.Files[F].BufferedLines;
    Many := 5;
    Tem := Cardinal(End_) div 64;
    { Multiply MANY by approximate square root of number of lines (analyze.c:465-468) }
    while True do
    begin
      Tem := Tem shr 2;
      if Tem = 0 then Break;
      Many := Many * 2;
    end;

    if F = 0 then
      Counts := @EquivCount[EquivMax]  { counts for file 1 (the OTHER file) }
    else
      Counts := @EquivCount[0];       { counts for file 0 (the OTHER file) }

    if F = 0 then
      Equivs := @Ctx.Files[0].Equivs[0]
    else
      Equivs := @Ctx.Files[1].Equivs[0];

    for I := 0 to End_ - 1 do
    begin
      if Equivs[I] = 0 then
        Continue;
      NMatch := Counts[Equivs[I]];
      if NMatch = 0 then
        Discarded[F * Ctx.Files[0].BufferedLines + I] := 1  { no match — definitely discarded }
      else if NMatch > Integer(Many) then
        Discarded[F * Ctx.Files[0].BufferedLines + I] := 2;  { provisionally discardable }
    end;
  end;

  { Don't really discard the provisional lines except when they occur in a
    run of discardables, with nonprovisionals at the beginning and end
    (analyze.c:487-593). }
  for F := 0 to 1 do
  begin
    End_ := Ctx.Files[F].BufferedLines;
    I := 0;
    while I < End_ do
    begin
      if Discarded[F * Ctx.Files[0].BufferedLines + I] = 2 then
      begin
        { Cancel provisional discards not in middle of run of discards }
        Discarded[F * Ctx.Files[0].BufferedLines + I] := 0;
      end
      else if Discarded[F * Ctx.Files[0].BufferedLines + I] <> 0 then
      begin
        { We have found a nonprovisional discard (analyze.c:499-590) }
        J := I;
        Length_ := 0;
        Provisional := 0;

        { Find end of this run of discardable lines. Count how many are
          provisionally discardable. }
        while (J < End_) and (Discarded[F * Ctx.Files[0].BufferedLines + J] <> 0) do
        begin
          if Discarded[F * Ctx.Files[0].BufferedLines + J] = 2 then
            Inc(Provisional);
          Inc(J);
        end;

        { Cancel provisional discards at end, and shrink the run (analyze.c:515-516) }
        while (J > I) and (Discarded[F * Ctx.Files[0].BufferedLines + J - 1] = 2) do
        begin
          Dec(J);
          Discarded[F * Ctx.Files[0].BufferedLines + J] := 0;
          Dec(Provisional);
        end;

        { Now we have the length of a run of discardable lines whose first
          and last are not provisional (analyze.c:518-520) }
        Length_ := J - I;

        { If 1/4 of the lines in the run are provisional, cancel discarding
          of all provisional lines in the run (analyze.c:523-529) }
        if Provisional * 4 > Length_ then
        begin
          while J > I do
          begin
            Dec(J);
            if Discarded[F * Ctx.Files[0].BufferedLines + J] = 2 then
              Discarded[F * Ctx.Files[0].BufferedLines + J] := 0;
          end;
        end
        else
        begin
          { Cancel any subrun of MINIMUM or more provisionals within the
            larger run (analyze.c:544-553). NOTE: the C code does NOT reset
            consec after `j -= consec` — keeping consec at MINIMUM is what
            makes the next iteration zero out the discards entry (consec
            becomes MINIMUM+1 > MINIMUM, hitting the `minimum < consec`
            branch). Resetting consec here (an earlier bug in this port)
            caused an infinite loop: back up, reset, hit minimum, back up,
            reset, ... forever. }

          { MINIMUM is approximate square root of LENGTH/4 (analyze.c:532-542).
            A subrun of two or more provisionals can stand when LENGTH is at
            least 16. A subrun of 4 or more can stand when LENGTH >= 64. }
          Minimum := 1;
          Tem := Cardinal(Length_) div 4;
          while True do
          begin
            Tem := Tem shr 2;
            if Tem = 0 then Break;
            Minimum := Minimum * 2;
          end;
          Inc(Minimum);

          Consec := 0;
          J := 0;
          while J < Length_ do
          begin
            if Discarded[F * Ctx.Files[0].BufferedLines + I + J] <> 2 then
              Consec := 0
            else
            begin
              Inc(Consec);
              if Minimum = Consec then
              begin
                { Back up to start of subrun, to cancel it all.
                  Do NOT reset Consec here — the C source leaves it at
                  Minimum so the next iteration makes it Minimum+1 > Minimum,
                  zeroing out the discards entry. }
                Dec(J, Consec);
              end
              else if Minimum < Consec then
                Discarded[F * Ctx.Files[0].BufferedLines + I + J] := 0;
            end;
            Inc(J);
          end;

          { Scan from beginning of run until we find 3 or more nonprovisionals
            in a row or until the first nonprovisional at least 8 lines in }
          Consec := 0;
          J := 0;
          while J < Length_ do
          begin
            if (J >= 8) and (Discarded[F * Ctx.Files[0].BufferedLines + I + J] = 1) then
              Break;
            if Discarded[F * Ctx.Files[0].BufferedLines + I + J] = 2 then
            begin
              Consec := 0;
              Discarded[F * Ctx.Files[0].BufferedLines + I + J] := 0;
            end
            else if Discarded[F * Ctx.Files[0].BufferedLines + I + J] = 0 then
              Consec := 0
            else
              Inc(Consec);
            if Consec = 3 then
              Break;
            Inc(J);
          end;

          { I advances to the last line of the run (analyze.c:573-574) }
          Inc(I, Length_ - 1);

          { Same thing, from end (analyze.c:577-589) }
          Consec := 0;
          J := 0;
          while J < Length_ do
          begin
            if (J >= 8) and (Discarded[F * Ctx.Files[0].BufferedLines + I - J] = 1) then
              Break;
            if Discarded[F * Ctx.Files[0].BufferedLines + I - J] = 2 then
            begin
              Consec := 0;
              Discarded[F * Ctx.Files[0].BufferedLines + I - J] := 0;
            end
            else if Discarded[F * Ctx.Files[0].BufferedLines + I - J] = 0 then
              Consec := 0
            else
              Inc(Consec);
            if Consec = 3 then
              Break;
            Inc(J);
          end;
        end;
      end;
      Inc(I);
    end;
  end;

  { Actually discard the lines (analyze.c:596-610) }
  for F := 0 to 1 do
  begin
    End_ := Ctx.Files[F].BufferedLines;
    J := 0;
    for I := 0 to End_ - 1 do
    begin
      if (Ctx.NoDiscards <> 0) or (Discarded[F * Ctx.Files[0].BufferedLines + I] = 0) then
      begin
        Ctx.Files[F].Undiscarded[J] := Ctx.Files[F].Equivs[I];
        Ctx.Files[F].Realindexes[J] := I;
        Inc(J);
      end
      else
        { Mark discarded line as changed (analyze.c:608) }
        Ctx.Files[F].ChangedFlag[I] := 1;
    end;
    Ctx.Files[F].NondiscardedLines := J;
  end;
end;

{ ==================================================================
  Section 9: Diag (analyze.c:110-332)
  ==================================================================

  Find the midpoint of the shortest edit script for a specified portion of
  the two files.

  Scan from the beginnings of the files, and simultaneously from the ends,
  doing a breadth-first search through the space of edit-sequence. When
  the two searches meet, we have found the midpoint of the shortest edit
  sequence.

  If MINIMAL is nonzero, find the minimal edit script regardless of
  expense. Otherwise, if the search is too expensive, use heuristics to
  stop the search and report a suboptimal answer.

  Algorithm: Myers O(ND) Bidirectional Middle-Snake Search.
  Reference: "An O(ND) Difference Algorithm and its Variations",
            Eugene Myers, Algorithmica 1(2):251-266, 1986, §4.2.

  Includes the Eggert TOO_EXPENSIVE heuristic (analyze.c:277-330) and
  big_snake heuristic (analyze.c:200-273) for O(N^1.5 log N) worst case. }
function Diag(var Ctx: TDiffContext; Xoff, Xlim, Yoff, Ylim, Minimal: Integer;
              var Part: TDiagPartition): Integer;
var
  Fd, Bd: PInteger;
  Xv, Yv: PInteger;
  Dmin, Dmax: Integer;
  Fmid, Bmid: Integer;
  Fmin, Fmax: Integer;
  Bmin, Bmax: Integer;
  C: Integer;
  OddFlag: Integer;
  D: Integer;
  BigSnake: Integer;
  X, Y, OldX: Integer;
  Tlo, Thi: Integer;
  Best: Integer;
  DD, DDAbs: Integer;
  V: Integer;
  K: Integer;
  FxyBest, FxBest: Integer;
  BxyBest, BxBest: Integer;
begin
  Fd := Ctx.Fdiag;
  Bd := Ctx.Bdiag;
  Xv := Ctx.Xvec;
  Yv := Ctx.Yvec;

  Dmin := Xoff - Ylim;  { Minimum valid diagonal }
  Dmax := Xlim - Yoff;  { Maximum valid diagonal }
  Fmid := Xoff - Yoff;  { Center diagonal of top-down search }
  Bmid := Xlim - Ylim;  { Center diagonal of bottom-up search }
  Fmin := Fmid;
  Fmax := Fmid;
  Bmin := Bmid;
  Bmax := Bmid;

  { odd = (fmid - bmid) & 1 — true if southeast corner is on an odd diagonal
    with respect to the northwest }
  OddFlag := (Fmid - Bmid) and 1;

  Fd[Fmid] := Xoff;
  Bd[Bmid] := Xlim;

  C := 1;
  while True do
  begin
    Inc(C);
    BigSnake := 0;

    { Extend the top-down search by an edit step in each diagonal
      (analyze.c:135-160) }
    if Fmin > Dmin then
    begin
      Dec(Fmin);
      Fd[Fmin - 1] := -1;
    end
    else
      Inc(Fmin);

    if Fmax < Dmax then
    begin
      Inc(Fmax);
      Fd[Fmax + 1] := -1;
    end
    else
      Dec(Fmax);

    D := Fmax;
    while D >= Fmin do
    begin
      Tlo := Fd[D - 1];
      Thi := Fd[D + 1];
      if Tlo >= Thi then
        X := Tlo + 1
      else
        X := Thi;
      OldX := X;
      Y := X - D;
      { Slide along the diagonal }
      while (X < Xlim) and (Y < Ylim) and (Xv[X] = Yv[Y]) do
      begin
        Inc(X);
        Inc(Y);
      end;
      if X - OldX > cSnakeLimit then
        BigSnake := 1;
      Fd[D] := X;
      if (OddFlag <> 0) and (Bmin <= D) and (D <= Bmax) and (Bd[D] <= X) then
      begin
        Part.Xmid := X;
        Part.Ymid := Y;
        Part.LoMinimal := 1;
        Part.HiMinimal := 1;
        Exit(2 * C - 1);
      end;
      Dec(D, 2);
    end;

    { Similarly extend the bottom-up search (analyze.c:162-187) }
    if Bmin > Dmin then
    begin
      Dec(Bmin);
      Bd[Bmin - 1] := cIntMax;
    end
    else
      Inc(Bmin);

    if Bmax < Dmax then
    begin
      Inc(Bmax);
      Bd[Bmax + 1] := cIntMax;
    end
    else
      Dec(Bmax);

    D := Bmax;
    while D >= Bmin do
    begin
      Tlo := Bd[D - 1];
      Thi := Bd[D + 1];
      if Tlo < Thi then
        X := Tlo
      else
        X := Thi - 1;
      OldX := X;
      Y := X - D;
      while (X > Xoff) and (Y > Yoff) and (Xv[X - 1] = Yv[Y - 1]) do
      begin
        Dec(X);
        Dec(Y);
      end;
      if OldX - X > cSnakeLimit then
        BigSnake := 1;
      Bd[D] := X;
      if (OddFlag = 0) and (Fmin <= D) and (D <= Fmax) and (X <= Fd[D]) then
      begin
        Part.Xmid := X;
        Part.Ymid := Y;
        Part.LoMinimal := 1;
        Part.HiMinimal := 1;
        Exit(2 * C);
      end;
      Dec(D, 2);
    end;

    if Minimal <> 0 then
      Continue;

    { Heuristic 1: big_snake (analyze.c:200-273)
      If c > 200 && big_snake && heuristic, check for a diagonal that has
      made disproportionate progress (v > 12 * (c + |dd|)). If found, return
      that midpoint (suboptimal but fast). }
    if (C > 200) and (BigSnake <> 0) and (Ctx.Heuristic <> 0) then
    begin
      { Forward search: find diagonal with most progress (analyze.c:204-231) }
      Best := 0;
      D := Fmax;
      while D >= Fmin do
      begin
        DD := D - Fmid;
        X := Fd[D];
        Y := X - D;
        V := (X - Xoff) * 2 - DD;
        if DD < 0 then DDAbs := -DD else DDAbs := DD;
        if V > 12 * (C + DDAbs) then
        begin
          if (V > Best) and (Xoff + cSnakeLimit <= X) and (X < Xlim) and
             (Yoff + cSnakeLimit <= Y) and (Y < Ylim) then
          begin
            { We have a good enough best diagonal; now insist that it end
              with a significant snake (analyze.c:217-228). }
            K := 1;
            while Xv[X - K] = Yv[Y - K] do
            begin
              if K = cSnakeLimit then
              begin
                Best := V;
                Part.Xmid := X;
                Part.Ymid := Y;
                Break;
              end;
              Inc(K);
            end;
          end;
        end;
        Dec(D, 2);
      end;
      if Best > 0 then
      begin
        Part.LoMinimal := 1;
        Part.HiMinimal := 0;
        Exit(2 * C - 1);
      end;

      { Backward search: find diagonal with most progress (analyze.c:239-266) }
      Best := 0;
      D := Bmax;
      while D >= Bmin do
      begin
        DD := D - Bmid;
        X := Bd[D];
        Y := X - D;
        V := (Xlim - X) * 2 + DD;
        if DD < 0 then DDAbs := -DD else DDAbs := DD;
        if V > 12 * (C + DDAbs) then
        begin
          if (V > Best) and (Xoff < X) and (X <= Xlim - cSnakeLimit) and
             (Yoff < Y) and (Y <= Ylim - cSnakeLimit) then
          begin
            { We have a good enough best diagonal; now insist that it end
              with a significant snake (analyze.c:254-263). }
            K := 0;
            while Xv[X + K] = Yv[Y + K] do
            begin
              if K = cSnakeLimit - 1 then
              begin
                Best := V;
                Part.Xmid := X;
                Part.Ymid := Y;
                Break;
              end;
              Inc(K);
            end;
          end;
        end;
        Dec(D, 2);
      end;
      if Best > 0 then
      begin
        Part.LoMinimal := 0;
        Part.HiMinimal := 1;
        Exit(2 * C - 1);
      end;
    end;

    { Heuristic 2: too_expensive (analyze.c:277-330)
      If we've gone well beyond the call of duty, give up and report halfway
      between our best results so far. }
    if C >= Ctx.TooExpensive then
    begin
      { Find forward diagonal that maximizes X + Y }
      FxyBest := -1;
      FxBest := 0;
      D := Fmax;
      while D >= Fmin do
      begin
        if Fd[D] < Xlim then
          X := Fd[D]
        else
          X := Xlim;
        Y := X - D;
        if Ylim < Y then
        begin
          X := Ylim + D;
          Y := Ylim;
        end;
        if FxyBest < X + Y then
        begin
          FxyBest := X + Y;
          FxBest := X;
        end;
        Dec(D, 2);
      end;

      { Find backward diagonal that minimizes X + Y }
      BxyBest := cIntMax;
      BxBest := 0;
      D := Bmax;
      while D >= Bmin do
      begin
        if Bd[D] > Xoff then
          X := Bd[D]
        else
          X := Xoff;
        Y := X - D;
        if Y < Yoff then
        begin
          X := Yoff + D;
          Y := Yoff;
        end;
        if X + Y < BxyBest then
        begin
          BxyBest := X + Y;
          BxBest := X;
        end;
        Dec(D, 2);
      end;

      { Use the better of the two diagonals }
      if (Xlim + Ylim) - BxyBest < FxyBest - (Xoff + Yoff) then
      begin
        Part.Xmid := FxBest;
        Part.Ymid := FxyBest - FxBest;
        Part.LoMinimal := 1;
        Part.HiMinimal := 0;
      end
      else
      begin
        Part.Xmid := BxBest;
        Part.Ymid := BxyBest - BxBest;
        Part.LoMinimal := 0;
        Part.HiMinimal := 1;
      end;
      Exit(2 * C - 1);
    end;
  end;
end;

{ ==================================================================
  Section 10: CompareSeq (analyze.c:348-400)
  ==================================================================

  Compare in detail contiguous subsequences of the two files which are
  known, as a whole, to match each other.

  The results are recorded in the vectors Files[N].ChangedFlag, by storing
  a 1 in the element for each line that is an insertion or deletion.

  The subsequence of file 0 is [Xoff, Xlim) and likewise for file 1.
  XLIM, YLIM are exclusive bounds. All line numbers are origin-0 and
  discarded lines are not counted.

  If MINIMAL is nonzero, find a minimal difference no matter how expensive
  it is. }
procedure CompareSeq(var Ctx: TDiffContext; Xoff, Xlim, Yoff, Ylim, Minimal: Integer);
var
  Xv, Yv: PInteger;
  C: Integer;
  Part: TDiagPartition;
begin
  Xv := Ctx.Xvec;
  Yv := Ctx.Yvec;

  { Slide down the bottom initial diagonal (analyze.c:355-356) }
  while (Xoff < Xlim) and (Yoff < Ylim) and (Xv[Xoff] = Yv[Yoff]) do
  begin
    Inc(Xoff);
    Inc(Yoff);
  end;
  { Slide up the top initial diagonal (analyze.c:358-359) }
  while (Xlim > Xoff) and (Ylim > Yoff) and (Xv[Xlim - 1] = Yv[Ylim - 1]) do
  begin
    Dec(Xlim);
    Dec(Ylim);
  end;

  { Handle simple cases (analyze.c:362-367) }
  if Xoff = Xlim then
  begin
    while Yoff < Ylim do
    begin
      Ctx.Files[1].ChangedFlag[Ctx.Files[1].Realindexes[Yoff]] := 1;
      Inc(Yoff);
    end;
  end
  else if Yoff = Ylim then
  begin
    while Xoff < Xlim do
    begin
      Ctx.Files[0].ChangedFlag[Ctx.Files[0].Realindexes[Xoff]] := 1;
      Inc(Xoff);
    end;
  end
  else
  begin
    { Find a point of correspondence in the middle of the files }
    C := Diag(Ctx, Xoff, Xlim, Yoff, Ylim, Minimal, Part);

    if C = 1 then
    begin
      { This should be impossible (analyze.c:377-392) — the simple cases
        above should have handled it. Raise to match diffutils' abort(). }
      raise Exception.Create('CudaDiff: Diag returned 1 — impossible state');
    end
    else
    begin
      { Use the partitions to split this problem into subproblems }
      CompareSeq(Ctx, Xoff, Part.Xmid, Yoff, Part.Ymid, Part.LoMinimal);
      CompareSeq(Ctx, Part.Xmid, Xlim, Part.Ymid, Ylim, Part.HiMinimal);
    end;
  end;
end;

{ ==================================================================
  Section 11: AddChange (analyze.c:736-750)
  ==================================================================

  Cons an additional entry onto the front of an edit script OLD.
  Line0 and Line1 are the first affected lines in the two files (origin 0).
  Deleted is the number of lines deleted here from file 0.
  Inserted is the number of lines inserted here in file 1.

  If Deleted = 0 then Line0 is the line before which the insertion was done;
  vice versa for Inserted and Line1. }
function AddChange(Line0, Line1, Deleted, Inserted: Integer; Old: PChange): PChange;
var
  NewNode: PChange;
begin
  NewNode := GetMem(SizeOf(TChange));
  FillChar(NewNode^, SizeOf(TChange), 0);
  NewNode^.Line0 := Line0;
  NewNode^.Line1 := Line1;
  NewNode^.Inserted := Inserted;
  NewNode^.Deleted := Deleted;
  NewNode^.Link := Old;
  NewNode^.Match0 := -1;  { WinMerge moved block code (not ported, G36.3) }
  NewNode^.Match1 := -1;
  Result := NewNode;
end;

{ ==================================================================
  Section 12: BuildScript (analyze.c:792-821)
  ==================================================================

  Scan the tables of which lines are inserted and deleted, producing an edit
  script in forward order.

  Note that changedN[-1] does exist, and contains 0 (sentinel — G9). The
  script is built by prepending, so the result is in forward order (first
  change = earliest in file). }
function BuildScript(var Ctx: TDiffContext): PChange;
var
  Script: PChange;
  Changed0, Changed1: PByte;
  I0, I1: Integer;
  Line0, Line1: Integer;
begin
  Script := nil;
  Changed0 := Ctx.Files[0].ChangedFlag;
  Changed1 := Ctx.Files[1].ChangedFlag;
  I0 := Ctx.Files[0].BufferedLines;
  I1 := Ctx.Files[1].BufferedLines;

  { Note: changedN[-1] does exist, and contains 0 (sentinel — G9).
    The loop walks backward to (-1, -1), at which point the sentinel
    guarantees no false change is detected. }
  while (I0 >= 0) or (I1 >= 0) do
  begin
    if (Changed0[I0 - 1] <> 0) or (Changed1[I1 - 1] <> 0) then
    begin
      Line0 := I0;
      Line1 := I1;
      while Changed0[I0 - 1] <> 0 do Dec(I0);
      while Changed1[I1 - 1] <> 0 do Dec(I1);
      Script := AddChange(I0, I1, Line0 - I0, Line1 - I1, Script);
    end;
    Dec(I0);
    Dec(I1);
  end;

  Result := Script;
end;

{ ==================================================================
  Section 13: ShiftBoundaries (analyze.c:628-726)
  ==================================================================

  Adjust inserts/deletes of identical lines to join changes as much as
  possible.

  We do something when a run of changed lines include a line at one end
  and have an excluded, identical line at the other. We are free to choose
  which identical line is included. `compareseq' usually chooses the one at
  the beginning, but usually it is cleaner to consider the following
  identical line to be the "change".

  The `inhibit` flag disables it — WinMerge sets inhibit = 0 (enabled). }
procedure ShiftBoundaries(var Ctx: TDiffContext);
var
  F: Integer;
  Changed, OtherChanged: PByte;
  Equivs: PInteger;
  I, J, IEnd: Integer;
  RunLength, Start_, Corresponding: Integer;
begin
  if Ctx.Inhibit <> 0 then
    Exit;

  for F := 0 to 1 do
  begin
    Changed := Ctx.Files[F].ChangedFlag;
    OtherChanged := Ctx.Files[1 - F].ChangedFlag;
    if F = 0 then
      Equivs := @Ctx.Files[0].Equivs[0]
    else
      Equivs := @Ctx.Files[1].Equivs[0];
    I := 0;
    J := 0;
    IEnd := Ctx.Files[F].BufferedLines;

    while True do
    begin
      { Scan forwards to find beginning of another run of changes.
        Also keep track of the corresponding point in the other file. }
      while (I < IEnd) and (Changed[I] = 0) do
      begin
        while OtherChanged[J] <> 0 do
          Inc(J);
        Inc(I);
      end;

      if I = IEnd then
        Break;

      Start_ := I;

      { Find the end of this run of changes }
      Inc(I);
      while Changed[I] <> 0 do
        Inc(I);
      while OtherChanged[J] <> 0 do
        Inc(J);

      repeat
        { Record the length of this run of changes (analyze.c:675) }
        RunLength := I - Start_;

        { Move the changed region back, so long as the previous unchanged
          line matches the last changed one (analyze.c:680-689) }
        while (Start_ > 0) and (Equivs[Start_ - 1] = Equivs[I - 1]) do
        begin
          Dec(Start_);
          Changed[Start_] := 1;
          Dec(I);
          Changed[I] := 0;
          while (Start_ > 0) and (Changed[Start_ - 1] <> 0) do
            Dec(Start_);
          while OtherChanged[J - 1] <> 0 do
            Dec(J);
        end;

        { Set CORRESPONDING to the end of the changed run (analyze.c:691-694) }
        if OtherChanged[J - 1] <> 0 then
          Corresponding := I
        else
          Corresponding := IEnd;

        { Move the changed region forward, so long as the first changed line
          matches the following unchanged one (analyze.c:696-710) }
        while (I <> IEnd) and (Equivs[Start_] = Equivs[I]) do
        begin
          Changed[Start_] := 0;
          Inc(Start_);
          Changed[I] := 1;
          Inc(I);
          while Changed[I] <> 0 do
            Inc(I);
          Inc(J);
          while OtherChanged[J] <> 0 do
          begin
            Corresponding := I;
            Inc(J);
          end;
        end;
      until RunLength = I - Start_;

      { If possible, move the fully-merged run of changes back to a
        corresponding run in the other file (analyze.c:717-723) }
      while Corresponding < I do
      begin
        Dec(Start_);
        Changed[Start_] := 1;
        Dec(I);
        Changed[I] := 0;
        while OtherChanged[J - 1] <> 0 do
          Dec(J);
      end;
    end;
  end;
end;

{ ==================================================================
  Section 14: AnalyzeHunk (util.c:798-874)
  ==================================================================

  Look at a hunk of edit script and report the range of lines in each file
  that it applies to. HUNK is the start of the hunk, which is a chain of
  `struct change'. The first and last line numbers of file 0 are stored in
  *FIRST0 and *LAST0, and likewise for file 1 in *FIRST1 and *LAST1.
  These are internal line numbers that count from 0.

  If no lines from file 0 are deleted, then FIRST0 is LAST0+1.

  Also sets *DELETES nonzero if any lines of file 0 are deleted and sets
  *INSERTS nonzero if any lines of file 1 are inserted. If only ignorable
  lines are inserted or deleted, both are set to 0.

  Sets hunk^.trivial = 1 if the hunk is trivial (all blank-line changes
  under ignore_blank_lines_flag). }
procedure AnalyzeHunk(var Ctx: TDiffContext; Hunk: PChange;
                     out First0, Last0, First1, Last1, Deletes, Inserts: Integer);
var
  L0, L1, ShowFrom, ShowTo: Integer;
  I: Integer;
  Trivial: Integer;
  Next_: PChange;
begin
  ShowFrom := 0;
  ShowTo := 0;

  First0 := Hunk^.Line0;
  First1 := Hunk^.Line1;

  Trivial := Ctx.IgnoreBlankLinesFlag;

  Next_ := Hunk;
  repeat
    L0 := Next_^.Line0 + Next_^.Deleted - 1;
    L1 := Next_^.Line1 + Next_^.Inserted - 1;
    Inc(ShowFrom, Next_^.Deleted);
    Inc(ShowTo, Next_^.Inserted);

    { Check triviality for file 0 lines (util.c:822-837) }
    I := Next_^.Line0;
    while (I <= L0) and (Trivial <> 0) do
    begin
      if Ctx.IgnoreBlankLinesFlag = 0 then
        Trivial := 0
      else if (Ctx.IgnoreAllSpaceFlag <> 0) or (Ctx.IgnoreSpaceChangeFlag <> 0) then
      begin
        if not IsBlankLine(Ctx.Files[0].Linbuf[I], Ctx.Files[0].Linbuf[I + 1]) then
          Trivial := 0;
      end
      else
      begin
        if (not IsEolCh(Ctx.Files[0].Linbuf[I][0])) and (Ctx.Files[0].Linbuf[I][0] <> 0) then
          Trivial := 0;
      end;
      Inc(I);
    end;

    { Check triviality for file 1 lines (util.c:838-853) }
    I := Next_^.Line1;
    while (I <= L1) and (Trivial <> 0) do
    begin
      if Ctx.IgnoreBlankLinesFlag = 0 then
        Trivial := 0
      else if (Ctx.IgnoreAllSpaceFlag <> 0) or (Ctx.IgnoreSpaceChangeFlag <> 0) then
      begin
        if not IsBlankLine(Ctx.Files[1].Linbuf[I], Ctx.Files[1].Linbuf[I + 1]) then
          Trivial := 0;
      end
      else
      begin
        if (not IsEolCh(Ctx.Files[1].Linbuf[I][0])) and (Ctx.Files[1].Linbuf[I][0] <> 0) then
          Trivial := 0;
      end;
      Inc(I);
    end;

    Next_ := Next_^.Link;
  until Next_ = nil;

  Last0 := L0;
  Last1 := L1;

  { If all inserted or deleted lines are ignorable, tell the caller to
    ignore this hunk (util.c:860-863) }
  if Trivial <> 0 then
  begin
    ShowFrom := 0;
    ShowTo := 0;
  end;

  { Stash the trivial flag for the consumer (util.c:865-870) }
  if Trivial <> 0 then
    Hunk^.Trivial := 1
  else
    Hunk^.Trivial := 0;

  Deletes := ShowFrom;
  Inserts := ShowTo;
end;

{ ==================================================================
  Section 15: AllocChangedFlag, AllocFdiagBdiag, ComputeTooExpensive
  ==================================================================

  Helper allocations done by diff_2_files (analyze.c:931-962). }
procedure AllocChangedFlag(var Ctx: TDiffContext);
var
  S: Integer;
  Base: PByte;
begin
  { Allocate changed_flag with sentinels (G9, analyze.c:931-936):
    - changed0[-1] = always 0 (sentinel before file 0)
    - changed0[0..buffered_lines[0]-1] = actual flags for file 0
    - changed0[buffered_lines[0]] and [+1] = gap (always 0)
    - changed1[0..buffered_lines[1]-1] = actual flags for file 1
    - changed1[buffered_lines[1]] = always 0 (sentinel after file 1) }
  S := Ctx.Files[0].BufferedLines + Ctx.Files[1].BufferedLines + 4;
  Base := XGetMem(S);
  Ctx.ChangedFlagAlloc := Base;
  Ctx.Files[0].ChangedFlag := Base + 1;
  Ctx.Files[1].ChangedFlag := Ctx.Files[0].ChangedFlag + Ctx.Files[0].BufferedLines + 2;
end;

procedure AllocFdiagBdiag(var Ctx: TDiffContext);
var
  Diags: Integer;
  Base: PInteger;
begin
  { Allocate fdiag and bdiag (analyze.c:950-953):
    - Single allocation of size diags * 2
    - fdiag = base + (nondiscarded_lines_1 + 1)
    - bdiag = base + diags + (nondiscarded_lines_1 + 1) }
  Diags := Ctx.Files[0].NondiscardedLines + Ctx.Files[1].NondiscardedLines + 3;
  Base := XGetMem(Diags * 2 * SizeOf(Integer));
  Ctx.FdiagAlloc := Base;
  Ctx.Fdiag := Base + Ctx.Files[1].NondiscardedLines + 1;
  Ctx.Bdiag := Base + Diags + Ctx.Files[1].NondiscardedLines + 1;
end;

procedure ComputeTooExpensive(var Ctx: TDiffContext);
var
  I: Integer;
  TotalLines: Integer;
begin
  { too_expensive = max(4096, 2^ceil(log4(N+M))) — Eggert heuristic (G20).
    This is approximately sqrt(N+M), floored at 4096. }
  Ctx.TooExpensive := 1;
  TotalLines := Ctx.Files[0].NondiscardedLines + Ctx.Files[1].NondiscardedLines;
  I := TotalLines;
  while I <> 0 do
  begin
    Ctx.TooExpensive := Ctx.TooExpensive shl 1;
    I := I shr 2;
  end;
  if Ctx.TooExpensive < 4096 then
    Ctx.TooExpensive := 4096;
end;

{ ==================================================================
  Section 16: Diff2Files (analyze.c:838-1119)
  ==================================================================

  Report the differences of two files. Returns a linked list of TChange
  records (the "edit script") in forward order (first change = earliest
  in file).

  DIVERGENCE (G8): The C version handles binary files, file I/O, moved
  blocks, and various output styles. The Pascal port receives strings
  (always text), doesn't port moved blocks (G36.3), and uses the change
  list directly (no output formatting). }
function Diff2Files(var Ctx: TDiffContext; const ATextA, ATextB: string): PChange;
var
  I: Integer;
  Script: PChange;
  PrimesArr: array of Integer;
  EquivsAlloc: Integer;
  First0, Last0, First1, Last1, Deletes, Inserts: Integer;
  Walk: PChange;
begin
  Script := nil;

  { Step 1: Load both files into private mutable buffers (replaces
    read_files/sip/slurp/prepare_text_end — G8). }
  LoadFile(Ctx, 0, ATextA);
  LoadFile(Ctx, 1, ATextB);

  { Step 2: Find identical prefix and suffix (io.c:find_identical_ends) }
  FindIdenticalEnds(Ctx);

  { Step 3: Set up the equivs hash table (io.c:1109-1126)
    Allocates buckets (hash table) and equivs (classes array). Shared
    between both files. }
  EquivsAlloc := 64;  { Initial capacity — will grow as needed }
  { Roughly guess based on total lines: 1 + (buffered_chars / 30) lines per file }
  Inc(EquivsAlloc, (Ctx.Files[0].BufferedChars + Ctx.Files[1].BufferedChars) div 30);
  SetLength(Ctx.EquivsClasses, EquivsAlloc);
  Ctx.EquivsIndex := 1;  { Class 0 is permanently safe for unhashed lines }
  Ctx.EquivsAlloc := EquivsAlloc;

  { Find a prime >= equivs_alloc / 3 for the bucket count (io.c:967-998,
    io.c:1120-1123). Use a small static primes table. }
  SetLength(PrimesArr, 18);
  PrimesArr[0] := 509;
  PrimesArr[1] := 1021;
  PrimesArr[2] := 2039;
  PrimesArr[3] := 4093;
  PrimesArr[4] := 8191;
  PrimesArr[5] := 16381;
  PrimesArr[6] := 32749;
  PrimesArr[7] := 65521;
  PrimesArr[8] := 131071;
  PrimesArr[9] := 262139;
  PrimesArr[10] := 524287;
  PrimesArr[11] := 1048573;
  PrimesArr[12] := 2097143;
  PrimesArr[13] := 4194301;
  PrimesArr[14] := 8388593;
  PrimesArr[15] := 16777213;
  PrimesArr[16] := 33554393;
  PrimesArr[17] := 67108859;

  I := 0;
  while (I < Length(PrimesArr)) and (PrimesArr[I] < EquivsAlloc div 3) do
    Inc(I);
  if I >= Length(PrimesArr) then
    I := Length(PrimesArr) - 1;
  Ctx.NBuckets := PrimesArr[I];
  SetLength(Ctx.Buckets, Ctx.NBuckets);
  for I := 0 to Ctx.NBuckets - 1 do
    Ctx.Buckets[I] := 0;

  { Step 4: Find and hash each line for both files (io.c:1128-1129) }
  FindAndHashEachLine(Ctx, 0);
  FindAndHashEachLine(Ctx, 1);

  { Set EquivMax for both files (io.c:1131) }
  Ctx.Files[0].EquivMax := Ctx.EquivsIndex;
  Ctx.Files[1].EquivMax := Ctx.EquivsIndex;

  { Step 5: Allocate changed_flag with sentinels (analyze.c:931-936) }
  AllocChangedFlag(Ctx);

  { Step 6: Discard confusing lines (analyze.c:942)
    This is the Hirschberg-Style Junk Discard — CRITICAL for performance
    (G19). Without it, the Myers search operates on the full input. }
  DiscardConfusingLines(Ctx);

  { Step 7: Set up xvec/yvec/fdiag/bdiag/too_expensive (analyze.c:947-962) }
  Ctx.Xvec := @Ctx.Files[0].Undiscarded[0];
  Ctx.Yvec := @Ctx.Files[1].Undiscarded[0];
  AllocFdiagBdiag(Ctx);
  ComputeTooExpensive(Ctx);

  { Step 8: Run the main comparison (analyze.c:967-968)
    compareseq(0, nondiscarded0, 0, nondiscarded1, no_discards)
    The no_discards parameter (=0) means heuristics ARE allowed. }
  CompareSeq(Ctx, 0, Ctx.Files[0].NondiscardedLines,
                  0, Ctx.Files[1].NondiscardedLines, Ctx.NoDiscards);

  { Step 9: Modify the results slightly to make them prettier (analyze.c:975) }
  ShiftBoundaries(Ctx);

  { Step 10: Get the results as a chain of TChange records (analyze.c:985) }
  Script := BuildScript(Ctx);

  { Step 11: If ignore_blank_lines_flag, walk the script and mark trivial
    hunks via analyze_hunk (analyze.c:989-1019). The trivial flag is used
    in ChangesToOpcodes to suppress the change. }
  if Ctx.IgnoreBlankLinesFlag <> 0 then
  begin
    Walk := Script;
    while Walk <> nil do
    begin
      AnalyzeHunk(Ctx, Walk, First0, Last0, First1, Last1, Deletes, Inserts);
      Walk := Walk^.Link;
    end;
  end;

  Result := Script;
end;

{ ==================================================================
  Section 17: FreeScript (helper)
  ==================================================================

  Free the change linked list. Each node was GetMem'd in AddChange. }
procedure FreeScript(Script: PChange);
var
  P, N: PChange;
begin
  P := Script;
  while P <> nil do
  begin
    N := P^.Link;
    FreeMem(P);
    P := N;
  end;
end;

{ ==================================================================
  Section 18: ChangesToOpcodes (G3)
  ==================================================================

  Convert the diffutils change list (linked list of TChange, in forward
  order) to difflib-compatible opcodes.

  The change list contains ONLY changes (insertions/deletions/replaces).
  Equal regions are implied by the gaps between changes. The identical
  prefix is an implicit equal region at the start; the identical suffix is
  an implicit equal region at the end.

  Trivial changes (marked by AnalyzeHunk when ignore_blank_lines_flag is on
  and all deleted+inserted lines are blank) are suppressed — they are NOT
  emitted as delete/insert/replace. The surrounding equal regions are merged
  to maintain difflib invariants (G7, G17). }
function ChangesToOpcodes(var Ctx: TDiffContext; Script: PChange; SizeA, SizeB: Integer): TDiffOpcodeArray;
var
  Result_: TDiffOpcodeArray;
  ResultCount: Integer;
  PosA, PosB: Integer;
  FileLine0, FileLine1: Integer;
  Walk: PChange;
  PrefixLines0, PrefixLines1: Integer;

  procedure Emit(Tag: Integer; I1, I2, J1, J2: Integer);
  begin
    if ResultCount = Length(Result_) then
      SetLength(Result_, Length(Result_) * 2 + 1);
    Result_[ResultCount].Tag := Tag;
    Result_[ResultCount].I1 := I1;
    Result_[ResultCount].I2 := I2;
    Result_[ResultCount].J1 := J1;
    Result_[ResultCount].J2 := J2;
    Inc(ResultCount);
  end;

  procedure EmitEqual(I1, I2, J1, J2: Integer);
  begin
    { Merge with previous equal opcode if adjacent (difflib invariants
      require no two adjacent opcodes of the same tag — G17.8). }
    if (ResultCount > 0) and (Result_[ResultCount - 1].Tag = cTagEqual) and
       (Result_[ResultCount - 1].I2 = I1) and (Result_[ResultCount - 1].J2 = J1) then
    begin
      Result_[ResultCount - 1].I2 := I2;
      Result_[ResultCount - 1].J2 := J2;
    end
    else
    begin
      { Only emit if non-empty }
      if (I2 > I1) or (J2 > J1) then
        Emit(cTagEqual, I1, I2, J1, J2);
    end;
  end;

begin
  SetLength(Result_, 16);
  ResultCount := 0;

  PosA := 0;
  PosB := 0;

  PrefixLines0 := Ctx.Files[0].PrefixLines;
  PrefixLines1 := Ctx.Files[1].PrefixLines;

  { Implicit prefix equal region (G3) }
  if (PrefixLines0 > 0) or (PrefixLines1 > 0) then
  begin
    EmitEqual(0, PrefixLines0, 0, PrefixLines1);
    PosA := PrefixLines0;
    PosB := PrefixLines1;
  end;

  { Walk the change list in forward order (G3) }
  Walk := Script;
  while Walk <> nil do
  begin
    { Convert internal line indices to file line indices (add prefix_lines) }
    FileLine0 := PrefixLines0 + Walk^.Line0;
    FileLine1 := PrefixLines1 + Walk^.Line1;

    if Walk^.Trivial = 0 then
    begin
      { Non-trivial change: emit the equal region before this change, then
        the change itself. }
      if (PosA < FileLine0) or (PosB < FileLine1) then
        EmitEqual(PosA, FileLine0, PosB, FileLine1);

      if (Walk^.Deleted > 0) and (Walk^.Inserted > 0) then
        Emit(cTagReplace, FileLine0, FileLine0 + Walk^.Deleted,
                          FileLine1, FileLine1 + Walk^.Inserted)
      else if Walk^.Deleted > 0 then
        Emit(cTagDelete, FileLine0, FileLine0 + Walk^.Deleted,
                        FileLine1, FileLine1)
      else
        Emit(cTagInsert, FileLine0, FileLine0,
                        FileLine1, FileLine1 + Walk^.Inserted);

      PosA := FileLine0 + Walk^.Deleted;
      PosB := FileLine1 + Walk^.Inserted;
    end
    else
    begin
      { Trivial change (blank-line only): suppress — treat the deleted and
        inserted lines as "equal". But difflib invariants require
        i2-i1 == j2-j1 for equal opcodes. So if Deleted != Inserted, we
        can't emit a single equal. Emit two pieces:
        - An equal covering the min(Deleted, Inserted) lines.
        - A delete or insert for the remainder.

        Wait — that defeats the purpose of suppression. The intent of
        "suppress blank-line hunks" (GNU diff -B) is to show NO difference
        for blank-line-only changes. But difflib format requires line
        indices to align. If we have 3 deleted blank lines and 2 inserted
        blank lines, showing "no difference" would mean the 3rd deleted
        line matches some line in file 1 — but there's no matching line.

        GNU diff -B's behavior: it suppresses the hunk entirely in the
        formatted output. But difflib requires complete coverage. So we
        emit:
        - An equal covering the matching portion (min(Deleted, Inserted)
          lines from each side, aligned).
        - A delete or insert for the remainder (the unmatched blank lines).

        This is the best we can do while maintaining difflib invariants.
        The Differ plugin's renderer will show the equal portion as
        unchanged and the delete/insert as the actual difference. }
      if (Walk^.Deleted > 0) and (Walk^.Inserted > 0) then
      begin
        { Both sides have blank lines — equalize the matching portion }
        if Walk^.Deleted = Walk^.Inserted then
        begin
          { Perfect match — emit equal covering both regions }
          if (PosA < FileLine0) or (PosB < FileLine1) then
            EmitEqual(PosA, FileLine0, PosB, FileLine1);
          EmitEqual(FileLine0, FileLine0 + Walk^.Deleted,
                    FileLine1, FileLine1 + Walk^.Inserted);
        end
        else if Walk^.Deleted > Walk^.Inserted then
        begin
          { More deleted than inserted: equal for the inserted count, then
            delete the rest }
          if (PosA < FileLine0) or (PosB < FileLine1) then
            EmitEqual(PosA, FileLine0, PosB, FileLine1);
          EmitEqual(FileLine0, FileLine0 + Walk^.Inserted,
                    FileLine1, FileLine1 + Walk^.Inserted);
          Emit(cTagDelete, FileLine0 + Walk^.Inserted, FileLine0 + Walk^.Deleted,
                          FileLine1 + Walk^.Inserted, FileLine1 + Walk^.Inserted);
        end
        else
        begin
          { More inserted than deleted: equal for the deleted count, then
            insert the rest }
          if (PosA < FileLine0) or (PosB < FileLine1) then
            EmitEqual(PosA, FileLine0, PosB, FileLine1);
          EmitEqual(FileLine0, FileLine0 + Walk^.Deleted,
                    FileLine1, FileLine1 + Walk^.Deleted);
          Emit(cTagInsert, FileLine0 + Walk^.Deleted, FileLine0 + Walk^.Deleted,
                          FileLine1 + Walk^.Deleted, FileLine1 + Walk^.Inserted);
        end;
      end
      else if Walk^.Deleted > 0 then
      begin
        { Only deletes (all blank): emit equal covering the gap.
          But difflib requires i2-i1 == j2-j1, so we can't emit equal with
          differing lengths. Emit a delete for the blank lines — they're
          blank, but they're still deleted. This matches the JGit port's
          behavior (the JGit port suppressed the hunk, but for non-zero
          length mismatches it had to emit something). }
        { Actually, for "only deletes (all blank)", the inserted count is 0,
          so file 1 has nothing to align with. We can't suppress entirely.
          Emit a delete — the user can see the blank lines were removed.
          This matches the GNU diff -B behavior (which would suppress the
          whole hunk only if BOTH sides are blank-only; here only one side
          has lines). }
        if (PosA < FileLine0) or (PosB < FileLine1) then
          EmitEqual(PosA, FileLine0, PosB, FileLine1);
        Emit(cTagDelete, FileLine0, FileLine0 + Walk^.Deleted,
                        FileLine1, FileLine1);
      end
      else
      begin
        { Only inserts (all blank): similar — emit an insert. }
        if (PosA < FileLine0) or (PosB < FileLine1) then
          EmitEqual(PosA, FileLine0, PosB, FileLine1);
        Emit(cTagInsert, FileLine0, FileLine0,
                        FileLine1, FileLine1 + Walk^.Inserted);
      end;

      PosA := FileLine0 + Walk^.Deleted;
      PosB := FileLine1 + Walk^.Inserted;
    end;

    Walk := Walk^.Link;
  end;

  { Trailing equal (suffix + any trailing equal in differing region) }
  if (PosA < SizeA) or (PosB < SizeB) then
    EmitEqual(PosA, SizeA, PosB, SizeB);

  { Trim Result to actual count }
  SetLength(Result_, ResultCount);
  Result := Result_;
end;

{ ==================================================================
  Section 19: DoDiffTexts (public entry point)
  ==================================================================

  Public API. Computes a difflib-compatible opcode list for two text
  strings using the GNU diffutils 2.7 Myers algorithm (with Eggert
  heuristic) ported from WinMerge v2.16.58.

  AAlgo is ACCEPTED but IGNORED — there is only one algorithm now (Myers).
  DIFF_ALGO_HISTOGRAM (1) is silently mapped to Myers (G5, G31). Document
  this divergence at the top of DoDiffTexts.

  AFlags is a bitmask of DIFF_IGN_* values (see G5 for the mapping).

  Returns a TDiffOpcodeArray (difflib-compatible opcodes). }
function DoDiffTexts(const ATextA, ATextB: string; AAlgo: Integer; AFlags: Integer): TDiffOpcodeArray;
var
  Ctx: TDiffContext;
  Script: PChange;
  SizeA, SizeB: Integer;
begin
  Result := nil;

  { AAlgo is accepted but ignored — there is only one algorithm now
    (GNU diffutils Myers with Eggert heuristic). DIFF_ALGO_HISTOGRAM (1)
    is silently mapped to Myers. The Differ plugin currently passes
    algo=1 by default; this is now equivalent to algo=0. The output may
    differ slightly from the previous JGit Histogram port (patience-like
    anchoring on unique lines is replaced by Myers output), but is still
    valid difflib opcodes (G31). }

  { G16: both empty → return [] (matches difflib) }
  if (ATextA = '') and (ATextB = '') then
  begin
    SetLength(Result, 0);
    Exit;
  end;

  { Initialize context with flag mapping (G5) }
  InitContext(Ctx, AFlags);
  try
    { Run the diff (returns linked list of TChange records) }
    Script := Diff2Files(Ctx, ATextA, ATextB);

    { Get total line counts (including prefix and suffix — these are the
      "real" sizes for opcodes). Total = prefix_lines + valid_lines
      (where valid_lines = buffered_lines + suffix_lines). }
    SizeA := Ctx.Files[0].PrefixLines + Ctx.Files[0].ValidLines;
    SizeB := Ctx.Files[1].PrefixLines + Ctx.Files[1].ValidLines;

    { Convert change list → difflib opcodes (G3) }
    Result := ChangesToOpcodes(Ctx, Script, SizeA, SizeB);

    { Cleanup the script linked list }
    FreeScript(Script);
  finally
    FreeContext(Ctx);
  end;
end;

end.
