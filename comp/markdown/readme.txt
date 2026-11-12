Markdown rendering control for CudaText (vendored component)

Source: Lazarus LCL component "markdown"
https://gitlab.com/freepascal.org/lazarus/lazarus/-/tree/main/components/markdown
(commit of the copy: 5a8ed37, main branch)

Vendored files:
- markdown.control.pas
- markdown.canvasrender.pp
- Src_3_2/*.pas (markdown parser sources copied from FPC trunk
  by the Lazarus component, kept as-is)

Only whitespace was normalized in the copied files (trailing spaces,
line endings, final newline). The component is compiled directly from
these sources, no Lazarus package installation is needed.

Modifications made for CudaText (compared to upstream):

markdown.control.pas
- DoMouseWheel() override: mouse wheel scrolls WheelScrollLines
  (default 3) text lines per wheel notch; before, the widgetset
  default scrolled only ~1 line.
- New property WheelScrollLines.
- Resize() re-evaluates scrollbar visibility when only the height
  changed (auto scrollbars were not shown/hidden for height-only
  resizes).
- BaseFontSize changes now also update the internal line height used
  for scrolling.
- New property OnHiliteCode, forwarded to the renderer.

markdown.canvasrender.pp
- New event type TMarkdownHiliteEvent + TMarkdownHiliteTokenList:
  allows the host app to colorize fenced code blocks (see below).
  The fenced-code renderer splits each code line into colored runs
  based on the tokens filled by the event handler.
- ResolveEntities() rewritten: stray '&' characters are kept as-is
  (upstream dropped the '&' and added a bogus ';'), unknown entities
  are kept literally.
- ParseMarkdown(utf8string) overload was a no-op stub, it now calls
  the TStrings overload.
- ParseMarkdown(TStrings) frees the previous document (memory leak).
- GetSelectedText() does not insert spaces between colored runs of
  the same code line.
- Empty code lines keep the line height.

Src_3_2/markdown.htmlentities.pas
- The generated entity table was corrupted in upstream FCL sources:
  almost every entity value was '?'. Values were regenerated from the
  WHATWG entities.json data (e.g. nbsp = U+00A0, copy = U+00A9).

Syntax highlighting of fenced code blocks
-----------------------------------------
The renderer exposes OnHiliteCode: TMarkdownHiliteEvent. It is called
once per code block with the fence info string (e.g. 'python' for
fenced blocks) and the full code text; the handler must fill the
passed TMarkdownHiliteTokenList with token positions (1-based UTF-8
byte offsets in the code text), colors and font styles. The renderer
then draws each code line as a sequence of colored runs. When no
tokens are provided, code blocks render as before.
