# ev/select over a threaded channel: one writer's values out of order, or held

One writer thread gives `0 … n-1` and then `:done` into an `ev/thread-chan`. The main fiber reads that channel through `ev/select`, beside a plain channel that a local fiber keeps feeding. A single writer's values should arrive, all of them, in the order given.

```sh
janet repro.janet              # reads through ev/select
MODE=take janet repro.janet    # control: ev/take alone
```

`RUNS` (default 20) and `N` (default 3000) set the runs and the number of values. The script exits 1 if any run went wrong.

## Results

Janet 1.43.0-dev-b7e32da0 on Windows 11, built with MSVC:

| Reader | Runs wrong |
|---|---|
| `ev/select` | 20 of 20, 10 of 10, 5 of 5 |
| `ev/take` (control) | 0 of 20, 0 of 5 |

Every run through `ev/select` receives values out of order somewhere in the middle. Every run then ends in one of two ways.

1. **The end marker overtakes the data**, in about a third of runs. `:done` arrives while one value (2997, 2998 or 2999) is still behind it, and that value is found in the channel afterwards.
2. **The reader hangs**, in about two thirds of runs. It has all `n` values but never receives `:done`, although the plain channel keeps answering the select for the whole 10 s deadline. When the reader gives up, the channel holds nothing (`ev/count` is 0). A moment later `:done` is there. The value was held in flight, not among the channel's items, and came out only once the reader's select was cancelled.

```
run 0: hung true, got 3000 of 3000, in order false, held when the reader stopped 0, left after @[:done]
run 2: hung false, got 2999 of 3000, in order false, held when the reader stopped 0, left after @[2998]
```

### The experiments

Same build and machine, 20 runs each, through `ev/select` (see "Experiments" below):

| Run | Out of order | `:done` before its data | Hung |
|---|---|---|---|
| Feeder every 0.0001 s (as above) | 20 | about a third | about two thirds |
| Same, `QUIET=1` | 20 | 8 | 0 |
| Feeder every 0.01 s (`FEED=0.01`) | 13 | 0 | 0 |

With `QUIET=1` the reader had all 3000 values and no `:done` in 12 runs: the runs that hang without it. In all 12, `:done` arrived as soon as the feeder stopped, with the reader still in the same select and nothing cancelled; the script's timing showed 0.0 ms, under its 0.1 ms resolution. The 8 other runs were the end marker overtaking one value (2996 to 2999), which the experiment does not touch.

```
run 0: hung false, got 3000 of 3000, in order false, held when the reader stopped 0, left after @[], :done came 0.0 ms after the feeder stopped
run 2: hung false, got 2999 of 3000, in order false, held when the reader stopped 0, left after @[2999]
```

So the end marker in the hang was neither lost nor held in the channel: it was in flight for as long as the plain channel kept waking the reader, and arrived within a turn of the loop once nothing did. A feeder slow enough to let a turn pass between ticks ends the hangs, and makes the reordering rarer but not gone.

Not yet run under Linux.

## What it points at

A give to a threaded channel hands its value to the first queued reader by posting an event to that reader's thread, without checking whether the reader still wants it (`janet_thread_chan_cb`, `src/core/ev.c`). A select answered by its other channel leaves its read queued on the threaded channel. The next give goes to that stale read. The callback then passes the value on or pushes it back, but by then a later give from the same writer may already have reached the next select.

Upstream `cd946c45` ("Apply fix for threaded channels 'eating' values") made the callback keep such a value instead of freeing it, and it is in the Janet tested here. The value is kept, but not in order, and in the hang not delivered until the select is cancelled.

### The hang, as the source reads (a hypothesis, tested below)

When `janet_thread_chan_cb` finds the read it was posted to stale, it does not deliver the value: it pops the next read from `read_pending` and posts the value to it again, as a new event (`src/core/ev.c`, the resend under "Fiber has already been canceled or resumed"). The next read is usually the one the reader's newest select registered.

`janet_loop1` runs expired timers, then the scheduled fibers, and only then polls events. The feeder sleeps 0.0001 s, so its timer has expired on every turn, and every turn goes:

1. The feeder gives `:tick` to the plain channel. That wakes the reader (`janet_schedule` raises its `sched_id`), so its read on the threaded channel is stale.
2. The reader selects again and registers a fresh read.
3. Only now is the posted event handled. It finds its read stale, and posts the value to the fresh one.

The value never lands among the channel's items, so `ev/count` says 0. Once the reader's select is cancelled, no fresh read is registered, the resend finds `read_pending` empty and pushes the value back into the items: that is when `:done` shows up. It happens at the end because during the run the writer's next give keeps things moving; after the last value nothing does.

The reordering needs no loop: the writer hands value *i* to a stale read (it may not look at a fiber of another thread), hands *i+1* to the reader's fresh one, and when the callback for *i* finds its read stale, *i+1* has already been delivered.

## Experiments

The hypothesis says the end marker is not lost or stuck in the channel: it is bounced from read to read for as long as the plain channel keeps waking the reader. Two switches test that.

```sh
QUIET=1 janet repro.janet      # stop the feeder once all n values are in
FEED=0.01 janet repro.janet    # feed the plain channel every 10 ms
```

- **`QUIET=1`.** When the reader has all `n` values and no `:done`, it stops the feeder and goes on selecting exactly as before; nothing is cancelled. Each such run is printed with how long `:done` took after the stop. If the hypothesis holds, the runs that hung without it now end, with `:done` arriving within a few ms of the stop. If they still hang to the deadline, the value is held somewhere else, and the hypothesis is wrong.
- **`FEED=0.01`.** A bounce needs the reader woken between every repost and its handling, so with a tick only every 10 ms it should get through within a turn: the hangs should vanish. The reordering needs a tick while the writer is giving, so it should become rarer too, without the explanation predicting it gone.

Both have been run on Windows; their results are under "Results". A run under Linux (or WSL) as well would show it is not Windows-specific, which nothing in the mechanism suggests it is.

Plain `ev/take` on the same channel is clean, so the stale select read is what triggers it.

## Where it came from

[gp](https://git.sr.ht/~pepe/gp) waited with `ev/select` over a threaded channel and a plain one, and lost a thread producer's last messages under load. gp now relays the threaded channel into the plain one from a single fiber that only takes.
