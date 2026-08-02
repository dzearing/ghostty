# The win32 design system

**Read this before changing any pixel of the Windows chrome.** It is the
rulebook the tab strip, the banner, the dialogs, the chooser, the menus and the
split dividers all paint to. A control that invents its own spacing, size,
radius, hover treatment or glyph geometry is a defect even if it looks fine on
its own — the defect is the inconsistency, and it is visible the moment two
controls sit next to each other.

It exists because the chrome was built one task at a time, and every task made
locally reasonable choices that did not agree globally. The user's report of
2026-07-31 is the cost, and every item in it is arithmetic, not taste:

> *"the plus icon has a huge left gap and no bottom gap ... the left half of the
> horizontal line of the plus is shorter than the right half ... the hamburger
> icon isn't wide enough by maybe 2px ... the x button's gap on the top touches
> the edge of the tab! AGAIN CONSISTENT MARGINS AND GAPS, ux shouldn't touch
> the edge of other ux!"*

Measured from the shipped constants at 125% (their scale): the "+" glyph square
sits **16 px** from the tab beside it and **1 px** from the strip's bottom edge.
A 16:1 ratio between two gaps that should be equal is not a rounding artifact,
and no amount of care at each individual call site would have caught it. A
system does.

Related: `win32-tab-strip.md` (the strip's measured platform reference and its
deliberate deviations) and `windows-parity-tasks.md` (the work queue). This
document owns the RULES; that one owns the tab strip's specific numbers.

---

## 0. The three rules that would have prevented every complaint

1. **Nothing touches anything.** Every painted element keeps at least one
   spacing step (4 DIP) from every other painted element and from its
   container's edge. The only exceptions are deliberate *merges*, which must be
   named here: the selected tab chiclet merges into the pane below it (that is
   how a WinUI TabView marks selection), and nothing else.

2. **Gaps are measured between PAINTED edges, never hit boxes.** A hit box is
   allowed to be bigger than the thing it paints — a forgiving click target
   costs nothing — but it is invisible, so it must never contribute to a gap.
   This one rule is the whole of the "+ has a huge left gap" bug: the layout put
   an 8 DIP gap between the tab and the button's *hit box*, and the hit box then
   held 5 DIP of slack around its painted square, so the user saw 13 DIP.

3. **Padding is symmetric until this document says otherwise.** If a control
   has more space on one side than another, that asymmetry is a decision with a
   reason written down, not an artifact of which band it happened to be
   centered in.

Corollary, and the reason the "+" and the "×" both ended up 1 px from an edge:
**a control's container must be sized to fit the control plus its padding.**
Centering a 26 DIP square in a 29 DIP band does not produce a 26 DIP button with
breathing room; it produces a jammed one. Size the band, don't squeeze the
control.

---

## 1. Spacing scale

One base unit: **4 DIP**. Every gap, pad and inset in the chrome is a member of

| Step | DIP | Used for |
|---|---|---|
| `xs` | 2 | Hairline insets, the gap inside a control between a glyph and its fill edge |
| `sm` | 4 | The default. Control-to-control gaps, container edge insets |
| `md` | 8 | Separating GROUPS of controls (the tab run from the button cluster) |
| `lg` | 12 | Card outer margins (`GlassCard.outerMargin` on Mac is 12; match it) |
| `xl` | 16 | Dialog content insets |
| `xxl` | 24 | Dialog section separation |

**No value outside this scale.** A 3 DIP pad or a 10 DIP text inset is a bug
report waiting to be filed; the current strip has both.

At fractional DPI a step is `round(dip * scale)`, and two steps that are equal
in DIP must be computed from the same constant so they cannot round apart.

---

## 2. Controls

### 2.1 Icon buttons

There is **one** chrome icon-button size, and one compact variant:

| Variant | Painted square | Hit box | Where |
|---|---|---|---|
| **Standard** | **28 DIP** | >= 32 DIP, centered on the paint | Tab strip "+", menu, close "x"; banner chevron; nav-bar controls |
| **Compact** | 20 DIP | >= 24 DIP | Dense list rows only (chooser row menus) |

Rules:

- Every icon button in one cluster paints **the same square at the same
  vertical center**. This is already asserted (`icon_button.zig`, "every icon
  button lands on ONE vertical frame") and must stay asserted.
- The **painted square keeps `sm` (4 DIP) clear on all four sides** of whatever
  band it sits in. That is what forces the band's height, not the reverse.
- The **hover fill** is a rounded rect inset `xs` (2 DIP) inside the painted
  square. It is never the hit box, and never wider than it is tall — a
  wider-than-tall fill reads as a tab, which is exactly the bug T204 fixed.
- Hit boxes may overlap the gaps between painted squares. They must never
  overlap each other.

### 2.2 Button states

Six states, one treatment, every control:

| State | Fill | Glyph / text | Notes |
|---|---|---|---|
| `rest` | none | base foreground | |
| `hover` | base +-15 per channel | base foreground | Sign: lighten in dark theme, darken in light |
| `pressed` | base +-25 | base foreground | A firmer hover, never a different hue |
| `active` | same as `hover` | base foreground | A menu button while its popup is open |
| `disabled` | none | foreground at 40% toward the background | Never just "greyer" by an arbitrary amount |
| `focused` | current state's fill | base foreground | **plus** a 2 DIP accent ring inset 1 DIP inside the painted square |

Two hard rules:

- **State is never conveyed by color alone** (WCAG 1.4.1). Focus is a ring;
  hover is a fill. A hover that only recolors a glyph — which is what the close
  "x" used to do — is not a hover.
- **Keyboard focus is always visible.** If a control can be tabbed to, it draws
  the ring. Missing focus rings are an accessibility defect, not a polish item.

### 2.3 Contrast (non-negotiable)

| Element | Minimum ratio | Standard |
|---|---|---|
| Body and label text | **4.5:1** vs its own background | WCAG 1.4.3 AA |
| Large text (>= 18.66px bold / 24px) | 3:1 | WCAG 1.4.3 AA |
| **Chrome glyphs** (+, x, hamburger, chevrons) | **3:1** vs the surface behind them | WCAG 1.4.11 (non-text contrast) |
| Control boundaries that carry meaning (dividers, focus rings, borders) | **3:1** | WCAG 1.4.11 |
| A hover fill against its rest background | perceptible, and the glyph must still clear 3:1 **on the hovered fill** | |

The last row is the one that gets missed: a +-15 shade that makes hover visible
must not push the glyph below 3:1 against the *new* fill. Check both states.

Runtime theming (user background colors, `background-opacity`, system accent)
must be re-checked against these floors, not assumed — that is what T150 is for.

A **fixed** foreground color cannot satisfy a floor, because a floor is a
statement about two colors. `chooser_rows.secondary_gray = #999999` looked like
a reasonable de-emphasized grey and was 2.8:1 on Fluent's light surface — under
both floors — so a light theme took the sublines, the status rings and the
glyphs out together (T310). Derive de-emphasized foregrounds from the surface
(`chrome_theme.textSecondaryOn`) and let the search enforce the floor.

### 2.4 Type ramp

**Three sizes, one module: `src/apprt/win32/type_ramp.zig`.**

| Role | Size | Weight | Where |
|---|---|---|---|
| Caption | **12** | 400 | sublines, subtitles, status strips, badges |
| Body | **14** | 400 | list-row titles, buttons, input fields, labels |
| Body strong | 14 | 600 | an emphasized body run |
| Subtitle | **20** | 600 | a pane's subject |

Two rules go with it:

- **Body is 14, not the system metric's 12, and that is a conscious
  divergence.** `SPI_GETNONCLIENTMETRICS` reports a 9 pt / 12 px body on
  Win11; Win11's own modern apps are at 14, and matching the GDI metric makes a
  dialog look like it shipped in 2009 next to Settings. Caption sits AT the
  system metric on purpose, so the smallest text we draw is never smaller than
  Windows' own. Reasoning and measurements: `win32-machine-chooser.md` §1.1,
  §3.2.
- **Emphasis is weight, never size.** A strong run is the same height as the
  body around it, so it cannot reflow the line box it sits in.

A line box is its role's height plus `sm` (4) of leading. Derive it — a
hardcoded 17 stops matching its text the moment the ramp moves.

The ramp exists because the number did not: `font_h = px(15, scale)` was
written out in **seven** dialogs, a size nobody chose, and the first task to
fix one copy would have made that dialog the odd one out. Same argument as
T257's chrome-geometry hoist: the duplication is not the defect, the silent
divergence it permits is.

### 2.5 Build-mode marking (T43)

A build that is **not the shipped release** — `Debug` or `ReleaseSafe`, the
same pair Mac gates its banner on — must be unmistakable at a glance, so a dev
instance is never mistaken for the user's terminal.

| Marker | Where | Rule |
|---|---|---|
| **Chrome tint** | the whole caption/tab band | The chrome background is dragged 35% toward warning amber (`chrome_theme.debugChromeBase`) **before** anything is derived from it |
| **Title suffix** | `" [DEBUG]"` | The taskbar and Alt-Tab, where the app paints no pixel of its own |

Two rules make it safe:

- **The tint goes into the BASE, never onto `Palette.bar`.** Everything
  `chrome_theme.resolve` derives — the text ramp, the accent, the danger red —
  then carries its §2.3 floor against the band that is really painted. A tint
  applied after the fact leaves every floor measured against a surface no
  longer on screen.
- **A fixed marker hue cannot mark a background that already IS that hue.** On
  an amber terminal background `mix(base, amber)` is the base again and the
  debug build looks exactly like the release one, so a second hue (violet)
  takes over below a minimum channel distance. Amber and violet are far enough
  apart that no background can defeat both — asserted, not argued.

**It is a tint and not a banner row on purpose.** Mac stacks a full-width
warning strip above the terminal; on Windows that row comes straight out of
§6's budget, which T234 and T205 had just spent two tasks reclaiming 95
physical px of. A tint costs zero rows and zero geometry — no rect moves, so no
layout module, hit test or acceptance-script datum changes with it.

**`GHOZTTY_DEBUG_MARKER=0` turns the tint off, and the GUI acceptance harness
sets it.** Those scripts run a DEBUG build and read its chrome pixels *as the
proxy for what ships*; a recolored band would move every one of those claims
onto a surface no user ever sees. That is measured, not feared — with the
marker live `tab-strip.ps1` went 8 red on a correct build, because every chrome
surface is a fixed-fraction wash of the bar and a **tinted bar is a lighter
bar, so each wash steps less far** (one failure was literally "an inactive tab
is invisible against the strip"). The default lives once, in
`test/win32/lib/TestDesktop.ps1`; `chrome-theme.ps1` re-enables it and is the
one script that owns the marker.

---

## 3. Shape

### 3.1 Corner radius

| Radius | Applies to |
|---|---|
| **4 DIP** | Icon-button hover fills, small chips, input fields |
| **6 DIP** | Tab chiclet top corners (bottom stays square: it merges into the pane) |
| **8 DIP** | Cards and overlays — banner card, TOC card, popovers |
| **0** | Full-bleed surfaces: the strip background, pane content, dividers |

Nothing else. A radius is a size signal — bigger surface, bigger radius — so a
4 DIP card or an 8 DIP button both read as mistakes.

### 3.2 Elevation

Win32 GDI has no shadow primitive, so elevation is expressed with the tools we
do have, and the levels are:

| Level | Meaning | Treatment |
|---|---|---|
| **0** | Flush chrome, part of the window surface | Tab strip, tabs, dividers. No border, no shadow. |
| **1** | Resting ON content | Banner card, TOC card. 1 px border at +8% luminance (dark) / -8% (light), plus a 2 px soft shade below. |
| **2** | Transient, floating over everything | Menus, dialogs, the chooser. Real DWM window shadow (they are HWNDs — let the OS draw it), plus the level-1 border. |

Rules: **elevation only ever increases toward the user** (a popup over a card
over the surface), a level-0 element never draws a shadow to fake depth it does
not have, and a level-2 popup never draws its own fake shadow when it is a real
window that DWM will shadow for it.

---

## 4. Glyphs

Chrome glyphs are **drawn, not typeset** — the reasoning is in
`icon_button.zig` (a missing symbol font renders as tofu; a text glyph carries
the user's font metrics, not ours). That freedom comes with the obligation to
get the geometry exactly right, because there is no font designer catching it.

### 4.1 Symmetry is by construction, not by intent

**Do not stroke glyphs with `CreatePen` + `MoveToEx`/`LineTo`.** Two GDI
behaviors make a pen-stroked mark asymmetric about its own center:

- `LineTo` **excludes the endpoint**, so a stroke from `cx-h` to `cx+h` paints
  `cx-h .. cx+h-1` — one pixel shorter on the trailing side.
- A pen wider than 1 px **centers on the path and biases** the extra pixel to
  one side (up/left) at even widths.

Together they are the "left half of the horizontal line of the plus is shorter
than the right half" report, and they are unfixable by nudging coordinates
because the bias flips with DPI.

Axis-aligned marks (+, hamburger, and any rule) are **filled rectangles** with
explicit inclusive extents. Diagonal marks (x, chevrons) are filled polygons or
anti-aliased paths. Either way the rule is:

> Every glyph's painted extent is **symmetric about its target square's center
> by construction**, and a unit test asserts `min + max == 2 * center` on both
> axes for every glyph at every supported scale.

### 4.2 Optical sizing

Equal geometric width does not mean equal apparent width. A glyph made only of
horizontal rules (the hamburger) reads **narrower** than one with a vertical
member (the plus) at the same extent — which is the user's "hamburger isn't
wide enough by maybe 2px", and they are right.

So each glyph carries its own mark width, tuned optically, and the test asserts
the *optical* relationship rather than raw equality:

| Glyph | Mark extent (DIP) | Why |
|---|---|---|
| `add` (+) | 12 | Reference |
| `close` (x) | 11 | A diagonal cross reads wider than its bounding box |
| `menu` (hamburger) | 14 | Horizontal-only marks read narrow |
| `chevron` | 12 wide, 6 rise | Shallower than a caret |
| `minimize`, `maximize`, `restore` | 10 | The caption cluster (T254). One number for all three — they sit side by side, so tuning between them would read as three sizes rather than three icons. Under `close` (11) because two of the three are *closed outlines*, and a closed outline reads larger than an open mark of the same extent |

Stroke thickness is **2 DIP** for every **open** mark (+, ×, hamburger,
chevron, the minimize rule) and **1 DIP** for a **closed outline** (maximize,
restore).

That split is an amendment (T254), not an exception. The 2 DIP rule was
written for marks where the eye reads the *stroke*; in a closed outline the eye
reads the *enclosed area*, and 2 DIP on a 10 DIP box leaves a 6 DIP interior —
the glyph reads as a filled square with a dot in it, which is exactly what the
first T254 build shipped. Windows' own `ChromeMaximize` is a 10x10 box with a
1 px stroke for the same reason. Same class of rule as the per-glyph mark
widths above: equal geometry is not equal apparent weight. Asserted as
`interior * 2 > mark_caption` in `icon_button.zig`.

**Every extent — mark and stroke alike — is rounded to the PARITY of the
square it sits in, not to an even number of pixels.** (This corrects the rule
as first written, which said "an even number of pixels so it cannot straddle a
half-pixel"; that is the right instinct applied to the wrong quantity.) A mark
centered on an integer grid has equal clearance on both sides only when
`side - extent` is even. Force that parity and the centering is exact
arithmetic; leave it to chance and the mark lands half a pixel off at roughly
half of all scales — which is the "one arm shorter than the other" defect,
reappearing. Round DOWN on a mismatch, never up, or the optical order
(`close < add < menu`) collapses at those same scales.

### 4.3 Diagonal marks: thickness is not the offset

A diagonal bar is built as a quad whose corners sit `k` pixels from the
centerline **along an axis**. At 45° its two long edges are then `2k` apart
vertically, so the thickness the eye sees is

> perpendicular = `2k / √2` = **`k · √2`**

— which is *larger* than `k`, not smaller. Reading that relation backwards
(setting `k` to a multiple of the stroke width, as though thickness were
`k/√2`) makes the arms ~2x too heavy, and an × whose arms are twice too heavy
merges into a **filled bowtie** with only its four tips showing. That shipped
for exactly one build and the user caught it on sight: *"what is wrong with the
x icon on the tab??? it should be the standard X close icon, not some weird
variant"*. So `k ≈ 3t/4 ≈ t/√2`, and a unit test asserts `|k·√2 − t| <= 1` at
every scale.

---

## 5. Dividers and split lines

| Property | Value |
|---|---|
| Visible band | **2 DIP** (not 1 — a 1 DIP line disappears at 100% and reads as an artifact) |
| Grab band | +-4 DIP either side of the visible band, invisible |
| Rest color | 3:1 against both panes it separates |
| **Hover** | Lighten by 25 per channel in dark themes, darken by 25 in light |
| Drag | Same as hover, held for the duration of the drag |
| Cursor | `SIZEWE` / `SIZENS` over the grab band |

**Hover is a color change, not only a cursor change.** A divider that reacts
only with the cursor gives no feedback to a user who is looking at the divider
rather than at the pointer, and none at all on a screenshot.

This is a **deliberate divergence from Mac**, whose divider is 1 pt: at Windows'
common fractional scales a 1 DIP band rounds to a single physical pixel that
visually vanishes against a dark pane. Recorded here so nobody "fixes" it back.

---

## 6. Vertical space is expensive

A terminal's vertical space belongs to the terminal. Chrome that is always
present must justify its height every time:

- **Do not show a control surface that has nothing to control.** A tab strip
  with one tab is 40 DIP of window spent to display no choice. The Mac client
  does not show one, and neither should this.
- Prefer **hosting chrome in space the window already spends** — the caption
  bar is already there and is mostly empty. Controls that must always be
  reachable (the window menu) belong there, left of the system minimize button.
  Since **T254** that is actually possible: `WM_NCCALCSIZE` hands the caption
  band to the client area and `caption_layout.zig` lays it out to the rules
  above (36 DIP = 4 + 28 + 4, the shared 28 DIP square, 4 DIP between painted
  edges). Before T254 the caption was stock DWM and there was no DC to draw
  into — a fact two task files disagreed about for a day.
- When a surface appears and disappears with content (the tab strip), its
  appearance must not shift the content underneath it jarringly; size the
  terminal from the space that remains, in one layout pass.

**Both bullets are now shipped, by T234.** `window-show-tab-bar = auto` shows
the strip only at 2+ tabs, and the window menu moved into the caption as a
"…" button. The two are one change and cannot be separated: the strip could not
go away while it was the app's only menu host, which is precisely what pinned
`auto => true` on Windows from T190 until T234.

Two rules the caption button had to obey, and one it had to break:

- **Different GROUPS get the next step up the scale.** The "…" is ours; the
  minimize/maximize/close trio is the OS's. Within the trio the gap is `sm` (4);
  between "…" and minimize it is `md` (8). Four evenly-spaced squares would read
  as one undifferentiated run — the same defect the "+"/"≡" pair was reported
  as. (`caption_layout.zig`, asserted in "nothing touches".)
- **It is the same 28 DIP square as everything else**, through the same
  `paintIconButton`, with the same rest/hover/pressed/active states. `active` is
  not decoration here: a menu button stays lit while its popup is up.
- **The one break: it does not get the corner.** Fitts' law says the top-right
  corner belongs to close, so the "…" sits to the LEFT of the whole system trio
  rather than nearest the edge, and its hit box does not run to any window edge.
  A destructive button and a menu button must not be reachable by the same
  careless throw of the pointer.

The visibility rule has an exception worth stating: a window with **no custom
caption** (`window-decoration = none`, and the quick terminal) has nowhere to
host the "…", so its strip stays up and keeps being the menu host. A control
surface with nothing to control may disappear; the *only* route to the app's
commands may not.

### The strongest form of the second bullet: one row, not two (T205)

"Host chrome in space the window already spends" has a limit case, and **T205**
is it: when the strip DOES have something to show, it goes **into** the caption
band rather than under it. One row of chrome, holding tabs, the "+", a drag
region, the "…" and the system trio — which is what Windows Terminal, Edge,
Explorer and VS Code all do.

Two rules fall out of it, and both are asserted:

- **Chrome that shares a row shares a baseline.** The caption buttons take
  their `btn_top` from the *strip's* own button derivation
  (`icon_button.targetBox` of `tab_strip_layout`'s `buttonHit`), not from
  centering a 28 DIP square in the 40 DIP band — the "+" and the tab close "×"
  are already on that frame (T204), and centering would land 2 px off it. The
  band's height likewise IS `tab_strip_layout.bar_h`, one number from one
  module.
- **Two painters, one row, disjoint blits.** `Layout.band_left` is the seam:
  the strip paints `[0, band_left)`, the caption paints `[band_left,
  client_w)`, and the "+"'s painted limit lands exactly on it. They fill the
  identical chrome background so the seam is invisible; what it buys is that a
  caption repaint (a hover on close) cannot erase a tab, whatever order the two
  paint in.

The alignment complaint that started this — *"the hamburger icon doesn't
horizontally align under the X above it"* — was never fixable by nudging x
coordinates. Two rows owned by two layouts can only ever *approximate* each
other, and the approximation drifts with DPI and with the caption button width.
One row makes the alignment structural. **Two rows of controls is the defect;
the misalignment is only how you notice.**

---

## 6b. Horizontal space: size to content, cap by proportion

The mirror of section 6. Where vertical chrome must justify every DIP it takes,
horizontal chrome must **use the room it already has** before it truncates
anything.

Truncating a title with 1000 px of empty strip beside it is the defect. The
rule for any run of content-bearing chrome (tabs today; breadcrumbs or chips
later):

1. **A slot's preferred width is its content's measured width plus padding.**
   Measure the text; do not assume a constant.
2. **Cap it by a PROPORTION of the container, not a fixed DIP number.** One tab
   may take up to **50%** of the available run — so on a wide window a long
   title gets 800 px, and on a narrow one the same tab yields. A fixed 200 DIP
   cap is a truncation rule disguised as a layout rule.
3. **Shrink only under pressure.** When the preferred widths do not all fit,
   fall back to equal share, clamped to `[min, cap]`, and only then truncate
   with an ellipsis.
4. **A single item never stretches to fill.** Sizing to content means a short
   title gets a short tab; the leftover strip stays empty (this is what
   Windows Terminal does and T202 correctly kept).

Note this **supersedes T202's fixed `max_tab_w = 200 DIP`**, which came from
measuring Windows Terminal's `TabWidthMode="Equal"`. The measurement was
right and the conclusion was too literal: matching a platform control's
*algorithm* is not the goal, not truncating for no reason is. Keep the
anti-stretch rule (4), replace the fixed cap with a proportional one.

Layout stays a pure function: the caller measures the strings and passes an
array of preferred widths in. Text measurement does not move into the layout
module; its INPUT grows by one array.

## 7. How to use this document

**Before** changing chrome geometry:

1. Find the rule here. If the change contradicts it, either the change is wrong
   or the rule needs updating with a reason — decide that explicitly, in the
   task, before writing code.
2. Put the numbers in a **pure geometry module** (`tab_strip_layout.zig`,
   `icon_button.zig`, `split_geometry.zig`, `banner_layout.zig`) so they are
   unit-testable with no window, no DPI and no OS.
3. Add the assertion that would have caught the defect, at **every supported
   scale** (1.0, 1.25, 1.5, 2.0). Most of these bugs are invisible at 1.0 and
   obvious at 1.25.

**Assertions this document expects to exist** (a rule with no test is a wish):

- Every painted element keeps >= 4 DIP from its container's edges and from its
  neighbours, at every scale.
- Gaps computed between painted edges equal their DIP constant, at every scale.
- Every glyph is symmetric about its target center on both axes.
- Every icon button in a cluster shares one square and one vertical frame.
- Text and glyph contrast clears its floor in both themes.
