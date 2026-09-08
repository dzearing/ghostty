# The IME checks that need a real input method (T642)

The viewer feedback composer, the terminal surface and every other text field
in the Windows build get IME composition from the OS rather than from code we
wrote. Most of that claim is now proved automatically. This file records the
part that is **not**, why it cannot be, and what to do about it before a
release.

## What the automated suite already proves

`test\win32\viewer-feedback.ps1` section K posts the real message sequence an
IME delivers a settled composition with — `WM_IME_STARTCOMPOSITION`, the
composed characters as `WM_IME_CHAR`, then `WM_IME_ENDCOMPOSITION` — at the
composer's text control, and asserts:

- the composed string lands in the control,
- ordinary typing still inserts afterwards (the composition ended cleanly),
- the pane's mirrored buffer is **byte-exact** for the composed text once the
  composition has ended, compared against the UTF-8 encoding of what the
  control holds. `EN_CHANGE` fires while a composition is still open, so the
  buffer does see partial text on the way through; what has to be true, and is
  asserted, is that it is right at the end.

That works with no IME installed because RichEdit inserts a `WM_IME_CHAR`
character itself, inside a composition bracket or outside one, without reading
any input context. It was measured on this box before the section was written.

## What it cannot prove, and why

Everything an IME renders or reads through the **input context** rather than
through the message:

| Check | Why it needs a real IME |
|---|---|
| The candidate window appears, and over the caret | Drawn by the IME, positioned from `ImmSetCompositionWindow`; nothing to observe without one |
| The intermediate (underlined) composition string | RichEdit reads `GCS_COMPSTR` from the IMC with `ImmGetCompositionString`; a synthesised `WM_IME_COMPOSITION` finds an empty context and inserts nothing |
| Where the caret rests once a composition commits | A real end-of-composition carries a result string RichEdit reads from the context and replaces the composition span with, leaving the caret after it. A synthesised one finds an empty context and collapses back to the composition's start, so the harness moves the caret itself before its continuation arm |
| Reconversion, and cancelling a composition with Escape | Same: driven by the IME through the context |
| The composition following the caret as the pill grows | Needs the IME's own window to observe |

The box this loop runs on has exactly one input method installed
(`en-US`, `0409:00000409`). Adding a Japanese one is a Windows language
feature-on-demand: it needs elevation and a download, and it permanently
changes the user's language bar and their Win+Space toggle on the machine they
work in every day. An acceptance run does not get to make that change, so the
table above is a **manual pre-release check**, not an automated one.

## The manual check

Run once per release, on any Windows box with a Microsoft IME installed
(Settings → Time & language → Language & region → Add a language → Japanese,
with "Basic typing" selected):

1. Open a viewer pane (`ghoztty +new-window --view=<some file>`), open the
   feedback composer, and switch to the Japanese IME (Win+Space).
2. Type `nihongo` and confirm: the candidate window appears **over the caret**,
   the intermediate string is shown underlined **inside the pill**, and the
   pill grows if the composition wraps.
3. Press Space to cycle candidates, Enter to commit. The committed word is in
   the composer, once, with no leftover underline.
4. Start a second composition and press Escape: the composition is cancelled
   and the composer stays **open** — Escape must not be stolen from the IME to
   close the composer.
5. Send with Ctrl+Enter and confirm the report on disk carries the composed
   text unmangled.
6. Repeat steps 2–3 in a terminal pane, which takes a different path
   (`Surface.zig` handles `WM_IME_COMPOSITION` itself rather than letting a
   control do it).

Record the result in the release's task or log entry. A failure here is a task,
filed the ordinary way.
