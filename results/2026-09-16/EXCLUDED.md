# Excluded and re-measured: ceiling block, frankenphp, repetition 3

The host went to sleep (lid closed) while this block was running.
`caffeinate -i` prevents idle sleep, not lid sleep. The block started at
14:56:43 UTC. The four `write` runs span the sleep, as the gaps in `run.log`
show:

| run | logged | rps (as logged) | gap since previous log line |
|---|---|---|---|
| `ceil_frankenphp_write_c16_r3` | 15:02:47 | 14,315 | 175 s (≈ 18 s expected) |
| `ceil_frankenphp_write_c64_r3` | 15:59:53 | 15,295 | 3,426 s |
| `ceil_frankenphp_write_c128_r3` | 16:09:47 | 12,128 | 594 s |
| `ceil_frankenphp_write_c256_r3` | 16:24:26 | 13,635 | 879 s |

A 15-second window that contains a suspended VM is not a measurement. The
`auth` and `read` runs of the same block ran before the sleep and looked
normal, but the whole block was re-measured so that repetition 3 comes from
a single uninterrupted session:

    STAMP=2026-09-16 CANDS=frankenphp REP_FROM=3 CEIL_REPS=3 ./bench/run.sh --ceiling

The re-run starts at the second "ceil rep 3 — frankenphp" line in `run.log`
(16:29:52 UTC). It is recorded under `topups` in `meta.json`.

**The raw files of the interrupted block were not kept.** They were meant to
be moved aside before the re-run, but the move command failed without an
error: `git mv -k` skips untracked files and still exits 0. The re-run then
wrote over them under the same names. The only record of the interrupted
block is the set of log lines in `run.log`, summarised above. No figure in
`summary.json` comes from the interrupted block.
