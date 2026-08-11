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

**Where a CONVENTION names the foreground, cap the fill instead of searching
the foreground** (T528). The close button's X is white on its red hover in
every native Windows window, so white is the spec and the only free variable
left is the red. Letting the search decide the foreground instead produced a
**black** X on a mid-dark band — legally, at 4.9:1 — because the red had
already been lightened past white's reach on its way to clearing 3:1 off the
band. Two correct rules, one wrong button, and no floor to catch it.

So the destructive FILL and the destructive MARK are two derivations, not one
color used twice:

| Palette entry | Role | Rule |
|---|---|---|
| `danger` | a FILL under a white glyph (caption close hover, the connection pill's Reconnect) | luminance capped so **white** clears 4.5:1 on it (`chrome_theme.dangerFillOn`) |
| `on_danger` | the foreground on `danger` | **white**, always |
| `danger_ink` | a red MARK on the band (the tab strip's close glyph) | 3:1 off the bar like any other chrome glyph |

The general form: when a fill's foreground is fixed by convention, the fill is
what must move. Where the cap and the 3:1 lift cannot both hold — a band around
`#2F2F2F`..`#595959`, where no red is light enough to clear the band and dark
enough to carry white — the convention wins and the fill sits at the cap. A red
slab still reads as a red slab against a grey band, which no luminance ratio
measures; a black X on it is a defect a user reports.

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

A line box is its role's height plus `sm` (4) of leading, and that too is one
call: **`type_ramp.lineBox(font, scale)`** (T313). Derive it — a hardcoded 17
stops matching its text the moment the ramp moves, and `BannerDialog`'s flat 16
around a 15 px label is what that looks like before it breaks: a fit by
coincidence, one ramp change away from clipping.

A line box is for a box that HOLDS TEXT. It is not the sizing rule for an
interactive row — a combo item, a list row, a button — which is sized to what it
must hold plus its own padding (§0's corollary). `HostSettingsDialog`'s
`item_h = font_h + px(6)` is deliberately not a line box for that reason.

The ramp exists because the number did not: `font_h = px(15, scale)` was
written out in **seven** dialogs, a size nobody chose, and the first task to
fix one copy would have made that dialog the odd one out. Same argument as
T257's chrome-geometry hoist: the duplication is not the defect, the silent
divergence it permits is. All seven read the ramp as of T313 (T310 did the
chooser surface; T313 the rest) — including the SIZE, the WEIGHT and the FACE,
because a dialog that takes its size from the ramp and hardcodes `600` beside
it has only moved where the divergence hides.

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

**One named exception: a STATUS CHIP is a capsule** — radius exactly half its
own height, so its ends are semicircles at every scale rather than a rounded
rect at some of them. It applies to the small mark-plus-label chips that report
a state rather than offering a command: the chooser's session badges
(`chooser_sessions`), and the remote connection pill in the caption band
(`remote_pill`, T367). Their height is likewise derived and not picked — one
caption line box plus the 4 DIP step — so the chip follows the type ramp
instead of pinning a number that stops matching its text. A chip on the fixed
scale would read as a small button, which is precisely what these are not (the
connection pill is only a button in ONE of its three states, and that is the
state where it changes color and grows a verb).

**A second named exception: the FEEDBACK COMPOSER PILL is a capsule** — the
viewer pane's feedback input (`viewer_feedback_layout.zig`, T634). By the table
above an input field is 4 DIP, and this one deliberately is not, for two
reasons. The shape is what says *chat composer* rather than *form field*, which
is the whole affordance; and Mac's composer is a capsule, so a 4 DIP box here
would be a viewer that reads as a different product on the two platforms — the
divergence this project does not ship.

Its radius is **half the COLLAPSED pill height**, pinned, not half the current
height. A radius recomputed at every height stops being a pill and becomes an
oval the moment the text grows to two lines; pinning it lets the straight sides
lengthen while the caps stay exactly as round as they started. (Mac writes the
same rule out in `ViewerFeedbackBar.pillCornerRadius`, and both are asserted.)

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

### 3.3 Card material: hand-composited, lit from one overhead point

An in-pane card (banner, TOC) is **not** a system backdrop — no Mica, no
Acrylic, no `DwmSetWindowAttribute` backdrop (T124). Two reasons, and the
second is the disqualifying one:

- A system material re-renders when the window's key state changes, so the
  card visibly shifts color every time you switch windows, and its frost
  washes the pane's hue toward grey. (Mac reached the same verdict about
  `glassEffect` and hand-draws `GlassCardBackground` for exactly this.)
- Mica and Acrylic sample what is **behind the window** — the desktop. A card
  floating inside a pane must be tinted off the **pane**, which is the one
  surface those materials cannot see.

So the card is composited once into a DIB over the pane's own background
(`banner_card.render`), which also keeps the overlay window fully opaque —
nothing behind it can bleed through.

Its two speculars are **elliptical gradients centered half a card-height
ABOVE the card**, horizontally centered: a sheen bulging down into the top,
and the hairline rim lit by the same point. Not a vertical ramp. A ramp that
varies only with height lights the far ends of a wide banner exactly as
brightly as its middle, which reads as a painted stripe rather than a lit
surface — and a banner spans the whole pane, so "wide" is the normal case.
The radii are fractions of the card's own width and height, so the falloff is
identical at any banner width and at any DPI (asserted at 1.0/1.25/1.5/2.0).

Consequence worth knowing: the gradient's first stop sits at the ellipse's
center, which is off the card, so **no pixel is ever lit at the first stop's
alpha**. Anything reading `banner_card.RIM_TOP` as "the brightness of a top
edge" is wrong by about 35%.

---

## 4. Glyphs

Chrome glyphs render **the system icon font first** — Segoe Fluent Icons on
Windows 11, Segoe MDL2 Assets on Windows 10 — and fall back to the hand-drawn
quads only when neither face is actually present (T497). The user's verdict on
the drawn marks was direct: *"our icons look chunky and don't really feel
native to the platform ... We should absolutely feel native like it was built
by microsoft using their design language."* A 2 DIP filled mark with square-cut
ends cannot read like a 1 px Fluent stroke, so on any normal machine the
chrome now draws Microsoft's own glyphs at fixed DIP sizes (`icon_button_paint`:
the caption cluster and tab close at 10, the strip/banner marks at 12), in
grayscale AA, colored by the same state machine as before. Presence is
**proven** (create/select/`GetTextFace`), never assumed — "ships with" is not
"is present", and tofu in a chrome button is worse than a heavier chevron.

The rules below govern the DRAWN FALLBACK (and any future glyph the icon font
lacks). They still matter: the fallback is what a stripped-down VM shows, and
its geometry discipline is why nobody notices the swap. The freedom of drawing
by hand comes with the obligation to get the geometry exactly right, because
there is no font designer catching it.

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

**The same rule, running the other way, on any SLOPED arm.** A mark whose band
is offset **vertically** by `t` — the banner's collapse chevron, the back and
forward arrows transposed from it, the roof of the home icon — paints a
perpendicular thickness of `t · cos θ`, which is *smaller* than `t`. It is the
identical error to the ×'s, mirrored: measuring thickness down a screen axis
instead of across the mark. The chevron's arms run 6 across and rise 4, so they
painted `0.83 · stroke_w` and read as a faded version of the "+" beside them
(T239). The correction is one shared helper, `icon_button.slopedStroke(run,
rise, t)`, which returns the vertical offset whose perpendicular band is `t`:

> `tv = t · hypot(run, rise) / run`

Note it is a **no-op below ~200% scaling** — the correction is a fraction of a
pixel there and a mark cannot be painted in fractions of one. That is not a
reason to skip it: the deficit grows with `stroke_w`, so it is exactly the
high-DPI screens where the odd glyph out is obvious.

The general rule both halves share, and the one to apply to any new mark:
**thickness is measured perpendicular to the mark, never down a screen axis.**
The unit test is written that way too — it measures every open glyph's quads as
parallelograms (`area / long side`) and asserts each lands within a pixel of
`stroke_w` at every scale from 1.0 to 3.0, so a new glyph that gets this wrong
fails without anyone having to remember the rule.

---

## 5. Dividers and split lines

| Property | Value |
|---|---|
| Visible band | **2 DIP** (not 1 — a 1 DIP line disappears at 100% and reads as an artifact) |
| Grab band | +-4 DIP either side of the visible band, invisible |
| Rest color | 3:1 against both panes it separates — **enforced**, see below |
| **Hover** | Lighten by 25 per channel in dark themes, darken by 25 in light |
| Drag | Same as hover, held for the duration of the drag |
| Cursor | `SIZEWE` / `SIZENS` over the grab band |

**Hover is a color change, not only a cursor change.** A divider that reacts
only with the cursor gives no feedback to a user who is looking at the divider
rather than at the pointer, and none at all on a screenshot.

This is a **deliberate divergence from Mac**, whose divider is 1 pt: at Windows'
common fractional scales a 1 DIP band rounds to a single physical pixel that
visually vanishes against a dark pane. Recorded here so nobody "fixes" it back.

**The 3:1 row is a rule the product applies, not advice to the user** (T251).
`split-divider-color` is an unconstrained color, so `#0a0a0a` on a black
terminal is a divider at 1.10:1 — invisible — whose hover shade (#232323) is
invisible too. The control and its feedback both disappear, which is exactly
what the §2.3 floor for "chrome glyphs and meaningful boundaries" exists to
prevent, and a divider is a meaningful boundary: it is the thing you grab to
resize a split. `split_geometry.dividerPaint` therefore lifts the color to the
floor **at paint time**, so the config value round-trips unchanged — the same
shape `min-contrast` uses for terminal text, and the same call the project
already made for under-contrast palette entries in T150/T247.

A **second deliberate divergence from Mac**, where `splitDividerColor`
(`Ghostty.Config.swift`) fills the raw value and checks nothing. Recorded here
for the same reason as the 2 DIP band.

Two consequences worth stating, because they are what makes the rule
implementable rather than aspirational:

- **The floor is absolute; the hover MAGNITUDE is what gives way.** A color can
  be squeezed between the two — `#f0f0f0` on a `#808080` background sits at
  3.47:1 with 15 units of headroom to white and only ~14 before the darker side
  drops through 3:1 — and then the hover is the largest shade that is still
  legal, not 25. A hover 10 units short still reads as a state change; a hover
  under 3:1 has stopped reading as a divider.
- **The hover re-aims when its conventional direction is exhausted.** A rest
  color clamped at the end of the channel range (white on a dark theme) would
  otherwise shade to itself. Legibility of the control outranks the
  §5 direction convention in that corner, and only there.

**Every divider in the window obeys the width and the color** — including the
hero-mode divider between the hero pane and its carousel, which is the same
2 DIP mark, reads the same `split-divider-color` (via `Window
.dividerConfiguredColor`, floored by `dividerPaint` against the carousel band
rather than a pane), and is centered in hero mode's own wider 6 DIP grab band
(T250). Until then it was 1 DIP with a color derived from the band, so one
window showed two dividers of two widths and a themed divider was themed on one
side of it and not the other.

The ONE thing it does differently is the hot state: hover and drag paint the
**accent**, not the ±25 shade. That is deliberate hero-mode behavior, cited
rather than assumed — Mac fills this divider with `Color(red: 0.416, green:
0.416, blue: 1.0)` while hovered or dragged
(`macos/Sources/Features/HeroMode/HeroModeView.swift:117`) — and T305 replaced
the ported copy of that literal with the user's own accent, floored to 3:1
against the band. A carousel is a selection surface and its accent already
means "this one"; the divider joining it reads as part of that surface.

---

## 5b. A color change goes through `WM_PAINT`; `GetDC` is only for a region nothing will invalidate (T252)

Chrome here is painted two ways, and the choice is not a style preference:

| | What it is | When it is right |
|---|---|---|
| `InvalidateRect` + `UpdateWindow` | Mark the region dirty, let `WM_PAINT` derive the pixels from state | **Default.** Anything whose appearance changed: a hover, a config re-color, a caption whose content moved |
| `GetDC` + draw + `ReleaseDC` | Draw straight to the window DC, outside the paint cycle | Only when nothing will ever invalidate that region — a band that MOVED, whose old pixels a child window now covers |

The test is **"did the region move, or did its color change?"** — not "is this
cheaper". A `GetDC` paint is not reproducible: nothing recorded that the region
needs drawing, so those pixels stand only until the first `WM_PAINT` that covers
them, and then whatever the paint routine derives from state replaces them. When
the state IS the source of truth (it always is here — `paintDividers` reads the
config and the hover handle), invalidating is both shorter and self-healing, and
the shortcut buys nothing.

Two call sites in `Window.zig` looked identical and were not, which is the
whole reason this is written down: `layoutSplits` paints dividers via `GetDC`
after `MoveWindow`ing every pane (a moved band — legitimate, and commented as
such at the call site), while `onConfigChange` used the same three lines for a
`split-divider-color` re-color where nothing moved. That one is now
`refreshAllDividerBands`.

A third case is allowed and is neither of the above: an **overlay on a control
we do not own** (`ViewerFeedbackBar`'s quote bars and placeholder over a
RichEdit). The control validates its own region inside `CallWindowProcW`, so
there is no cycle left to join; what makes it safe is that the paint is *driven
by* `WM_PAINT`, so it is reproduced on every repaint like anything inside the
cycle.

**What this rule is NOT about is capture visibility.** T233 recorded that
`GetDC` pixels "never reach the backing store" and are therefore invisible to
`PrintWindow` — the capture every acceptance script on the T211 background
desktop uses. Re-measured for T252 (2026-08-11, three builds of
`split-divider.ps1`): they are visible. With `paintWindow`'s divider pass
compiled out and only the `GetDC` painters left, the capture read both the
startup red band and a live re-color to cyan; the control build with neither
painter kept the stale red. What actually made T233's hover invisible is that
the hover STATE does not survive on that desktop — a posted `WM_MOUSEMOVE` sets
it and the OS posts `WM_MOUSELEAVE` within a frame, because `TrackMouseEvent`
watches a real cursor that is not there. `split-divider.ps1`'s own header says
so, and its hover oracle is the debug log for exactly that reason. Keep the
paint rule; drop the reason, because a wrong reason sends the next reader
hunting a capture bug that is not there.

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
  band to the client area and `caption_layout.zig` lays it out. (Since T496
  the standalone band is the native 32 DIP caption height, not a number
  derived from the app's button square — see the trio exception below.)
  Before T254 the caption was stock DWM and there was no DC to draw
  into — a fact two task files disagreed about for a day.
- When a surface appears and disappears with content (the tab strip), its
  appearance must not shift the content underneath it jarringly; size the
  terminal from the space that remains, in one layout pass.

**Both bullets are now shipped, by T234.** `window-show-tab-bar = auto` shows
the strip only at 2+ tabs, and the window menu moved into the caption as a
"…" button. The two are one change and cannot be separated: the strip could not
go away while it was the app's only menu host, which is precisely what pinned
`auto => true` on Windows from T190 until T234.

### The system trio is native, the "…" is ours (T496)

The minimize/maximize/close trio is a **NAMED platform exception** to the
28-square / 4-DIP-gap rules: it paints as **native Windows 11 caption
buttons** — 46 DIP wide, full band height, flush to the window's top and right
edges, ZERO gaps between them, rectangular hover/pressed fills (square
corners, no inset), close hovering the palette's `danger` red with its
**white** `on_danger` glyph (§2.3 — the convention names that foreground, so
the red is what the contrast search may move). T254 originally drew the trio as the app's own rounded
squares; the user saw it against a real Win11 titlebar and overrode it
(2026-08-05): *"the minimize/restore/close buttons at the top right do not
match the windows 11 look and feel. This makes the app seem off."* The trio
belongs to the OS, so it is drawn to the OS's ruler — which is exactly the
split Edge and Explorer ship (their own controls get small rounded hovers; the
system trio is slabs).

The app's own "…" stays inside the design system:

- **It is the same 28 DIP square as everything else**, through the same
  `paintIconButton`, with the same rest/hover/pressed/active states. `active`
  is not decoration here: a menu button stays lit while its popup is up.
- **Different GROUPS get the next step up the scale**: `md` (8) between the
  "…" and the minimize slab. Since the two groups now speak different visual
  languages, the separation is what keeps the seam readable.
- **It does not get the corner.** Fitts' law says the top-right corner belongs
  to close — and since T496 the corner is *painted* close, not merely
  hit-tested close. A destructive button and a menu button must not be
  reachable by the same careless throw of the pointer.

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

- **Chrome that shares a row shares a baseline.** The APP's buttons in the
  band — the "…" — take their `btn_top` from the *strip's* own button
  derivation (`icon_button.targetBox` of `tab_strip_layout`'s `buttonHit`),
  not from centering a 28 DIP square in the 40 DIP band — the "+" and the tab
  close "×" are already on that frame (T204), and centering would land 2 px
  off it. The band's height likewise IS `tab_strip_layout.bar_h`, one number
  from one module. (The system trio ignores the baseline on purpose: native
  slabs span the band's full height, T496 — exactly what Windows Terminal's
  caption buttons do in its tab row.)
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

**Over a tab there is NO top resize edge — the tab owns its full height, and
that is measured parity (T266).** A merged row puts the window's top resize
band ON the tabs, and the question of how much of a tab the frame may claim
was settled empirically, 2026-08-06, against a live `WindowsTerminal.exe`
1.24 at 125%: WT's tab **island child** answers `HTCLIENT` from the window's
very top row at a tab's x — the user's mouse never reaches the top-level
window over a tab, so a WT tab owns every one of its rows. The top resize
edge lives only in the **empty drag band** (WT's drag-bar child, which starts
right of the tab run, answers `HTTOP` there — 7 rows at 120 dpi, slightly
under the 9-row `SM_CYSIZEFRAME + SM_CXPADDEDBORDER` metric) and in the
**corners**. `caption_layout.ncHitTest` mirrors that: between the corners the
frame stops at `min(client_right, band_left)`; over the empty band and the
caption's own controls it keeps the full system metric (the stock-frame
convention — WT's private 7 is not a metric anything else uses). Measurement
method matters: `WM_NCHITTEST` sent to WT's *top-level* window answers
`HTTOP` over the tab run too, but that region is covered by the island child,
so the parent's answer is unreachable — probe the child the mouse actually
lands on. Pinned from both sides in `caption_layout` (T266 tests, all four
scales) and probed live in `chrome-merged-row.ps1` §4.

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
5. **Grow with the content, shrink only at a structural relayout** (T249). The
   moment a slot's width is a function of a string, it is a function of however
   often that string changes — and in a terminal the answer is "every command".
   Windows' own `cmd.exe` retitles itself `<cmd.exe path> - <command>` for the
   duration of each command, with nothing configured; measured on 2026-08-11,
   one `ping` moved the next tab and the "+" **186 px out and 186 px back**, and
   the point that had been that tab's centre sat inside its neighbour while the
   command ran, so a click there selected the wrong tab. Across realistic shell
   titles the swings reached 30% of the window width.

   So the run keeps a per-slot **high-water width**. A slot widens the instant
   its content needs the room — refusing that is rule 3's ellipsis with strip to
   spare, which is the defect this whole section exists to name. It narrows only
   when the run is being re-laid-out anyway: an item added or removed, the
   container resized, the DPI changed, the order changed. That is the honest
   split — the grow happens as the user acts, the shrink fires later,
   attributable to nothing, and an unattributable move is what walks a click
   target out from under a stationary pointer.

   **The ratchet is released, never allowed to truncate.** Once the high-water
   marks no longer fit, every slot drops back to its measured preference; rule 3
   is the only thing that may ever ellipsize. A marked width outliving the
   string that earned it must not squeeze the run.

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
