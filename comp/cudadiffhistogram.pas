(*
  CudaDiff — Free Pascal port of JGit's line-diff engine.

  Ported from:
    https://github.com/eclipse-jgit/jgit/tree/v7.7.1.202607240634-r/org.eclipse.jgit/src/org/eclipse/jgit/diff

  Pinned tag: v7.7.1.202607240634-r
  Commit URL pattern:
    https://raw.githubusercontent.com/eclipse-jgit/jgit/v7.7.1.202607240634-r/org.eclipse.jgit/src/org/eclipse/jgit/diff/<File>.java

  License: BSD-3-Clause (Eclipse Distribution License v1.0) — same as JGit.

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

  ----------------------------------------------------------------
  Source files ported
  ----------------------------------------------------------------
    JGit file                                | Pascal counterpart
    -----------------------------------------|---------------------------
    diff/Sequence.java                       | TSequence
    diff/SequenceComparator.java             | TSequenceComparator
    diff/SequenceComparator.reduceCommonStartEnd | TSequenceComparator.ReduceCommonStartEnd
    diff/RawText.java                        | TRawText
    diff/RawTextComparator.java              | TRawTextComparator + subclasses
    diff/Edit.java                           | TEdit + TEditType
    diff/EditList.java                       | TEditList
    diff/HashedSequence.java                 | THashedSequence
    diff/HashedSequenceComparator.java       | THashedSequenceComparator
    diff/HashedSequencePair.java             | THashedSequencePair
    diff/Subsequence.java                    | TSubsequence
    diff/SubsequenceComparator.java           | TSubsequenceComparator
    diff/DiffAlgorithm.java                  | TDiffAlgorithm (+ DiffAlgorithm.normalize)
    diff/LowLevelDiffAlgorithm.java          | TLowLevelDiffAlgorithm
    diff/MyersDiff.java                      | TMyersDiff + TMyersMiddleEdit + TMyersEditPaths
    diff/HistogramDiff.java                  | THistogramDiff + THistogramDiffState
    diff/HistogramDiffIndex.java             | THistogramDiffIndex
    util/IntList.java                         | TIntList
    util/LongList.java                        | TLongList
    util/RawCharUtil.java                     | (inlined as class methods of THashUtil)
    util/RawParseUtils.java (lineMap, nextLF)| TRawText.LineMap (with documented divergence)

  ----------------------------------------------------------------
  Documented divergences from JGit
  ----------------------------------------------------------------
  1. Line splitting (G8): JGit's RawParseUtils.lineMap() splits on \n only.
     Pascal's TRawText.Create splits on \r\n (treated as one boundary),
     \r (lone CR), and \n (lone LF) — matching CudaText's split_lines_safe()
     convention. See TRawText.Create for details.

  2. DIFF_IGN_CASE (G5): JGit has no case-insensitive comparator. We implement
     ASCII-only tolower per byte (matching WinMerge's io.c:348 behavior, NOT
     Unicode case folding). See TRawTextComparator*Equals methods.

  3. DIFF_IGN_NUMBERS (G6): JGit has no equivalent. We skip digit bytes
     entirely when hashing/comparing (matching WinMerge's io.c:307,334,345,356,
     382,393 behavior — `continue` on isdigit(c)). Both comparators perform a
     trailing cleanup pass after their main loops so leftover digits (and, in
     WS_IGNORE_ALL, leftover whitespace) do not cause a false "unequal" verdict
     when the other side is exhausted — keeps Equals consistent with
     HashRegion ("v33" == "v" under WHITESPACE|NUMBERS).

  4. DIFF_IGN_EOL (G9): JGit has no equivalent. We trim trailing \r\n / \n / \r
     from the line before hashing/comparing.

  5. Structural divergence (G31): JGit's RawTextComparator exposes WS_IGNORE_*
     as mutually-exclusive singletons (DEFAULT, WS_IGNORE_ALL, WS_IGNORE_LEADING,
     WS_IGNORE_TRAILING, WS_IGNORE_CHANGE). The Pascal port originally kept all
     five as subclasses, but after DIFF_IGN_WHITESPACE_CHANGE / _EOL / _BEGINNING
     were removed from diff_proc only two remain: TRawTextComparatorDefault and
     TRawTextComparatorWSIgnoreAll. CASE/NUMBERS/EOL flags are layered on top
     via helper functions (XformByte, IsSkippedByte, TrimTrailingEOL) called
     inline in each subclass's Equals/HashRegion. JGit has no precedent for
     this layering — it's documented as a divergence but produces the same
     result a Java-side ad-hoc comparator would produce.

  6. Compiler mode (G10, G12): CudaText is compiled with -Cr -Co (range +
     overflow checks). DJB2 and Knuth multiplicative hash intentionally wrap
     on overflow, so we wrap the affected code in $PUSH/$R-/$Q-...$POP.

  7. JGit's RawTextComparator.reduceCommonStartEnd has a likely typo:
     `int bPtr = a.lines.get(e.beginB + 1)` — reads from `a.lines` instead
     of `b.lines`. We port it correctly (use b.lines for bPtr). This only
     matters when a and b have different line layouts, which is rare but
     possible; the bug is harmless in 99% of real-world cases because
     aPtr/bPtr happen to coincide when sequences are similar.

  8. Pascal strings under objfpc mode with $H+ are AnsiString (UTF-8 bytes
     by CudaText convention). This matches JGit's byte[] semantics 1:1.
     We use RawByteString for content storage and access bytes via PByte —
     no UnicodeString/WideString/UnicodeLowerCase anywhere in this unit.

  9. Whitespace = space + tab only (G30): IsWhitespaceByte returns true
     for 0x20/0x09 only. JGit's RawCharUtil.isWhitespace() also counts
     \r and \n. Done for consistency with the other two engines
     (cudadiffmyers.IsWSpace / cudadiffchars.isSafeWhitespace) and with
     the wiki spec: line endings are the domain of DIFF_IGN_EOL only.
     With JGit's set, "a\r\n" compared EQUAL to "a\n" under
     DIFF_IGN_WHITESPACE alone in this engine but DIFFERENT in Myers —
     an inconsistency.

 10. DIFF_IGN_BLANK_LINES is a post-pass over the finished opcode
      list (G37): a hunk (insert/delete/replace) whose lines are ALL
      blank on both sides is re-tagged as a single 'ignore' opcode
      (ranges behave like 'replace'). Blank = empty after the EOL
      terminator, or - when DIFF_IGN_WHITESPACE is also set - only
      spaces/tabs (verified against GNU 'diff -B' / 'diff -B -b' ground
      truth: space-only lines are NOT blank under -B alone).
      'equal' opcodes are never touched, so i2-i1 == j2-j1 always holds
      for them; the Differ plugin paints 'ignore' regions with a
      distinct color and compensates the length mismatch with an
      inter-line gap (Editor.gap supports per-gap color + tag), the way
      WinMerge renders its "ignored differences". The same logic lives
      in cudadiffmyers.pas.

 11. PERFORMANCE PATCH (2026-08, private build, REVISION 3) — changes
      local to this unit; the public interface (DoDiffTexts, TDiffOpcode)
      is untouched. Background: profiling (Very Sleepy / callgrind) of
      two ~2 MB files with many differences and heavily repeated text
      showed ~68 s inside a single DoDiffTexts histogram call. The cost
      was per-comparison work: every element comparison in ScanA /
      TryLongestCommonSequence / Myers snakes paid a 3-layer virtual
      comparator stack whose leaf step is a byte-wise line comparison,
      and the histogram's occurrence-chain walks and extension loops
      perform tens of millions of those comparisons on repetitive text.

      REVISION HISTORY. Rev 1 shipped OPT-1 (flatten the comparator
      stack in the histogram hot loops) and OPT-2 (ScanA punts the
      whole region to the Myers fallback when any single element
      occurs more than maxChainLength times in the region). Measured on
      2 MB / 50k-line block-repetitive files, OPT-2 was a REGRESSION on
      exactly the inputs it targeted: any region containing a
      >64x-repeated line — which includes the ROOT region of any
      sufficiently repetitive file, since blank lines / closing braces
      / repeated records easily exceed 64 occurrences — was handed to
      Myers WHOLE, and Myers' unbounded O((N+M) x D) middle-snake
      search is slower than the pathology the punt tried to prevent
      (bench: 5.8x slower than the unpatched engine, with a heavily
      fragmented edit script). Rev 2 REMOVES OPT-2 entirely and
      restores JGit-faithful scanA semantics: occurrence counts
      saturate at MAX_CNT (255) exactly as in JGit, and too-common
      elements are ignored per-element by tryLongestCommonSequence's
      "recCnt(rec) > cnt" filter — the mechanism JGit itself uses.

      OPT-1 (kept from rev 1; no behavior change — rev-1 output was
      verified bit-identical against the unpatched engine by a
      4,200-case differential fuzz harness): THistogramDiffIndex
      resolves, at construction, the wrapper chains into flat
      references — cached line hashes are read via direct pointers,
      and each region's line byte-spans are precomputed into flat
      arrays — and the hot loops compare via hash gate + one call to
      TRawTextComparator.EqualsSpans (Equals of both subclasses now
      only resolves the spans and delegates; the comparison body is
      the previous Equals body, verbatim). When the wrapper chain is
      not the expected one, every fast path falls back to the original
      FCmp calls, so correctness never depends on the layout check.

      OPT-3 (new in rev 2; no behavior change — output verified
      bit-identical against the unpatched engine on the differential
      bench corpus): THashedSequencePair interns every line of both
      sequences into small integer IDs through a hash table keyed by
      the base comparator's own HashRegion() projection and verified
      on every hash collision by the base comparator's own
      EqualsSpans() (so "equal IDs" is EXACTLY "equal under the
      comparator", including all DIFF_IGN_* flags). The cached
      per-line hash arrays then hold the IDs, which makes element
      equality a single integer compare everywhere: the histogram
      index's ScanA / TryLongestCommonSequence (via OPT-1's flat
      pointers), the Myers fallback's snake walks, and normalize's
      shift loops. The byte-wise line comparison now runs exactly
      once per DISTINCT line during interning — O(input bytes),
      about 10-30 ms for 2x2 MB — instead of once per algorithm
      comparison step. Interning is skipped when the wrapper chain is
      not the expected one (then everything uses the OPT-1/legacy
      paths), so correctness never depends on it.

      OPT-4 (new in rev 2; bounded worst case — controlled divergence;
      GATED behind the OPT4_ENABLE_MYERS_D_CAP switch since rev 3):
      the Myers middle-snake search is no longer unbounded. One search
      stops after MYERS_MAX_D (16384) d-iterations or the natural
      meeting bound (N+M)/2, whichever comes first, and on cap
      exhaustion emits the remaining region as a single REPLACE
      edit — a valid tiling with coarser granularity. This bounds both
      the histogram's fallback path (regions with no rare-enough
      anchor, e.g. pure duplicated blocks) and the cAlgoMyers
      top-level engine: the unpatched engine needs minutes on 50k-line
      all-different regions, the capped one finishes in well under a
      second. Regions with ordinary edit distances (up to ~8k edits)
      still produce exact Myers output — identical to the unpatched
      engine — because their natural bound is below the cap.

      REVISION 3: OPT-4 is now the only opt-in/opt-out choice in this
      unit, controlled by the single boolean constant
      OPT4_ENABLE_MYERS_D_CAP, declared in the INTERFACE const block
      right below the uses clause (top of the unit). True (default)
      keeps rev-2 behavior. False restores the pre-patch UNBOUNDED
      middle-snake search — algorithm behavior then is bit-identical
      to the original unit (and to JGit) for every input, at the cost
      of the old worst case. Flip the constant and rebuild to toggle.
      OPT-1 and OPT-3 are behavior-neutral by construction and remain
      always-on (not switchable).
*)

unit CudaDiffHistogram;

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
  { *** OPT-4 MASTER SWITCH — the only behavior-affecting option in
    this unit. Flip this value and rebuild to toggle. ***

    True  (default): OPT-4 enabled (rev-2 behavior). The Myers
          middle-snake search stops after MYERS_MAX_D d-iterations
          and the leftover region is emitted as one REPLACE edit.
          Exact output for every region with edit distance up to
          ~2 x MYERS_MAX_D; only truly degenerate (mostly-different)
          regions degrade to a coarser block replace. This is what
          keeps 50k-line all-different regions under a second
          instead of minutes.

    False: OPT-4 fully disabled. The middle-snake search is
          unbounded — EXACTLY the pre-patch unit's (and JGit's)
          algorithm: identical results and opcodes for every input,
          but degenerate regions can again take minutes.

    The cap value is MYERS_MAX_D, declared in the implementation
    section (below the HistogramDiffIndex constants); 16384 is a
    good default, tune only if you know why.
    OPT-1/OPT-3 are behavior-neutral and not switchable. }
  OPT4_ENABLE_MYERS_D_CAP = True;

  { Algorithm selectors — must match proc_py_const.pas DIFF_ALGO_* }
  cAlgoMyers     = 0;
  cAlgoHistogram = 1;

  { Ignore flags — must match proc_py_const.pas DIFF_IGN_* }
  cIgnCase        = 1;      // DIFF_IGN_CASE
  cIgnWhitespace  = 2;      // DIFF_IGN_WHITESPACE
  cIgnEOL         = 4;      // DIFF_IGN_EOL
  cIgnNumbers     = 8;      // DIFF_IGN_NUMBERS
  cIgnBlankLines  = 16;     // DIFF_IGN_BLANK_LINES

  { Opcode tag values — must match proc_py_const.pas DIFF_TAG_* }
  cTagEqual   = 0;
  cTagDelete  = 1;
  cTagInsert  = 2;
  cTagReplace = 3;
  cTagIgnore  = 4;      // all-blank hunk suppressed by DIFF_IGN_BLANK_LINES

type
  { Public opcode type. Same layout as CudaDiffChars.TDiffOpcode but a
    SEPARATE Pascal type (G14) — the two units must not alias. }
  TDiffOpcode = record
    Tag: Integer;   // 0=equal, 1=delete, 2=insert, 3=replace, 4=ignore (suppressed all-blank hunk)
    I1, I2, J1, J2: Integer;
  end;
  TDiffOpcodeArray = array of TDiffOpcode;

  { Forward declarations }
  TSequence = class;
  TSequenceComparator = class;
  TRawText = class;
  TRawTextComparator = class;
  THashedSequence = class;
  THashedSequenceComparator = class;
  TSubsequence = class;
  TSubsequenceComparator = class;

  { ----------------------------------------------------------------
    TEdit — ported from diff/Edit.java (lines 32-262)
    ----------------------------------------------------------------
    A modified region between two versions of roughly the same content.

    beginA < endA && beginB == endB  -> delete (B removed region from A)
    beginA == endA && beginB < endB  -> insert (B inserted region at beginA)
    beginA < endA && beginB < endB   -> replace (B replaced region in A)
    beginA == endA && beginB == endB  -> empty (describes nothing)
  }
  TEditType = (etInsert, etDelete, etReplace, etEmpty);

  TEdit = record
    beginA, endA, beginB, endB: Integer;
    function GetType: TEditType; inline;
    function IsEmpty: Boolean; inline;
    function GetLengthA: Integer; inline;
    function GetLengthB: Integer; inline;
    procedure Shift(amount: Integer); inline;
    function Before(const cut: TEdit): TEdit; inline;
    function After(const cut: TEdit): TEdit; inline;
    procedure ExtendA; inline;
    procedure ExtendB; inline;
    procedure Swap; inline;
  end;
  TEditArray = array of TEdit;

  { ----------------------------------------------------------------
    TEditList — ported from diff/EditList.java (lines 18-56)
    ----------------------------------------------------------------
    Specialized list of TEdit records. We use a dynamic array of TEdit
    (records, value-type) rather than Java's ArrayList<Edit> (references).
    Edits are mutated via SetItem (write-back after copy). }
  TEditList = class
  private
    FItems: TEditArray;
    FCount: Integer;
    procedure Grow;
  public
    constructor Create(capacity: Integer = 16);
    function Size: Integer; inline;
    function Get(i: Integer): TEdit; inline;
    procedure SetItem(i: Integer; const e: TEdit); inline;
    procedure Add(const e: TEdit);
    procedure AddAt(index: Integer; const e: TEdit);
    procedure AddAll(other: TEditList);
    { Remove and return the last element. Matches Java's
      `queue.remove(queue.size() - 1)`. Raises if empty. }
    function RemoveLast: TEdit;
    class function Singleton(const e: TEdit): TEditList; static;
    property Items[i: Integer]: TEdit read Get write SetItem; default;
  end;

  { ----------------------------------------------------------------
    TIntList — ported from util/IntList.java (lines 17-219)
    ----------------------------------------------------------------
    A more efficient List<Integer> using a primitive integer array.
    We omit the sort() method (unused by diff code). }
  TIntList = class
  private
    FEntries: array of Integer;
    FCount: Integer;
    procedure Grow;
  public
    constructor Create(capacity: Integer = 10);
    function Size: Integer; inline;
    function Get(i: Integer): Integer; inline;
    procedure Clear;
    procedure Add(n: Integer);
    procedure SetItem(index: Integer; n: Integer);
    procedure FillTo(toIndex: Integer; val: Integer);
  end;

  { ----------------------------------------------------------------
    TLongList — ported from util/LongList.java (lines 19-155)
    ----------------------------------------------------------------
    A more efficient List<Long> using a primitive long array. }
  TLongList = class
  private
    FEntries: array of Int64;
    FCount: Integer;
    procedure Grow;
  public
    constructor Create(capacity: Integer = 10);
    function Size: Integer; inline;
    function Get(i: Integer): Int64; inline;
    procedure Clear;
    procedure Add(n: Int64);
    procedure SetItem(index: Integer; n: Int64);
    procedure FillTo(toIndex: Integer; val: Int64);
  end;

  { ----------------------------------------------------------------
    TSequence — ported from diff/Sequence.java (lines 29-37)
    ---------------------------------------------------------------- }
  TSequence = class
    function Size: Integer; virtual; abstract;
  end;

  { ----------------------------------------------------------------
    TSequenceComparator — ported from diff/SequenceComparator.java
    ----------------------------------------------------------------
    Equivalence function for a TSequence compared by difference algorithm.
    Indexes within a sequence are zero-based. }
  TSequenceComparator = class
    function Equals(a: TSequence; ai: Integer; b: TSequence; bi: Integer): Boolean; reintroduce; virtual; abstract;
    function Hash(seq: TSequence; ptr: Integer): Integer; virtual; abstract;
    function ReduceCommonStartEnd(a: TSequence; b: TSequence; var e: TEdit): TEdit; virtual;
  end;

  { ----------------------------------------------------------------
    TRawText — ported from diff/RawText.java (lines 41-590)
    ----------------------------------------------------------------
    A Sequence supporting UNIX-formatted text in byte[] format. Elements are
    lines of the file, delimited by line terminators.

    DIVERGENCE (G8): JGit's RawText uses RawParseUtils.lineMap() which
    splits on \n only. We split on \r\n (single boundary), \r, and \n —
    matching CudaText's split_lines_safe() convention. For files with
    \r\n or \n endings (99% of real-world files), line content is identical
    to JGit's split. Only files with lone \r endings (old Mac style, rare)
    produce different line counts. }
  TRawText = class(TSequence)
  private
    FContent: RawByteString;
    FLines: TIntList;
    FContentPtr: PByte;  // cached pointer to FContent[0] for fast byte access
    procedure UpdateContentPtr;
  public
    { Constructs a RawText from a UTF-8 byte buffer (Pascal string under
      objfpc mode with $H+). Matches JGit's RawText(byte[]) constructor. }
    constructor Create(const input: RawByteString);
    destructor Destroy; override;

    function Size: Integer; override;
    { Start byte offset of line i (0-based). Matches JGit's getStart(i) —
      uses lines[i+1] internally because lines[0] is a MIN_VALUE sentinel. }
    function GetStart(i: Integer): Integer; inline;
    { End byte offset of line i (0-based). Matches JGit's getEnd(i) —
      uses lines[i+2] internally. }
    function GetEnd(i: Integer): Integer; inline;

    property Content: RawByteString read FContent;
    property ContentPtr: PByte read FContentPtr;
    property Lines: TIntList read FLines;
  end;

  { ----------------------------------------------------------------
    TRawTextComparator — ported from diff/RawTextComparator.java
    ----------------------------------------------------------------
    Equivalence function for TRawText.

    Subclasses (one per JGit singleton that is still reachable from
      diff_proc flags):
      TRawTextComparatorDefault     -> RawTextComparator.DEFAULT
      TRawTextComparatorWSIgnoreAll -> RawTextComparator.WS_IGNORE_ALL

    JGit's WS_IGNORE_LEADING / WS_IGNORE_TRAILING / WS_IGNORE_CHANGE
    singletons are NOT ported: their diff_proc flags
    (DIFF_IGN_WHITESPACE_BEGINNING / _EOL / _CHANGE) were removed.

    Each subclass overrides Equals + HashRegion. The Hash() and
    ReduceCommonStartEnd() implementations live here (shared across subclasses).

    FFlags holds the non-WS ignore flags (CASE, NUMBERS, EOL) — these
    are applied uniformly across all WS modes via helper functions
    XformByte / IsSkippedByte / TrimTrailingEOL. }
  TRawTextComparator = class(TSequenceComparator)
  private
    FFlags: Integer;  // CASE | NUMBERS | EOL (WS flags handled by subclass)
  protected
    { JGit's RawTextComparator.hashCode — uses RawTextComparator.hashRegion.
      Implemented per-subclass. }
    function HashRegion(raw: PByte; ptr, end_: Integer): Integer; virtual; abstract;
  public
    constructor Create(AFlags: Integer = 0);

    { Ported from RawTextComparator.hash() (lines 223-228).
      begin = lines[lno+1], end = lines[lno+2]. }
    function Hash(seq: TSequence; ptr: Integer): Integer; override;

    { PERFORMANCE PATCH (OPT-1): span-based equality entry point.
      Compares byte ranges [aStart, aEnd) of ra and [bStart, bEnd) of rb
      under the subclass's rules — exactly what Equals does after
      resolving both lines' spans via Lines.Get (ai+1 / ai+2). The
      histogram hot loops call this directly with precomputed spans to
      skip the virtual comparator stack; Equals of each subclass now
      delegates here, so the two entry points can never disagree.
      Abstract like HashRegion — every concrete subclass must provide
      it (only Default and WSIgnoreAll exist, see G31). }
    function EqualsSpans(ra: TRawText; aStart, aEnd: Integer;
      rb: TRawText; bStart, bEnd: Integer): Boolean; virtual; abstract;

    { Ported from RawTextComparator.reduceCommonStartEnd() (lines 231-282).
      Fast byte-level prefix/suffix trim, then super.reduceCommonStartEnd
      for the remaining line-level trim. }
    function ReduceCommonStartEnd(a: TSequence; b: TSequence; var e: TEdit): TEdit; override;

    property Flags: Integer read FFlags;
  end;

  { DEFAULT: no special treatment — strict byte equality.
    Ported from RawTextComparator.DEFAULT (lines 25-53). }
  TRawTextComparatorDefault = class(TRawTextComparator)
  public
    function Equals(a: TSequence; ai: Integer; b: TSequence; bi: Integer): Boolean; override;
    function EqualsSpans(ra: TRawText; aStart, aEnd: Integer;
      rb: TRawText; bStart, bEnd: Integer): Boolean; override;
    function HashRegion(raw: PByte; ptr, end_: Integer): Integer; override;
  end;

  { WS_IGNORE_ALL: ignores all whitespace.
    Ported from RawTextComparator.WS_IGNORE_ALL (lines 56-104). }
  TRawTextComparatorWSIgnoreAll = class(TRawTextComparator)
  public
    function Equals(a: TSequence; ai: Integer; b: TSequence; bi: Integer): Boolean; override;
    function EqualsSpans(ra: TRawText; aStart, aEnd: Integer;
      rb: TRawText; bStart, bEnd: Integer): Boolean; override;
    function HashRegion(raw: PByte; ptr, end_: Integer): Integer; override;
  end;

  { ----------------------------------------------------------------
    THashedSequence — ported from diff/HashedSequence.java
    ----------------------------------------------------------------
    Wraps a TSequence to assign hash codes to elements. Acts as a proxy
    for the real sequence, caching element hash codes. }
  THashedSequence = class(TSequence)
  private
    FBase: TSequence;
    FHashes: array of Integer;
    function GetHash(i: Integer): Integer; inline;
  public
    constructor Create(base: TSequence; hashes: array of Integer);
    function Size: Integer; override;
    property Base: TSequence read FBase;
    property Hashes[i: Integer]: Integer read GetHash;
  end;

  { ----------------------------------------------------------------
    THashedSequenceComparator — ported from HashedSequenceComparator.java
    ----------------------------------------------------------------
    Wrap another comparator for use with THashedSequence. Evaluates the
    cached hash code before testing the underlying comparator's equality. }
  THashedSequenceComparator = class(TSequenceComparator)
  private
    FCmp: TSequenceComparator;
    { PERFORMANCE PATCH (OPT-3): True when the pair that created this
      comparator interned both sequences' lines into integer IDs stored
      in the THashedSequence.FHashes arrays. Then hash equality IS
      content equality (the intern table resolved every hash collision
      with the base comparator's EqualsSpans), so Equals() can skip the
      byte-wise fallback comparison entirely. }
    FIdsExact: Boolean;
  public
    constructor Create(cmp: TSequenceComparator; AIdsExact: Boolean = False);
    function Equals(a: TSequence; ai: Integer; b: TSequence; bi: Integer): Boolean; override;
    function Hash(seq: TSequence; ptr: Integer): Integer; override;
    function ReduceCommonStartEnd(a: TSequence; b: TSequence; var e: TEdit): TEdit; override;
    property Cmp: TSequenceComparator read FCmp;
  end;

  { ----------------------------------------------------------------
    THashedSequencePair — ported from HashedSequencePair.java
    ----------------------------------------------------------------
    Wraps two TSequence instances to cache their element hash codes. }
  THashedSequencePair = class
  private
    FCmp: TSequenceComparator;
    FBaseA: TSequence;
    FBaseB: TSequence;
    FCachedA: THashedSequence;
    FCachedB: THashedSequence;
    { PERFORMANCE PATCH (OPT-3): True when InternAll succeeded and
      FCachedA/FCachedB hold interned line IDs instead of plain hashes.
      Propagated to the comparator by GetComparator. }
    FIdsExact: Boolean;
    function Wrap(base: TSequence): THashedSequence;
    { PERFORMANCE PATCH (OPT-3): intern every line of both base
      sequences into integer IDs; on success builds FCachedA/FCachedB
      eagerly and sets FIdsExact. On failure (unexpected wrapper
      chain) leaves everything untouched so GetA/GetB lazily fall
      back to Wrap(). }
    procedure InternAll;
  public
    constructor Create(cmp: TSequenceComparator; a, b: TSequence);
    destructor Destroy; override;
    function GetComparator: THashedSequenceComparator;
    function GetA: THashedSequence;
    function GetB: THashedSequence;
  end;

  { ----------------------------------------------------------------
    TSubsequence — ported from diff/Subsequence.java
    ----------------------------------------------------------------
    Wraps a TSequence to have a narrower range of elements. Translates
    element indexes on the fly by adding `begin` to them. }
  TSubsequence = class(TSequence)
  private
    FBase: TSequence;
    FBegin: Integer;
    FSize: Integer;
  public
    constructor Create(base: TSequence; begn, end_: Integer);
    function Size: Integer; override;
    class function A(base: TSequence; const region: TEdit): TSubsequence; static;
    class function B(base: TSequence; const region: TEdit): TSubsequence; static;
    class procedure ToBaseEdit(var e: TEdit; sa, sb: TSubsequence); static;
    class function ToBaseEditList(edits: TEditList; sa, sb: TSubsequence): TEditList; static;
    property Base: TSequence read FBase;
    property BeginOffset: Integer read FBegin;
  end;

  { ----------------------------------------------------------------
    TSubsequenceComparator — ported from SubsequenceComparator.java
    ---------------------------------------------------------------- }
  TSubsequenceComparator = class(TSequenceComparator)
  private
    FCmp: TSequenceComparator;
  public
    constructor Create(cmp: TSequenceComparator);
    function Equals(a: TSequence; ai: Integer; b: TSequence; bi: Integer): Boolean; override;
    function Hash(seq: TSequence; ptr: Integer): Integer; override;
    function ReduceCommonStartEnd(a: TSequence; b: TSequence; var e: TEdit): TEdit; override;
    property Cmp: TSequenceComparator read FCmp;
  end;

  { ----------------------------------------------------------------
    TDiffAlgorithm — ported from diff/DiffAlgorithm.java
    ---------------------------------------------------------------- }
  TDiffAlgorithm = class
  public
    { Ported from DiffAlgorithm.diff() (lines 79-105).
      Reduces common start/end, then dispatches by EditType. }
    function Diff(cmp: TSequenceComparator; a, b: TSequence): TEditList;
    { Subclass-specific implementation. JGit's diffNonCommon() is the
      post-prefix/suffix-trim entry point. }
    function DiffNonCommon(cmp: TSequenceComparator; a, b: TSequence): TEditList; virtual; abstract;
    { Ported from DiffAlgorithm.normalize() (lines 186-210).
      Shifts INSERT/DELETE edits to their latest possible position.
      Called by Diff() after diffNonCommon returns. }
    class function Normalize(cmp: TSequenceComparator; e: TEditList; a, b: TSequence): TEditList; static;
  end;

  { ----------------------------------------------------------------
    TLowLevelDiffAlgorithm — ported from LowLevelDiffAlgorithm.java
    ---------------------------------------------------------------- }
  TLowLevelDiffAlgorithm = class(TDiffAlgorithm)
  public
    function DiffNonCommon(cmp: TSequenceComparator; a, b: TSequence): TEditList; override;
    { Subclass-specific. Wraps sequences in HashedSequencePair first, then
      calls the algorithm-specific method with a (0, a.size, 0, b.size) region. }
    procedure DiffNonCommonLow(edits: TEditList;
      cmp: THashedSequenceComparator;
      a, b: THashedSequence;
      const region: TEdit); virtual; abstract;
  end;

  { ----------------------------------------------------------------
    TMyersDiff — ported from diff/MyersDiff.java
    ----------------------------------------------------------------
    O(ND) Myers diff with linear-space middle-snake optimization.

    The basic idea: line numbers of text A as columns ("x"), lines of text B
    as rows ("y"). Find shortest "edit path" from upper-left to lower-right
    where you can go horizontally or vertically, but diagonal (x+1,y+1) only
    if line x in A equals line y in B.

    Optimization: generate D-paths simultaneously from both sides. When
    the ends meet, we've found "the middle" of the path. From the end
    points of that diagonal part, we generate the rest recursively.
    This requires only linear space. }
  TMyersDiff = class(TLowLevelDiffAlgorithm)
  public
    procedure DiffNonCommonLow(edits: TEditList;
      cmp: THashedSequenceComparator;
      a, b: THashedSequence;
      const region: TEdit); override;
  end;

  { ----------------------------------------------------------------
    THistogramDiff — ported from diff/HistogramDiff.java
    ----------------------------------------------------------------
    Extended Bram Cohen patience diff. Builds a histogram of occurrences
    for each element of A. Scans B for matching elements with the lowest
    occurrence count; splits region around that LCS, recurses. Falls back
    to MyersDiff when a region's hash-bucket chains exceed maxChainLength
    (default 64) — the JGit rule. PERFORMANCE PATCH (OPT-4, only when
    OPT4_ENABLE_MYERS_D_CAP = True): the fallback (and the cAlgoMyers
    engine) is bounded by a diagonal-step budget; see header note 11. }
  THistogramDiff = class(TLowLevelDiffAlgorithm)
  private
    FFallback: TDiffAlgorithm;
    FMaxChainLength: Integer;
  public
    constructor Create;
    procedure SetFallbackAlgorithm(alg: TDiffAlgorithm);
    procedure SetMaxChainLength(maxLen: Integer);
    procedure DiffNonCommonLow(edits: TEditList;
      cmp: THashedSequenceComparator;
      a, b: THashedSequence;
      const region: TEdit); override;
    property Fallback: TDiffAlgorithm read FFallback;
    property MaxChainLength: Integer read FMaxChainLength;
  end;

{ ----------------------------------------------------------------
  Public entry point — called by formmain_py_api.inc
  ---------------------------------------------------------------- }
function DoDiffTexts(const ATextA, ATextB: string;
                     AAlgo: Integer;
                     AFlags: Integer): TDiffOpcodeArray;

{ ------------------------------------------------------------------
  Cooperative cancellation (diff_proc DIF_CANCEL)
  ------------------------------------------------------------------
  The background diff thread in formmain_py_api.inc (TCudaDiffThread)
  points this threadvar at its cancel flag before calling DoDiffTexts,
  and nils it afterwards. The engine's long-running loops poll the flag
  at coarse granularity (per outer-loop step); when it is set they raise
  EDiffCancelled.

  The exception unwinds the Pascal stack: FPC runs every try/finally
  block and finalizes every refcounted string / dynamic array on the
  way out, so all intermediate state (RawTexts, hashed sequences, the
  histogram index's tables, the edit-script queues) is released --
  nothing leaks. This is why the cancellation is cooperative instead of
  a forced thread kill: a killed thread skips the unwinding, leaking
  its stack, its heap blocks and any heap lock it held at kill time.

  Each unit (CudaDiffMyers / CudaDiffHistogram / CudaDiffChars) declares
  its own threadvar, so several background compares can run at once and
  cancelling one job never touches the others. Synchronous calls run on
  the main thread, whose threadvar stays nil -- they are never
  cancelled. }
type
  EDiffCancelled = class(Exception);

threadvar
  { nil = no cancellation requested for the current thread's diff }
  DiffCancelFlag: PBoolean;

implementation

{ ------------------------------------------------------------------
  Cooperative-cancellation poll (diff_proc DIF_CANCEL)
  ------------------------------------------------------------------
  Poll the cancellation flag of the calling thread's diff job; raises
  EDiffCancelled when diff_proc(DIF_CANCEL) was called for that job.
  Called from the engine's outer loops at coarse granularity, so the
  cost is one nil-check per loop step. nil means "no diff thread / no
  cancellation" -- synchronous callers never cancel. }
procedure DiffCheckCancelled; inline;
begin
  if (DiffCancelFlag <> nil) and DiffCancelFlag^ then
    raise EDiffCancelled.Create('diff cancelled');
end;

{ ------------------------------------------------------------------
  HistogramDiffIndex constants — ported from diff/HistogramDiffIndex.java
  (lines 28-38).
  JGit declares these as `private static final int` inside the class.
  Pascal's objfpc mode doesn't support `class const` in classes
  (only in Delphi mode), so we declare them at unit scope instead.
  The values are the same as JGit's and referenced directly by
  THistogramDiffIndex methods below.
  ------------------------------------------------------------------ }
const
  HDI_REC_NEXT_SHIFT = 28 + 8;       // 36
  HDI_REC_PTR_SHIFT  = 8;
  HDI_REC_PTR_MASK   = (1 shl 28) - 1;
  HDI_REC_CNT_MASK   = (1 shl 8) - 1;
  HDI_MAX_PTR        = HDI_REC_PTR_MASK;
  HDI_MAX_CNT        = (1 shl 8) - 1;

  { PERFORMANCE PATCH (OPT-1): Knuth multiplicative hash constant used by
    THistogramDiffIndex.HashA / HashB (was a function-local const inside
    the former Hash method). Same value as JGit's 0x9e370001. Also used
    to bucket OPT-3's line-interning table. }
  HDI_KNUTH_MULTIPLIER = $9E370001;

  { PERFORMANCE PATCH (OPT-4): d-iteration cap for ONE Myers middle-snake
    search (see TMyersMiddleEdit.Calculate). ONLY CONSULTED WHEN
    OPT4_ENABLE_MYERS_D_CAP = True (interface const, top of unit); with
    the switch off the search is unbounded and this constant is unused.
    The search's natural bound
    is d = (N+M)/2 (paths must meet by then); for regions whose real
    edit distance is larger than ~2 x MYERS_MAX_D the search would grind
    for O((N+M) x D) steps, so d is capped at MYERS_MAX_D and the region
    is emitted as a single REPLACE edit instead. Measured (FPC -O2 -Cr
    -Co, 50k+50k lines): repetitive regions with D ~ 16k stay EXACT
    (their meet depth is below the cap); a fully-different 100k-line
    region bails after ~25 s instead of the unpatched engine's
    unbounded minutes. 16384 keeps regions with edit distance up to
    ~32k (i.e. all "many but ordinary" differences — the profile that
    produced 8000 hunks in the user's capture) EXACT; only truly
    degenerate regions (mostly-different content) degrade to a block
    replace. }
  MYERS_MAX_D = 16384;

{ ------------------------------------------------------------------
  Helper functions — byte transforms for CASE/NUMBERS/EOL flags.
  These are NOT part of JGit (which has no such flags) — documented
  divergence from JGit, applied uniformly across all WS comparators.
  ------------------------------------------------------------------ }

{ Apply ASCII-only tolower to a byte when DIFF_IGN_CASE is set.
  Matches WinMerge's io.c:348 behavior. Unicode case folding is NOT
  performed because it can change byte length (e.g. İ -> i̇). }
function XformByte(c: Byte; AFlags: Integer): Byte; inline;
begin
  if (AFlags and cIgnCase) <> 0 then
    if (c >= $41) and (c <= $5A) then  // 'A'..'Z'
      Exit(c or $20);
  Result := c;
end;

{ Returns True if this byte should be skipped (under DIFF_IGN_NUMBERS).
  Matches WinMerge's io.c:307,334,345,356,382,393 — `continue` past
  every digit byte. Only ASCII [0-9] counts; non-ASCII digits do not. }
function IsSkippedByte(c: Byte; AFlags: Integer): Boolean; inline;
begin
  if (AFlags and cIgnNumbers) <> 0 then
    if (c >= $30) and (c <= $39) then  // '0'..'9'
      Exit(True);
  Result := False;
end;

{ Returns True if c is a whitespace byte for the DIFF_IGN_WHITESPACE
  comparator: space (0x20) and tab (0x09) ONLY.

  DIVERGENCE from JGit: RawCharUtil.isWhitespace() (util/RawCharUtil.java:
  35-37) also counts \r and \n. We exclude them on purpose: in diff_proc,
  "whitespace" means space+tab in ALL THREE engines (cudadiffchars /
  cudadiffhistogram / cudadiffmyers — IsWSpace there is 0x20/0x09 too),
  and line terminators are the domain of DIFF_IGN_EOL. With \r/\n included
  here, "a\r\n" vs "a\n" compared EQUAL under DIFF_IGN_WHITESPACE alone in
  the histogram engine but DIFFERENT in the Myers engine — an
  cross-engine inconsistency (the terminators also leaked into the row
  hash, making the EOL flag a no-op for the WS comparator). Line
  terminators never count as whitespace. }
function IsWhitespaceByte(c: Byte): Boolean; inline;
begin
  Result := (c = $09) or (c = $20);
end;

{ Trims trailing whitespace bytes (space / tab — see IsWhitespaceByte)
  from [ptr, end_). Ported from RawCharUtil.trimTrailingWhitespace()
  (util/RawCharUtil.java:52-58). Returns the new end position. }
function TrimTrailingWhitespace(raw: PByte; start, end_: Integer): Integer; inline;
var
  p: Integer;
begin
  p := end_ - 1;
  while (start <= p) and IsWhitespaceByte(raw[p]) do
    Dec(p);
  Result := p + 1;
end;

{ NOTE: RawCharUtil.trimLeadingWhitespace() (util/RawCharUtil.java:73-78) is
  NOT ported — it was only used by the WS_IGNORE_LEADING / WS_IGNORE_CHANGE
  comparators, which are not ported (their diff_proc flags
  DIFF_IGN_WHITESPACE_BEGINNING / DIFF_IGN_WHITESPACE_CHANGE were removed). }

{ Trims trailing EOL (\r\n, \n, \r) from [ptr, end_) when DIFF_IGN_EOL is set.
  DIVERGENCE from JGit (G9) — JGit has no such comparator. }
function TrimTrailingEOL(raw: PByte; ptr, end_: Integer; AFlags: Integer): Integer; inline;
begin
  if (AFlags and cIgnEOL) <> 0 then
  begin
    if end_ > ptr then
    begin
      if raw[end_ - 1] = $0A then  // \n
      begin
        Dec(end_);
        if (end_ > ptr) and (raw[end_ - 1] = $0D) then  // \r before \n
          Dec(end_);
      end
      else if raw[end_ - 1] = $0D then  // \r
        Dec(end_);
    end;
  end;
  Result := end_;
end;

{ ------------------------------------------------------------------
  DJB2 hash helper — ported from RawTextComparator.DEFAULT.hashRegion
  (diff/RawTextComparator.java:47-52).

  DJB2: seed = 5381, multiplier = 33 (implemented as (hash << 5) + hash).
  Per-byte: hash := ((hash shl 5) + hash) + (raw[ptr] and $FF).
  Wraps on overflow intentionally — must use $PUSH/$R-/$Q- around it
  to match JGit's behavior under -Cr -Co (G10, G12). }
function Djb2Hash(raw: PByte; ptr, end_: Integer): Integer;
{$PUSH}{$R-}{$Q-}
var
  h: Integer;
begin
  h := 5381;
  while ptr < end_ do
  begin
    h := ((h shl 5) + h) + (raw[ptr] and $FF);
    Inc(ptr);
  end;
  Result := h;
end;
{$POP}

{ DJB2 hash with CASE-fold transform applied per byte.
  DIVERGENCE: WinMerge-style ASCII tolower on bytes (G5). }
function Djb2HashCase(raw: PByte; ptr, end_: Integer; AFlags: Integer): Integer;
{$PUSH}{$R-}{$Q-}
var
  h: Integer;
  c: Byte;
begin
  h := 5381;
  while ptr < end_ do
  begin
    c := raw[ptr];
    if (AFlags and cIgnNumbers) <> 0 then
      if (c >= $30) and (c <= $39) then
      begin
        Inc(ptr);
        Continue;
      end;
    h := ((h shl 5) + h) + (XformByte(c, AFlags) and $FF);
    Inc(ptr);
  end;
  Result := h;
end;
{$POP}

{ ------------------------------------------------------------------
  TEdit methods
  ------------------------------------------------------------------ }

function TEdit.GetType: TEditType;
begin
  if beginA < endA then
  begin
    if beginB < endB then
      Exit(etReplace);
    Exit(etDelete);
  end;
  if beginB < endB then
    Exit(etInsert);
  Result := etEmpty;
end;

function TEdit.IsEmpty: Boolean;
begin
  Result := (beginA = endA) and (beginB = endB);
end;

function TEdit.GetLengthA: Integer;
begin
  Result := endA - beginA;
end;

function TEdit.GetLengthB: Integer;
begin
  Result := endB - beginB;
end;

procedure TEdit.Shift(amount: Integer);
begin
  Inc(beginA, amount);
  Inc(endA, amount);
  Inc(beginB, amount);
  Inc(endB, amount);
end;

function TEdit.Before(const cut: TEdit): TEdit;
begin
  Result.beginA := beginA;
  Result.endA := cut.beginA;
  Result.beginB := beginB;
  Result.endB := cut.beginB;
end;

function TEdit.After(const cut: TEdit): TEdit;
begin
  Result.beginA := cut.endA;
  Result.endA := endA;
  Result.beginB := cut.endB;
  Result.endB := endB;
end;

procedure TEdit.ExtendA;
begin
  Inc(endA);
end;

procedure TEdit.ExtendB;
begin
  Inc(endB);
end;

procedure TEdit.Swap;
var
  sBegin, sEnd: Integer;
begin
  sBegin := beginA;
  sEnd := endA;
  beginA := beginB;
  endA := endB;
  beginB := sBegin;
  endB := sEnd;
end;

{ ------------------------------------------------------------------
  TEditList methods
  ------------------------------------------------------------------ }

constructor TEditList.Create(capacity: Integer);
begin
  inherited Create;
  SetLength(FItems, capacity);
  FCount := 0;
end;

procedure TEditList.Grow;
var
  newCap: Integer;
begin
  if Length(FItems) = 0 then
    newCap := 16
  else
    newCap := (Length(FItems) + 16) * 3 div 2;
  SetLength(FItems, newCap);
end;

function TEditList.Size: Integer;
begin
  Result := FCount;
end;

function TEditList.Get(i: Integer): TEdit;
begin
  if (i < 0) or (i >= FCount) then
    raise EArgumentOutOfRangeException.CreateFmt('TEditList.Get(%d) out of range [0, %d)', [i, FCount]);
  Result := FItems[i];
end;

procedure TEditList.SetItem(i: Integer; const e: TEdit);
begin
  if (i < 0) or (i >= FCount) then
    raise EArgumentOutOfRangeException.CreateFmt('TEditList.SetItem(%d) out of range [0, %d)', [i, FCount]);
  FItems[i] := e;
end;

procedure TEditList.Add(const e: TEdit);
begin
  if FCount = Length(FItems) then
    Grow;
  FItems[FCount] := e;
  Inc(FCount);
end;

procedure TEditList.AddAt(index: Integer; const e: TEdit);
begin
  if (index < 0) or (index > FCount) then
    raise EArgumentOutOfRangeException.CreateFmt('TEditList.AddAt(%d) out of range [0, %d]', [index, FCount]);
  if FCount = Length(FItems) then
    Grow;
  if index < FCount then
    Move(FItems[index], FItems[index + 1], (FCount - index) * SizeOf(TEdit));
  FItems[index] := e;
  Inc(FCount);
end;

procedure TEditList.AddAll(other: TEditList);
var
  i: Integer;
begin
  if other = nil then
    Exit;
  for i := 0 to other.Size - 1 do
    Add(other.Get(i));
end;

class function TEditList.Singleton(const e: TEdit): TEditList;
begin
  Result := TEditList.Create(1);
  Result.Add(e);
end;

function TEditList.RemoveLast: TEdit;
{ Returns the last element and decrements FCount. The underlying array
  is NOT shrunk (just like Java's ArrayList.remove, which only decrements
  size). Subsequent Add() calls will reuse the slot. }
begin
  if FCount = 0 then
    raise EArgumentOutOfRangeException.Create('TEditList.RemoveLast: empty list');
  Dec(FCount);
  Result := FItems[FCount];
end;

{ ------------------------------------------------------------------
  TIntList methods — ported from util/IntList.java
  ------------------------------------------------------------------ }

constructor TIntList.Create(capacity: Integer);
begin
  inherited Create;
  SetLength(FEntries, capacity);
  FCount := 0;
end;

procedure TIntList.Grow;
var
  newCap: Integer;
begin
  if Length(FEntries) = 0 then
    newCap := 10
  else
    newCap := (Length(FEntries) + 16) * 3 div 2;
  SetLength(FEntries, newCap);
end;

function TIntList.Size: Integer;
begin
  Result := FCount;
end;

function TIntList.Get(i: Integer): Integer;
begin
  if (i < 0) or (i >= FCount) then
    raise EArgumentOutOfRangeException.CreateFmt('TIntList.Get(%d) out of range [0, %d)', [i, FCount]);
  Result := FEntries[i];
end;

procedure TIntList.Clear;
begin
  FCount := 0;
end;

procedure TIntList.Add(n: Integer);
begin
  if FCount = Length(FEntries) then
    Grow;
  FEntries[FCount] := n;
  Inc(FCount);
end;

procedure TIntList.SetItem(index: Integer; n: Integer);
begin
  if (index < 0) or (index > FCount) then
    raise EArgumentOutOfRangeException.CreateFmt('TIntList.SetItem(%d) out of range [0, %d]', [index, FCount]);
  if index = FCount then
    Add(n)
  else
    FEntries[index] := n;
end;

procedure TIntList.FillTo(toIndex: Integer; val: Integer);
begin
  while FCount < toIndex do
    Add(val);
end;

{ ------------------------------------------------------------------
  TLongList methods — ported from util/LongList.java
  ------------------------------------------------------------------ }

constructor TLongList.Create(capacity: Integer);
begin
  inherited Create;
  SetLength(FEntries, capacity);
  FCount := 0;
end;

procedure TLongList.Grow;
var
  newCap: Integer;
begin
  if Length(FEntries) = 0 then
    newCap := 10
  else
    newCap := (Length(FEntries) + 16) * 3 div 2;
  SetLength(FEntries, newCap);
end;

function TLongList.Size: Integer;
begin
  Result := FCount;
end;

function TLongList.Get(i: Integer): Int64;
begin
  if (i < 0) or (i >= FCount) then
    raise EArgumentOutOfRangeException.CreateFmt('TLongList.Get(%d) out of range [0, %d)', [i, FCount]);
  Result := FEntries[i];
end;

procedure TLongList.Clear;
begin
  FCount := 0;
end;

procedure TLongList.Add(n: Int64);
begin
  if FCount = Length(FEntries) then
    Grow;
  FEntries[FCount] := n;
  Inc(FCount);
end;

procedure TLongList.SetItem(index: Integer; n: Int64);
begin
  if (index < 0) or (index > FCount) then
    raise EArgumentOutOfRangeException.CreateFmt('TLongList.SetItem(%d) out of range [0, %d]', [index, FCount]);
  if index = FCount then
    Add(n)
  else
    FEntries[index] := n;
end;

procedure TLongList.FillTo(toIndex: Integer; val: Int64);
begin
  while FCount < toIndex do
    Add(val);
end;

{ ------------------------------------------------------------------
  TSequenceComparator — ported from diff/SequenceComparator.java
  ------------------------------------------------------------------ }

{ Ported from SequenceComparator.reduceCommonStartEnd() (lines 81-99).
  Default implementation: use equals() to skip common leading and trailing
  items. Mutates e in place; returns the (modified) e.

  Subclasses (RawTextComparator) override this with a faster byte-level
  fast path that ultimately calls back into this method via inherited. }
function TSequenceComparator.ReduceCommonStartEnd(a: TSequence; b: TSequence; var e: TEdit): TEdit;
begin
  // Skip over items that are common at the start.
  while (e.beginA < e.endA) and (e.beginB < e.endB)
        and Equals(a, e.beginA, b, e.beginB) do
  begin
    { Cooperative-cancellation poll: O(N) line-trim loop (the RawText
      comparator's byte fast path delegates here for its slow path). }
    if ((e.beginA + e.beginB) and $FFF) = 0 then
      DiffCheckCancelled;
    Inc(e.beginA);
    Inc(e.beginB);
  end;

  // Skip over items that are common at the end.
  while (e.beginA < e.endA) and (e.beginB < e.endB)
        and Equals(a, e.endA - 1, b, e.endB - 1) do
  begin
    if ((e.beginA + e.beginB) and $FFF) = 0 then
      DiffCheckCancelled;
    Dec(e.endA);
    Dec(e.endB);
  end;

  Result := e;
end;

{ ------------------------------------------------------------------
  TRawText — ported from diff/RawText.java (lines 41-590)
  ------------------------------------------------------------------ }

{ Ported from RawText(byte[]) constructor (lines 72-74).
  Calls RawParseUtils.lineMap(input, 0, input.length) — but with our
  documented divergence (G8): split on \r\n / \r / \n instead of just \n.

  Builds an IntList with this layout:
    Index 0     : MIN_VALUE sentinel (matches JGit's `map.fillTo(1, Integer.MIN_VALUE)`)
    Index 1..N  : byte offset of the start of each line (1-based indexing)
    Index N+1   : end-of-content (= Length(input))

  For "abc\n":
    Index 0: MIN_VALUE
    Index 1: 0    (start of line "abc\n")
    Index 2: 4    (end of content)
  -> Size() = 3 - 2 = 1 line.

  For "" (empty input):
    Index 0: MIN_VALUE
    Index 1: 0    (end of content)
  -> Size() = 2 - 2 = 0 lines.

  For "abc" (no terminator):
    Index 0: MIN_VALUE
    Index 1: 0    (start of line "abc")
    Index 2: 3    (end of content)
  -> Size() = 3 - 2 = 1 line.

  For "a\r\nb\nc\rd" (mixed EOLs):
    Index 0: MIN_VALUE
    Index 1: 0    (start of "a\r\n")
    Index 2: 3    (start of "b\n")
    Index 3: 5    (start of "c\r")
    Index 4: 7    (start of "d" - no terminator)
    Index 5: 8    (end of content)
  -> Size() = 5 - 2 = 4 lines.

  Edge cases (must match split_lines_safe exactly):
    1. "abc\n" -> 1 line: "abc\n"
    2. ""      -> 0 lines
    3. "abc"   -> 1 line: "abc"
    4. "a\r\nb\nc\rd" -> 4 lines: "a\r\n", "b\n", "c\r", "d"
    5. "\r\n"  -> 1 line: "\r\n" (NOT 2 lines)
    6. "\n\n"  -> 2 lines: "\n", "\n"

  Implementation: scan byte-by-byte. At each position, look for \r\n
  (treated as ONE boundary), \r, or \n. }
constructor TRawText.Create(const input: RawByteString);
var
  map: TIntList;
  p, n: Integer;
  raw: PByte;
begin
  inherited Create;
  FContent := input;
  UpdateContentPtr;
  raw := FContentPtr;
  n := Length(input);

  map := TIntList.Create((n div 36) + 8);
  FLines := map;

  // JGit: map.fillTo(1, Integer.MIN_VALUE) — index 0 is a MIN_VALUE sentinel.
  // In Pascal, Low(Integer) = -2147483648 = Java's Integer.MIN_VALUE.
  map.FillTo(1, Low(Integer));

  p := 0;
  while p < n do
  begin
    { Cooperative-cancellation poll: O(bytes) line-map pass, one per line }
    DiffCheckCancelled;
    map.Add(p);
    // Find next line boundary: \r\n (one boundary), \r (one boundary), \n (one boundary).
    // Match RawParseUtils.nextLF() semantics: returns position *after* the LF.
    while p < n do
    begin
      if raw[p] = $0A then  // \n
      begin
        Inc(p);  // position *after* the LF
        Break;
      end
      else if raw[p] = $0D then  // \r
      begin
        Inc(p);
        if (p < n) and (raw[p] = $0A) then  // \r\n
          Inc(p);
        Break;
      end
      else
        Inc(p);
    end;
  end;

  // Final sentinel: end-of-content. Matches JGit's map.add(end) at the end.
  map.Add(n);
end;

destructor TRawText.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

procedure TRawText.UpdateContentPtr;
begin
  if Length(FContent) > 0 then
    FContentPtr := PByte(Pointer(FContent))
  else
    FContentPtr := nil;
end;

{ Ported from RawText.size() (lines 119-126).
  Line map is always 2 entries larger than line count: index 0 is padding,
  last index is total buffer length (sentinel). }
function TRawText.Size: Integer;
begin
  Result := FLines.Size - 2;
end;

{ Ported from RawText.getStart(i) (private, lines 241-243).
  Uses lines[i+1] because lines[0] is the MIN_VALUE sentinel. }
function TRawText.GetStart(i: Integer): Integer;
begin
  Result := FLines.Get(i + 1);
end;

{ Ported from RawText.getEnd(i) (private, lines 245-247).
  Uses lines[i+2] — the next line's start = current line's end. }
function TRawText.GetEnd(i: Integer): Integer;
begin
  Result := FLines.Get(i + 2);
end;

{ ------------------------------------------------------------------
  TRawTextComparator methods — ported from diff/RawTextComparator.java
  ------------------------------------------------------------------ }

constructor TRawTextComparator.Create(AFlags: Integer);
begin
  inherited Create;
  FFlags := AFlags;
end;

{ Ported from RawTextComparator.hash() (lines 223-228).
  begin = lines[lno+1], end = lines[lno+2].
  Delegates to per-subclass HashRegion. }
function TRawTextComparator.Hash(seq: TSequence; ptr: Integer): Integer;
var
  rt: TRawText;
  lBegin, lEnd: Integer;
begin
  rt := seq as TRawText;
  lBegin := rt.Lines.Get(ptr + 1);
  lEnd := rt.Lines.Get(ptr + 2);
  Result := HashRegion(rt.ContentPtr, lBegin, lEnd);
end;

{ Ported from RawTextComparator.findForwardLine() (lines 284-289).
  Scans lines forward from idx until lines[idx+2] >= ptr. }
function FindForwardLine(lines: TIntList; idx, ptr: Integer): Integer;
var
  endIdx: Integer;
begin
  endIdx := lines.Size - 2;
  while (idx < endIdx) and (lines.Get(idx + 2) < ptr) do
    Inc(idx);
  Result := idx;
end;

{ Ported from RawTextComparator.findReverseLine() (lines 291-295).
  Scans lines backward from idx while ptr <= lines[idx]. }
function FindReverseLine(lines: TIntList; idx, ptr: Integer): Integer;
begin
  while (0 < idx) and (ptr <= lines.Get(idx)) do
    Dec(idx);
  Result := idx;
end;

{ Ported from RawTextComparator.reduceCommonStartEnd() (lines 231-282).

  Fast byte-level prefix/suffix trim, then super.reduceCommonStartEnd
  for line-level trim via equals().

  DIVERGENCE: JGit's source at line 245 reads `bPtr = a.lines.get(e.beginB + 1)`
  which is almost certainly a typo for `b.lines.get(...)`. We port it
  correctly with `b.lines.get(...)`. The bug in JGit only matters when
  a and b have different line layouts (rare); in 99% of cases aPtr and
  bPtr coincide because the common prefix implies similar line layouts.

  Also: when CASE/NUMBERS/EOL flags are set, the byte-level fast path
  becomes *conservative* — it stops at the first raw byte difference
  even though equals() would say the bytes are equivalent (e.g. 'A'
  vs 'a' with CASE on). This is safe — the slow path picks up the slack
  via ReduceCommonStartEnd's inherited equals() loop. }
function TRawTextComparator.ReduceCommonStartEnd(a: TSequence; b: TSequence; var e: TEdit): TEdit;
var
  ra, rb: TRawText;
  aRaw, bRaw: PByte;
  aPtr, bPtr, aEnd, bEnd: Integer;
  partialA: Boolean;
begin
  ra := a as TRawText;
  rb := b as TRawText;

  if (e.beginA = e.endA) or (e.beginB = e.endB) then
    Exit(e);

  aRaw := ra.ContentPtr;
  bRaw := rb.ContentPtr;

  aPtr := ra.Lines.Get(e.beginA + 1);
  bPtr := rb.Lines.Get(e.beginB + 1);  // FIX: JGit typo uses `a.lines.get` here

  aEnd := ra.Lines.Get(e.endA + 1);
  bEnd := rb.Lines.Get(e.endB + 1);

  // Sanity bounds check (matches JGit's ArrayIndexOutOfBoundsException check).
  if (aPtr < 0) or (bPtr < 0) or (aEnd > Length(ra.Content)) or (bEnd > Length(rb.Content)) then
    raise ERangeError.Create('TRawTextComparator.ReduceCommonStartEnd: out-of-bounds');

  // Forward byte scan: find first byte where a and b differ.
  while (aPtr < aEnd) and (bPtr < bEnd) and (aRaw[aPtr] = bRaw[bPtr]) do
  begin
    Inc(aPtr);
    Inc(bPtr);
  end;

  // Reverse byte scan: find last byte where a and b differ (from the end).
  while (aPtr < aEnd) and (bPtr < bEnd) and (aRaw[aEnd - 1] = bRaw[bEnd - 1]) do
  begin
    Dec(aEnd);
    Dec(bEnd);
  end;

  // Map byte positions back to line indices.
  e.beginA := FindForwardLine(ra.Lines, e.beginA, aPtr);
  e.beginB := FindForwardLine(rb.Lines, e.beginB, bPtr);

  e.endA := FindReverseLine(ra.Lines, e.endA, aEnd);

  // If a's trimmed end falls mid-line, advance bEnd by the same byte offset
  // so the next FindReverseLine on b maps to the same line index.
  partialA := aEnd < ra.Lines.Get(e.endA + 1);
  if partialA then
    Inc(bEnd, ra.Lines.Get(e.endA + 1) - aEnd);

  e.endB := FindReverseLine(rb.Lines, e.endB, bEnd);

  // If a wasn't partial but b is, advance endA by one to include the
  // partial line in b's diff region.
  if (not partialA) and (bEnd < rb.Lines.Get(e.endB + 1)) then
    Inc(e.endA);

  // Fall through to super.reduceCommonStartEnd for line-level trim via
  // equals() — picks up any common lines the byte fast-path missed
  // (e.g. when CASE/NUMBERS/EOL flags are active).
  Result := inherited ReduceCommonStartEnd(a, b, e);
end;

{ ------------------------------------------------------------------
  TRawTextComparatorDefault — ported from RawTextComparator.DEFAULT
  (lines 25-53)
  ------------------------------------------------------------------ }

{ Ported from RawTextComparator.DEFAULT.equals() (lines 27-44).
  PERFORMANCE PATCH (OPT-1): thin span resolver — reads both lines' byte
  spans from the line map and delegates to EqualsSpans, whose body is the
  previous Equals body verbatim. Behavior is identical: the spans passed
  down are exactly the as_/ae_/bs_/be_ values the old code computed via
  Lines.Get(ai+1) / Lines.Get(ai+2) after the Inc(ai)/Inc(bi).

  With DIFF_IGN_CASE: applies ASCII tolower per byte (NOT Unicode folding).
  With DIFF_IGN_NUMBERS: skips digit bytes entirely (compares as if they
    weren't there).
  With DIFF_IGN_EOL: trims trailing \r\n / \n / \r before comparing. }
function TRawTextComparatorDefault.Equals(a: TSequence; ai: Integer; b: TSequence; bi: Integer): Boolean;
var
  ra, rb: TRawText;
begin
  ra := a as TRawText;
  rb := b as TRawText;
  Result := EqualsSpans(ra,
    ra.Lines.Get(ai + 1), ra.Lines.Get(ai + 2),
    rb, rb.Lines.Get(bi + 1), rb.Lines.Get(bi + 2));
end;

{ PERFORMANCE PATCH (OPT-1): former body of Equals (lines 27-44),
  operating on caller-resolved byte spans. }
function TRawTextComparatorDefault.EqualsSpans(ra: TRawText; aStart, aEnd: Integer;
  rb: TRawText; bStart, bEnd: Integer): Boolean;
var
  as_, bs, ae, be: Integer;
  aRaw, bRaw: PByte;
  ac, bc: Byte;
begin
  as_ := aStart;
  bs := bStart;
  ae := aEnd;
  be := bEnd;

  // DIFF_IGN_EOL: trim trailing EOL from each line before comparing.
  ae := TrimTrailingEOL(ra.ContentPtr, as_, ae, FFlags);
  be := TrimTrailingEOL(rb.ContentPtr, bs, be, FFlags);

  aRaw := ra.ContentPtr;
  bRaw := rb.ContentPtr;

  // Default fast path: if no CASE/NUMBERS flags, lengths must match.
  if (FFlags and (cIgnCase or cIgnNumbers)) = 0 then
  begin
    if (ae - as_) <> (be - bs) then
      Exit(False);
    while as_ < ae do
    begin
      if aRaw[as_] <> bRaw[bs] then
        Exit(False);
      Inc(as_);
      Inc(bs);
    end;
    Exit(True);
  end;

  // Slow path: with CASE/NUMBERS, lengths may differ (digits skipped).
  while (as_ < ae) and (bs < be) do
  begin
    ac := aRaw[as_];
    if IsSkippedByte(ac, FFlags) then
    begin
      Inc(as_);
      Continue;
    end;
    bc := bRaw[bs];
    if IsSkippedByte(bc, FFlags) then
    begin
      Inc(bs);
      Continue;
    end;
    if XformByte(ac, FFlags) <> XformByte(bc, FFlags) then
      Exit(False);
    Inc(as_);
    Inc(bs);
  end;

  // Skip any trailing skipped bytes (digits) so trailing digits don't
  // cause a false "unequal" verdict.
  while (as_ < ae) and IsSkippedByte(aRaw[as_], FFlags) do
    Inc(as_);
  while (bs < be) and IsSkippedByte(bRaw[bs], FFlags) do
    Inc(bs);

  Result := (as_ = ae) and (bs = be);
end;

{ Ported from RawTextComparator.DEFAULT.hashRegion() (lines 47-52).
  DJB2 hash with seed 5381, multiplier 33 (implemented as (hash << 5) + hash).
  Wraps on overflow intentionally (see $PUSH/$R-/$Q- in Djb2Hash/Djb2HashCase).

  With CASE/NUMBERS: applies the transforms per byte. }
function TRawTextComparatorDefault.HashRegion(raw: PByte; ptr, end_: Integer): Integer;
begin
  end_ := TrimTrailingEOL(raw, ptr, end_, FFlags);
  if (FFlags and (cIgnCase or cIgnNumbers)) = 0 then
    Result := Djb2Hash(raw, ptr, end_)
  else
    Result := Djb2HashCase(raw, ptr, end_, FFlags);
end;

{ ------------------------------------------------------------------
  TRawTextComparatorWSIgnoreAll — ported from RawTextComparator.WS_IGNORE_ALL
  (lines 56-104)
  ------------------------------------------------------------------ }

{ Ported from RawTextComparator.WS_IGNORE_ALL.equals() (lines 58-92).
  Ignores all whitespace bytes. Trims trailing WS, then walks both lines
  in lockstep, skipping any WS bytes encountered.

  PERFORMANCE PATCH (OPT-1): thin span resolver — reads both lines' byte
  spans from the line map and delegates to EqualsSpans, whose body is the
  previous Equals body verbatim.

  With CASE/NUMBERS: applies XformByte/IsSkippedByte in addition to
  the WS skipping. With EOL: trims trailing EOL before the WS trim. }
function TRawTextComparatorWSIgnoreAll.Equals(a: TSequence; ai: Integer; b: TSequence; bi: Integer): Boolean;
var
  ra, rb: TRawText;
begin
  ra := a as TRawText;
  rb := b as TRawText;
  Result := EqualsSpans(ra,
    ra.Lines.Get(ai + 1), ra.Lines.Get(ai + 2),
    rb, rb.Lines.Get(bi + 1), rb.Lines.Get(bi + 2));
end;

{ PERFORMANCE PATCH (OPT-1): former body of Equals (lines 58-92),
  operating on caller-resolved byte spans. }
function TRawTextComparatorWSIgnoreAll.EqualsSpans(ra: TRawText; aStart, aEnd: Integer;
  rb: TRawText; bStart, bEnd: Integer): Boolean;
var
  as_, bs, ae, be: Integer;
  aRaw, bRaw: PByte;
  ac, bc: Byte;
begin
  as_ := aStart;
  bs := bStart;
  ae := aEnd;
  be := bEnd;

  ae := TrimTrailingEOL(ra.ContentPtr, as_, ae, FFlags);
  be := TrimTrailingEOL(rb.ContentPtr, bs, be, FFlags);
  ae := TrimTrailingWhitespace(ra.ContentPtr, as_, ae);
  be := TrimTrailingWhitespace(rb.ContentPtr, bs, be);

  aRaw := ra.ContentPtr;
  bRaw := rb.ContentPtr;

  while (as_ < ae) and (bs < be) do
  begin
    ac := aRaw[as_];
    while (as_ < ae - 1) and IsWhitespaceByte(ac) do
    begin
      Inc(as_);
      ac := aRaw[as_];
    end;

    bc := bRaw[bs];
    while (bs < be - 1) and IsWhitespaceByte(bc) do
    begin
      Inc(bs);
      bc := bRaw[bs];
    end;

    // Skip digit bytes (DIFF_IGN_NUMBERS).
    if IsSkippedByte(ac, FFlags) then
    begin
      Inc(as_);
      Continue;
    end;
    if IsSkippedByte(bc, FFlags) then
    begin
      Inc(bs);
      Continue;
    end;

    if XformByte(ac, FFlags) <> XformByte(bc, FFlags) then
      Exit(False);

    Inc(as_);
    Inc(bs);
  end;

  { Trailing cleanup — same idea as TRawTextComparatorDefault.Equals:
    the main loop above exits as soon as ONE side is exhausted, so the
    other side can still hold skippable bytes (digits under
    DIFF_IGN_NUMBERS, and whitespace that sits between/after digit
    runs — the in-loop WS skip is bounded by ae-1/be-1 and the
    trailing-WS trim ran before digit positions were known).
    Without this cleanup, "v33" vs "v" compared UNEQUAL under
    WHITESPACE|NUMBERS while hashRegion (which skips both WS and
    digits everywhere) hashed them identically — an Equals/hash
    inconsistency that made HashedSequenceComparator reject the pair
    and the diff report a change (DIFF_IGN_NUMBERS bug). }
  while (as_ < ae) and (IsSkippedByte(aRaw[as_], FFlags)
                        or IsWhitespaceByte(aRaw[as_])) do
    Inc(as_);
  while (bs < be) and (IsSkippedByte(bRaw[bs], FFlags)
                        or IsWhitespaceByte(bRaw[bs])) do
    Inc(bs);

  Result := (as_ = ae) and (bs = be);
end;

{ Ported from RawTextComparator.WS_IGNORE_ALL.hashRegion() (lines 95-103).
  DJB2 hash that skips whitespace bytes. With CASE/NUMBERS: applies
  transforms on the non-WS bytes. }
function TRawTextComparatorWSIgnoreAll.HashRegion(raw: PByte; ptr, end_: Integer): Integer;
{$PUSH}{$R-}{$Q-}
var
  h: Integer;
  c: Byte;
begin
  end_ := TrimTrailingEOL(raw, ptr, end_, FFlags);
  end_ := TrimTrailingWhitespace(raw, ptr, end_);
  h := 5381;
  while ptr < end_ do
  begin
    c := raw[ptr];
    if not IsWhitespaceByte(c) then
    begin
      if not IsSkippedByte(c, FFlags) then
        h := ((h shl 5) + h) + (XformByte(c, FFlags) and $FF);
    end;
    Inc(ptr);
  end;
  Result := h;
end;
{$POP}

{ NOTE: TRawTextComparatorWSIgnoreLeading / WSIgnoreTrailing / WSIgnoreChange
  (JGit's RawTextComparator.WS_IGNORE_LEADING / WS_IGNORE_TRAILING /
  WS_IGNORE_CHANGE singletons) are NOT ported — their diff_proc flags
  (DIFF_IGN_WHITESPACE_BEGINNING / DIFF_IGN_WHITESPACE_EOL /
  DIFF_IGN_WHITESPACE_CHANGE) were removed from the API, so no code path
  could ever instantiate them. }

{ ------------------------------------------------------------------
  THashedSequence methods — ported from diff/HashedSequence.java
  ------------------------------------------------------------------ }

constructor THashedSequence.Create(base: TSequence; hashes: array of Integer);
var
  i: Integer;
begin
  inherited Create;
  FBase := base;
  SetLength(FHashes, Length(hashes));
  for i := 0 to High(hashes) do
    FHashes[i] := hashes[i];
end;

function THashedSequence.Size: Integer;
begin
  Result := FBase.Size;
end;

function THashedSequence.GetHash(i: Integer): Integer;
begin
  Result := FHashes[i];
end;

{ ------------------------------------------------------------------
  THashedSequenceComparator — ported from HashedSequenceComparator.java
  ------------------------------------------------------------------ }

constructor THashedSequenceComparator.Create(cmp: TSequenceComparator;
  AIdsExact: Boolean);
begin
  inherited Create;
  FCmp := cmp;
  FIdsExact := AIdsExact;
end;

{ Ported from HashedSequenceComparator.equals() (lines 37-41).
  Returns true only if cached hashes match AND underlying comparator
  agrees (avoids hash collisions).

  PERFORMANCE PATCH (OPT-3): when FIdsExact, the cached values are
  interned line IDs — equal ID is PROOF of content equality (the intern
  table resolved every hash collision with a full EqualsSpans compare),
  so the second clause is dropped and this becomes a single integer
  compare. This is the hot comparison for the Myers fallback's snake
  walks and for the histogram index's non-flat fallback path. }
function THashedSequenceComparator.Equals(a: TSequence; ai: Integer; b: TSequence; bi: Integer): Boolean;
var
  ha, hb: THashedSequence;
begin
  ha := a as THashedSequence;
  hb := b as THashedSequence;
  if FIdsExact then
    Exit(ha.GetHash(ai) = hb.GetHash(bi));
  Result := (ha.GetHash(ai) = hb.GetHash(bi))
        and FCmp.Equals(ha.Base, ai, hb.Base, bi);
end;

{ Ported from HashedSequenceComparator.hash() (lines 44-46).
  Returns the cached hash. }
function THashedSequenceComparator.Hash(seq: TSequence; ptr: Integer): Integer;
var
  h: THashedSequence;
begin
  h := seq as THashedSequence;
  Result := h.GetHash(ptr);
end;

{ Delegate to wrapped comparator's reduceCommonStartEnd. JGit uses
  SequenceComparator<? super S> for the wrapped cmp, which means the
  HashedSequenceComparator doesn't override reduceCommonStartEnd
  (it falls through to the default). We mirror that here. }
function THashedSequenceComparator.ReduceCommonStartEnd(a: TSequence; b: TSequence; var e: TEdit): TEdit;
begin
  // JGit uses SequenceComparator<? super S>, so the wrapped comparator
  // (e.g. RawTextComparator) handles reduceCommonStartEnd. But the
  // sequences we get are THashedSequence — they need to be unwrapped
  // before passing to the wrapped comparator.
  // HOWEVER: in JGit's flow, reduceCommonStartEnd is called on the
  // OUTER comparator (the one passed to DiffAlgorithm.diff()), not on
  // the HashedSequenceComparator. The HashedSequenceComparator is only
  // used inside diffNonCommon after prefix/suffix trim has already
  // happened. So this method is never reached in practice — but if it
  // is, fall through to default behavior (which uses Equals()).
  Result := inherited ReduceCommonStartEnd(a, b, e);
end;

{ ------------------------------------------------------------------
  THashedSequencePair — ported from HashedSequencePair.java
  ------------------------------------------------------------------ }

constructor THashedSequencePair.Create(cmp: TSequenceComparator; a, b: TSequence);
{ PERFORMANCE PATCH (OPT-3): the constructor eagerly interns both
  sequences' lines into integer IDs when the wrapper chain is the
  expected one (see InternAll); GetA/GetB then return the interned
  cached sequences. On any other chain shape InternAll leaves the
  caches nil and GetA/GetB lazily fall back to Wrap(). }
begin
  inherited Create;
  FCmp := cmp;
  FBaseA := a;
  FBaseB := b;
  FCachedA := nil;
  FCachedB := nil;
  FIdsExact := False;
  InternAll;
end;

destructor THashedSequencePair.Destroy;
begin
  FCachedA.Free;
  FCachedB.Free;
  inherited Destroy;
end;

function THashedSequencePair.GetComparator: THashedSequenceComparator;
begin
  { OPT-3: propagate ID-exactness so Equals() can skip the byte-wise
    fallback compare (the IDs in the FHashes arrays are verified
    equal-by-content by the intern table). }
  Result := THashedSequenceComparator.Create(FCmp, FIdsExact);
end;

function THashedSequencePair.GetA: THashedSequence;
begin
  if FCachedA = nil then
    FCachedA := Wrap(FBaseA);
  Result := FCachedA;
end;

function THashedSequencePair.GetB: THashedSequence;
begin
  if FCachedB = nil then
    FCachedB := Wrap(FBaseB);
  Result := FCachedB;
end;

{ Ported from HashedSequencePair.wrap() (lines 81-87).
  Pre-computes hashes for every element of `base`.
  OPT-3: only used on the non-interned fallback path — when InternAll
  succeeds, the cached sequences already exist and hold IDs. }
function THashedSequencePair.Wrap(base: TSequence): THashedSequence;
var
  end_: Integer;
  hashes: array of Integer;
  ptr: Integer;
begin
  end_ := base.Size;
  SetLength(hashes, end_);
  for ptr := 0 to end_ - 1 do
    hashes[ptr] := FCmp.Hash(base, ptr);
  Result := THashedSequence.Create(base, hashes);
end;

{ PERFORMANCE PATCH (OPT-3): intern every line of both base sequences
  into integer IDs, and create the cached THashedSequences eagerly.

  Soundness: a line's table key is HashRegion() under the base
  comparator (the exact same projection the algorithm's hash gate
  used), and every hash collision inside a bucket is resolved by a
  full EqualsSpans() comparison — the exact same comparison the
  algorithm's Equals fallback performed. Therefore two lines get the
  same ID if and only if the comparator considers them equal, for ALL
  comparator/flag combinations. With IDs stored in the FHashes arrays,
  the hash-gate comparison ("hashes equal") becomes exact equality,
  and the byte-wise fallback compare is provably redundant in the hot
  paths — it runs once per distinct line right here instead of once
  per algorithm comparison step.

  Failure to resolve the expected wrapper chain leaves FIdsExact
  False and FCachedA/FCachedB nil, so GetA/GetB lazily fall back to
  Wrap() (plain hash codes, not IDs) and every consumer uses the
  pre-OPT-3 code paths. }
procedure THashedSequencePair.InternAll;
var
  baseCmp: TRawTextComparator;
  ra, rb: TRawText;
  offA, offB, nA, nB, total: Integer;
  idsA, idsB: array of Integer;
  tblBits: Integer;
  table: array of Integer;
  recHash: array of Integer;
  recRaw: array of TRawText;
  recStart: array of Integer;
  recEnd: array of Integer;
  recNext: array of Integer;
  recCount: Integer;
  i: Integer;

  { Looks up (or inserts) the line `line` of `raw`; returns its ID.
    Records are 1-based; ID == record index. }
  function InternLine(raw: TRawText; line: Integer): Integer;
  var
    s, e, h, bkt, r: Integer;
    found: Boolean;
  begin
    s := raw.GetStart(line);
    e := raw.GetEnd(line);
    h := baseCmp.HashRegion(raw.ContentPtr, s, e);
    {$PUSH}{$R-}{$Q-}
    bkt := Integer(UInt32(UInt32(h) * UInt32(HDI_KNUTH_MULTIPLIER))
      shr (32 - tblBits));
    {$POP}
    r := table[bkt];
    found := False;
    while r <> 0 do
    begin
      if (recHash[r] = h)
        and baseCmp.EqualsSpans(recRaw[r], recStart[r], recEnd[r],
                                raw, s, e) then
      begin
        found := True;
        Break;
      end;
      r := recNext[r];
    end;
    if found then
      Exit(r);
    // New distinct line: append a record and chain it into the bucket.
    Inc(recCount);
    r := recCount;
    recHash[r] := h;
    recRaw[r] := raw;
    recStart[r] := s;
    recEnd[r] := e;
    recNext[r] := table[bkt];
    table[bkt] := r;
    Result := r;
  end;

begin
  FIdsExact := False;
  // Managed locals: explicit nil so the compiler's flow analysis is happy
  // (matches this unit's "silence managed type" convention).
  idsA := nil;
  idsB := nil;
  table := nil;
  recHash := nil;
  recRaw := nil;
  recStart := nil;
  recEnd := nil;
  recNext := nil;
  if not (FCmp is TSubsequenceComparator) then
    Exit;
  if not (TSubsequenceComparator(FCmp).Cmp is TRawTextComparator) then
    Exit;
  if not (FBaseA is TSubsequence) or not (FBaseB is TSubsequence) then
    Exit;
  if not (TSubsequence(FBaseA).Base is TRawText) then
    Exit;
  if not (TSubsequence(FBaseB).Base is TRawText) then
    Exit;

  baseCmp := TRawTextComparator(TSubsequenceComparator(FCmp).Cmp);
  ra := TRawText(TSubsequence(FBaseA).Base);
  rb := TRawText(TSubsequence(FBaseB).Base);
  offA := TSubsequence(FBaseA).BeginOffset;
  offB := TSubsequence(FBaseB).BeginOffset;
  nA := FBaseA.Size;
  nB := FBaseB.Size;
  total := nA + nB;

  if total = 0 then
  begin
    FCachedA := THashedSequence.Create(FBaseA, idsA);
    FCachedB := THashedSequence.Create(FBaseB, idsB);
    FIdsExact := True;
    Exit;
  end;

  { Bucket count: next power of two >= 2*total (load factor <= 0.5),
    capped at 2^22 to bound memory on gigantic inputs (the load factor
    just rises; chains stay short for real text). }
  tblBits := 1;
  while (tblBits < 22) and ((Int64(1) shl tblBits) < Int64(total) * 2) do
    Inc(tblBits);

  SetLength(table, 1 shl tblBits);
  SetLength(recHash, total + 1);
  SetLength(recRaw, total + 1);
  SetLength(recStart, total + 1);
  SetLength(recEnd, total + 1);
  SetLength(recNext, total + 1);
  recCount := 0;

  { Intern A first, then B, through the SAME table so a line common to
    both files gets one ID shared across sequences. }
  SetLength(idsA, nA);
  for i := 0 to nA - 1 do
  begin
    { Cooperative-cancellation poll: O(N) interning pass }
    if (i and $FFF) = 0 then
      DiffCheckCancelled;
    idsA[i] := InternLine(ra, offA + i);
  end;
  SetLength(idsB, nB);
  for i := 0 to nB - 1 do
  begin
    if (i and $FFF) = 0 then
      DiffCheckCancelled;
    idsB[i] := InternLine(rb, offB + i);
  end;

  FCachedA := THashedSequence.Create(FBaseA, idsA);
  FCachedB := THashedSequence.Create(FBaseB, idsB);
  FIdsExact := True;
end;

{ ------------------------------------------------------------------
  TSubsequence — ported from diff/Subsequence.java
  ------------------------------------------------------------------ }

constructor TSubsequence.Create(base: TSequence; begn, end_: Integer);
begin
  inherited Create;
  FBase := base;
  FBegin := begn;
  FSize := end_ - begn;
end;

function TSubsequence.Size: Integer;
begin
  Result := FSize;
end;

class function TSubsequence.A(base: TSequence; const region: TEdit): TSubsequence;
begin
  Result := TSubsequence.Create(base, region.beginA, region.endA);
end;

class function TSubsequence.B(base: TSequence; const region: TEdit): TSubsequence;
begin
  Result := TSubsequence.Create(base, region.beginB, region.endB);
end;

class procedure TSubsequence.ToBaseEdit(var e: TEdit; sa, sb: TSubsequence);
begin
  Inc(e.beginA, sa.FBegin);
  Inc(e.endA, sa.FBegin);
  Inc(e.beginB, sb.FBegin);
  Inc(e.endB, sb.FBegin);
end;

class function TSubsequence.ToBaseEditList(edits: TEditList; sa, sb: TSubsequence): TEditList;
var
  i: Integer;
  e: TEdit;
begin
  if edits <> nil then
    for i := 0 to edits.Size - 1 do
    begin
      e := edits.Get(i);
      ToBaseEdit(e, sa, sb);
      edits.SetItem(i, e);
    end;
  Result := edits;
end;

{ ------------------------------------------------------------------
  TSubsequenceComparator — ported from SubsequenceComparator.java
  ------------------------------------------------------------------ }

constructor TSubsequenceComparator.Create(cmp: TSequenceComparator);
begin
  inherited Create;
  FCmp := cmp;
end;

function TSubsequenceComparator.Equals(a: TSequence; ai: Integer; b: TSequence; bi: Integer): Boolean;
var
  sa, sb: TSubsequence;
begin
  sa := a as TSubsequence;
  sb := b as TSubsequence;
  Result := FCmp.Equals(sa.Base, ai + sa.BeginOffset, sb.Base, bi + sb.BeginOffset);
end;

function TSubsequenceComparator.Hash(seq: TSequence; ptr: Integer): Integer;
var
  s: TSubsequence;
begin
  s := seq as TSubsequence;
  Result := FCmp.Hash(s.Base, ptr + s.BeginOffset);
end;

function TSubsequenceComparator.ReduceCommonStartEnd(a: TSequence; b: TSequence; var e: TEdit): TEdit;
begin
  // Delegate to wrapped comparator (default behavior — matches JGit which
  // doesn't override reduceCommonStartEnd in SubsequenceComparator).
  Result := inherited ReduceCommonStartEnd(a, b, e);
end;

{ ------------------------------------------------------------------
  TDiffAlgorithm — ported from diff/DiffAlgorithm.java
  ------------------------------------------------------------------ }

{ Ported from DiffAlgorithm.diff() (lines 79-105).
  Reduces common start/end, then dispatches by EditType. }
function TDiffAlgorithm.Diff(cmp: TSequenceComparator; a, b: TSequence): TEditList;
var
  region: TEdit;
  regionType: TEditType;
  cs: TSubsequenceComparator;
  as_, bs: TSubsequence;
  e: TEditList;
begin
  // coverEdit(a, b) — full coverage of both sequences.
  region.beginA := 0;
  region.endA := a.Size;
  region.beginB := 0;
  region.endB := b.Size;

  region := cmp.ReduceCommonStartEnd(a, b, region);
  regionType := region.GetType;

  case regionType of
    etInsert, etDelete:
      Exit(TEditList.Singleton(region));

    etReplace:
    begin
      if (region.GetLengthA = 1) and (region.GetLengthB = 1) then
        Exit(TEditList.Singleton(region));

      cs := TSubsequenceComparator.Create(cmp);
      try
        as_ := TSubsequence.A(a, region);
        bs := TSubsequence.B(b, region);
        try
          e := DiffNonCommon(cs, as_, bs);
          TSubsequence.ToBaseEditList(e, as_, bs);
          Result := Normalize(cmp, e, a, b);
          // Result takes ownership of e — Normalize returns the same list.
          Exit;
        finally
          as_.Free;
          bs.Free;
        end;
      finally
        cs.Free;
      end;
    end;

    etEmpty:
      Exit(TEditList.Create(0));
  end;

  raise EAssertionFailed.Create('TDiffAlgorithm.Diff: unexpected edit type');
end;

{ Ported from DiffAlgorithm.normalize() (lines 186-210).
  Shifts INSERT/DELETE edits to their latest possible position.

  Strategy: walk the edit list from end to beginning. For each INSERT or
  DELETE, check if the line right after the edit (in the relevant sequence)
  equals the inserted/deleted line. If so, shift the edit down by 1. Repeat
  until no more shifts possible.

  Without this, the output won't match `git diff` (G18). }
class function TDiffAlgorithm.Normalize(cmp: TSequenceComparator; e: TEditList; a, b: TSequence): TEditList;
var
  i: Integer;
  cur: TEdit;
  prev: TEdit;
  curType: TEditType;
  maxA, maxB: Integer;
  hasPrev: Boolean;
begin
  hasPrev := False;
  prev := Default(TEdit);  // silence "not initialized" warning
  for i := e.Size - 1 downto 0 do
  begin
    { Cooperative-cancellation poll: O(D) post-pass; the shift loops
      below can walk far on moved blocks. }
    DiffCheckCancelled;
    cur := e.Get(i);
    curType := cur.GetType;

    if hasPrev then
    begin
      maxA := prev.beginA;
      maxB := prev.beginB;
    end
    else
    begin
      maxA := a.Size;
      maxB := b.Size;
    end;

    if curType = etInsert then
    begin
      while (cur.endA < maxA) and (cur.endB < maxB)
            and cmp.Equals(b, cur.beginB, b, cur.endB) do
        cur.Shift(1);
    end
    else if curType = etDelete then
    begin
      while (cur.endA < maxA) and (cur.endB < maxB)
            and cmp.Equals(a, cur.beginA, a, cur.endA) do
        cur.Shift(1);
    end;

    e.SetItem(i, cur);
    prev := cur;
    hasPrev := True;
  end;
  Result := e;
end;

{ ------------------------------------------------------------------
  TLowLevelDiffAlgorithm — ported from LowLevelDiffAlgorithm.java
  ------------------------------------------------------------------ }

{ Ported from LowLevelDiffAlgorithm.diffNonCommon() (lines 18-30).
  Wraps cmp/a/b in HashedSequencePair, then dispatches to the
  subclass-specific diffNonCommon variant. }
function TLowLevelDiffAlgorithm.DiffNonCommon(cmp: TSequenceComparator; a, b: TSequence): TEditList;
var
  p: THashedSequencePair;
  hc: THashedSequenceComparator;
  ha, hb: THashedSequence;
  res: TEditList;
  region: TEdit;
begin
  p := THashedSequencePair.Create(cmp, a, b);
  try
    hc := p.GetComparator;
    ha := p.GetA;
    hb := p.GetB;

    res := TEditList.Create;
    region.beginA := 0;
    region.endA := a.Size;
    region.beginB := 0;
    region.endB := b.Size;
    DiffNonCommonLow(res, hc, ha, hb, region);

    hc.Free;
    // Note: ha, hb are owned by p; don't free them here.
  finally
    p.Free;
  end;
  Result := res;
end;

{ ------------------------------------------------------------------
  TMyersDiff — ported from diff/MyersDiff.java
  ------------------------------------------------------------------ }

type
  { Forward declarations for nested types }
  TMyersMiddleEdit = class;
  TMyersEditPaths = class;

  { Ported from MyersDiff.EditPaths (inner class, lines 281-431).
    Holds the x-positions and snake end-points for each (d, k) pair
    during the forward/backward sweep.

    The "snake" is a packed Int64 holding (x, y) where y = k + x.
    High 32 bits = x, low 32 bits = y. Matches JGit's newSnake/snake2x/snake2y. }
  TMyersEditPaths = class
  private
    Fx: TIntList;
    Fsnake: TLongList;
    FbeginK, FendK, FmiddleK: Integer;
    FprevBeginK, FprevEndK: Integer;
    FminK, FmaxK: Integer;
    Fowner: TMyersMiddleEdit;

    { Force k into the [minK, maxK] range, preserving parity
      (k must have the same parity as middleK ± d). }
    function ForceKIntoRange(k: Integer): Integer;
    function GetIndex(d, k: Integer): Integer;
    function GetX(d, k: Integer): Integer;
    function GetSnake(d, k: Integer): Int64;

    { Snake end-point packing — matches JGit's newSnake/snake2x/snake2y. }
    class function NewSnake(k, x: Integer): Int64; static;
    class function Snake2X(s: Int64): Integer; static; inline;
    class function Snake2Y(s: Int64): Integer; static; inline;

    { Hook methods — abstract in JGit, virtual here. }
    function Snake(k, x: Integer): Integer; virtual; abstract;
    function GetLeft(x: Integer): Integer; virtual; abstract;
    function GetRight(x: Integer): Integer; virtual; abstract;
    function IsBetter(left, right: Integer): Boolean; virtual; abstract;
    procedure AdjustMinMaxK(k, x: Integer); virtual; abstract;
    function Meets(d, k, x: Integer; const asnake: Int64): Boolean; virtual; abstract;

    function MakeEdit(const snake1, snake2: Int64): Boolean;

    { Ported from MyersDiff.EditPaths.calculate() (lines 372-430).
      For each d, computes the d-paths for diagonals k = middleK-d, middleK-d+2,
      ..., middleK+d (k alternates parity with d). Returns True if forward
      and backward paths meet (we've found the middle). }
    function Calculate(d: Integer): Boolean;
  public
    constructor Create(owner: TMyersMiddleEdit);
    destructor Destroy; override;

    procedure Initialize(k, x, minK, maxK: Integer);

    property BeginK: Integer read FbeginK;
    property EndK: Integer read FendK;
    property MiddleK: Integer read FmiddleK;
  end;

  { Ported from MyersDiff.ForwardEditPaths (lines 433-479). }
  TMyersForwardEditPaths = class(TMyersEditPaths)
  protected
    function Snake(k, x: Integer): Integer; override;
    function GetLeft(x: Integer): Integer; override;
    function GetRight(x: Integer): Integer; override;
    function IsBetter(left, right: Integer): Boolean; override;
    procedure AdjustMinMaxK(k, x: Integer); override;
    function Meets(d, k, x: Integer; const asnake: Int64): Boolean; override;
  end;

  { Ported from MyersDiff.BackwardEditPaths (lines 481-527). }
  TMyersBackwardEditPaths = class(TMyersEditPaths)
  protected
    function Snake(k, x: Integer): Integer; override;
    function GetLeft(x: Integer): Integer; override;
    function GetRight(x: Integer): Integer; override;
    function IsBetter(left, right: Integer): Boolean; override;
    procedure AdjustMinMaxK(k, x: Integer); override;
    function Meets(d, k, x: Integer; const asnake: Int64): Boolean; override;
  end;

  { Ported from MyersDiff.MiddleEdit (inner class, lines 190-528). }
  TMyersMiddleEdit = class
  private
    Fcmp: THashedSequenceComparator;
    Fa, Fb: THashedSequence;
    Fedits: TEditList;
    FbeginA, FendA, FbeginB, FendB: Integer;
    Fedit: TEdit;
    Fforward: TMyersEditPaths;
    Fbackward: TMyersEditPaths;

    procedure Initialize(beginA, endA, beginB, endB: Integer);

    { Ported from MiddleEdit.calculate() (lines 216-237).
      Finds the "middle" Edit of the shortest edit path between the
      given subsequences. Once forward and backward paths meet, we
      construct the Edit from their snake end-points. }
    function Calculate(beginA, endA, beginB, endB: Integer): TEdit;

    { Ported from MiddleEdit.calculateEdits (top-level, lines 133-179).
      Recursive divide-and-conquer entry: find middle, recurse on
      left part, emit middle edit (if non-empty), recurse on right part. }
    procedure CalculateEdits(beginA, endA, beginB, endB: Integer);
  public
    constructor Create(edits: TEditList; cmp: THashedSequenceComparator;
      a, b: THashedSequence);
    destructor Destroy; override;
  end;

constructor TMyersEditPaths.Create(owner: TMyersMiddleEdit);
begin
  inherited Create;
  Fowner := owner;
  Fx := TIntList.Create;
  Fsnake := TLongList.Create;
end;

destructor TMyersEditPaths.Destroy;
begin
  Fx.Free;
  Fsnake.Free;
  inherited Destroy;
end;

procedure TMyersEditPaths.Initialize(k, x, minK, maxK: Integer);
begin
  FminK := minK;
  FmaxK := maxK;
  FbeginK := k;
  FendK := k;
  FmiddleK := k;
  Fx.Clear;
  Fx.Add(x);
  Fsnake.Clear;
  Fsnake.Add(NewSnake(k, x));
end;

function TMyersEditPaths.ForceKIntoRange(k: Integer): Integer;
{ Ported from MyersDiff.EditPaths.forceKIntoRange() (lines 310-317).
  If k is out of [minK, maxK], clamp it back in, preserving parity. }
begin
  if k < FminK then
    Exit(FminK + ((k xor FminK) and 1))
  else if k > FmaxK then
    Exit(FmaxK - ((k xor FmaxK) and 1));
  Result := k;
end;

function TMyersEditPaths.GetIndex(d, k: Integer): Integer;
{ Ported from MyersDiff.EditPaths.getIndex() (lines 289-294).
  Converts (d, k) into the index into the x and snake arrays.
  Formula: i = (d + k - middleK) / 2. }
begin
  Result := (d + k - FmiddleK) div 2;
end;

function TMyersEditPaths.GetX(d, k: Integer): Integer;
{ Ported from MyersDiff.EditPaths.getX() (lines 296-301). }
begin
  Result := Fx.Get(GetIndex(d, k));
end;

function TMyersEditPaths.GetSnake(d, k: Integer): Int64;
{ Ported from MyersDiff.EditPaths.getSnake() (lines 303-308). }
begin
  Result := Fsnake.Get(GetIndex(d, k));
end;

class function TMyersEditPaths.NewSnake(k, x: Integer): Int64;
{ Ported from MyersDiff.EditPaths.newSnake() (lines 336-340).
  Packs (x, y=k+x) into a single Int64: (x << 32) | y. }
begin
  Result := (Int64(UInt32(x)) shl 32) or (UInt32(Int64(k) + x));
end;

class function TMyersEditPaths.Snake2X(s: Int64): Integer;
{ Ported from MyersDiff.EditPaths.snake2x() (lines 342-344).
  Returns the upper 32 bits as a signed int. }
begin
  Result := Integer(UInt32(UInt64(s) shr 32));
end;

class function TMyersEditPaths.Snake2Y(s: Int64): Integer;
{ Ported from MyersDiff.EditPaths.snake2y() (lines 346-348).
  Returns the lower 32 bits as a signed int. }
begin
  Result := Integer(UInt32(UInt64(s) and $FFFFFFFF));
end;

function TMyersEditPaths.MakeEdit(const snake1, snake2: Int64): Boolean;
{ Ported from MyersDiff.EditPaths.makeEdit() (lines 350-370).
  Constructs an Edit from two snake end-points. If the snakes are
  incompatible (non-overlapping), snap x1/y1 to x2/y2 — this forces
  a decision in the next recursion step. }
var
  x1, x2, y1, y2: Integer;
begin
  x1 := Snake2X(snake1);
  x2 := Snake2X(snake2);
  y1 := Snake2Y(snake1);
  y2 := Snake2Y(snake2);
  if (x1 > x2) or (y1 > y2) then
  begin
    x1 := x2;
    y1 := y2;
  end;
  Fowner.Fedit.beginA := x1;
  Fowner.Fedit.endA := x2;
  Fowner.Fedit.beginB := y1;
  Fowner.Fedit.endB := y2;
  Result := True;
end;

function TMyersEditPaths.Calculate(d: Integer): Boolean;
{ Ported from MyersDiff.EditPaths.calculate() (lines 372-430).
  For each d, walk diagonals k from endK down to beginK (step -2),
  compute the new x position from the (d-1)-path's neighbors (k-1 and k+1),
  extend with a snake, and check if forward/backward paths meet. }
var
  k: Integer;
  left, right: Integer;
  leftSnake, rightSnake: Int64;
  i: Integer;
  end_: Integer;
  newX: Integer;
  newSnakeVal: Int64;
begin
  FprevBeginK := FbeginK;
  FprevEndK := FendK;
  FbeginK := ForceKIntoRange(FmiddleK - d);
  FendK := ForceKIntoRange(FmiddleK + d);

  k := FendK;
  while k >= FbeginK do
  begin
    left := -1;
    right := -1;
    leftSnake := -1;
    rightSnake := -1;

    if k > FprevBeginK then
    begin
      i := GetIndex(d - 1, k - 1);
      left := Fx.Get(i);
      end_ := Snake(k - 1, left);
      if left <> end_ then
        leftSnake := NewSnake(k - 1, end_)
      else
        leftSnake := Fsnake.Get(i);
      if Meets(d, k - 1, end_, leftSnake) then
        Exit(True);
      left := GetLeft(end_);
    end;

    if k < FprevEndK then
    begin
      i := GetIndex(d - 1, k + 1);
      right := Fx.Get(i);
      end_ := Snake(k + 1, right);
      if right <> end_ then
        rightSnake := NewSnake(k + 1, end_)
      else
        rightSnake := Fsnake.Get(i);
      if Meets(d, k + 1, end_, rightSnake) then
        Exit(True);
      right := GetRight(end_);
    end;

    if (k >= FprevEndK) or ((k > FprevBeginK) and IsBetter(left, right)) then
    begin
      newX := left;
      newSnakeVal := leftSnake;
    end
    else
    begin
      newX := right;
      newSnakeVal := rightSnake;
    end;

    if Meets(d, k, newX, newSnakeVal) then
      Exit(True);

    AdjustMinMaxK(k, newX);

    i := GetIndex(d, k);
    Fx.SetItem(i, newX);
    Fsnake.SetItem(i, newSnakeVal);

    Dec(k, 2);
  end;
  Result := False;
end;

{ TMyersForwardEditPaths — ported from MyersDiff.ForwardEditPaths (lines 433-479) }

function TMyersForwardEditPaths.Snake(k, x: Integer): Integer;
{ Ported from ForwardEditPaths.snake() (lines 435-440).
  Walks diagonally forward as long as a[x] == b[k+x]. Returns the new x. }
begin
  while (x < Fowner.FendA) and ((k + x) < Fowner.FendB) do
    if not Fowner.Fcmp.Equals(Fowner.Fa, x, Fowner.Fb, k + x) then
      Break
    else
      Inc(x);
  Result := x;
end;

function TMyersForwardEditPaths.GetLeft(x: Integer): Integer;
begin
  Result := x;
end;

function TMyersForwardEditPaths.GetRight(x: Integer): Integer;
begin
  Result := x + 1;
end;

function TMyersForwardEditPaths.IsBetter(left, right: Integer): Boolean;
begin
  Result := left > right;
end;

procedure TMyersForwardEditPaths.AdjustMinMaxK(k, x: Integer);
{ Ported from ForwardEditPaths.adjustMinMaxK() (lines 458-465). }
begin
  if (x >= Fowner.FendA) or ((k + x) >= Fowner.FendB) then
  begin
    if k > Fowner.Fbackward.MiddleK then
      FmaxK := k
    else
      FminK := k;
  end;
end;

function TMyersForwardEditPaths.Meets(d, k, x: Integer; const asnake: Int64): Boolean;
{ Ported from ForwardEditPaths.meets() (lines 468-478).
  Checks if the forward d-path meets the backward (d-1)-path at diagonal k. }
begin
  if (k < Fowner.Fbackward.BeginK) or (k > Fowner.Fbackward.EndK) then
    Exit(False);
  if (((d - 1 + k - Fowner.Fbackward.MiddleK) mod 2) <> 0) then
    Exit(False);
  if x < Fowner.Fbackward.GetX(d - 1, k) then
    Exit(False);
  MakeEdit(asnake, Fowner.Fbackward.GetSnake(d - 1, k));
  Result := True;
end;

{ TMyersBackwardEditPaths — ported from MyersDiff.BackwardEditPaths (lines 481-527) }

function TMyersBackwardEditPaths.Snake(k, x: Integer): Integer;
{ Ported from BackwardEditPaths.snake() (lines 483-488).
  Walks diagonally backward as long as a[x-1] == b[k+x-1]. Returns the new x. }
begin
  while (x > Fowner.FbeginA) and ((k + x) > Fowner.FbeginB) do
    if not Fowner.Fcmp.Equals(Fowner.Fa, x - 1, Fowner.Fb, k + x - 1) then
      Break
    else
      Dec(x);
  Result := x;
end;

function TMyersBackwardEditPaths.GetLeft(x: Integer): Integer;
begin
  Result := x - 1;
end;

function TMyersBackwardEditPaths.GetRight(x: Integer): Integer;
begin
  Result := x;
end;

function TMyersBackwardEditPaths.IsBetter(left, right: Integer): Boolean;
begin
  Result := left < right;
end;

procedure TMyersBackwardEditPaths.AdjustMinMaxK(k, x: Integer);
{ Ported from BackwardEditPaths.adjustMinMaxK() (lines 506-513). }
begin
  if (x <= Fowner.FbeginA) or ((k + x) <= Fowner.FbeginB) then
  begin
    if k > Fowner.Fforward.MiddleK then
      FmaxK := k
    else
      FminK := k;
  end;
end;

function TMyersBackwardEditPaths.Meets(d, k, x: Integer; const asnake: Int64): Boolean;
{ Ported from BackwardEditPaths.meets() (lines 516-526).
  Checks if the backward d-path meets the forward d-path at diagonal k. }
begin
  if (k < Fowner.Fforward.BeginK) or (k > Fowner.Fforward.EndK) then
    Exit(False);
  if (((d + k - Fowner.Fforward.MiddleK) mod 2) <> 0) then
    Exit(False);
  if x > Fowner.Fforward.GetX(d, k) then
    Exit(False);
  MakeEdit(Fowner.Fforward.GetSnake(d, k), asnake);
  Result := True;
end;

{ TMyersMiddleEdit — ported from MyersDiff.MiddleEdit (lines 190-528) }

constructor TMyersMiddleEdit.Create(edits: TEditList; cmp: THashedSequenceComparator;
  a, b: THashedSequence);
begin
  inherited Create;
  Fedits := edits;
  Fcmp := cmp;
  Fa := a;
  Fb := b;
  Fforward := TMyersForwardEditPaths.Create(Self);
  Fbackward := TMyersBackwardEditPaths.Create(Self);
end;

destructor TMyersMiddleEdit.Destroy;
begin
  Fforward.Free;
  Fbackward.Free;
  inherited Destroy;
end;

procedure TMyersMiddleEdit.Initialize(beginA, endA, beginB, endB: Integer);
{ Ported from MiddleEdit.initialize() (lines 191-203).
  Strips common parts on either end via snake() — this is the
  initial prefix/suffix trim that runs BEFORE the middle-search. }
var
  k, x: Integer;
begin
  FbeginA := beginA;
  FendA := endA;
  FbeginB := beginB;
  FendB := endB;

  // Strip common prefix.
  k := beginB - beginA;
  x := Fforward.Snake(k, beginA);
  FbeginA := x;
  FbeginB := k + x;

  // Strip common suffix.
  k := endB - endA;
  x := Fbackward.Snake(k, endA);
  FendA := x;
  FendB := k + x;
end;

function TMyersMiddleEdit.Calculate(beginA, endA, beginB, endB: Integer): TEdit;
{ Ported from MiddleEdit.calculate() (lines 216-237).
  If either side is empty, return immediately. Otherwise, set up forward
  and backward EditPaths and iterate d=1,2,... until they meet.

  PERFORMANCE PATCH (OPT-4) — GATED by the OPT4_ENABLE_MYERS_D_CAP
  boolean constant in the interface const block (top of the unit):
  the d-iteration is bounded. Natural termination (forward and
  backward paths must meet once their combined depth covers the edit
  distance, which is at most (N+M)) gives dLimit = (N+M+2) div 2 —
  JGit's implicit bound. With the switch True, that is additionally
  capped at MYERS_MAX_D: a region whose edit distance exceeds
  ~2 x MYERS_MAX_D would need O((N+M) x D) steps to solve exactly, so
  when the cap is hit the whole region is emitted as a single REPLACE
  edit (valid tiling, coarser granularity) instead of grinding on.
  Regions with ordinary edit distances (up to ~8k edits) stay exact —
  same output as the unpatched engine.

  With the switch False, dLimit is set to High(Integer) and the bail
  branch below is unreachable: the loop then runs until the paths
  meet — EXACTLY the pre-patch unit's (and JGit's) unbounded search,
  bit-identical results and opcodes for every input. }
var
  minK, maxK, d, dLimit, natural: Integer;
begin
  if (beginA = endA) or (beginB = endB) then
  begin
    Fedit.beginA := beginA;
    Fedit.endA := endA;
    Fedit.beginB := beginB;
    Fedit.endB := endB;
    Exit(Fedit);
  end;
  FbeginA := beginA;
  FendA := endA;
  FbeginB := beginB;
  FendB := endB;

  minK := beginB - endA;
  maxK := endB - beginA;

  Fforward.Initialize(beginB - beginA, beginA, minK, maxK);
  Fbackward.Initialize(endB - endA, endA, minK, maxK);

  // PERFORMANCE PATCH (OPT-4, gated): dLimit = min(natural bound, cap).
  if OPT4_ENABLE_MYERS_D_CAP then
  begin
    natural := ((endA - beginA) + (endB - beginB) + 2) div 2;
    if natural > MYERS_MAX_D then
      dLimit := MYERS_MAX_D
    else
      dLimit := natural;
  end
  else
    dLimit := High(Integer); // OPT-4 off: unbounded, exactly the original loop

  d := 1;
  while True do
  begin
    { Cooperative-cancellation poll: the Myers fallback's middle-snake
      search is the unbounded hot loop for regions without a rare-enough
      anchor (pure duplicated blocks). }
    DiffCheckCancelled;
    if Fforward.Calculate(d) or Fbackward.Calculate(d) then
      Break;
    if d >= dLimit then
    begin
      // OPT-4: budget exhausted — give up on the middle snake and emit
      // the whole region as one REPLACE edit. CalculateEdits terminates
      // on this result (no smaller before/after parts are queued).
      // NOTE: unreachable when OPT4_ENABLE_MYERS_D_CAP = False, because
      // dLimit is then High(Integer) and the paths always meet first.
      Fedit.beginA := beginA;
      Fedit.endA := endA;
      Fedit.beginB := beginB;
      Fedit.endB := endB;
      Exit(Fedit);
    end;
    Inc(d);
  end;
  Result := Fedit;
end;

procedure TMyersMiddleEdit.CalculateEdits(beginA, endA, beginB, endB: Integer);
{ Ported from MyersDiff.calculateEdits() (lines 160-179).
  Recursive: find middle edit, recurse on left part, emit middle (if non-empty),
  recurse on right part. Uses snake() to find where the common prefix/suffix
  of each part ends, so we don't re-process them. }
var
  edit: TEdit;
  k, x: Integer;
begin
  { Cooperative-cancellation poll: CalculateEdits is recursive -- the
    d-loop poll inside Calculate covers each middle-snake search, this
    keeps the recursion itself interruptible too. }
  DiffCheckCancelled;

  edit := Calculate(beginA, endA, beginB, endB);

  if (beginA < edit.beginA) or (beginB < edit.beginB) then
  begin
    k := edit.beginB - edit.beginA;
    x := Fbackward.Snake(k, edit.beginA);
    CalculateEdits(beginA, x, beginB, k + x);
  end;

  if edit.GetType <> etEmpty then
    Fedits.Add(edit);

  if (endA > edit.endA) or (endB > edit.endB) then
  begin
    k := edit.endB - edit.endA;
    x := Fforward.Snake(k, edit.endA);
    CalculateEdits(x, endA, k + x, endB);
  end;
end;

{ TMyersDiff main entry — ported from MyersDiff constructor + calculateEdits }

procedure TMyersDiff.DiffNonCommonLow(edits: TEditList;
  cmp: THashedSequenceComparator;
  a, b: THashedSequence;
  const region: TEdit);
{ Ported from MyersDiff constructor (lines 116-123) + calculateEdits (lines 133-141).
  Initializes a MiddleEdit, then calls CalculateEdits with the region. }
var
  middle: TMyersMiddleEdit;
  bA, eA, bB, eB: Integer;
begin
  middle := TMyersMiddleEdit.Create(edits, cmp, a, b);
  try
    bA := region.beginA;
    eA := region.endA;
    bB := region.beginB;
    eB := region.endB;
    middle.Initialize(bA, eA, bB, eB);
    // Use the trimmed bounds from middle's Initialize (which strips common
    // prefix/suffix via snake()).
    if (middle.FbeginA < middle.FendA) or (middle.FbeginB < middle.FendB) then
      middle.CalculateEdits(middle.FbeginA, middle.FendA,
                            middle.FbeginB, middle.FendB);
  finally
    middle.Free;
  end;
end;

{ Note: middle's FbeginA etc. are private to TMyersMiddleEdit, but
  TMyersDiff is in the same unit's implementation section, so it can
  access them. We exposed them as private (not strict private) to
  allow this cross-class access within the same unit. }

{ ------------------------------------------------------------------
  THistogramDiff — ported from diff/HistogramDiff.java
  ------------------------------------------------------------------ }

constructor THistogramDiff.Create;
begin
  inherited Create;
  FFallback := TMyersDiff.Create;
  FMaxChainLength := 64;
end;

procedure THistogramDiff.SetFallbackAlgorithm(alg: TDiffAlgorithm);
begin
  FFallback := alg;
end;

procedure THistogramDiff.SetMaxChainLength(maxLen: Integer);
begin
  FMaxChainLength := maxLen;
end;

type
  { ----------------------------------------------------------------
    THistogramDiffIndex — ported from diff/HistogramDiffIndex.java
    ----------------------------------------------------------------
    Computes occurrence counts of elements in a region of A, then scans B
    for the longest common subsequence with the lowest occurrence count.

    PERFORMANCE PATCH (OPT-1): the hot loops (ScanA /
    TryLongestCommonSequence) compare elements and hash them through the
    flattened FFlat state below instead of the 3-layer virtual comparator
    stack. PERFORMANCE PATCH (OPT-3): when the sequence pair interned
    lines into integer IDs (FIdsExact), every comparison in those loops
    is an exact integer compare — no byte-wise line comparison at all
    (rev-1's OPT-2 occurrence-count punt has been removed; see header
    note 11). }
  THistogramDiffIndex = class
  private
    FMaxChainLength: Integer;
    FCmp: THashedSequenceComparator;
    Fa, Fb: THashedSequence;
    FRegion: TEdit;

    { Hash table — keyed by hash(s, idx). Index into recs. }
    Ftable: array of Integer;
    FkeyShift: Integer;

    { Records — packed 3-tuples (next, ptr, count) in a single Int64. }
    Frecs: array of Int64;
    FrecCnt: Integer;

    { For element ptr in A, next[ptr - ptrShift] is the next occurrence
      of the same element in A (or 0 for end of chain). }
    Fnext: array of Integer;
    { For element ptr in A, recIdx[ptr - ptrShift] is the index into recs
      describing all occurrences of this element. }
    FrecIdx: array of Integer;

    FptrShift: Integer;

    Flcs: TEdit;
    Fcnt: Integer;
    FhasCommon: Boolean;

    { ---------- PERFORMANCE PATCH (OPT-1): flattened hot-path state -----
      Resolved once in the constructor when the wrapper chains are the
      expected ones (THashedSequence -> TSubsequence -> TRawText and
      THashedSequenceComparator -> TSubsequenceComparator ->
      TRawTextComparator — the only structure DoDiffTexts ever builds).
      All hot-loop helpers below check FFlat and fall back to the
      original FCmp calls when it is False, so correctness never
      depends on the layout check. }

    { True when the flat references below are valid. }
    FFlat: Boolean;

    { PERFORMANCE PATCH (OPT-3): True when the sequence pair interned
      lines into integer IDs (see THashedSequencePair.InternAll), i.e.
      FAhashPtr/FBhashPtr hold IDs and gate equality is exact equality.
      Then the hot loops never need the byte spans and the per-region
      span precompute is skipped. }
    FIdsExact: Boolean;

    { Innermost real comparator (what the TSubsequenceComparator wraps).
      NOT owned by the index — it outlives it. }
    FBaseCmp: TRawTextComparator;

    { Underlying raw texts and their subsequence begin offsets: element i
      of Fa/Fb is base line (FAoff + i) / (BFoff + i) of FAraw/FBraw. }
    FAraw, FBraw: TRawText;
    FAoff, BFoff: Integer;

    { Direct views of Fa.FHashes / Fb.FHashes (cached line hashes).
      Non-nil whenever the respective sequence is non-empty; the hot
      loops only dereference the pointer of a sequence they have already
      established to be non-empty (ScanA only runs for a non-empty A
      region, TryLongestCommonSequence only for a non-empty B region,
      and EqualsAB is only reached when records exist => A non-empty). }
    FAhashPtr, FBhashPtr: PInteger;

    { Per-region line byte spans (start/end offsets into FAraw/FBraw
      content), region-relative:
        A span at raw index i -> FAs/FAe[i - FptrShift]
        B span at raw index j -> FBs/FBe[j - FRegion.beginB]
      Filled for exactly the indices the hot loops can touch.
      OPT-3: left EMPTY when FIdsExact — the hot loops compare IDs and
      never need the spans (which also removes the O(region) fill cost
      from every recursion step). }
    FAs, FAe: array of Integer;
    FBs, FBe: array of Integer;

    { Table hash for element idx of A / B: Knuth multiplicative mix of
      the cached line hash. Ported from HistogramDiffIndex.hash()
      (lines 276-278): (cmp.hash(s, idx) * $9E370001) >>> keyShift,
      wrapping on overflow intentionally (G10). }
    function HashA(idx: Integer): Integer;
    function HashB(idx: Integer): Integer;

    { Flattened FCmp.Equals(Fa, ai, Fb/Fa, bi): cached-hash gate first
      (exactly what THashedSequenceComparator.equals does), then a
      single span-based comparison through FBaseCmp.EqualsSpans with the
      offsets Equals would have resolved (exactly what the wrapped
      TSubsequenceComparator -> TRawTextComparator.Equals chain does). }
    function EqualsAA(ai, aj: Integer): Boolean;
    function EqualsAB(ai, bi: Integer): Boolean;

    class function RecCreate(nextRec, ptr, cnt: Integer): Int64; static; inline;
    class function RecNext(rec: Int64): Integer; static; inline;
    class function RecPtr(rec: Int64): Integer; static; inline;
    class function RecCnt(rec: Int64): Integer; static; inline;
    class function TableBits(sz: Integer): Integer; static;

    function ScanA: Boolean;
    function TryLongestCommonSequence(bPtr: Integer): Integer;
  public
    constructor Create(maxChainLength: Integer;
      cmp: THashedSequenceComparator;
      a, b: THashedSequence;
      const r: TEdit);

    { Ported from HistogramDiffIndex.findLongestCommonSequence() (lines 137-148).
      Returns a TEdit. To distinguish "null" (JGit's null return) from
      a real empty edit, we use a sentinel: Result.beginA = -1 means null.
      Caller checks `lcs.beginA = -1` for null, else checks `lcs.IsEmpty`. }
    function FindLongestCommonSequence: TEdit;
  end;

  { ----------------------------------------------------------------
    THistogramDiffState — ported from HistogramDiff.State (lines 108-187).
    ---------------------------------------------------------------- }
  THistogramDiffState = class
  private
    FCmp: THashedSequenceComparator;
    Fa, Fb: THashedSequence;
    FQueue: TEditList;
    Fedits: TEditList;
    FOwner: THistogramDiff;
    procedure DiffReplace(const r: TEdit);
    procedure Diff(const r: TEdit);
    function Subcmp: TSubsequenceComparator;
  public
    constructor Create(edits: TEditList;
      cmp: THashedSequenceComparator;
      a, b: THashedSequence;
      owner: THistogramDiff);
    destructor Destroy; override;
    procedure DiffRegion(const r: TEdit);
  end;

procedure THistogramDiff.DiffNonCommonLow(edits: TEditList;
  cmp: THashedSequenceComparator;
  a, b: THashedSequence;
  const region: TEdit);
{ Ported from HistogramDiff.diffNonCommon() (lines 101-106).
  Creates a State and calls diffRegion on the region. }
var
  state: THistogramDiffState;
begin
  state := THistogramDiffState.Create(edits, cmp, a, b, Self);
  try
    state.DiffRegion(region);
  finally
    state.Free;
  end;
end;

{ THistogramDiffIndex implementation }

constructor THistogramDiffIndex.Create(maxChainLength: Integer;
  cmp: THashedSequenceComparator;
  a, b: THashedSequence;
  const r: TEdit);
{ Ported from HistogramDiffIndex constructor (lines 114-135).
  PERFORMANCE PATCH (OPT-1): also resolves the flattened hot-path
  references (see the FFlat block in the class declaration). }
var
  sz, tb: Integer;
  i, bsz: Integer;
  aSub, bSub: TSubsequence;
begin
  inherited Create;
  FMaxChainLength := maxChainLength;
  FCmp := cmp;
  Fa := a;
  Fb := b;
  FRegion := r;

  if FRegion.endA >= HDI_MAX_PTR then
    raise EArgumentException.Create('Sequence too large for diff algorithm');

  sz := r.GetLengthA;
  tb := TableBits(sz);
  SetLength(Ftable, 1 shl tb);
  FkeyShift := 32 - tb;
  FptrShift := r.beginA;

  if sz > 32 then
    SetLength(Frecs, sz div 8)
  else
    SetLength(Frecs, 4);
  SetLength(Fnext, sz);
  SetLength(FrecIdx, sz);

  { ---- PERFORMANCE PATCH (OPT-1): resolve flattened hot-path state ----
    Expected wrapper chains (the only ones DoDiffTexts builds):
      Fa/Fb : THashedSequence -> TSubsequence -> TRawText
      FCmp  : THashedSequenceComparator -> TSubsequenceComparator ->
              TRawTextComparator
    If anything doesn't match, FFlat stays False and every hot-loop
    helper falls back to the original FCmp virtual calls. }
  FFlat := False;
  FIdsExact := FCmp.FIdsExact;
  FBaseCmp := nil;
  FAraw := nil;
  FBraw := nil;
  FAoff := 0;
  BFoff := 0;
  FAhashPtr := nil;
  FBhashPtr := nil;
  if (FCmp.Cmp is TSubsequenceComparator)
    and (TSubsequenceComparator(FCmp.Cmp).Cmp is TRawTextComparator)
    and (Fa.Base is TSubsequence)
    and (Fb.Base is TSubsequence) then
  begin
    aSub := TSubsequence(Fa.Base);
    bSub := TSubsequence(Fb.Base);
    if (aSub.Base is TRawText) and (bSub.Base is TRawText) then
    begin
      FBaseCmp := TRawTextComparator(TSubsequenceComparator(FCmp.Cmp).Cmp);
      FAraw := TRawText(aSub.Base);
      FBraw := TRawText(bSub.Base);
      FAoff := aSub.BeginOffset;
      BFoff := bSub.BeginOffset;

      { Direct views of the cached line hashes (arrays are stable after
        THashedSequence.Create; the sequences outlive the index).
        OPT-3: with interned IDs these hold IDs, which is what makes the
        gate compare below exact. }
      if Length(Fa.FHashes) > 0 then
        FAhashPtr := @Fa.FHashes[0];
      if Length(Fb.FHashes) > 0 then
        FBhashPtr := @Fb.FHashes[0];

      { Precompute this region's line byte spans, stored REGION-RELATIVE:
        raw element i of the subsequence is base line (FAoff + i) — note
        the region begin is NOT part of FAoff, regions are in subsequence
        coordinates — so its span is [Lines.Get(FAoff + i + 1),
        Lines.Get(FAoff + i + 2)). We store it at index (i - beginA)
        (= i - FptrShift), which is exactly how the hot loops address the
        arrays (FAs[ai - FptrShift]). These are the same offsets
        TRawTextComparatorDefault.Equals resolves per call in the
        unpatched engine, after TSubsequenceComparator adds the begin
        offset. }
      { OPT-3: with interned IDs the hot loops never need the byte
        spans (comparisons are pure integer ops), so the per-region
        span precompute — two Lines.Get per line for every region the
        recursion visits — is skipped entirely. The non-ID path keeps
        the precompute: it needs the spans for EqualsSpans calls. }
      if not FIdsExact then
      begin
        SetLength(FAs, sz);
        SetLength(FAe, sz);
        for i := 0 to sz - 1 do
        begin
          FAs[i] := FAraw.Lines.Get(FAoff + FptrShift + i + 1);
          FAe[i] := FAraw.Lines.Get(FAoff + FptrShift + i + 2);
        end;

        bsz := FRegion.GetLengthB;
        SetLength(FBs, bsz);
        SetLength(FBe, bsz);
        for i := 0 to bsz - 1 do
        begin
          FBs[i] := FBraw.Lines.Get(BFoff + FRegion.beginB + i + 1);
          FBe[i] := FBraw.Lines.Get(BFoff + FRegion.beginB + i + 2);
        end;
      end;

      FFlat := True;
    end;
  end;
end;

{ PERFORMANCE PATCH (OPT-1): table hash of element idx of A.
  Flattened form of the former Hash(Fa, idx): reads the cached line hash
  directly instead of FCmp.Hash(Fa, idx) ->
  THashedSequenceComparator.Hash -> THashedSequence.GetHash. }
function THistogramDiffIndex.HashA(idx: Integer): Integer;
{$PUSH}{$R-}{$Q-}
begin
  if FFlat then
    Result := Integer(UInt32(UInt32(FAhashPtr[idx]) * UInt32(HDI_KNUTH_MULTIPLIER)) shr FkeyShift)
  else
    Result := Integer(UInt32(UInt32(FCmp.Hash(Fa, idx)) * UInt32(HDI_KNUTH_MULTIPLIER)) shr FkeyShift);
end;
{$POP}

{ PERFORMANCE PATCH (OPT-1): table hash of element idx of B (see HashA). }
function THistogramDiffIndex.HashB(idx: Integer): Integer;
{$PUSH}{$R-}{$Q-}
begin
  if FFlat then
    Result := Integer(UInt32(UInt32(FBhashPtr[idx]) * UInt32(HDI_KNUTH_MULTIPLIER)) shr FkeyShift)
  else
    Result := Integer(UInt32(UInt32(FCmp.Hash(Fb, idx)) * UInt32(HDI_KNUTH_MULTIPLIER)) shr FkeyShift);
end;
{$POP}

{ PERFORMANCE PATCH (OPT-1): flattened FCmp.Equals(Fa, ai, Fa, aj).
  Semantically identical to the virtual chain:
    THashedSequenceComparator.Equals(Fa, ai, Fa, aj)
      = (Fa.FHashes[ai] = Fa.FHashes[aj])              <- hash gate
        and TSubsequenceComparator.Equals(Fa.Base, ai, Fa.Base, aj)
        = TRawTextComparator.Equals(FAraw, ai + FAoff, FAraw, aj + FAoff)
        = EqualsSpans over the two lines' byte spans   <- what FAs/FAe hold.
  Only called from ScanA with both indexes inside [beginA, endA).

  PERFORMANCE PATCH (OPT-3): when FIdsExact, FHashes holds interned
  line IDs — equal IDs prove content equality, so the EqualsSpans
  fallback is skipped and this is a pure integer compare. }
function THistogramDiffIndex.EqualsAA(ai, aj: Integer): Boolean;
begin
  if FFlat then
    if FIdsExact then
      Result := (FAhashPtr[ai] = FAhashPtr[aj])
    else
      Result := (FAhashPtr[ai] = FAhashPtr[aj])
        and FBaseCmp.EqualsSpans(FAraw,
             FAs[ai - FptrShift], FAe[ai - FptrShift],
             FAraw, FAs[aj - FptrShift], FAe[aj - FptrShift])
  else
    Result := FCmp.Equals(Fa, ai, Fa, aj);
end;

{ PERFORMANCE PATCH (OPT-1): flattened FCmp.Equals(Fa, ai, Fb, bi) —
  see EqualsAA. Only called from TryLongestCommonSequence with ai inside
  [beginA, endA) and bi inside [beginB, endB).
  PERFORMANCE PATCH (OPT-3): with IDs (FIdsExact) this is a pure
  integer compare — the extension loops below run it once per step. }
function THistogramDiffIndex.EqualsAB(ai, bi: Integer): Boolean;
begin
  if FFlat then
    if FIdsExact then
      Result := (FAhashPtr[ai] = FBhashPtr[bi])
    else
      Result := (FAhashPtr[ai] = FBhashPtr[bi])
        and FBaseCmp.EqualsSpans(FAraw,
             FAs[ai - FptrShift], FAe[ai - FptrShift],
             FBraw, FBs[bi - FRegion.beginB], FBe[bi - FRegion.beginB])
  else
    Result := FCmp.Equals(Fa, ai, Fb, bi);
end;

class function THistogramDiffIndex.RecCreate(nextRec, ptr, cnt: Integer): Int64;
begin
  Result := (Int64(UInt32(nextRec)) shl HDI_REC_NEXT_SHIFT)
        or (Int64(UInt32(ptr)) shl HDI_REC_PTR_SHIFT)
        or (UInt32(cnt) and HDI_REC_CNT_MASK);
end;

class function THistogramDiffIndex.RecNext(rec: Int64): Integer;
begin
  Result := Integer(UInt32(UInt64(rec) shr HDI_REC_NEXT_SHIFT));
end;

class function THistogramDiffIndex.RecPtr(rec: Int64): Integer;
begin
  Result := Integer(UInt32(UInt64(rec) shr HDI_REC_PTR_SHIFT) and HDI_REC_PTR_MASK);
end;

class function THistogramDiffIndex.RecCnt(rec: Int64): Integer;
begin
  Result := Integer(UInt32(rec) and HDI_REC_CNT_MASK);
end;

class function THistogramDiffIndex.TableBits(sz: Integer): Integer;
{ Ported from HistogramDiffIndex.tableBits() (lines 298-305).
  Computes ceil(log2(sz)), with a minimum of 1. }
var
  bits: Integer;
  temp: Cardinal;
begin
  // 31 - numberOfLeadingZeros(sz)
  // FPC has BitSizeOf / LeadByte? Use the simple loop form.
  bits := 0;
  temp := Cardinal(sz);
  while temp > 1 do
  begin
    temp := temp shr 1;
    Inc(bits);
  end;
  // bits = floor(log2(sz))
  if bits = 0 then
    bits := 1;
  if (1 shl bits) < sz then
    Inc(bits);
  Result := bits;
end;

function THistogramDiffIndex.ScanA: Boolean;
{ Ported from HistogramDiffIndex.scanA() (lines 150-198).
  Scans A backwards, building the hash table. Returns False if any
  chain exceeds maxChainLength (region should fall back to Myers).

  PERFORMANCE PATCH (OPT-1): table hash via HashA, element comparison
  via the flattened EqualsAA — no virtual comparator stack per step.
  PERFORMANCE PATCH (OPT-3): when the pair interned lines into IDs
  (FIdsExact — see THashedSequencePair.InternAll), EqualsAA is a pure
  integer compare; occurrence counts saturate at MAX_CNT (255),
  exactly JGit's behavior. Rev-1's OPT-2 occurrence-count punt has
  been REMOVED — it regressed real repetitive inputs by handing whole
  regions (including the ROOT region of any file with a >64x-repeated
  line, which blank lines / closing braces easily trigger) to the
  Myers fallback; see header note 11. Too-common elements are skipped
  per-element by TryLongestCommonSequence's "RecCnt(rec) > Fcnt"
  filter, which is the mechanism JGit itself uses. }
label
  SCAN;
var
  ptr, tIdx, rIdx, chainLen, newCnt: Integer;
  rec: Int64;
  sz, tmp: Integer;
  n: array of Int64;
begin
  ptr := FRegion.endA - 1;
  while ptr >= FRegion.beginA do
  begin
    { Cooperative-cancellation poll: ScanA's outer loop is one of the two
      histogram hot loops; one poll per A element of the region. }
    DiffCheckCancelled;
    tIdx := HashA(ptr);
    chainLen := 0;
    rIdx := Ftable[tIdx];
    while rIdx <> 0 do
    begin
      rec := Frecs[rIdx];
      if EqualsAA(RecPtr(rec), ptr) then
      begin
        // ptr is identical to another element. Insert onto front of existing chain.
        newCnt := RecCnt(rec) + 1;
        if newCnt > HDI_MAX_CNT then
          newCnt := HDI_MAX_CNT;
        Frecs[rIdx] := RecCreate(RecNext(rec), ptr, newCnt);
        Fnext[ptr - FptrShift] := RecPtr(rec);
        FrecIdx[ptr - FptrShift] := rIdx;
        goto SCAN;  // continue outer loop
      end;
      rIdx := RecNext(rec);
      Inc(chainLen);
    end;

    if chainLen = FMaxChainLength then
      Exit(False);

    // New unique element — add a record.
    Inc(FrecCnt);
    rIdx := FrecCnt;
    if rIdx = Length(Frecs) then
    begin
      sz := Length(Frecs) * 2;
      tmp := 1 + FRegion.GetLengthA;
      if tmp < sz then sz := tmp;
      SetLength(n, sz);
      Move(Frecs[0], n[0], Length(Frecs) * SizeOf(Int64));
      Frecs := n;
    end;
    Frecs[rIdx] := RecCreate(Ftable[tIdx], ptr, 1);
    FrecIdx[ptr - FptrShift] := rIdx;
    Ftable[tIdx] := rIdx;

  SCAN:
    Dec(ptr);
  end;
  Result := True;
end;

function THistogramDiffIndex.TryLongestCommonSequence(bPtr: Integer): Integer;
{ Ported from HistogramDiffIndex.tryLongestCommonSequence() (lines 200-274).
  For each element of B starting at bPtr, scans A's hash chain for matches.
  Tracks the longest LCS with the lowest occurrence count.

  PERFORMANCE PATCH (OPT-1): table hash via HashB, all element
  comparisons via the flattened EqualsAB — each step is now a cached
  integer hash compare plus (on gate pass) one span-based byte compare,
  instead of three virtual calls with `as` casts per step.
  PERFORMANCE PATCH (OPT-3): with interned IDs (FIdsExact) the gate
  compare is exact — no byte compare at all — which is what makes the
  TRY_LOCATIONS occurrence walks and the extension loops cheap on
  heavily repeated text. }
var
  bNext: Integer;
  rIdx: Integer;
  rec: Int64;
  as_, bs, ae, be, np, rc: Integer;
  tmp: Integer;
label
  TRY_LOCATIONS, BREAK_TRY;
begin
  bNext := bPtr + 1;
  rIdx := Ftable[HashB(bPtr)];
  while rIdx <> 0 do
  begin
    rec := Frecs[rIdx];

    // If there are more occurrences in A than current best, skip this chain.
    if RecCnt(rec) > Fcnt then
    begin
      if not FhasCommon then
        FhasCommon := EqualsAB(RecPtr(rec), bPtr);
      rIdx := RecNext(rec);
      Continue;
    end;

    as_ := RecPtr(rec);
    if not EqualsAB(as_, bPtr) then
    begin
      rIdx := RecNext(rec);
      Continue;
    end;

    FhasCommon := True;

    // TRY_LOCATIONS loop
    TRY_LOCATIONS:
      np := Fnext[as_ - FptrShift];
      bs := bPtr;
      ae := as_ + 1;
      be := bs + 1;
      rc := RecCnt(rec);

      // Extend backwards.
      while (FRegion.beginA < as_) and (FRegion.beginB < bs)
            and EqualsAB(as_ - 1, bs - 1) do
      begin
        Dec(as_);
        Dec(bs);
        if rc > 1 then
        begin
          tmp := RecCnt(Frecs[FrecIdx[as_ - FptrShift]]);
          if tmp < rc then rc := tmp;
        end;
      end;

      // Extend forwards.
      while (ae < FRegion.endA) and (be < FRegion.endB)
            and EqualsAB(ae, be) do
      begin
        if rc > 1 then
        begin
          tmp := RecCnt(Frecs[FrecIdx[ae - FptrShift]]);
          if tmp < rc then rc := tmp;
        end;
        Inc(ae);
        Inc(be);
      end;

      if bNext < be then
        bNext := be;
      if (Flcs.GetLengthA < ae - as_) or (rc < Fcnt) then
      begin
        Flcs.beginA := as_;
        Flcs.beginB := bs;
        Flcs.endA := ae;
        Flcs.endB := be;
        Fcnt := rc;
      end;

      if np = 0 then
        goto BREAK_TRY;

      while np < ae do
      begin
        np := Fnext[np - FptrShift];
        if np = 0 then
          goto BREAK_TRY;
      end;

      as_ := np;
      goto TRY_LOCATIONS;

    BREAK_TRY:
    rIdx := RecNext(rec);
  end;
  Result := bNext;
end;

function THistogramDiffIndex.FindLongestCommonSequence: TEdit;
{ Ported from HistogramDiffIndex.findLongestCommonSequence() (lines 137-148).
  Returns a TEdit. To distinguish JGit's "null" return from a real
  (possibly empty) edit, we use the sentinel beginA = -1 for null.
  Caller checks `lcs.beginA = -1` for null, else checks `lcs.IsEmpty`. }
var
  bPtr: Integer;
begin
  if not ScanA then
  begin
    // ScanA failed (chain length exceeded) — return null sentinel.
    Result.beginA := -1;
    Result.endA := -1;
    Result.beginB := -1;
    Result.endB := -1;
    Exit;
  end;

  Flcs.beginA := 0;
  Flcs.endA := 0;
  Flcs.beginB := 0;
  Flcs.endB := 0;
  Fcnt := FMaxChainLength + 1;

  bPtr := FRegion.beginB;
  while bPtr < FRegion.endB do
  begin
    { Cooperative-cancellation poll: the other histogram hot loop --
      TryLongestCommonSequence is called once per B element of the
      region, and its occurrence-chain walks are bounded by
      maxChainLength. }
    DiffCheckCancelled;
    bPtr := TryLongestCommonSequence(bPtr);
  end;

  if FhasCommon and (FMaxChainLength < Fcnt) then
  begin
    // Common elements exist but none had a small-enough chain length.
    // Return null sentinel so caller falls back to fallback algorithm.
    Result.beginA := -1;
    Result.endA := -1;
    Result.beginB := -1;
    Result.endB := -1;
  end
  else
    Result := Flcs;
end;

{ THistogramDiffState implementation }

constructor THistogramDiffState.Create(edits: TEditList;
  cmp: THashedSequenceComparator;
  a, b: THashedSequence;
  owner: THistogramDiff);
begin
  inherited Create;
  FCmp := cmp;
  Fa := a;
  Fb := b;
  Fedits := edits;
  FOwner := owner;
  FQueue := TEditList.Create;
end;

destructor THistogramDiffState.Destroy;
begin
  FQueue.Free;
  inherited Destroy;
end;

procedure THistogramDiffState.DiffRegion(const r: TEdit);
{ Ported from State.diffRegion() (lines 125-129). }
var
  e: TEdit;
begin
  DiffReplace(r);
  while FQueue.Size > 0 do
  begin
    { Cooperative-cancellation poll: the region recursion -- every queued
      before/after part re-enters Diff/ScanA/TryLongestCommonSequence. }
    DiffCheckCancelled;
    e := FQueue.RemoveLast;
    Diff(e);
  end;
end;

procedure THistogramDiffState.DiffReplace(const r: TEdit);
{ Ported from State.diffReplace() (lines 131-162).
  Finds the LCS in the region; if found and non-empty, queues before/after
  parts for further diffing. If empty, adds the region as a REPLACE.
  If no LCS, falls back to the fallback algorithm (Myers by default). }
var
  idx: THistogramDiffIndex;
  lcs: TEdit;
  cs: TSubsequenceComparator;
  as_, bs: TSubsequence;
  res: TEditList;
  fbLow: TLowLevelDiffAlgorithm;
begin
  idx := THistogramDiffIndex.Create(FOwner.MaxChainLength, FCmp, Fa, Fb, r);
  try
    lcs := idx.FindLongestCommonSequence;
  finally
    idx.Free;
  end;

  // Check for "null" sentinel (beginA = -1).
  if lcs.beginA <> -1 then
  begin
    if lcs.IsEmpty then
    begin
      // Nothing in common — replace the entire region.
      Fedits.Add(r);
    end
    else
    begin
      FQueue.Add(r.After(lcs));
      FQueue.Add(r.Before(lcs));
    end;
  end
  else if FOwner.Fallback is TLowLevelDiffAlgorithm then
  begin
    // Fallback is low-level (Myers): call diffNonCommon directly on hashed seqs.
    fbLow := TLowLevelDiffAlgorithm(FOwner.Fallback);
    fbLow.DiffNonCommonLow(Fedits, FCmp, Fa, Fb, r);
  end
  else if FOwner.Fallback <> nil then
  begin
    // Non-low-level fallback (we don't currently use this path, but
    // port the logic for completeness).
    cs := Subcmp;
    try
      as_ := TSubsequence.A(Fa, r);
      bs := TSubsequence.B(Fb, r);
      try
        res := FOwner.Fallback.DiffNonCommon(cs, as_, bs);
        try
          TSubsequence.ToBaseEditList(res, as_, bs);
          Fedits.AddAll(res);
        finally
          res.Free;
        end;
      finally
        as_.Free;
        bs.Free;
      end;
    finally
      cs.Free;
    end;
  end
  else
  begin
    // No fallback — emit as REPLACE.
    Fedits.Add(r);
  end;
end;

procedure THistogramDiffState.Diff(const r: TEdit);
{ Ported from State.diff() (lines 164-182). }
var
  rType: TEditType;
begin
  rType := r.GetType;
  case rType of
    etInsert, etDelete:
      Fedits.Add(r);
    etReplace:
    begin
      if (r.GetLengthA = 1) and (r.GetLengthB = 1) then
        Fedits.Add(r)
      else
        DiffReplace(r);
    end;
    etEmpty:
      raise Exception.Create('THistogramDiffState.Diff: unexpected EMPTY edit');
  end;
end;

function THistogramDiffState.Subcmp: TSubsequenceComparator;
begin
  Result := TSubsequenceComparator.Create(FCmp);
end;

{ Note: Math_Min was originally a standalone helper, but it caused
  forward-declaration issues because ScanA and TryLongestCommonSequence
  are defined before it. We inline the comparisons directly instead.
  This keeps the file self-contained without reordering methods. }

{ ------------------------------------------------------------------
  Internal helpers — choose comparator + algorithm based on flags.
  ------------------------------------------------------------------ }

{ Chooses the right TRawTextComparator subclass based on the WS flag.
  Only two subclasses exist (G31): WS_IGNORE_ALL (DIFF_IGN_WHITESPACE)
  and DEFAULT. }
function CreateComparator(AFlags: Integer): TRawTextComparator;
var
  nonWSFlags: Integer;
begin
  // CASE, NUMBERS, EOL are orthogonal — pass them to the
  // comparator's FFlags so per-byte transforms apply uniformly.
  nonWSFlags := AFlags and (cIgnCase or cIgnNumbers or cIgnEOL);

  if (AFlags and cIgnWhitespace) <> 0 then
    Result := TRawTextComparatorWSIgnoreAll.Create(nonWSFlags)
  else
    Result := TRawTextComparatorDefault.Create(nonWSFlags);
end;

{ Chooses the right diff algorithm. }
function CreateAlgorithm(AAlgo: Integer): TDiffAlgorithm;
begin
  case AAlgo of
    cAlgoHistogram:
      Result := THistogramDiff.Create
    else
      Result := TMyersDiff.Create;
  end;
end;

{ ------------------------------------------------------------------
  EditList -> TDiffOpcodeArray conversion (with EQUAL synthesis).
  Ported conceptually from G3: JGit's EditList contains only
  INSERT/DELETE/REPLACE — equal regions must be synthesized by walking
  the list and filling gaps.
  ------------------------------------------------------------------ }
function EditListToOpcodes(const edits: TEditList;
  sizeA, sizeB: Integer): TDiffOpcodeArray;
var
  i: Integer;
  op: TDiffOpcode;
  curA, curB: Integer;
  e: TEdit;
  eType: TEditType;
  raw: TDiffOpcodeArray;
  rawCount: Integer;
begin
  Result := nil;  // silence "managed type not initialized" warning
  SetLength(raw, edits.Size * 2 + 1);
  rawCount := 0;

  curA := 0;
  curB := 0;
  for i := 0 to edits.Size - 1 do
  begin
    { Cooperative-cancellation poll: O(D) post-pass }
    if (i and $FFF) = 0 then
      DiffCheckCancelled;
    e := edits.Get(i);
    eType := e.GetType;

    // Synthesize EQUAL for the gap between the previous edit and this one.
    if (e.beginA > curA) or (e.beginB > curB) then
    begin
      op.Tag := cTagEqual;
      op.I1 := curA;
      op.I2 := e.beginA;
      op.J1 := curB;
      op.J2 := e.beginB;
      raw[rawCount] := op;
      Inc(rawCount);
    end;

    case eType of
      etInsert:
      begin
        op.Tag := cTagInsert;
        op.I1 := e.beginA;
        op.I2 := e.endA;
        op.J1 := e.beginB;
        op.J2 := e.endB;
      end;
      etDelete:
      begin
        op.Tag := cTagDelete;
        op.I1 := e.beginA;
        op.I2 := e.endA;
        op.J1 := e.beginB;
        op.J2 := e.endB;
      end;
      etReplace:
      begin
        op.Tag := cTagReplace;
        op.I1 := e.beginA;
        op.I2 := e.endA;
        op.J1 := e.beginB;
        op.J2 := e.endB;
      end;
      etEmpty:
        Continue;  // skip EMPTY edits (no-op)
    end;
    raw[rawCount] := op;
    Inc(rawCount);

    curA := e.endA;
    curB := e.endB;
  end;

  // Final EQUAL for the trailing gap.
  if (curA < sizeA) or (curB < sizeB) then
  begin
    op.Tag := cTagEqual;
    op.I1 := curA;
    op.I2 := sizeA;
    op.J1 := curB;
    op.J2 := sizeB;
    raw[rawCount] := op;
    Inc(rawCount);
  end;

  // Copy to result of exact size.
  SetLength(Result, rawCount);
  if rawCount > 0 then
    Move(raw[0], Result[0], rawCount * SizeOf(TDiffOpcode));
end;

{ ------------------------------------------------------------------
  DIFF_IGN_BLANK_LINES suppression (G37) — WinMerge-style
  "ignored differences". Identical logic lives in cudadiffmyers.pas
  (its Section 18); see the header note there for the full rationale.

  Every hunk (insert/delete/replace) whose lines are ALL blank on both
  sides is re-tagged as a single 'ignore' opcode (ranges behave like
  'replace'). 'equal' opcodes are never touched, so i2-i1 == j2-j1
  keeps holding for them; the Differ plugin paints 'ignore' regions
  with a distinct color and compensates the length mismatch with an
  inter-line gap (Editor.gap supports per-gap color + tag), the way
  WinMerge renders its "ignored differences".

  Blank (verified against GNU diffutils -B / -B -b): empty after
  stripping the EOL terminator, or — with DIFF_IGN_WHITESPACE — only
  spaces/tabs. Space-only lines are NOT blank without the whitespace
  flag. Line spans come from the engine's own TRawText line map, so
  the check can never disagree with the engine's line splitting.
  ------------------------------------------------------------------ }

{ True when the line content (EOL terminator stripped) is empty, or
  consists only of spaces/tabs under AWhitespaceAlso. }
function IsBlankLineRaw(rt: TRawText; ALine: Integer;
  AWhitespaceAlso: Boolean): Boolean;
var
  raw: PByte;
  P, PEnd: Integer;
begin
  if (ALine < 0) or (ALine >= rt.Size) then
    Exit(False);
  raw := rt.ContentPtr;
  P := rt.GetStart(ALine);
  PEnd := rt.GetEnd(ALine);

  // Strip the trailing EOL terminator (LF / CR / CRLF).
  while (PEnd > P) and ((raw[PEnd - 1] = 10) or (raw[PEnd - 1] = 13)) do
    Dec(PEnd);

  while P < PEnd do
  begin
    if not (AWhitespaceAlso and ((raw[P] = 32) or (raw[P] = 9))) then
      Exit(False);
    Inc(P);
  end;
  Result := True;
end;

{ True when every line of the opcode's ranges on BOTH sides is blank.
  An empty range (pure insert/delete hunks) is vacuously blank. }
function HunkAllBlank(rtA, rtB: TRawText; const Op: TDiffOpcode;
  AWhitespaceAlso: Boolean): Boolean;
var
  K: Integer;
begin
  for K := Op.I1 to Op.I2 - 1 do
    if not IsBlankLineRaw(rtA, K, AWhitespaceAlso) then
      Exit(False);
  for K := Op.J1 to Op.J2 - 1 do
    if not IsBlankLineRaw(rtB, K, AWhitespaceAlso) then
      Exit(False);
  Result := True;
end;

{ Re-tag every all-blank non-equal hunk as 'ignore'. Directly-adjacent
  all-blank hunks (e.g. a delete followed by an insert) merge into a
  single 'ignore' opcode — opcodes tile the inputs, so the run's union
  is contiguous and replaces the run exactly. }
procedure MarkIgnoredBlankHunks(rtA, rtB: TRawText; AWhitespaceAlso: Boolean;
  var Ops: TDiffOpcodeArray);
var
  I, J, K, Shift: Integer;
  I2Max, J2Max: Integer;
begin
  I := 0;
  while I < Length(Ops) do
  begin
    { Cooperative-cancellation poll: O(D) post-pass; HunkAllBlank scans
      each hunk's lines, so a poll per opcode keeps it interruptible. }
    if (I and $FFF) = 0 then
      DiffCheckCancelled;
    if (Ops[I].Tag <> cTagEqual) and
       HunkAllBlank(rtA, rtB, Ops[I], AWhitespaceAlso) then
    begin
      I2Max := Ops[I].I2;
      J2Max := Ops[I].J2;
      J := I + 1;
      while (J < Length(Ops)) and (Ops[J].Tag <> cTagEqual) and
            HunkAllBlank(rtA, rtB, Ops[J], AWhitespaceAlso) do
      begin
        I2Max := Ops[J].I2;
        J2Max := Ops[J].J2;
        Inc(J);
      end;

      Ops[I].Tag := cTagIgnore;
      Ops[I].I2 := I2Max;
      Ops[I].J2 := J2Max;

      // Delete the merged-away ops [I+1 .. J-1].
      Shift := J - I - 1;
      if Shift > 0 then
      begin
        for K := J to High(Ops) do
          Ops[K - Shift] := Ops[K];
        SetLength(Ops, Length(Ops) - Shift);
      end;
      Inc(I);
    end
    else
      Inc(I);
  end;
end;

{ ------------------------------------------------------------------
  Public entry point
  ------------------------------------------------------------------ }
function DoDiffTexts(const ATextA, ATextB: string;
                     AAlgo: Integer;
                     AFlags: Integer): TDiffOpcodeArray;
var
  rtA, rtB: TRawText;
  cmp: TRawTextComparator;
  algo: TDiffAlgorithm;
  edits: TEditList;
  sizeA, sizeB: Integer;
  ops: TDiffOpcodeArray;
begin
  Result := nil;  // silence "managed type not initialized" warning
  // Construct RawTexts from raw UTF-8 byte buffers.
  rtA := TRawText.Create(RawByteString(ATextA));
  rtB := TRawText.Create(RawByteString(ATextB));
  try
    sizeA := rtA.Size;
    sizeB := rtB.Size;

    // G16: empty-input behavior.
    if (sizeA = 0) and (sizeB = 0) then
    begin
      SetLength(Result, 0);
      Exit;
    end;

    cmp := CreateComparator(AFlags);
    try
      algo := CreateAlgorithm(AAlgo);
      try
        edits := algo.Diff(cmp, rtA, rtB);
        try
          ops := EditListToOpcodes(edits, sizeA, sizeB);
          // DIFF_IGN_BLANK_LINES: re-tag all-blank hunks as 'ignore'
          // (G37). Runs on the final opcodes — the algorithm above is
          // untouched.
          if (AFlags and cIgnBlankLines) <> 0 then
            MarkIgnoredBlankHunks(rtA, rtB,
              (AFlags and cIgnWhitespace) <> 0, ops);
        finally
          edits.Free;
        end;
      finally
        algo.Free;
      end;
    finally
      cmp.Free;
    end;

    Result := ops;
  finally
    rtA.Free;
    rtB.Free;
  end;
end;

end.
