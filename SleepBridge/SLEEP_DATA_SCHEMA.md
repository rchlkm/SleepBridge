# Sleep data schema — Google Fit ↔ Apple Health

## Google Fit's sleep schema

Google Fit models sleep in two layers: **sessions** (the overall sleep
period) and **segment points** (fine-grained stage data within a session).

### Sessions

A sleep session is fetched from:
```
GET /fitness/v1/users/me/sessions?startTime=...&endTime=...
```
Each session has an `activityType`. Sleep sessions are `activityType == 72`.
A session gives you the overall start/end time in milliseconds
(`startTimeMillis`, `endTimeMillis`) — but no stage detail by itself.

### Segment points (the stage detail)

To get the actual light/deep/REM/awake breakdown *inside* one session's time
range, you call:
```
POST /fitness/v1/users/me/dataset:aggregate
{
  "aggregateBy": [{ "dataTypeName": "com.google.sleep.segment" }],
  "startTimeMillis": <session start>,
  "endTimeMillis": <session end>
}
```
This returns a list of points, each with a start/end (in nanoseconds) and an
`intVal` describing the stage during that window. In practice, the Nest Hub
reports roughly **one point per minute** — so a single 7-hour sleep session
can come back as 400+ individual points, almost always long runs of the same
`intVal` repeated minute after minute. That's what SleepBridge's "Merge
Stages" step collapses into single spans.

### `com.google.sleep.segment` intVal reference

| intVal | Meaning |
|---|---|
| 1 | Awake (during the sleep cycle) |
| 2 | Sleep (generic — used when the source can't distinguish stages) |
| 3 | Out-of-bed |
| 4 | Light sleep |
| 5 | Deep sleep |
| 6 | REM sleep |

## Apple Health's sleep schema

Apple Health stores sleep as `HKCategoryTypeIdentifier.sleepAnalysis`
samples. Each sample is just a start date, an end date, and one value from
`HKCategoryValueSleepAnalysis`:

| Case | rawValue | Meaning |
|---|---|---|
| `.inBed` | 0 | Overall "in bed" span — a container period, not a sleep stage itself |
| `.asleepUnspecified` | 1 | Asleep, but the source couldn't tell which stage |
| `.awake` | 2 | Awake, within an otherwise asleep period |
| `.asleepCore` | 3 | Light/core sleep |
| `.asleepDeep` | 4 | Deep sleep |
| `.asleepREM` | 5 | REM sleep |

Apple expects an `.inBed` sample spanning the *whole* sleep period, separate
from and alongside the individual stage samples that sit inside it — it's
not derived automatically from the stage samples.

## The mapping

Google Fit and Apple Health don't line up 1:1, and Google Fit has no concept
of an overall "in bed" span at all — SleepBridge derives that itself from
each session's start/end. This is the exact table `SleepStageMapper.swift`
implements:

| Google Fit intVal | Google Fit meaning | → | Apple `HKCategoryValueSleepAnalysis` |
|---|---|---|---|
| *(session start/end)* | *(no equivalent)* | → | `.inBed` (synthesized, one per session) |
| 1 | Awake | → | `.awake` |
| 2 | Sleep (generic) | → | `.asleepUnspecified` |
| 3 | Out-of-bed | → | *(dropped — no clean Apple equivalent for a mid-session marker)* |
| 4 | Light sleep | → | `.asleepCore` |
| 5 | Deep sleep | → | `.asleepDeep` |
| 6 | REM sleep | → | `.asleepREM` |

## Why the merge step exists

Without merging, a night with Nest Hub sensing could produce 400+ HealthKit
samples (one per minute) instead of a handful (one per stage transition).
The merge stage collapses consecutive points of the same `intVal` into a
single run, **but only when they're actually contiguous in time** — if
there's a gap between two same-value points (missing data), they're kept as
two separate stages rather than treating the gap as if it were continuously
that stage. This trades a small amount of data reduction for not fabricating
sleep data during a period Google Fit didn't actually report on.

## Why duplicate-checking is exact-match, not time-overlap

Before writing, SleepBridge queries existing `HKCategorySample`s in the same
time range and skips any formatted sample whose start, end, *and* stage value
all match an existing one exactly. This is deliberately strict: a
same-start/different-end sample is treated as new data, not assumed to be an
update to the existing one — HealthKit samples are immutable once written, so
"updating" isn't really an option here anyway. If Google Fit's own data for a
past night ever changes retroactively, the old (now-stale) sample would stay
in Apple Health, and the corrected one would be added alongside it, since
there's no mechanism here for detecting or removing superseded samples.
