# vendor/mesa-gl — the fallback OpenGL implementation Ghoztty ships on Windows

`x64/opengl32.dll` here is an unmodified Mesa build. `zig build` installs it as
`zig-out/bin/gl/opengl32.dll` for Windows win32 targets, the MSI and the
portable ZIP carry it as `<install>\gl\opengl32.dll`, and
`src/renderer/gl_loader.zig` opens it **by full path** when the display
driver's own OpenGL measures below the renderer's floor (T1251/T1252).

## Why it is in a `gl\` subdirectory and not beside `ghoztty.exe`

`opengl32.dll` is not a KnownDLL. A copy next to the exe would be loaded by the
operating system for **every** launch, which would silently move every user
with a perfectly good GPU onto this implementation. The exe imports no
`OPENGL32.dll` at all (T1251) and the loader chooses the module at run time, so
the fallback can only ever be reached deliberately.

## Why the `d3d12` build and not `llvmpipe`

The failure this exists for is a Remote Desktop session, whose display driver
offers OpenGL 1.1. Mesa's `d3d12` gallium driver reaches the real GPU through
Direct3D 12, which an RDP session does have — so the fallback is a working
GPU-backed renderer there, not a slideshow. It is also a fifth of the size:

| Mesa 26.2.1 build | `opengl32.dll` on disk | archive |
|---|---|---|
| `d3d12` (shipped) | 17,092,608 B | 3.1 MB |
| `llvmpipe`        | 58,872,320 B | 15.8 MB |

`llvmpipe` would be the pure-CPU floor for a machine with no D3D12 device at
all. That machine is rare (D3D12 has WARP as a software device on every
supported Windows), it would quadruple the download for every user who never
needs any of this, and when the fallback cannot draw either, T1249's honest
refusal dialog is still the right ending. If a real report ever shows a machine
that the `d3d12` build cannot serve, revisit this row rather than guessing.

## Provenance

`PINNED.json` is the record: upstream project, release, asset URL, the
archive's SHA-256, and the SHA-256/size of every file extracted from it. Nothing
here is fetched at build time — the bytes are in the repo, so an offline build,
a CI runner and a release all package the same implementation with no network
and no `7z` in the pipeline.

## Updating to a newer Mesa

```sh
dist/windows-installer/fetch-mesa-gl.sh --version 26.3.0     # download + extract + rewrite PINNED.json
dist/windows-installer/fetch-mesa-gl.sh --verify             # re-download and prove the bytes on disk
```

`--verify` is the reproducibility check: it re-downloads the pinned asset,
checks the archive hash, extracts it again and compares the result byte for byte
with what is committed here. Both need `7z`/`7zr`/`7za` on PATH (the upstream
asset is a `.7z` that uses the BCJ2 filter, which Python's `py7zr` cannot read);
the standalone `7zr.exe` from <https://www.7-zip.org/> is enough on Windows and
`p7zip-full` on Linux.

After a version bump, run `test\win32\startup-failure.ps1` — arm H is the one
that launches the terminal on the SHIPPED fallback with no environment override
and reads back that it drew with it.
