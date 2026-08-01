# The win32 tab strip — visual spec

Status: **live** (T202 landed geometry/shape; T203 owns color, T204 owns the
control glyphs). Everything that paints the strip — `paintTabBar` in
`src/apprt/win32/Window.zig`, and the pure geometry in
`src/apprt/win32/tab_strip_layout.zig` — paints to *this* document, so the
three tasks do not each re-derive a target.

The strip is a hand-painted GDI band, not a WinUI control, so "native" here
means *measurably matching* the platform's own tab strip rather than hosting
its implementation. The reference is **Windows Terminal** (WinUI 3 `TabView`),
because it is the tab strip a Windows terminal user already has open.

## Measured reference

Windows Terminal (Windows 11, this box, primary monitor at **120 DPI = 125%**),
captured with `PrintWindow(PW_RENDERFULLCONTENT)` and read back pixel by pixel
so the numbers are observed rather than quoted from the WinUI defaults. Three
tabs, client width ~1610 px.

| Thing | Measured (px @125%) | DIP | Notes |
|---|---|---|---|
| Strip total height | 50 | 40 | WT's strip *is* the titlebar |
| Padding above the tabs | 10 | 8 | drag region |
| Tab (chiclet) height | 40 | **32** | |
| Tab width, 3 tabs, wide window | ~300 | **240** | equal share, capped |
| Top corner radius | ~8 | **6** | curve settles over 8 rows |
| Strip background | `RGB(51,51,51)` | | |
| Selected tab fill | `RGB(12,12,12)` | | **== the content background** |
| Unselected tab fill | *none* | | fully transparent over the strip |
| Separator between unselected tabs | `RGB(68,68,68)`, 1 px | | strip bg + 17 |
| Selection underline | **absent** | | there is no accent line anywhere |
| Dead strip space right of the tabs | ~700 px of 1610 | | tabs never stretch |

Two findings drove T202, and both are direct contradictions of what Ghoztty
was drawing:

1. **Tabs do not stretch.** Three tabs took 900 px of a 1610 px strip and left
   the remaining ~700 px empty. A tab's width is its equal share of the
   available strip, clamped to a maximum — it is never handed the remainder.
2. **Selection is a shape, not a line.** The selected tab is a rounded-top
   chiclet filled with the *content* background, so it merges into the pane
   below it. There is no underline, no accent bar, and unselected tabs have no
   fill at all.

WinUI's `TabView` also offers `TabWidthMode="SizeToContent"`; Terminal does not
use it (measured: two tabs with visibly different title lengths came out the
same width). Equal-share-capped is therefore what we implement, and it has the
side benefit of needing no text measurement in the layout module.

> **T235 overturned that last paragraph, and it is worth saying why.** The
> measurement was right; the inference was not. Terminal's behavior is not a
> target in itself — *not truncating a title while most of the strip sits empty*
> is. "It needs no text measurement" was the reasoning's real driver, and
> convenience is not a design rule. Ghoztty now sizes to content, capped at 50%
> of the run, and keeps the layout module text-free by having the **caller**
> measure and pass preferred widths in. Finding 1 above (tabs do not stretch)
> is untouched and permanent; finding 2 is untouched.

## What Ghoztty draws

Same idiom, with two deliberate deviations, both recorded here so a later
reader does not "fix" them back:

- **Strip height is 40 DIP**, which is also WT's measured height — arrived at
  from the other direction. It used to be 32 on the reasoning that WT's strip
  replaces the titlebar and spends 8 DIP of its height on a drag region, while
  ours sits *below* a real caption bar. That reasoning was sound and the
  conclusion was still wrong: the 8 DIP it saved came out of the buttons'
  breathing room, not out of a drag region we do not have, and the result was a
  29 DIP band holding a 26 DIP square — 1–2 px of "padding" that landed
  differently at every scale (T232). The height is now *derived*, not chosen:
  `tab_top_pad + pad_sm + icon_button.target + pad_sm` = 4 + 4 + 28 + 4.
  `tabBarHeight()` is also the scale oracle for three acceptance scripts, which
  compute `scale = barH / 40`.
  **T205 collapsed the deviation entirely**: the strip no longer sits below a
  caption bar — it IS the caption bar, exactly like WT's, complete with the
  drag region the old reasoning said we did not have. `bar_h` is now also
  `caption_layout.Metrics.caption_h` in `.with_tabs` mode, and the caption
  buttons take their vertical frame from `buttonHit`/`targetBox` here so the
  "+", the tab close "×" and minimize/maximize/close all paint on one baseline.
- **~~Maximum tab width is 200 DIP~~** (not WT's measured 240), the documented
  WinUI `TabViewItemMaxWidth` default. Our tabs carry no icon, so 200 DIP holds
  as much title as WT's 240 does. **Retired by T235**: matching a platform
  control's *algorithm* was never the goal, and a fixed DIP maximum truncated
  titles with a thousand pixels of empty strip beside them. A tab is now its
  own content's width, capped at **50% of the tab run** — a proportion of the
  container. What survives from this measurement is the anti-stretch rule (a
  tab is never handed the remainder), which was always the important half. See
  `docs/design/win32-design-system.md` §6b.

### Metrics (DIP; all scaled by the window's DPI factor)

| Name | DIP | Meaning |
|---|---|---|
| `bar_h` | 40 | strip height — *derived*: `tab_top_pad + pad_sm + 28 + pad_sm` |
| `tab_top_pad` | 4 | strip background above the chiclet, so the corner reads |
| `pad_sm` | 4 | the 4 DIP spacing step, once — every default gap reads it |
| `min_tab_w` | 60 | tabs stop shrinking here, then overflow instead — also the floor the proportional cap can never dip below |
| ~~`max_tab_w`~~ | ~~200~~ | **gone (T235)**. The maximum is `capWidth(run) = max(run / 2, min_tab_w)`, computed per layout — not a metric |
| `corner_r` | 6 | top corners only |
| `strip_pad_l` | 4 | inset before the first tab |
| `strip_pad_r` | 4 | inset after the menu button — the strip is inset the *same* at both ends. Since **T205** it is the inset to the *seam* on a merged row: the caller hands `layout` a client width of `caption_layout.Layout.band_left + strip_pad_r`, which lands the "+"'s painted right edge exactly on `band_left` |
| `group_gap` | 8 | last tab → "+", and "+" → menu, **between painted edges** |
| `btn_paint` | 28 | the PAINTED square of "+"/"≡"/"×" — every gap is measured against this |
| `btn_pad` | 2 | how far each button's hit box grows past its square, per side |
| `btn_w` | 32 | "+"/"≡" hit box = `btn_paint + 2 * btn_pad` |
| `close_btn_w` | 32 | close hit box inside a tab — the same square, the same padding |
| `text_pad` | 8 | leading title padding |
| `stripe_h` | 3 (min 2 px) | T72 user tab-color tag |

### Rules

1. **Size to content, cap by proportion** (T235, design system §6b). Each tab's
   slot is `clamp(preferred_paint + tab_gap, min_tab_w, capWidth(tabs_avail))`,
   where `preferred_paint` is the measured title plus padding — the caller
   measures the text and passes an array in, so the layout module still owns no
   font and no HDC. If the slots all fit, every tab gets its own; the leftover
   strip stays **empty**, never stretched. Only when they do not all fit does
   the strip fall back to `tab_w = clamp(tabs_avail / tab_count, min_tab_w,
   capWidth(tabs_avail))` applied to **every** tab including the last, and only
   then does `DT_END_ELLIPSIS` truncate. There is no remainder rule in either
   branch.
2. Tabs may occupy only up to `group_gap` short of where the "+" would sit at
   its rightmost allowed position, so a tab can never be painted under the
   button band. When even `min_tab_w` will not fit them all, the ones that do
   not fit are **not laid out at all** (zero rect ⇒ invisible ⇒ unhittable),
   rather than drawn off the end.
3. The "+" follows the last tab, `group_gap` after it, until it reaches its
   limit (`group_gap` before the menu button); the menu button is pinned to the
   right edge. With few tabs the two controls are far apart, which is the point
   — they are different groups (WinUI: `AddTabButton` vs `TabStripFooter`).
4. The selected tab is a rounded-top chiclet in the content background. No
   underline. Unselected tabs paint nothing; hover paints the same chiclet in
   the hover fill.
5. A 1 px vertical separator sits between two adjacent tabs when neither is
   selected or hovered, vertically inset to the middle ~50% of the chiclet.
6. The T72 tab-color stripe is clipped to the chiclet, so it takes the rounded
   corners instead of squaring them off.

### What lives where

- Geometry: `src/apprt/win32/tab_strip_layout.zig` (pure, unit-tested in the
  `-Dapp-runtime=none` lane). One `layout()` call produces the tab rects, the
  "+" rect and the menu rect; painting and all three hit tests consume it, so
  they cannot drift apart.
- Painting: `paintTabBar` in `src/apprt/win32/Window.zig`.
- On-box validation: `test/win32/tab-strip.ps1`.
