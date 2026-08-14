<#
.SYNOPSIS
    Arm hardware data breakpoints on a function's spilled parameters under cdb
    and catch the instruction that writes them (T458).

.DESCRIPTION
    The T443/T454 corruption zeroes the spilled incoming parameters of a LIVE
    Page.verifyIntegrity stack frame -- slots that are written once in the
    prologue and never again. Everything so far worked backwards from the
    wreckage; this library works forwards: stop the program at the moment of
    the write, and name the writing instruction with its full stack.

    The recipe, end to end:

    1. PROBE. Run cdb just long enough to disassemble the target function and
       parse its Debug prologue: `push rbp` / an optional run of further
       `push <reg>` saves / the frame allocation / `lea rbp,[rsp+Y]` followed
       by a leading run of `mov [rbp+/-off],reg` spills (possibly via
       a scratch register: `mov rax,rdx; mov [rbp-10h],rax` spills rdx). The
       frame allocation has two shapes and both are read (T834): `sub rsp,X`
       for a frame under 4 KB, and `mov eax,X; call __chkstk; sub rsp,rax` --
       the stack-probe form the compiler switches to at 4 KB and above. From
       that: the canonical spill slot per incoming register (the FIRST spill
       per origin register -- the slots the T454 dump showed corrupted), the
       arm point (first instruction after the spill run, so the prologue's own
       stores never trip the breakpoints), and the return-address slot
       (rbp + 8 + X - Y), all as symbol-relative offsets that survive ASLR.
    2. ARM PER CALL. A breakpoint at the arm point runs a command FILE that
       sets `ba1..baN w8` on the computed slot addresses and plants a one-shot
       `bp /1 poi(<ret slot>)` that clears them when the function returns. The
       armed window is exactly the live frame, so stack reuse after return can
       never false-positive.
    3. ON HIT, the ba's command file prints the writing instruction (`ub @rip`
       -- a data breakpoint fires AFTER the write retires), every thread's
       stack, and a full minidump, then quits. First hit is the prize.

    Three cdb specifics this encodes so they are not re-derived (they cost one
    experiment each during T458, on top of the three CrashCatch.ps1 already
    documents):

    - Nested quotes in breakpoint commands do not work; a breakpoint command
      that itself needs to set a breakpoint-with-command uses `$$<file`
      includes instead. One level of quoting only, ever.
    - Paths inside those quoted `$$<` strings hit the backslash-escape trap,
      so every path handed to cdb here uses FORWARD slashes.
    - Explicit breakpoint IDs (`bu0`, `ba1`..`ba4`) keep the disarm file's
      `bc` from ever clearing the entry breakpoint: cdb auto-assigns the
      lowest free ID, so without pinned IDs the one-shot return breakpoint
      would race the ba slots for numbering.

    Known limits, by design:
    - x64 has FOUR debug registers; at most 4 slots are armed (default: all
      distinct origin registers found, capped at 4).
    - Only an rbp-based Zig Debug frame is understood, in its two allocation
      shapes (plain `sub rsp,X`, or the `__chkstk` probe form at 4 KB and
      above). A tiny leaf function can get a frameless `push rax` prologue
      instead; the probe refuses it loudly rather than arming the wrong bytes.
    - Threads created AFTER a ba is set do not inherit debug registers. The
      T450 capture showed only parked thread-pool workers, so this is
      acceptable; a hit from an unstarted thread would need a different tool.
    - If the target function unwinds instead of returning (it should not:
      Zig errors return normally), the one-shot disarm never fires and stale
      ba slots can storm. verifyIntegrity always returns.
    - Concurrent calls of the target on two threads re-arm the same ba IDs
      (last arm wins). The terminal tests the corruption lands on are
      single-threaded at that point.

.NOTES
    Dot-source AFTER CrashCatch.ps1 is loaded (it reuses Get-CdbPath,
    New-CdbScript, Read-CrashCatchLog, Get-LastProgressLine and
    Remove-OldCrashCapture):

        . "$PSScriptRoot\lib\CrashCatch.ps1"
        . "$PSScriptRoot\lib\DataBreak.ps1"

    ASCII only, PowerShell 5.1 compatible.
#>

# --------------------------------------------------------------- small helpers

function Get-DataBreakModuleName {
    <#
    .SYNOPSIS
        The cdb module name for an exe: basename with non-identifier
        characters replaced by underscores (ghoztty-agent-test.exe ->
        ghoztty_agent_test).
    #>
    param([Parameter(Mandatory)][string]$ExePath)
    $base = [IO.Path]::GetFileNameWithoutExtension($ExePath)
    return ($base -replace '[^A-Za-z0-9_]', '_')
}

function Format-RbpExpression {
    <#
    .SYNOPSIS
        A signed frame offset as a cdb address expression: @rbp-0x10 / @rbp /
        @rbp+0x358.
    #>
    param([Parameter(Mandatory)][long]$Offset)
    if ($Offset -eq 0) { return '@rbp' }
    if ($Offset -gt 0) { return ('@rbp+0x{0:x}' -f $Offset) }
    return ('@rbp-0x{0:x}' -f (- $Offset))
}

# ---------------------------------------------------------------------- probe

function Invoke-CdbOnce {
    <#
    .SYNOPSIS
        Run one short cdb session against an exe and return its transcript
        lines. Internal helper for the probe.
    #>
    param(
        [Parameter(Mandatory)][string]$CdbPath,
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSeconds = 120
    )
    $tmp = Join-Path $env:TEMP ("databreak-probe-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $out = Join-Path $tmp 'probe.log'
    $err = Join-Path $tmp 'probe.err.log'
    $prevSym = $env:_NT_SYMBOL_PATH
    $env:_NT_SYMBOL_PATH = (Split-Path -Parent $ExePath)
    try {
        $p = Start-Process -FilePath $CdbPath -ArgumentList ('-c "' + $Command + '" "' + $ExePath + '"') `
            -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
        $null = $p.Handle
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
            $p.WaitForExit(10000) | Out-Null
            return $null
        }
    } finally {
        $env:_NT_SYMBOL_PATH = $prevSym
    }
    $lines = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue)
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return $lines
}

function Invoke-DataBreakProbe {
    <#
    .SYNOPSIS
        Disassemble the target function's prologue and compute everything the
        armed run needs, as module-relative offsets (which survive ASLR
        between the probe session and the armed session).
    .PARAMETER SignatureFilter
        Substring to pick one overload when the bare symbol name is ambiguous
        (e.g. 'page.Page' selects Page.verifyIntegrity over
        PageList.verifyIntegrity -- Zig gives both the same bare name).
    .OUTPUTS
        Ok, Error, ExePath, ModuleName, Symbol, Candidates, ModuleBase,
        EntryAddress, EntryRva, FrameSub, FrameLea, FrameShape ('sub' or
        'chkstk'), ExtraPushes, RetSlotOffset, Spills (Offset/Reg/Origin per
        spill, in order), ArmedSlots (first spill per origin register),
        ArmOffset, ArmRva, RawDisasm.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Symbol,
        [string]$SignatureFilter = '',
        [string]$Cdb,
        # 40, not 32: a __chkstk prologue (T834) spends four more instructions
        # before the spill run starts, and the run has to end inside this window.
        [int]$DisasmLength = 40,
        [int]$TimeoutSeconds = 120
    )

    $res = [pscustomobject]@{
        Ok            = $false
        Error         = ''
        ExePath       = $Exe
        ModuleName    = ''
        Symbol        = $Symbol
        Candidates    = @()
        ModuleBase    = [uint64]0
        EntryAddress  = [uint64]0
        EntryRva      = [long]0
        FrameSub      = [long]0
        FrameLea      = [long]0
        FrameShape    = ''
        ExtraPushes   = [int]0
        RetSlotOffset = [long]0
        Spills        = @()
        ArmedSlots    = @()
        ArmOffset     = [long]0
        ArmRva        = [long]0
        RawDisasm     = @()
    }

    if (-not (Test-Path -LiteralPath $Exe)) { $res.Error = "no such exe: $Exe"; return $res }
    $exePath = (Resolve-Path -LiteralPath $Exe).Path
    $res.ExePath = $exePath
    $cdbPath = Get-CdbPath -Override $Cdb
    if (-not $cdbPath) { $res.Error = 'no cdb.exe found'; return $res }

    $module = Get-DataBreakModuleName -ExePath $exePath
    $res.ModuleName = $module
    $target = "$module!$Symbol"
    $exeLeaf = [IO.Path]::GetFileName($exePath)

    # ---- session A: where is the symbol, and where is the module?
    $xLines = Invoke-CdbOnce -CdbPath $cdbPath -ExePath $exePath -Command "x $target; q" -TimeoutSeconds $TimeoutSeconds
    if ($null -eq $xLines) { $res.Error = "probe timed out after ${TimeoutSeconds}s"; return $res }
    if ($xLines.Count -eq 0) { $res.Error = 'probe produced no output'; return $res }

    foreach ($l in $xLines) {
        if ($res.ModuleBase -eq 0 -and $l -match ('^ModLoad:\s+([0-9a-f]{8})`([0-9a-f]{8})\s+[0-9a-f`]+\s+.*' + [regex]::Escape($exeLeaf) + '\s*$')) {
            $res.ModuleBase = [Convert]::ToUInt64($Matches[1] + $Matches[2], 16)
            continue
        }
        if ($l -match '^([0-9a-f]{8})`([0-9a-f]{8})\s+(\S+!\S+)(?:\s+\((.*)\))?\s*$') {
            if ($Matches[3] -ne $target) { continue }
            $sig = ''
            if ($Matches[4]) { $sig = $Matches[4] }
            $res.Candidates += [pscustomobject]@{
                Address   = [Convert]::ToUInt64($Matches[1] + $Matches[2], 16)
                Signature = $sig
            }
        }
    }
    if ($res.ModuleBase -eq 0) { $res.Error = "could not find the module base for $exeLeaf in the probe transcript"; return $res }
    if ($res.Candidates.Count -eq 0) { $res.Error = "symbol '$target' not found"; return $res }

    $picked = @($res.Candidates)
    if ($SignatureFilter) {
        $picked = @($picked | Where-Object { $_.Signature -like ('*' + $SignatureFilter + '*') })
    }
    if ($picked.Count -eq 0) {
        $sigs = (@($res.Candidates | ForEach-Object { '(' + $_.Signature + ')' }) -join ', ')
        $res.Error = "no overload of '$target' matches -SignatureFilter '$SignatureFilter'; candidates: $sigs"
        return $res
    }
    if ($picked.Count -gt 1) {
        $sigs = (@($picked | ForEach-Object { '(' + $_.Signature + ')' }) -join ', ')
        $res.Error = "symbol '$target' is ambiguous -- pass -SignatureFilter to pick one of: $sigs"
        return $res
    }
    $res.EntryAddress = $picked[0].Address
    $res.EntryRva = [long]($picked[0].Address - $res.ModuleBase)

    # ---- session B: disassemble by module+rva, which cannot be ambiguous.
    $uCmd = ('u {0}+0x{1:x} L{2}; q' -f $module, $res.EntryRva, $DisasmLength)
    $lines = Invoke-CdbOnce -CdbPath $cdbPath -ExePath $exePath -Command $uCmd -TimeoutSeconds $TimeoutSeconds
    if ($null -eq $lines) { $res.Error = "probe timed out after ${TimeoutSeconds}s"; return $res }

    # Instruction lines look like:
    #   00007ff7`efc2e2f0 55              push    rbp
    # Parse only AFTER cdb echoes the `u` command: the transcript opens with
    # the loader break's own `int 3` line, which is instruction-shaped too.
    $insns = @()
    $started = $false
    foreach ($l in $lines) {
        if (-not $started) {
            if ($l -match 'Reading initial command') { $started = $true }
            continue
        }
        if ($l -match '^([0-9a-f]{8})`([0-9a-f]{8})\s+[0-9a-f]{2,}\s+(\S+)(?:\s+(.*))?$') {
            $insns += [pscustomobject]@{
                Address  = [Convert]::ToUInt64($Matches[1] + $Matches[2], 16)
                Mnemonic = $Matches[3]
                Operands = $(if ($Matches[4]) { $Matches[4].Trim() } else { '' })
            }
        }
    }
    $res.RawDisasm = @($lines | Where-Object { $_ -match '^[0-9a-f]{8}`[0-9a-f]{8}\s' -or $_ -match '!' } | Select-Object -First ($DisasmLength + 6))
    if ($insns.Count -lt 5) {
        $res.Error = "could not disassemble '$target' at rva 0x$('{0:x}' -f $res.EntryRva); got $($insns.Count) instruction(s)"
        return $res
    }

    # The Zig Debug frame: push rbp / [more push <reg>] / the frame
    # allocation / lea rbp,[rsp+Y]. Anything else is a shape this recipe has
    # not seen -- fail loudly with the disasm attached rather than arming the
    # wrong bytes.
    if ($insns[0].Mnemonic -ne 'push' -or $insns[0].Operands -ne 'rbp') {
        $res.Error = "prologue does not start with 'push rbp': $($insns[0].Mnemonic) $($insns[0].Operands)"
        return $res
    }

    # Callee-saved registers pushed after rbp. Each one moves the return-address
    # slot another 8 bytes away from rbp, and nothing else about the recipe
    # changes. A frame that needs a __chkstk probe saves two of them here
    # (push rsi / push rdi) in the shape T834 found.
    $i = 1
    while ($i -lt $insns.Count -and $insns[$i].Mnemonic -eq 'push' -and $insns[$i].Operands -match '^r[a-z0-9]+$') {
        $res.ExtraPushes++
        $i++
    }
    if ($i -ge $insns.Count - 1) {
        $res.Error = "prologue is nothing but pushes in the first $($insns.Count) instruction(s) of '$target'"
        return $res
    }

    # The frame allocation, in either shape:
    #   sub rsp,X                                 -- frames under 4 KB
    #   mov eax,X / call __chkstk / sub rsp,rax   -- 4 KB and above (T834)
    # Both allocate X bytes; only the instruction count differs.
    if ($insns[$i].Mnemonic -eq 'sub' -and $insns[$i].Operands -match '^rsp,([0-9a-f]+)h?$') {
        $res.FrameSub = [Convert]::ToInt64($Matches[1], 16)
        $res.FrameShape = 'sub'
        $i++
    }
    elseif ($insns[$i].Mnemonic -eq 'mov' -and $insns[$i].Operands -match '^eax,([0-9a-f]+)h?$') {
        $size = [Convert]::ToInt64($Matches[1], 16)
        if ($i + 2 -ge $insns.Count) {
            $res.Error = "a __chkstk prologue was cut short by -DisasmLength in '$target'"
            return $res
        }
        if ($insns[$i + 1].Mnemonic -ne 'call' -or $insns[$i + 1].Operands -notmatch '__chkstk') {
            $res.Error = ("expected 'call __chkstk' after 'mov eax,{0:x}h': {1} {2}" -f `
                    $size, $insns[$i + 1].Mnemonic, $insns[$i + 1].Operands)
            return $res
        }
        if ($insns[$i + 2].Mnemonic -ne 'sub' -or $insns[$i + 2].Operands -ne 'rsp,rax') {
            $res.Error = "expected 'sub rsp,rax' after the __chkstk call: $($insns[$i + 2].Mnemonic) $($insns[$i + 2].Operands)"
            return $res
        }
        $res.FrameSub = $size
        $res.FrameShape = 'chkstk'
        $i += 3
    }
    else {
        $res.Error = "expected a frame allocation ('sub rsp,X' or 'mov eax,X; call __chkstk; sub rsp,rax'): $($insns[$i].Mnemonic) $($insns[$i].Operands)"
        return $res
    }

    if ($i -ge $insns.Count) {
        $res.Error = "the prologue was cut short by -DisasmLength in '$target'"
        return $res
    }
    if ($insns[$i].Mnemonic -ne 'lea' -or $insns[$i].Operands -notmatch '^rbp,\[rsp(?:\+([0-9a-f]+)h?)?\]$') {
        $res.Error = "expected 'lea rbp,[rsp+Y]' after the frame allocation: $($insns[$i].Mnemonic) $($insns[$i].Operands)"
        return $res
    }
    if ($Matches[1]) { $res.FrameLea = [Convert]::ToInt64($Matches[1], 16) } else { $res.FrameLea = 0 }
    $i++

    $res.EntryAddress = $insns[0].Address
    # entry rsp (the return address slot) relative to the frame pointer:
    # rbp = entry_rsp - 8 - 8*pushes - X + Y  =>  ret slot = rbp + 8 + 8*pushes + X - Y.
    $res.RetSlotOffset = 8 + (8 * $res.ExtraPushes) + $res.FrameSub - $res.FrameLea

    # Walk the leading spill run. Two shapes participate:
    #   mov qword ptr [rbp(+/-off)],REG   -- a spill
    #   mov REGa,REGb                     -- a copy (spills of REGa are
    #                                        attributed to REGb's origin)
    # The first anything-else instruction ends the run and is the arm point.
    $origin = @{}
    $spills = @()
    $armAddr = [uint64]0
    for (; $i -lt $insns.Count; $i++) {
        $insn = $insns[$i]
        if ($insn.Mnemonic -eq 'mov' -and $insn.Operands -match '^qword ptr \[rbp(?:([+-])([0-9a-f]+)h?)?\],(r[a-z0-9]+)$') {
            $off = [long]0
            if ($Matches[2]) {
                $off = [Convert]::ToInt64($Matches[2], 16)
                if ($Matches[1] -eq '-') { $off = - $off }
            }
            $reg = $Matches[3]
            $src = $reg
            if ($origin.ContainsKey($reg)) { $src = $origin[$reg] }
            $spills += [pscustomobject]@{ Offset = $off; Reg = $reg; Origin = $src }
            continue
        }
        if ($insn.Mnemonic -eq 'mov' -and $insn.Operands -match '^(r[a-z0-9]+),(r[a-z0-9]+)$') {
            $dst = $Matches[1]; $from = $Matches[2]
            $src = $from
            if ($origin.ContainsKey($from)) { $src = $origin[$from] }
            $origin[$dst] = $src
            continue
        }
        $armAddr = $insn.Address
        break
    }
    if ($spills.Count -eq 0) {
        $res.Error = "no prologue spills found in '$target' -- nothing to arm"
        return $res
    }
    if ($armAddr -eq 0) {
        $res.Error = "the spill run never ended within $DisasmLength instructions -- raise -DisasmLength"
        return $res
    }
    $res.Spills = $spills

    # First spill per origin register: those are the canonical incoming-value
    # slots -- the ones the T454 dump showed zeroed.
    $seen = @{}
    $armed = @()
    foreach ($s in $spills) {
        if ($seen.ContainsKey($s.Origin)) { continue }
        $seen[$s.Origin] = $true
        $armed += $s
    }
    $res.ArmedSlots = $armed
    $res.ArmOffset = [long]($armAddr - $res.EntryAddress)
    $res.ArmRva = $res.EntryRva + $res.ArmOffset
    $res.Ok = $true
    return $res
}

# ------------------------------------------------------------------ armed run

function Read-DataBreakLog {
    <#
    .SYNOPSIS
        Parse a databreak cdb transcript: arm/disarm counts and the hit block.
    #>
    param([Parameter(Mandatory)][string]$LogPath)

    $res = [pscustomobject]@{
        ArmCount    = 0
        DisarmCount = 0
        Hit         = $false
        WriterSite  = ''
        WriterBlock = @()
        StackBlock  = @()
        VictimRbp   = ''
        HitValue    = ''
    }
    if (-not (Test-Path -LiteralPath $LogPath)) { return $res }

    # ONE compiled-regex pass over the file for every marker. A full-lane run
    # arms per call of the target -- hundreds of thousands of cycles -- so the
    # transcript can run to millions of lines, and a PowerShell function call
    # per line does not come back in usable time. Select-String scans in
    # native code. Marker lines are the word alone, optionally behind cdb's
    # `N:MMM>` prompt; cdb also echoes the `.echo GHOZTTY-...` COMMAND back,
    # which must not count (the CrashCatch.ps1 lesson) -- the anchored match
    # excludes it.
    $markerPat = '^\s*(?:\d+:\d+>\s*)?GHOZTTY-(ARM|DISARM|DATABREAK-HIT|VICTIM-RBP|WRITER|STACK|ALL-THREADS-HIT|DATABREAK-END)\s*$'
    $hits = @(Select-String -LiteralPath $LogPath -Pattern $markerPat -ErrorAction SilentlyContinue)

    $hitAt = -1; $writerAt = -1; $stackAt = -1; $allAt = -1; $endAt = -1; $rbpAt = -1
    foreach ($m in $hits) {
        $which = $m.Matches[0].Groups[1].Value
        $at = $m.LineNumber - 1
        switch ($which) {
            'ARM' { $res.ArmCount++ }
            'DISARM' { $res.DisarmCount++ }
            'DATABREAK-HIT' { if ($hitAt -lt 0) { $hitAt = $at } }
            'VICTIM-RBP' { if ($rbpAt -lt 0) { $rbpAt = $at } }
            'WRITER' { if ($writerAt -lt 0) { $writerAt = $at } }
            'STACK' { if ($stackAt -lt 0) { $stackAt = $at } }
            'ALL-THREADS-HIT' { if ($allAt -lt 0) { $allAt = $at } }
            'DATABREAK-END' { if ($endAt -lt 0) { $endAt = $at } }
        }
    }
    if ($hitAt -lt 0) { return $res }
    $res.Hit = $true

    # Only a hit needs the actual lines, and a hit quits the session, so the
    # slice after the marker is short even when the file is not.
    $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
    if ($endAt -lt 0) { $endAt = $lines.Count - 1 }

    # The victim frame pointer saved into $t9 at arm time.
    if ($rbpAt -ge 0) {
        foreach ($l in $lines[$rbpAt..([Math]::Min($rbpAt + 3, $endAt))]) {
            if ($l -match '\$t9\s*=\s*([0-9a-f`]+)') { $res.VictimRbp = ($Matches[1] -replace '`', ''); break }
        }
    }

    # The `r` output ends with the current location: `module!fn+0xNN:` --
    # that is one instruction PAST the write (a data breakpoint fires after
    # the write retires), but names the writing function.
    $scanTo = $endAt
    if ($writerAt -gt $hitAt) { $scanTo = $writerAt }
    foreach ($l in $lines[$hitAt..$scanTo]) {
        if ($l -match '^\s*(?:\d+:\d+>\s*)?([A-Za-z_][\w]*![^\s:]+):\s*$') { $res.WriterSite = $Matches[1] }
        if ($l -match '^rax=([0-9a-f]{16})\b') { $res.HitValue = '0x' + $Matches[1] }
    }
    # Report blocks with cdb's own prompt-echo lines stripped: what remains is
    # the disassembly and the frames, which is what a reader needs.
    function Select-Payload {
        param($Slice)
        return @($Slice | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*\d+:\d+>' })
    }
    if ($writerAt -ge 0) {
        $stop = $endAt
        if ($stackAt -gt $writerAt) { $stop = $stackAt - 1 }
        $res.WriterBlock = Select-Payload -Slice @($lines[($writerAt + 1)..$stop])
    }
    if ($stackAt -ge 0) {
        $stop = $endAt
        if ($allAt -gt $stackAt) { $stop = $allAt - 1 }
        $res.StackBlock = Select-Payload -Slice @($lines[($stackAt + 1)..$stop])
    }
    return $res
}

function Invoke-DataBreakPageWatch {
    <#
    .SYNOPSIS
        Arm hardware write breakpoints on a HEAP field -- `&page.memory.ptr` --
        for the rest of the run, instead of on a stack slot per call (T474/T838).

    .DESCRIPTION
        Invoke-DataBreak arms the target function's spilled parameters and
        disarms them when it returns, so the cost is one break-into-debugger
        round trip per call. Against the real target that is 335,878 cycles at
        ~2 ms: the lane never finished and the run measured nothing.

        T443 turn 3 established that the damaged 4 bytes are not on the stack at
        all -- they are `Page.memory.ptr` on the heap (`memory` is field 0, so
        `&page.memory.ptr` IS the page's own address). A heap address is stable
        for the life of the page, which is what makes a cheaper shape possible:

        1. Break at the same probed arm point in $Symbol and read the object
           pointer out of its first spill slot.
        2. Gate it: non-null, and the field it names must itself be a plausible
           aligned pointer. That is what proves the slot really holds a *Page
           rather than something the caller left there.
        3. Arm `ba w8` on `<self>+<FieldOffset>` and LEAVE IT ARMED. Nothing
           disarms.
        4. Once $WatchCount distinct objects are armed, DISABLE the entry
           breakpoint. From then on the program runs at full speed: the total
           cost of the instrument is $WatchCount round trips, not one per call.

        Each armed breakpoint's command file gates the report on the T443
        signature -- the post-write qword above $Implausible, which no
        user-mode pointer can reach. Ordinary writes to the slot (a pooled Page
        being re-initialised at the same address, a deinit zeroing it) continue
        silently, so the armed window can outlive the page that opened it.

        THE SHAPE GUARD ($GuardOffset) is the second half of that gate, and it
        is not optional decoration -- the first armed run of the real thing
        reported a hit that turned out to be recycled memory. The page had been
        freed, its pool region handed back to the GPA, and a later page's
        backing buffer allocated over it; `hyperlink.dupe`'s `@memcpy` of the
        URI "https://example.com" into `dst_page.string_alloc` then wrote ASCII
        over the watched bytes, and ASCII reads as an implausible pointer.
        So the report also requires the qword $GuardOffset bytes past the
        watched pointer -- `memory.len` for a Page -- to be UNCHANGED since the
        arm. T443's damage leaves it alone (every dump printed `page_len=0x6f000`
        intact), while recycled memory does not survive it. $GuardOffset 0
        disables the guard and takes the false positives with it.

        WHAT THIS IS BLIND TO, said plainly because a partial watch that reads
        as total coverage is the failure mode here: x64 has FOUR debug
        registers, so at most four addresses are watched out of the thousands a
        lane touches. What is watched is an ADDRESS, not a page -- every later
        page that lands on the same pool slot is covered too, which is the only
        reason the odds are better than 4-out-of-N. A run that ends clean says
        "no implausible write reached these four addresses", never "no
        corruption happened".

    .PARAMETER SelfSlotOffset
        Explicit rbp-relative offsets of the slots that might hold the object
        pointer. Default: EVERY canonical spill slot the probe found, tried in
        order, first one that passes the gates wins.

        Guessing a single slot does not work and this is measured: the fixture's
        `check(self, a, b)` spills rdx/r8/r9 in parameter order, while the real
        `Page.verifyIntegrity(self, alloc)` in ghoztty-agent-test.exe spills
        r8/rdx/rcx -- so "the first spill is the first parameter" is false on the
        one target that matters. The gates are what make trying all of them safe:
        a candidate is only armed if it holds a plausible aligned pointer whose
        own field at +$FieldOffset is a plausible pointer aligned to $FieldAlign,
        which is a description only a real *Page satisfies.

    .PARAMETER FieldOffset
        Byte offset of the watched pointer inside the object. 0 for
        `Page.memory.ptr`, which is field 0.

    .PARAMETER FieldAlign
        The watched pointer's expected alignment, used as an arm-time gate.
        4096 for a page-aligned backing buffer; 1 disables the gate.

    .PARAMETER MaxArmAttempts
        Give up arming after this many calls of $Symbol and disable the entry
        breakpoint anyway, so a wrong slot costs seconds rather than the run.

    .OUTPUTS
        The same shape Invoke-DataBreak returns, plus SelfSlotOffset and
        ArmedFull. DisarmCount is always 0 by design.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Symbol,
        [string]$SignatureFilter = '',
        [long[]]$SelfSlotOffset = @(),
        [long]$FieldOffset = 0,
        [long]$FieldAlign = 4096,
        [long]$GuardOffset = 8,
        [int]$HotLimit = 1000,
        [int]$WatchCount = 4,
        [int]$WatchSize = 8,
        [string]$Implausible = '0x800000000000',
        [int]$MaxArmAttempts = 2000,
        [string[]]$Arguments = @(),
        [int]$AttachPid = 0,
        [string]$OutDir,
        [int]$TimeoutSeconds = 1800,
        [int]$Keep = 3,
        [string]$Cdb,
        [string]$Repo = 'D:\git\ghoztty',
        [switch]$KeepLog,
        [scriptblock]$Writer = { param($s) Write-Host $s }
    )

    $probe = Invoke-DataBreakProbe -Exe $Exe -Symbol $Symbol -SignatureFilter $SignatureFilter -Cdb $Cdb
    $result = [pscustomobject]@{
        Probe          = $probe
        Hit            = $false
        Crashed        = $false
        ArmCount       = 0
        DisarmCount    = 0
        ArmedFull      = $false
        Tried          = $false
        HotDropped     = 0
        EndedEarly     = $false
        StrayBreak     = ''
        SelfSlotOffset = [long]0
        SelfSlotCandidates = @()
        WriterSite     = ''
        WriterBlock    = @()
        StackBlock     = @()
        VictimRbp      = ''
        HitValue       = ''
        ArmedOffsets   = @()
        LastTest       = ''
        DumpPath       = ''
        LogPath        = ''
        ErrLogPath     = ''
        ExitCode       = $null
        Seconds        = 0
        Error          = ''
        CrashResult    = $null
    }
    if (-not $probe.Ok) { $result.Error = $probe.Error; return $result }

    if ($WatchCount -lt 1) { $WatchCount = 1 }
    if ($WatchCount -gt 4) { $WatchCount = 4 }

    $candidates = @()
    if ($SelfSlotOffset.Count -gt 0) { $candidates = @($SelfSlotOffset) }
    elseif ($probe.ArmedSlots.Count -gt 0) { $candidates = @($probe.ArmedSlots | ForEach-Object { $_.Offset }) }
    if ($candidates.Count -eq 0) {
        $result.Error = "no spill slot to read the object pointer from in '$Symbol'"
        return $result
    }
    $result.SelfSlotOffset = $candidates[0]
    $result.SelfSlotCandidates = @($candidates)
    $result.ArmedOffsets = @($candidates)

    $cdbPath = Get-CdbPath -Override $Cdb
    if (-not $OutDir) { $OutDir = Join-Path $Repo '.dumps' }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path

    $base = [IO.Path]::GetFileNameWithoutExtension($probe.ExePath)
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $tag = "$base-pagewatch-$stamp-1"
    $dump = Join-Path $OutDir "$tag.dmp"
    $log = Join-Path $OutDir "$tag.log"
    $errLog = Join-Path $OutDir "$tag.err.log"
    $scriptFile = Join-Path $OutDir "$tag.cdb"
    $dumpFwd = $dump -replace '\\', '/'

    # Every generated file is one $$< include, so every cdb command below sits
    # at exactly ONE level of quoting -- the rule the header records.
    $helpers = @()
    $armFiles = @()
    $hitFiles = @()
    $reportFiles = @()
    for ($n = 1; $n -le $WatchCount; $n++) {
        $armFiles += (Join-Path $OutDir ("$tag.arm$n.txt"))
        $hitFiles += (Join-Path $OutDir ("$tag.hit$n.txt"))
        $reportFiles += (Join-Path $OutDir ("$tag.report$n.txt"))
    }

    $fieldSuffix = $(if ($FieldOffset -ne 0) { '+0x{0:x}' -f $FieldOffset } else { '' })
    $alignMask = [long]0
    if ($FieldAlign -gt 1) { $alignMask = $FieldAlign - 1 }

    for ($n = 1; $n -le $WatchCount; $n++) {
        $slot = '@$t{0}{1}' -f $n, $fieldSuffix
        $hitFwd = $hitFiles[$n - 1] -replace '\\', '/'

        # The report lives in its OWN include, not inline in the `.if`. cdb
        # echoes every command it runs, so an inline report is echoed on every
        # ordinary write to the address too -- and one storming address wrote
        # a 335 MB transcript in thirteen minutes before this was split out.
        # Its lines all run unconditionally and the last is `q`, so the
        # "an early `g` leaves the rest queued for the next stop" hazard that
        # forces the arm files onto one line does not apply here.
        @(
            '.echo GHOZTTY-DATABREAK-HIT',
            ('r $t9 = ' + $slot),
            '.echo GHOZTTY-VICTIM-RBP',
            'r $t9',
            'r',
            '.echo GHOZTTY-WRITER',
            ('dq ' + $slot + ' L2'),
            'ub @rip L3',
            'u @rip L2',
            '.echo GHOZTTY-STACK',
            '.lines -e',
            'kv 40',
            '.echo GHOZTTY-ALL-THREADS-HIT',
            '~*kv 40',
            ".dump /ma $dumpFwd",
            '.echo GHOZTTY-DATABREAK-END',
            'q'
        ) | Set-Content -LiteralPath $reportFiles[$n - 1] -Encoding ASCII

        $hitGate = 'poi(' + $slot + ') >= ' + $Implausible
        if ($GuardOffset -gt 0) {
            $hitGate = '(' + $hitGate + ') & (poi(' + $slot + '+0x{0:x}) == @$t1{1})' -f $GuardOffset, $n
        }
        # A watched address that outlives its page can be recycled into memory
        # something writes constantly, and then every write breaks into the
        # debugger at ~2 ms. Left alone that is not a slow run, it is a run that
        # never ends: the first real armed lane spent thirteen minutes and
        # 335 MB of transcript on one such address. After -HotLimit ordinary
        # writes the breakpoint is dropped and SAID so -- three watched
        # addresses that ran to the end is a result; four that silently starved
        # the lane is not.
        @(
            ('.if (' + $hitGate + ') { $$<' + ($reportFiles[$n - 1] -replace '\\', '/') + ' }'),
            ('r $t{0} = @$t{0} + 1' -f (14 + $n)),
            ('.if (@$t{0} > 0x{1:x}) {{ bd{2}; .echo GHOZTTY-WATCH-HOT }}' -f (14 + $n), $HotLimit, $n),
            'g'
        ) | Set-Content -LiteralPath $hitFiles[$n - 1] -Encoding ASCII

        # Find the object pointer: walk the candidate slots and keep the first
        # that survives the gates. MASM's `&` does not short-circuit, so the
        # value gate (is this even a pointer?) and the field gate (does it point
        # at something shaped like a *Page?) are two separate lines -- the
        # second only ever dereferences an address the first already vetted.
        $find = @('r $t0 = 0')
        foreach ($c in $candidates) {
            $cExpr = 'poi(' + (Format-RbpExpression -Offset $c) + ')'
            $valGate = @(
                ('(' + $cExpr + ' > 0x10000)'),
                ('(' + $cExpr + ' < ' + $Implausible + ')'),
                ('((' + $cExpr + ' & 7) == 0)')
            ) -join ' & '
            $find += ('.if ((@$t0 == 0) & ' + $valGate + ') { r $t0 = ' + $cExpr + ' }')
            $fieldExpr = 'poi(@$t0' + $fieldSuffix + ')'
            $reject = @(
                ('(' + $fieldExpr + ' == 0)'),
                ('(' + $fieldExpr + ' >= ' + $Implausible + ')')
            )
            if ($alignMask -gt 0) { $reject += ('((' + $fieldExpr + ' & 0x{0:x}) != 0)' -f $alignMask) }
            $find += ('.if ((@$t0 != 0) & (' + ($reject -join ' | ') + ')) { r $t0 = 0 }')
        }

        $gates = @('(@$t0 != 0)')
        for ($k = 1; $k -lt $n; $k++) { $gates += ('(@$t0 != @$t{0})' -f $k) }

        $advance = $(if ($n -lt $WatchCount) {
                'bp0 {0}+0x{1:x} "$$<{2}"' -f $probe.ModuleName, $probe.ArmRva, ($armFiles[$n] -replace '\\', '/')
            }
            else { 'bd0; .echo GHOZTTY-ARMED-FULL' })
        $armParts = @(('r $t{0} = @$t0' -f $n))
        if ($GuardOffset -gt 0) {
            # The shape guard's baseline, captured while the object is known
            # good. Compared at hit time; a mismatch means these bytes are no
            # longer the object that was armed.
            $armParts += ('r $t1{0} = poi({1}+0x{2:x})' -f $n, $slot, $GuardOffset)
        }
        $armParts += ('ba{0} w{1} {2} "$$<{3}"' -f $n, $WatchSize, $slot, $hitFwd)
        $armParts += '.echo GHOZTTY-ARM'
        $armParts += $advance
        $armBody = $armParts -join '; '

        @(
            $find,
            'r $t7 = @$t7 + 1',
            # Once, on the first call: the difference between "the gates
            # rejected everything" and "the function was never called" is the
            # whole diagnosis when a run arms nothing, and without this marker
            # the verdict has to hedge between them.
            '.if (@$t7 == 1) { .echo GHOZTTY-ARM-TRY }',
            ('.if (' + ($gates -join ' & ') + ') { ' + $armBody + ' }'),
            ('.if (@$t7 > 0x{0:x}) {{ bd0; .echo GHOZTTY-ARM-GIVEUP }}' -f $MaxArmAttempts),
            'g'
        ) | Set-Content -LiteralPath $armFiles[$n - 1] -Encoding ASCII
    }
    $helpers = @($armFiles) + @($hitFiles) + @($reportFiles) + @($scriptFile)

    $entry = ('bp0 {0}+0x{1:x} "$$<{2}"' -f $probe.ModuleName, $probe.ArmRva, ($armFiles[0] -replace '\\', '/'))
    # A hardware data breakpoint arrives as a single-step exception. cdb matches
    # it to the registered `ba` first, so a real hit still runs its command file
    # -- but one that matches NOTHING (a thread created after the arm, which
    # does not inherit the debug registers) falls through to the sse filter,
    # breaks, returns from `g`, and drops straight into the script's closing
    # `q`. That happened 110s into the first guarded lane run: cdb quit, the
    # test binary died at exit 84 mid-`remote.connection`, and the verdict still
    # said "no implausible write observed". Ignoring the filter keeps the run
    # going; the cost is that a stray single step is no longer visible, which
    # is why EndedEarly below is checked anyway.
    New-CdbScript -DumpPath $dump -PrologCommands @($entry, 'sxi sse') |
        Set-Content -LiteralPath $scriptFile -Encoding ASCII

    $prevSym = $env:_NT_SYMBOL_PATH
    $env:_NT_SYMBOL_PATH = (Split-Path -Parent $probe.ExePath)

    $argList = @('-lines', '-cf', ('"' + $scriptFile + '"'))
    if ($AttachPid -gt 0) { $argList += @('-p', "$AttachPid") }
    else {
        $argList += ('"' + $probe.ExePath + '"')
        foreach ($x in $Arguments) { $argList += ('"' + $x + '"') }
    }

    & $Writer ("databreak: page-watch -- up to {0} address(es) at <self>{1}; candidate slots for <self>: {2} (in {3}!{4})" -f `
            $WatchCount, $(if ($FieldOffset -ne 0) { '+0x{0:x}' -f $FieldOffset } else { '+0' }), `
        (@($candidates | ForEach-Object { Format-RbpExpression -Offset $_ }) -join ', '), $probe.ModuleName, $probe.Symbol)
    if ($AttachPid -gt 0) { & $Writer ("databreak: attaching to pid {0}" -f $AttachPid) }
    $t0 = Get-Date
    $p = Start-Process -FilePath $cdbPath -ArgumentList ($argList -join ' ') `
        -RedirectStandardOutput $log -RedirectStandardError $errLog -NoNewWindow -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        & $Writer "databreak: TIMEOUT after ${TimeoutSeconds}s -- killing"
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        $p.WaitForExit(10000) | Out-Null
    }
    $result.Seconds = [int]((Get-Date) - $t0).TotalSeconds
    $env:_NT_SYMBOL_PATH = $prevSym
    $result.ExitCode = $p.ExitCode
    $result.LogPath = $log
    $result.ErrLogPath = $errLog

    $parsed = Read-DataBreakLog -LogPath $log
    $result.ArmCount = $parsed.ArmCount
    $result.DisarmCount = $parsed.DisarmCount
    $result.Hit = $parsed.Hit
    $result.WriterSite = $parsed.WriterSite
    $result.WriterBlock = $parsed.WriterBlock
    $result.StackBlock = $parsed.StackBlock
    $result.VictimRbp = $parsed.VictimRbp
    $result.HitValue = $parsed.HitValue
    $result.LastTest = Get-LastProgressLine -Path $errLog
    $result.ArmedFull = (@(Select-String -LiteralPath $log -Pattern '^\s*(?:\d+:\d+>\s*)?GHOZTTY-ARMED-FULL\s*$' -ErrorAction SilentlyContinue).Count -gt 0)
    $result.Tried = (@(Select-String -LiteralPath $log -Pattern '^\s*(?:\d+:\d+>\s*)?GHOZTTY-ARM-TRY\s*$' -ErrorAction SilentlyContinue).Count -gt 0)
    $result.HotDropped = @(Select-String -LiteralPath $log -Pattern '^\s*(?:\d+:\d+>\s*)?GHOZTTY-WATCH-HOT\s*$' -ErrorAction SilentlyContinue).Count
    # A break nobody routed ends the session at cdb's closing `q`, killing the
    # debuggee mid-lane -- and the verdict would otherwise read as a clean full
    # run. Any first-chance report that is not one of ours is that condition.
    if (-not $result.Hit -and -not $result.Crashed) {
        # Anchored past the LOADER break, which is a first-chance
        # `Break instruction exception` cdb reports on every run before it even
        # reads the command file. Counting that one would make every clean run
        # look like it stopped early -- the mirror image of the bug this check
        # exists for, and it fails the same way: by lying about coverage.
        # The anchor is cdb's FIRST prompt line: the loader break is reported
        # before cdb has a prompt to echo the command file at, so anything past
        # that point is a stop the script did not ask for. (`-cf` prints no
        # "Reading initial command" banner, which is what the first attempt at
        # this anchored on and why every clean run then read as stopped early.)
        $anchor = 0
        $start = @(Select-String -LiteralPath $log -Pattern '^\s*\d+:\d+>' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($start.Count -gt 0) { $anchor = $start[0].LineNumber }
        $stray = @(Select-String -LiteralPath $log -Pattern '^\([0-9a-f]+\.[0-9a-f]+\):.*\(first chance\)' -ErrorAction SilentlyContinue |
                Where-Object { $_.LineNumber -gt $anchor })
        if ($stray.Count -gt 0) {
            $result.EndedEarly = $true
            $result.StrayBreak = $stray[$stray.Count - 1].Line.Trim()
        }
    }

    $crashMarker = @(Select-String -LiteralPath $log -Pattern '^\s*(?:\d+:\d+>\s*)?GHOZTTY-CRASH-BEGIN\s*$' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($crashMarker.Count -gt 0) {
        $crash = Read-CrashCatchLog -LogPath $log
        if ($crash.Crashed) {
            $result.Crashed = $true
            $result.CrashResult = $crash
        }
    }
    if (Test-Path -LiteralPath $dump) { $result.DumpPath = $dump }

    Remove-Item -LiteralPath $helpers -Force -ErrorAction SilentlyContinue
    if ($result.Hit -or $result.Crashed) {
        Remove-OldCrashCapture -OutDir $OutDir -Keep $Keep
    } elseif (-not $KeepLog -and -not $result.EndedEarly) {
        Remove-Item -LiteralPath $log, $errLog -Force -ErrorAction SilentlyContinue
        $result.LogPath = ''
        $result.ErrLogPath = ''
    }
    return $result
}

function Invoke-DataBreak {
    <#
    .SYNOPSIS
        Probe a function's prologue, then run the program under cdb with
        hardware write breakpoints armed on its spilled parameters for the
        lifetime of every call.
    .PARAMETER SlotOffsets
        Override the armed slots with explicit rbp-relative offsets (signed).
        The probe still supplies the arm point and the return slot. This is
        how the acceptance test aims at a slot the fixture actually writes.
    .PARAMETER AttachPid
        ATTACH to this already-running process instead of launching the probed
        exe. The probe still reads the exe named by -Exe -- that is where the
        prologue and the module RVA come from -- so the caller must make sure
        the pid is running that same image.

        This is what makes it possible to arm against a test binary that only
        the `zig build` runner knows how to start (T832): the T443 corruption
        has never once been observed in a directly-launched process. Attaching
        was chosen over `cdb -o` (follow children) after both of that route's
        failure modes were measured: `g` returns once per child attach, so a
        script ending in `g; q` quits at the first one, and a `bu
        <module>+<rva>` breakpoint is rejected outright ("Bp expression
        contains symbols not qualified with module name") because a bare
        module name is read as a symbol. Attaching keeps the whole single
        process arm/disarm recipe -- and the module is already loaded, so the
        breakpoint is the same plain `bp0` the launch path uses.
    .OUTPUTS
        Probe, Hit, Crashed, ArmCount, DisarmCount, WriterSite, WriterBlock,
        StackBlock, VictimRbp, HitValue, ArmedOffsets, LastTest, DumpPath,
        LogPath, ErrLogPath, ExitCode, Seconds, Error, CrashResult.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Symbol,
        [string]$SignatureFilter = '',
        [long[]]$SlotOffsets = @(),
        [int]$MaxSlots = 4,
        [string[]]$Arguments = @(),
        [int]$AttachPid = 0,
        [string]$OutDir,
        [int]$TimeoutSeconds = 1200,
        [int]$Keep = 3,
        [string]$Cdb,
        [string]$Repo = 'D:\git\ghoztty',
        [switch]$KeepLog,
        [scriptblock]$Writer = { param($s) Write-Host $s }
    )

    $probe = Invoke-DataBreakProbe -Exe $Exe -Symbol $Symbol -SignatureFilter $SignatureFilter -Cdb $Cdb
    $result = [pscustomobject]@{
        Probe        = $probe
        Hit          = $false
        Crashed      = $false
        ArmCount     = 0
        DisarmCount  = 0
        WriterSite   = ''
        WriterBlock  = @()
        StackBlock   = @()
        VictimRbp    = ''
        HitValue     = ''
        ArmedOffsets = @()
        LastTest     = ''
        DumpPath     = ''
        LogPath      = ''
        ErrLogPath   = ''
        ExitCode     = $null
        Seconds      = 0
        Error        = ''
        CrashResult  = $null
    }
    if (-not $probe.Ok) { $result.Error = $probe.Error; return $result }

    $offsets = @()
    if ($SlotOffsets.Count -gt 0) {
        $offsets = @($SlotOffsets)
    } else {
        $offsets = @($probe.ArmedSlots | ForEach-Object { $_.Offset })
    }
    if ($offsets.Count -gt $MaxSlots) { $offsets = @($offsets | Select-Object -First $MaxSlots) }
    if ($offsets.Count -gt 4) { $offsets = @($offsets | Select-Object -First 4) }
    $result.ArmedOffsets = $offsets

    $cdbPath = Get-CdbPath -Override $Cdb
    if (-not $OutDir) { $OutDir = Join-Path $Repo '.dumps' }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path

    $base = [IO.Path]::GetFileNameWithoutExtension($probe.ExePath)
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $tag = "$base-databreak-$stamp-1"
    $dump = Join-Path $OutDir "$tag.dmp"
    $log = Join-Path $OutDir "$tag.log"
    $errLog = Join-Path $OutDir "$tag.err.log"
    $armFile = Join-Path $OutDir "$tag.arm.txt"
    $disarmFile = Join-Path $OutDir "$tag.disarm.txt"
    $hitFile = Join-Path $OutDir "$tag.hit.txt"
    $scriptFile = Join-Path $OutDir "$tag.cdb"

    # Forward slashes everywhere a path enters a quoted cdb string.
    $dumpFwd = $dump -replace '\\', '/'
    $armFwd = $armFile -replace '\\', '/'
    $disarmFwd = $disarmFile -replace '\\', '/'
    $hitFwd = $hitFile -replace '\\', '/'

    $armLines = @('.echo GHOZTTY-ARM', 'r $t9=@rbp')
    $ids = @()
    for ($i = 0; $i -lt $offsets.Count; $i++) {
        $id = $i + 1
        $ids += $id
        $armLines += ('ba{0} w8 {1} "$$<{2}"' -f $id, (Format-RbpExpression -Offset $offsets[$i]), $hitFwd)
    }
    $armLines += ('bp /1 poi({0}) "$$<{1}"' -f (Format-RbpExpression -Offset $probe.RetSlotOffset), $disarmFwd)
    $armLines += 'g'
    $armLines | Set-Content -LiteralPath $armFile -Encoding ASCII

    @('.echo GHOZTTY-DISARM', ('bc ' + ($ids -join ' ')), 'g') |
        Set-Content -LiteralPath $disarmFile -Encoding ASCII

    @(
        '.echo GHOZTTY-DATABREAK-HIT',
        '.echo GHOZTTY-VICTIM-RBP',
        'r $t9',
        'r',
        '.echo GHOZTTY-WRITER',
        'ub @rip L3',
        'u @rip L2',
        '.echo GHOZTTY-STACK',
        '.lines -e',
        'kv 40',
        '.echo GHOZTTY-ALL-THREADS-HIT',
        '~*kv 40',
        ".dump /ma $dumpFwd",
        '.echo GHOZTTY-DATABREAK-END',
        'q'
    ) | Set-Content -LiteralPath $hitFile -Encoding ASCII

    # The entry breakpoint arms the slots; the crash filters keep the ordinary
    # crash capture (T450) for a run where the corruption faults before -- or
    # without -- touching an armed slot. Module+rva rather than a symbol
    # expression: it survives ASLR between sessions and cannot be ambiguous
    # (Zig gives overloads the same bare name).
    # `bu` rather than `bp` when the target process does not exist yet: the
    # module is loaded later, by a child, so the address cannot be resolved at
    # the loader break. cdb re-evaluates a `bu` on every module load, in every
    # process it is following, which is exactly the semantics -ChildDebug needs.
    $entry = ('bp0 {0}+0x{1:x} "$$<{2}"' -f $probe.ModuleName, $probe.ArmRva, $armFwd)
    New-CdbScript -DumpPath $dump -PrologCommands @($entry) |
        Set-Content -LiteralPath $scriptFile -Encoding ASCII

    $prevSym = $env:_NT_SYMBOL_PATH
    $env:_NT_SYMBOL_PATH = (Split-Path -Parent $probe.ExePath)

    $argList = @('-lines', '-cf', ('"' + $scriptFile + '"'))
    if ($AttachPid -gt 0) {
        $argList += @('-p', "$AttachPid")
    }
    else {
        $argList += ('"' + $probe.ExePath + '"')
        foreach ($x in $Arguments) { $argList += ('"' + $x + '"') }
    }

    & $Writer ("databreak: arming {0} slot(s) on {1}!{2} -- {3}" -f `
            $offsets.Count, $probe.ModuleName, $probe.Symbol, `
        (@($offsets | ForEach-Object { Format-RbpExpression -Offset $_ }) -join ', '))
    if ($AttachPid -gt 0) { & $Writer ("databreak: attaching to pid {0}" -f $AttachPid) }
    $t0 = Get-Date
    $p = Start-Process -FilePath $cdbPath -ArgumentList ($argList -join ' ') `
        -RedirectStandardOutput $log -RedirectStandardError $errLog -NoNewWindow -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        & $Writer "databreak: TIMEOUT after ${TimeoutSeconds}s -- killing"
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        $p.WaitForExit(10000) | Out-Null
    }
    $result.Seconds = [int]((Get-Date) - $t0).TotalSeconds
    $env:_NT_SYMBOL_PATH = $prevSym
    $result.ExitCode = $p.ExitCode
    $result.LogPath = $log
    $result.ErrLogPath = $errLog

    $parsed = Read-DataBreakLog -LogPath $log
    $result.ArmCount = $parsed.ArmCount
    $result.DisarmCount = $parsed.DisarmCount
    $result.Hit = $parsed.Hit
    $result.WriterSite = $parsed.WriterSite
    $result.WriterBlock = $parsed.WriterBlock
    $result.StackBlock = $parsed.StackBlock
    $result.VictimRbp = $parsed.VictimRbp
    $result.HitValue = $parsed.HitValue
    $result.LastTest = Get-LastProgressLine -Path $errLog

    # Read-CrashCatchLog walks the file line by line in PowerShell, which a
    # multi-million-line armed transcript cannot afford -- so only hand it
    # logs where a fast native scan sees the crash marker at all.
    $crashMarker = @(Select-String -LiteralPath $log -Pattern '^\s*(?:\d+:\d+>\s*)?GHOZTTY-CRASH-BEGIN\s*$' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($crashMarker.Count -gt 0) {
        $crash = Read-CrashCatchLog -LogPath $log
        if ($crash.Crashed) {
            $result.Crashed = $true
            $result.CrashResult = $crash
        }
    }
    if (Test-Path -LiteralPath $dump) { $result.DumpPath = $dump }

    Remove-Item -LiteralPath $scriptFile, $armFile, $disarmFile, $hitFile -Force -ErrorAction SilentlyContinue
    if ($result.Hit -or $result.Crashed) {
        Remove-OldCrashCapture -OutDir $OutDir -Keep $Keep
    } elseif (-not $KeepLog) {
        Remove-Item -LiteralPath $log, $errLog -Force -ErrorAction SilentlyContinue
        $result.LogPath = ''
        $result.ErrLogPath = ''
    }
    return $result
}
