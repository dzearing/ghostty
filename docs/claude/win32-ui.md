# Windows UI: design-system enforcement summary

> Progressive-disclosure doc routed from `/CLAUDE.md`. Load this — together
> with the full rulebook `docs/design/win32-design-system.md` — before
> changing any pixel of win32 chrome (tab strip, banner, dialogs, chooser,
> menus, split dividers).

## Windows UI: the design system is mandatory

**Before changing any pixel of the win32 chrome — tab strip, banner, dialogs,
chooser, menus, split dividers — read `docs/design/win32-design-system.md`.**
It is the rulebook, not a style suggestion, and a control that invents its own
spacing, sizing, radius, hover treatment or glyph geometry is a defect even
when it looks fine in isolation. The defect is the inconsistency.

The short version, all of which is enforceable and most of which is already
asserted in the pure geometry modules:

- **One 4 DIP spacing scale** (2/4/8/12/16/24). No value off the scale.
- **Nothing touches anything.** >= 4 DIP between any two painted elements and
  between an element and its container's edge. Deliberate merges (the selected
  tab chiclet into the pane) are named in the doc; there are no others.
- **Gaps are measured between PAINTED edges, never hit boxes.** A hit box may
  be larger than its paint, but it is invisible and never contributes a gap.
- **Size the container to the control**, not the reverse — centering a 26 DIP
  square in a 29 DIP band yields a jammed control, not a padded one.
- **One icon-button size** (28 DIP painted square, >= 32 DIP hit box), one
  fill treatment, one set of states (rest/hover/pressed/active/disabled/
  focused). State is never color alone; focus is always visible.
- **Contrast floors:** 4.5:1 text, **3:1 for chrome glyphs and meaningful
  boundaries** (WCAG 1.4.11), re-checked on the hovered fill too.
- **Radius scale** 4 (buttons) / 6 (tab chiclet top) / 8 (cards), and three
  elevation levels with shadows only where the level allows one.
- **Glyphs are filled shapes, never `LineTo` pen strokes** — `LineTo` drops the
  endpoint and wide pens bias one side, which is how a "+" ends up with one arm
  shorter than the other. Symmetry is asserted, not intended. Mark widths are
  tuned **optically** per glyph (a hamburger reads narrower than a plus at the
  same extent).
- **Dividers are 2 DIP** with a real hover color change (lighten in dark,
  darken in light) — not a cursor change alone.
- **Vertical space belongs to the terminal.** Chrome that controls nothing does
  not appear (no tab strip at one tab); always-reachable controls belong in the
  caption bar, which the window already pays for.
- **Horizontal chrome sizes to content, capped by PROPORTION** (a tab may take
  up to 50% of the run), never by a fixed DIP number that truncates a title
  while the strip sits half empty.

Put numbers in the pure geometry modules (`tab_strip_layout.zig`,
`icon_button.zig`, `split_geometry.zig`, `banner_layout.zig`) and assert them at
1.0, 1.25, 1.5 and 2.0 — most of these defects are invisible at 1.0 and obvious
at 1.25.

