# The first capacity ladder, and why it is not in the result

The `floor`, `dbceiling` and `tune` phases of this run stand. The first
attempt at the `ladder` and `soak` phases does not. It is kept here in full —
`EXCLUDED-ladder-attempt-1.jsonl` and `excluded-raw/` — because the reason it
failed is worth more than the numbers would have been.

## What it looked like

Capacity per cell, median of three repetitions, with the spread beside it:

| candidate | cores | capacity | min | max |
|---|---|---|---|---|
| go | 1 | 14,250 | 4,500 | 15,000 |
| go | 2 | 14,250 | 14,250 | 18,000 |
| go | 4 | 18,750 | **1,250** | 48,000 |
| fpm | 4 | 8,000 | 6,000 | 18,000 |
| frankenphp | 4 | 5,250 | 5,250 | 19,500 |

A four-core Go service that carries 1,250 requests a second in one repetition
and 48,000 in another is not a measurement. The `tune` phase of the same run,
driving the same three candidates flat out on the same cores minutes earlier,
had them at 55,715, 20,379 and 25,556 — orderly, and scaling with cores.

## What was wrong

Two things, and only the second one is interesting.

**The reset was measured along with the candidate.** Between two ladder steps
`db/reset.sql` deletes the rows the previous step wrote, vacuums and issues a
`CHECKPOINT`. The next 30-second window started immediately afterwards, while
the database was still writing that checkpoint back. When that happened the
write half of the mix stalled behind it. It is visible in the data: the read
half is untouched and only writes spike — at `rep1 4c go`, read p99 3.34 ms,
write p99 10.61 ms.

**A single spoiled window was unrecoverable.** The search doubles the rate
until one fails, then bisects. 10.61 ms is six hundredths of a millisecond
over the 10 ms service level, so the very first step of that cell — 3,000
requests a second, on four cores, against a candidate that would go on to
carry 48,750 — was recorded as a failure. The search had no passing rate to
bisect against, turned downwards, and spent the rest of the cell confirming
that Go can serve 1,250 requests a second. The same thing happened to
`rep2 2c fpm`, whose first window showed a write p99 of 295 ms.

Everything else in the run was stable. The identical 3,000/s step was measured
in all 27 cells over two hours; CPU per request at that step varies by a few
per cent within each candidate-and-core combination and shows no drift over
the run. There was no slow half-hour to blame. Two windows out of 243 were
spoiled, and the search design turned both of them into a wrong answer for a
whole cell.

## What was changed

1. `reset_events` now waits `ladder.settleSeconds` (6 s) after the checkpoint
   before the next window starts.
2. A failing window is measured a second time at the same rate. The search only
   turns around when both windows agree. Both attempts are recorded; the second
   carries the suffix `_t2`.

The ladder and soak phases were then measured again, into this same directory.
Nothing else about the run, the images, the candidates or the pool sizes
changed; `tuning.jsonl` is the one the re-measured ladder used.

## Why it is published rather than deleted

A capacity number that comes out of a search is only as good as the search.
This one had a failure mode that produced confident, precise, wrong answers
rather than obvious garbage — `18,750/s, median of three` reads like a result.
It was caught because the closed-loop `tune` phase disagreed with it by a
factor of three. A run with only one way of measuring capacity would not have
caught it.
