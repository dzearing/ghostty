# win32 machine chooser — the measured target (T302)

**Status:** the agreed spec for the Ctrl+Shift+N surface. T227 paints to this
document; so does anything that touches `MachineChooser.zig`,
`chooser_layout.zig`, `chooser_rows.zig`, `chooser_menu.zig`,
`HostSettingsDialog.zig`, or `RelayAccountRow.zig` afterwards.

It is the `win32-tab-strip.md` analog for the chooser, and it exists for the
same reason: T202 stopped the tab strip being argued about by writing the
numbers down once, so every later task painted to one agreed target instead of
to an opinion. Read `win32-design-system.md` first — it is the rulebook, and
where a number here is on its scale it says so rather than restating it.

The bar this serves is the user's, 2026-07-31, verbatim:

> "Your idea of parity is not the same as mine. I mean, pixel parity, the UX
> looks and feels cohesive and polished and scrubbed, and it isn't just buttons
> that exist in the same place, but it looks like a posh win32 version of the
> MacOS app. The borders look nice. There's a master details view. There are
> ways to get to the activity viewer."

**"Posh win32 version" is the operative phrase.** Not a pixel-cloned macOS
dialog running on Windows: the *structure*, *proportions* and *behavior* come
from Mac, and the *type, metrics, accent, focus and theme* come from Windows.
Every row of every table below is labeled with which side it takes.

---

## 0. Sources, and what each one is worth

Three sources, in descending order of authority. A claim in this document must
name which one it came from, because they are not equally trustworthy.

| # | Source | What it is good for | How it was obtained |
|---|---|---|---|
| **S1** | `macos/Sources/Features/Remote/MachineChooserView.swift` | Structure, proportions, composition, behavior | Read out of the source with line cites. This is exact — SwiftUI states its own metrics numerically. |
| **S2** | The live Windows box | The native type ramp, system metrics, accent, theme state | Measured 2026-08-01 via `SystemParametersInfoForDpi(SPI_GETNONCLIENTMETRICS)`, `GetSystemMetrics`, `uxtheme` and the DWM registry. Exact for this box. |
| **S3** | Microsoft's published Fluent/WinUI type ramp and control metrics | The Win11 *idiom* — what a modern Windows app looks like, as opposed to a 2009 GDI dialog | Documented, **not measured**. Every use is labeled `(S3, documented)`. |

### The method that did NOT work, and why it is not worth retrying

T227 specified source #2 as *"a real Win11 master-detail dialog (Settings, Task
Manager) captured through `Get-TestWindowPixels`"*. **That does not work, and it
fails silently.** Measured on the box:

- `PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)` against Task Manager's main
  window returns **a flat black bitmap** — 1379x1134, exactly **one** distinct
  color over a 7px sampling grid. The call succeeds; the seam scan then found
  zero vertical edges, which reads as "no master-detail seam" rather than as
  "no capture".
- The reason is architectural, not a bug to work around: Task Manager, Settings
  and every other Win11 master-detail app are **WinUI/XAML**, which composites
  through DirectComposition rather than painting into the window DC. There is
  nothing for `PrintWindow` to copy. This is the same class of limit T214
  recorded for `GhozttyTerminal` — and it has the same failure mode, a capture
  that is *empty rather than absent*, so assertions pass against nothing.
- The Win32 apps that *do* capture cleanly (classic dialogs) are precisely the
  ones that do **not** show the Win11 idiom, so a capture that works is a
  capture of the wrong thing.

So the Win11 reference in this document is split deliberately: everything
queryable is **measured (S2)**, and the Fluent language is **cited as
documentation (S3)** and never presented as a measurement. **Do not file a task
to "capture Settings properly."**

A second, cheaper lesson from the same probe: **Task Manager launches
elevated, so a non-elevated session cannot close it again** — `Stop-Process`,
`CloseMainWindow` and `taskkill` all return Access Denied. A reference fixture
you cannot clean up is a bad fixture. Prefer a fixture the test owns.

---

## 1. What Windows actually measures (S2)

All measured on this box, 2026-08-01, dark app theme.

### 1.1 The system type ramp

`SPI_GETNONCLIENTMETRICS` via `SystemParametersInfoForDpi`, so these are the
per-DPI values Windows itself hands a well-behaved app:

| DPI | scale | message / caption / menu / status font |
|---|---|---|
| 96 | 1.00 | Segoe UI, **12 px**, 9 pt, weight 400 |
| 120 | 1.25 | Segoe UI, **15 px**, 9 pt, weight 400 |
| 144 | 1.50 | Segoe UI, **18 px**, 9 pt, weight 400 |
| 192 | 2.00 | Segoe UI, **24 px**, 9 pt, weight 400 |

Every role — message box, caption, small caption, menu, status — is the same
9 pt Segoe UI on this box. There is no system-provided ramp; a ramp has to be
chosen, which is what §3 does.

### 1.2 System metrics and theme parts

| Metric | Value @96 | Note |
|---|---|---|
| `SM_CYCAPTION` | 23 | |
| `SM_CXVSCROLL` | 17 | scrollbar width; `iScrollWidth` 17/21/26/34 across the four DPIs |
| `SM_CXSMICON` / `SM_CYSMICON` | 16 / 16 | the size a row glyph should read at |
| `SM_CXBORDER` / `SM_CYBORDER` | 1 / 1 | |
| `SM_CXEDGE` / `SM_CYEDGE` | 2 / 2 | |
| `iCaptionHeight` | 22 / 28 / 33 / 44 | across 96/120/144/192 |
| `iPaddedBorderWidth` | 4 / 5 / 6 / 8 | across 96/120/144/192 |
| `BUTTON` / `PUSHBUTTON` content margins | L3 R3 T3 B3 | uxtheme, TS_TRUE |
| `COMBOBOX` / `BORDER` content margins | L3 R3 T3 B3 | uxtheme |

`uxtheme` has **no** Win11 answer for `LISTVIEW/LISTITEM` (size and content
margins both return `n/a`) and its `LISTVIEW` fill colors come back `#FFFFFF`
for every state including `selected` — i.e. the classic-theme parts, not the
Fluent list. **Do not source list-row metrics or list colors from uxtheme.**

### 1.3 Accent and theme

| Key | Value on this box |
|---|---|
| `HKCU\Software\Microsoft\Windows\DWM\AccentColor` | `0xFF810068` (ABGR) → **`#680081`** |
| `...\Themes\Personalize\AppsUseLightTheme` | `0` (dark) |
| `...\Themes\Personalize\SystemUsesLightTheme` | `0` (dark) |

The accent on this box is a **purple**, which matters: the chooser currently
hardcodes a blue (`#3D8EF8`). Nothing about the surface is currently connected
to the user's accent, and a purple-accented desktop makes that obvious at a
glance. That connection is **T203's** job (system accent + light/dark), not
this document's — see §6.

### 1.4 The Fluent ramp (S3, documented — not measured)

Used below only where S2 has no answer:

| Role | Size | Weight |
|---|---|---|
| Caption | 12 px | 400 |
| Body | 14 px | 400 |
| Body Strong | 14 px | 600 |
| Subtitle | 20 px | 600 |
| Title | 28 px | 600 |

---

## 2. What Mac actually measures (S1)

Every number below is read out of `MachineChooserView.swift`; the line is the
cite. Values are SwiftUI points, which map 1:1 to DIP.

### 2.1 The shell

| Element | Mac value | Line |
|---|---|---|
| Dialog | **840 x 540**, fixed | 270 |
| Account header pad | 16 horizontal, 10 vertical | 251-252 |
| Header rule | `Divider()` under the account row | 253 |
| Master column width | **260**, fixed | 259 |
| Master column wash | `Color.primary.opacity(0.035)` | 260 |
| Column rule | `Divider()` between master and detail | 261 |
| Footer rule + footer | `Divider()`, then Cancel alone at 16 all round | 267, 737-742 |

The account area is at the **top**, above the master-detail split, "because
account state is a global affordance" (244-246); the footer is Cancel and
nothing else (733-735); the primary action lives in the **detail pane**, not
the footer.

### 2.2 Master column

| Element | Mac value | Line |
|---|---|---|
| Filter field pad | 14 top + horizontal, 10 bottom | 329-330 |
| Row list inset | 8 horizontal, 8 bottom | 343-344 |
| Row-to-row spacing | **2** (`VStack(spacing: 2)`) | 338 |
| Row pad | 8 horizontal, 6 vertical | 376-377 |
| Row corner radius | **6** | 379 |
| Row selected fill | `accent.opacity(0.25)` | 92 |
| Row hover fill | `primary.opacity(0.06)` | 94 |
| Status column width | **12**, reserved in every row | 997 |
| Status glyph | 9 px semibold, shape-coded (filled / hollow / dotted) | 1089, 1074-1096 |
| Icon column width | **28**, fixed so text never drifts | 1001 |
| Status→icon→text gap | 8 | 1007, 1025 |
| Title / subtitle | `.body` / `.caption` secondary, 2 apart | 1015-1021 |
| Count badge | `.caption2` in a capsule, pad 6 h / 1 v, `secondary.opacity(0.18)`, 6 leading | 177-185 |
| Refresh status strip | `.caption` secondary, pad 14 h / 8 v | 403-406 |

### 2.3 Detail pane

| Element | Mac value | Line |
|---|---|---|
| Pane pad | **16** all round | 496 |
| Identity → action row gap | **14** | 441 |
| Glyph column | 30 wide, 22 pt symbol, secondary | 443-446 |
| Glyph → text gap | 12 | 442 |
| Title | `.title3` semibold, 1 line | 449-450 |
| Title → subtitle gap | 2 | 447 |
| Subtitle | `.caption` secondary, "N sessions · host" | 521-540 |
| Action row gap | **8** | 456 |
| Action order | primary (prominent, default action) → Restore All? → Activity? → `…` menu? | 456-492 |
| `…` menu | borderless, indicator hidden, `fixedSize()` — a glyph, not a command | 483-490 |
| Session list | rows 6 apart, list pad 16 | 548, 590 |
| Session row | pad 12 h / 9 v, radius **8**, fill `accent.opacity(0.16)` selected / `primary.opacity(0.04)` rest, 1 px stroke `accent.opacity(0.55)` when selected | 689-698 |
| Session liveness dot | 8 px, green alive / secondary dead, 4 from top | 624-627 |
| Session pills | `.caption2` capsule, pad 6 h / 1 v, `color.opacity(0.18)` (`0.15` for secondary) | 716-722 |
| Empty state | 28 pt glyph tertiary + "No machines" secondary, centered | 423-432 |

### 2.4 Account row

| Element | Mac value | Line |
|---|---|---|
| Signed in | email (`.caption`, secondary, **middle**-truncated, max 240 wide, right-aligned) over a **link**-styled "Sign Out", 1 apart; a **34 px circle avatar** to their right, 10 away | 903-916 |
| Avatar | Google picture when present, else a **monogram**: accent-gradient circle, first letter uppercased at `size * 0.42` semibold white | 942-976 |
| Signing in | small spinner + "Waiting for browser sign-in…", `.caption`, 6 apart | 918-925 |
| Signed out | a plain bordered "Sign In with Google" button | 926-927 |
| Unconfigured | `.caption` secondary pointing at the setup doc, 2 lines | 928-932 |

### 2.5 Host Settings

Mac renders it as an **`NSAlert` accessory view**, not a dialog of its own
(1143-1185): label column 120 right-aligned, 8 gap, field column 240, fields
24-26 tall, an editable `NSComboBox` of shell presets with `completes = true`,
placeholder "Remote default", Save / Cancel. Rename (1217-1229) and Remove
(1191-1203) are likewise `NSAlert`s, Remove flagged `hasDestructiveAction`.

---

## 3. The reconciled target

Where the two sides disagree, this is the ruling and the reason.

### 3.1 Take from Mac (structure and proportion)

- **840 x 540 fixed**, master 260, account row on top, Cancel alone in the
  footer, primary action in the detail pane. Already true; keep it.
- Row composition: reserved 12 status column → 28 icon column → title over
  subtitle → trailing count badge. Row-to-row rhythm 2.
- Detail pane 16 all round, 14 between identity and actions, action gap 8,
  action order primary → Restore All → Activity → `…`.
- The `…` menu is a **glyph button**, never a fourth labeled command.
- Empty / loading / error states exist and are centered, not blank.

### 3.2 Take from Windows (type, metrics, shape, color)

- **Type ramp: Fluent (S3), not the 12 px GDI system font (S2).** The surface
  is a modern app dialog, so:

  | Role | Target | Where |
  |---|---|---|
  | Caption | **12 px** | row subtitle, detail subtitle, status strip, badges, account email |
  | Body | **14 px** | row title, buttons, filter field, session labels |
  | Body Strong | 14 px semibold | reserved |
  | Subtitle | **20 px semibold** | detail-pane title |

  This is a **deliberate divergence from `SPI_GETNONCLIENTMETRICS`** (12 px
  body) and it must be recorded as one: Win11's own modern apps are at 14, and
  matching the 9 pt GDI font would make the chooser look like a 2009 dialog
  next to Settings. It is NOT a licence to invent sizes — 12/14/20 and nothing
  else, and the caption size deliberately coincides with the system font so the
  smallest text on the surface is never smaller than Windows' own.

- **Corner radius comes from the design system's scale (§3.1), not from Mac's.**
  Mac uses 6 for machine rows and 8 for session rows; the scale here has 4 for
  small chips and input fields, 6 for tab chiclets, 8 for cards and overlays.
  Ruling: **machine rows and session rows are both 4** (they are list items,
  the smallest surface on the dialog), badges/pills are **4**, and only a real
  floating card would be 8. Mac's 6/8 encodes macOS's larger radius language
  and does not survive the crossing.

- **Icon column: Mac's 28 DIP box, glyph drawn at `SM_CXSMICON` (16) scaled.**
  The column stays 28 so text cannot drift per row (S1, 1001); the mark inside
  it is sized the way Windows sizes a small icon.

- **Spacing is snapped to the 4 DIP scale (design system §1).** Mac's 14, 10, 9
  and 6 are off it. The mapping:

  | Mac | Target | Step |
  |---|---|---|
  | 16 (dialog pad) | 16 | `xl` |
  | 14 (filter pad, identity→actions) | **12** | `lg` |
  | 12 (glyph→text) | 12 | `lg` |
  | 10 (account v-pad, filter bottom) | **8** | `md` |
  | 8 (row pad, action gap, list inset) | 8 | `md` |
  | 6 (row v-pad, session spacing, badge pad) | **4** | `sm` |
  | 2 (row spacing, title→subtitle) | 2 | `xs` |

  Nothing outside 2/4/8/12/16/24.

- **Accent, selection and hover follow the system accent and theme** — the
  chooser must not hardcode either. See §6: that is T203/T273/T274, and this
  document only fixes what the chooser is *allowed* to assume (nothing).

- **Focus is always visible** (design system §2.2). Every stop in the Tab order
  — filter, list, primary, activity, menu, cancel, account — draws a focus
  indicator, and the list draws it on the focused ROW, distinct from selection
  (a row can be selected while the list does not have focus).

### 3.3 Elevation and borders

The chooser is a real HWND popup, so it is **elevation 2** (design system
§3.2): let DWM draw the window shadow, never fake one. Inside it everything is
**elevation 0** — flush chrome on one surface — except the transient management
menu, which is level 2 in its own right. The three rules (header, master/detail,
footer) are the only borders on the surface; nothing gets a decorative outline.

---

## 4. Where the current win32 chooser stands

Read out of the source 2026-08-01. This is the delta list T227 works, ordered
by how visible it is.

**Status, 2026-08-01.** T227 split into **T310** (findings 4, 7, 8, 9, 12 —
DONE), **T311** (5, 6) and **T312** (10). Findings 2 and 3 were already closed
by T305 before this table was acted on: `chooser_rows`' washes are
`color_math.wash` and its accent is a parameter. Finding 1 is **T308**.
Finding 13 was verified by T310 and holds — the list keeps at least 5 whole rows
against a 4-line strip at 1.0/1.25/1.5/2.0.

| # | Finding | Evidence | Severity |
|---|---|---|---|
| 1 | **The whole surface is hardcoded dark.** `COLOR_BG = RGB(32,32,32)`, `COLOR_FIELD_BG`, `COLOR_TEXT`, `COLOR_LABEL` are constants, and `DWMWA_USE_IMMERSIVE_DARK_MODE` is set to a literal `1`. `HostSettingsDialog.zig` repeats all four constants verbatim. | `MachineChooser.zig:92-95, 310`; `HostSettingsDialog.zig:36-39` | high (light theme) |
| 2 | **Every wash, divider and hover blends toward white unconditionally.** `columnWash`, `hoverFill`, `dividerColor` composite `#FFFFFF` over the background. On a light background the wash and the divider both vanish. | `chooser_rows.zig:249-266` | high (light theme) |
| 3 | **The accent is a hardcoded blue.** `accent = #3D8EF8`; the box's accent is `#680081`. Selection fill and border both derive from it. | `chooser_rows.zig:232, 239-247` vs §1.3 | high |
| 4 | **The type ramp is off on every role.** `font_h = 15`, `title_font_h = 20`, `subtitle_font_h = 12` at scale 1.0, against a §3.2 target of 14 / 20 / 12 and a system font of 12. Body is 1 px over Fluent and 3 px over the system font. | `chooser_layout.zig:244-245`; `chooser_rows.zig:194` | medium |
| 5 | **No avatar and no monogram.** The account row is a static text plus a 150-wide button; Mac's is email + link over a 34 px accent-gradient monogram circle. | `chooser_layout.zig:107-111` vs §2.4 | medium |
| 6 | **"Sign Out" is a button where Mac has a link,** and the two states share one 150 DIP slot, so the button is sized for the longer caption in both. | `chooser_layout.zig:108` | low |
| 7 | **Row radius 6, off the design-system scale** (§3.1 target 4). | `chooser_rows.zig:180` | low |
| 8 | **Icon column is 20 wide, not 28** — so the text column's left edge does not match Mac's grid, and a wider glyph would push it. | `chooser_rows.zig:166` vs S1 1001 | low |
| 9 | **Off-scale spacing survives in five places**: `fill_inset_y = 1`, `title_y = 7`, glyph gap `6`, text gap `10`, `text_pad_right = 10`. | `chooser_rows.zig:158-189` | low |
| 10 | **No focus indicator on the owner-drawn list.** Tab order exists and is tested (`nextFocus`), but a focused-but-not-selected row is invisible, and selection is drawn the same whether the list has focus or not. | `MachineChooser.zig:1745-1854` | medium |
| 11 | **No count badge on a row** and **no session list in the detail pane** — the detail subtitle says "Online · host" where Mac says "N sessions · host". | `chooser_rows.zig:103-111` | deferred to T146 |
| 12 | **`secondary_gray` is a fixed `#999999`** with no contrast floor against whatever background it lands on (design system §2.3 requires 4.5:1 text / 3:1 chrome). | `chooser_rows.zig:236` | medium |
| 13 | **The status strip caps at 4 lines and steals from the list** — correct and deliberate (`clampHintLines`), but the list can then be as short as 5 rows; check that against the 540 height at 200%. | `chooser_layout.zig:147-161` | verify only |

Things that are already right and must not regress: the 840x540 shell, the 260
master column, the wash-behind-the-column idea, the whole-rows list snap, the
action-row packer (content-sized buttons, proportional shed, square glyph
button), the reserved 12 px status column, `hostnameSubtext`'s
noise-suppression rule, and the Tab order.

---

## 5. How this gets validated

Unchanged in spirit from T227's Validation, made concrete:

- **Pure metrics → the none lane.** Every number in §3 lands in
  `chooser_layout.zig` / `chooser_rows.zig` and is asserted at **1.0, 1.25, 1.5
  and 2.0** — the design system's rule, because these defects are invisible at
  1.0 and obvious at 1.25.
- **A spacing-scale test.** One test that walks the layout's gaps and fails on
  any value not in {2,4,8,12,16,24} at scale 1.0. This is the test that keeps
  §3.2's mapping from rotting.
- **Colors are asserted as relationships, not literals** — wash lighter than
  the background *in the direction the theme implies*, divider above the wash,
  hover below selection, text above its background by the §2.3 floor. A literal
  hex assertion would have to be rewritten by T203 the moment the accent
  becomes the system's.
- **Pixels → `test/win32/ipc-machine-chooser.ps1`**, which already runs on the
  background test desktop at ALL PASS 45 and whose probes were proved faithful
  through `Get-TestWindowPixels` (T217 batch 7: 64 distinct colors, pill tint
  47, gutter 0). The chooser is our own GDI painter, so unlike §0's WinUI
  problem it captures correctly.
- **`-NegativeControl` inverts a load-bearing pixel claim and FAILS** — and per
  T283, the negative control must invert something the assertion actually
  depends on.
- **T248 applies**: the script must not reuse a `--target` name against a
  persisted session, or from the second run on it measures the previous run's
  pixels. Kill the repo agent and launch with `--session-persistence=off`.
- Floor: both `zig build test` lanes, `zig build test-agent`, P1-P3 ALL PASS.

---

## 6. What this document deliberately does NOT own

- **System accent + light/dark plumbing — T203.** Findings 1, 2 and 3 above are
  *stated* here because they are the biggest visible defects on this surface,
  but the mechanism (reading the accent, reading the theme, propagating both
  into win32 chrome) is one job for the whole app, not a chooser-local hack.
  T273 (window-theme no longer reaches the client-painted caption and tab strip)
  and T274 (win32 chrome foregrounds are hardcoded light) are the same
  mechanism. **T227 must consume T203's plumbing, not re-derive it** — the T206
  rule: import the constants, do not re-invent them.
- **Session browse, Kill, Restore All — T146.** Finding 11, and the reason the
  detail pane's subtitle differs from Mac's.
- **Activity Monitor's own pixels — T227 covers the BUTTON, not the panel.**
  The panel is T284-T287 and its own follow-ups (T289-T293, T297-T301).
- **The chooser control locators used by three test scripts — T294.**

---

## 7. Provenance

Every measurement in §1 was taken on this box on 2026-08-01 with
`SystemParametersInfoForDpi`, `GetSystemMetrics`, `OpenThemeData` /
`GetThemePartSize` / `GetThemeMargins` / `GetThemeColor`, and the DWM /
Personalize registry keys. Every Mac number in §2 carries its
`MachineChooserView.swift` line. Every current-state finding in §4 carries the
win32 file and line it was read from. Nothing here was eyeballed, and §0
records the one method that was tried and does not work.
