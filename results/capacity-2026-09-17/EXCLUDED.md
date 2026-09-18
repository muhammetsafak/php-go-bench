# Two capacity ladders that are not in the result, and why

The `floor`, `dbceiling` and `tune` phases of this run stand. Two attempts at
measuring capacity with a **search** do not. Both are kept here in full —
`EXCLUDED-ladder-attempt-1.jsonl` with `excluded-raw/`,
`EXCLUDED-ladder-attempt-2.jsonl` with `excluded-raw-2/` — because the reason
they failed is worth more than the numbers would have been, and because the
second one failed for a reason the first one hid.

The published capacity comes from a third method, `phase_grid`: seven fixed
rates per cell, the same seven in every repetition, and a rate counts as
carried when a majority of the repetitions met the service level at it.

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
until one fails, then bisects. 10.61 ms is six tenths of a millisecond
over the 10 ms service level, so the very first step of that cell — 3,000
requests a second, on four cores, against a candidate that would go on to
carry 48,000 — was recorded as a failure. The search had no passing rate to
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


---

# Attempt 2 — the search was never the right shape

The fixes above were made and the ladder and soak were measured again. The
result was worse, and this time nothing was spoiled.

| candidate | cores | rep 1 | rep 2 | rep 3 |
|---|---|---|---|---|
| go | 1 | 1,250 | 6,500 | 3,500 |
| go | 4 | 45,000 | 24,000 | — |
| fpm | 1 | 1,750 | 2,750 | 750 |
| fpm | 4 | 4,250 | 5,750 | — |

The same three candidates driven flat out in the `tune` phase, on the same
cores, with the same pool sizes, differ by a few per cent between repetitions:
go 17,042 / 29,721 / 55,715 at one, two and four cores; fpm 6,188 / 11,260 /
20,379. CPU per request at a fixed rate was stable across the whole seven-hour
run to within about ten per cent. Nothing was drifting.

## What the numbers actually said

The first step of the `fpm`, one core, repetition 1 cell, at 3,000 requests a
second:

* every one of the 90,000 requests was answered, both halves at exactly their
  target rate
* p50 1.44 ms
* **p99 3,718 ms**
* 22.7 CPU-seconds over a 30 s window — 0.76 of the one core it had

A service that is not CPU-saturated, is delivering the full rate, and has a
median of 1.4 ms does not have a 3.7-second 99th percentile because it ran out
of capacity. oha reports two latencies and they disagreed by a factor of
twenty:

| | p50 | p75 | p99 | slowest |
|---|---|---|---|---|
| time to first byte | 1.42 ms | 47 ms | **191 ms** | 267 ms |
| latency-corrected | 1.44 ms | 1,539 ms | **3,718 ms** | 3,819 ms |

The server answered in 191 ms at the 99th percentile. The other 3.5 seconds is
time the request spent waiting to be **sent**: with `--latency-correction` a
request is timed from the moment it was due, so once responses get slow enough
that the generator's connections are all occupied, the schedule slips and every
subsequent request inherits the slip. That is the correct thing for an
open-loop measurement to do — it is what stops a load generator from politely
slowing down and calling the result a pass. But it turns the boundary into a
**cliff**: a rate is either comfortably met or catastrophically missed, with
almost nothing in between, and the cliff sits wherever the queue happened to
tip that time.

## Why a search cannot measure a cliff that moves

An exponential-then-bisect search assumes that pass/fail is monotone in the
rate and stable enough to interrogate one point at a time. Neither holds here.
Every repetition asks a different sequence of questions, so every repetition
walks a different path across a boundary that is itself moving, and the answer
is wherever that particular walk stopped. Confirming a failure with a second
window — the attempt-2 fix — narrows the noise but does not change the shape of
the problem: `fpm` at one core failed 3,000/s twice in a row in repetition 1
and carried 2,750/s in repetition 2.

The `tune` phase disagreed with attempt 1 by a factor of three and with attempt
2 by a factor of eight. It was right both times.

## What replaced it

Seven fixed rates per cell, anchored to what that candidate carried flat out at
that core budget, measured in all three repetitions, and voted:

* nothing to steer — a spoiled window costs one point in one repetition
* the repetitions answer the *same* questions, so they can be compared
* the output is a curve, not a point: the rate at which latency leaves the
  service level is visible rather than inferred, and the published number is
  the last grid rate a majority of repetitions carried

The cost is measuring some rates that are obviously out of reach. That is the
cheaper mistake.
