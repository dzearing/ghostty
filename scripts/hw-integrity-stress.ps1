# hw-integrity-stress.ps1 - self-verifying CPU + memory integrity stress (T449)
#
# Why this exists: when compilers and test binaries take access violations at
# random addresses, the first question is whether the MACHINE is computing
# correctly at all. This answers that with a measurement rather than a hunch.
#
# Each worker thread repeatedly:
#   1. allocates a fresh buffer (fresh allocation => fresh physical pages, so
#      the sweep roams over RAM instead of re-testing one hot region),
#   2. fills it from a deterministic PRNG seeded per (thread, round),
#   3. hashes it with SHA-256 and folds it with an integer checksum,
#   4. re-derives the SAME buffer and re-checks both.
#
# The values are reproducible by construction, so ANY mismatch is the hardware
# (or something injecting into the process) returning a different answer to the
# same computation. A clean run does not prove the box is healthy - it bounds
# how badly it is misbehaving under this particular load.
#
# Exit 0 = no mismatch observed, 1 = at least one mismatch (hardware verdict).

[CmdletBinding()]
param(
    [int]$Minutes = 4,
    [int]$Threads = [Math]::Max(2, [Environment]::ProcessorCount - 4),
    [int]$BufferMB = 32
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Threading;

public static class HwStress
{
    public static long Iterations;
    public static long Mismatches;
    public static string FirstFailure;

    // xorshift64* - cheap, deterministic, and touches every byte we allocate.
    private static void Fill(byte[] buf, ulong seed)
    {
        ulong x = seed | 1UL;
        for (int i = 0; i < buf.Length; i += 8)
        {
            x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
            ulong v = x * 2685821657736338717UL;
            buf[i]     = (byte)(v      );
            buf[i + 1] = (byte)(v >>  8);
            buf[i + 2] = (byte)(v >> 16);
            buf[i + 3] = (byte)(v >> 24);
            buf[i + 4] = (byte)(v >> 32);
            buf[i + 5] = (byte)(v >> 40);
            buf[i + 6] = (byte)(v >> 48);
            buf[i + 7] = (byte)(v >> 56);
        }
    }

    // A second, independent reduction so a fault has to fool two different
    // instruction mixes (SHA-NI and the plain integer ALU) to go unnoticed.
    private static ulong Checksum(byte[] buf)
    {
        ulong a = 0xcbf29ce484222325UL, b = 1469598103934665603UL;
        for (int i = 0; i < buf.Length; i++)
        {
            a = (a ^ buf[i]) * 1099511628211UL;
            b = b + buf[i] * 0x9E3779B97F4A7C15UL;
            b = (b << 7) | (b >> 57);
        }
        return a ^ b;
    }

    private static string Hex(byte[] h)
    {
        var sb = new System.Text.StringBuilder(h.Length * 2);
        foreach (byte x in h) sb.Append(x.ToString("x2"));
        return sb.ToString();
    }

    // Threads are created here rather than in PowerShell: a PowerShell
    // ScriptBlock cannot be used as a ThreadStart delegate on a raw .NET
    // thread, so a PS-side thread pool silently fails to start any work.
    public static Thread[] Start(int threads, int bytes, int seconds)
    {
        var ts = new Thread[threads];
        for (int i = 0; i < threads; i++)
        {
            ts[i] = new Thread(Worker);
            ts[i].IsBackground = true;
            ts[i].Start(new object[] { i, bytes, seconds });
        }
        return ts;
    }

    public static void Worker(object state)
    {
        object[] args = (object[])state;
        int id = (int)args[0];
        int bytes = (int)args[1];
        int seconds = (int)args[2];

        var sw = Stopwatch.StartNew();
        ulong round = 0;
        using (var sha = SHA256.Create())
        {
            while (sw.Elapsed.TotalSeconds < seconds)
            {
                round++;
                ulong seed = ((ulong)id << 40) ^ round;

                byte[] buf = new byte[bytes];
                Fill(buf, seed);
                string h1 = Hex(sha.ComputeHash(buf));
                ulong c1 = Checksum(buf);

                // Re-derive from scratch: same inputs, same code, same answer.
                byte[] buf2 = new byte[bytes];
                Fill(buf2, seed);
                string h2 = Hex(sha.ComputeHash(buf2));
                ulong c2 = Checksum(buf2);

                // And re-read the ORIGINAL buffer, which has now been sitting
                // in RAM while the rest of the machine hammered it.
                string h3 = Hex(sha.ComputeHash(buf));
                ulong c3 = Checksum(buf);

                Interlocked.Increment(ref Iterations);

                if (h1 != h2 || h1 != h3 || c1 != c2 || c1 != c3)
                {
                    Interlocked.Increment(ref Mismatches);
                    string msg = string.Format(
                        "thread={0} round={1} sha=({2},{3},{4}) sum=({5:x},{6:x},{7:x})",
                        id, round, h1.Substring(0, 16), h2.Substring(0, 16), h3.Substring(0, 16), c1, c2, c3);
                    Interlocked.CompareExchange(ref FirstFailure, msg, null);
                }
            }
        }
    }
}
'@

$seconds = [int]($Minutes * 60)
$bytes = $BufferMB * 1MB

Write-Host "hw-integrity-stress: threads=$Threads buffer=${BufferMB}MB duration=${Minutes}min"
Write-Host "  working set target ~$([int]($Threads * $BufferMB * 2 / 1024)) GB, fresh allocations each round"

$started = Get-Date
$workers = [HwStress]::Start($Threads, $bytes, $seconds)

while (($workers | Where-Object { $_.IsAlive })) {
    Start-Sleep -Seconds 20
    Write-Host ("  {0,5}s  iterations={1}  mismatches={2}" -f `
        [int]((Get-Date) - $started).TotalSeconds, `
        [HwStress]::Iterations, [HwStress]::Mismatches)
    if (((Get-Date) - $started).TotalSeconds -gt ($seconds + 60)) { break }
}
foreach ($t in $workers) { [void]$t.Join(30000) }

$iter = [HwStress]::Iterations
$bad = [HwStress]::Mismatches
$gb = [math]::Round($iter * $BufferMB * 2 / 1024, 1)

Write-Host ""
Write-Host "RESULT iterations=$iter verified=${gb}GB mismatches=$bad"
if ($bad -gt 0) {
    Write-Host "FIRST FAILURE: $([HwStress]::FirstFailure)"
    Write-Host "VERDICT: HARDWARE - the machine returned different answers to identical computations."
    exit 1
}
Write-Host "VERDICT: no computational mismatch observed under this load."
exit 0
