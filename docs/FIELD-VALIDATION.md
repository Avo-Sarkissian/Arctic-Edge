# Field Validation Protocol

Everything in ArcticEdge is verified in a simulator and nothing is verified on snow. This document is the plan for one ski day that changes that.

It is deliberately ordered so the cheapest, most fatal checks come first. If Phase 1 fails, the rest of the day tells you nothing, because the app will not have recorded anything to analyse.

## Before you leave

- [ ] Install a **Release** build on the phone you will actually ski with. Debug builds carry the classifier HUD and different optimisation; do not validate on Debug.
- [ ] Launch once at home. Accept **Location (While Using)**, **Motion & Fitness**, and **Health**. Confirm Settings shows Location: *Precise*, Background capture: *Ready*, Barometer: *Available*.
- [ ] Settings, then **Delete all data**. Start the day from an empty store so frame counts are unambiguous.
- [ ] Note the starting battery percentage and the time.
- [ ] Bring a paper notebook or a second phone for the run log. You cannot annotate runs in the app, and you will not remember run 14 by the chairlift.

## Phase 1: does it capture at all?

This is the single most important measurement of the day. Everything else is downstream.

1. Tap **Start Day** at the base.
2. **Lock the screen** and put the phone in the pocket you normally use. Note which pocket and which orientation (screen toward leg or away).
3. Ski **three runs** without touching the phone at all. No peeking between runs.
4. After the third run, open the app and go to **History**.

**Pass:** three runs appear, with plausible start times, durations of roughly the right length, and a carving score or an explicit "not enough data" on each.

**Fail modes and what they mean:**

| What you see | What it means |
|---|---|
| No runs at all | Capture died on screen lock. The `location` background mode is not taking effect. Everything else is blocked until this is fixed. |
| One long run instead of three | The classifier is not detecting run ends. Chairlift detection is the suspect (it currently requires `CMMotionActivity` to report automotive). |
| Runs exist but every score says "not enough data" | Turns are not being detected, or the onset retag is dropping frames. Check the reported turn count in the shortfall message. |
| Durations wildly wrong | A clock-domain regression. Should be impossible now, but it is the bug that hid the longest. |

Record: **number of runs recorded / number of runs skied**, and the battery percentage.

## Phase 2: lift taxonomy

The classifier was designed against chairlifts. Surface lifts drag a standing rider on skis: moderate speed, real IMU variance, and `CMMotionActivity` may not report automotive. That can inject a phantom uphill "run".

Ride whichever of these the mountain has, one at a time, and note the time:

- [ ] Chairlift (the baseline case)
- [ ] Gondola or enclosed cabin
- [ ] T-bar, poma, or rope tow
- [ ] Magic carpet
- [ ] A long flat traverse or cat track (not a lift, but the other false-positive risk)

Afterwards, check History for runs that start during any of those windows.

**Pass:** no run recorded during any lift ride.
**Fail:** note which lift type produced a phantom run. That is a concrete classifier fix with a known trigger.

## Phase 3: the technique set (this is the calibration data)

This is what actually moves the carving score off provisional. The score cannot be calibrated from ordinary skiing, because ordinary skiing is all roughly the same quality. It needs a deliberate spread.

Ski **at least 12 runs** across this range, and **write down the run number and your own honest rating (1 to 5) immediately after each one**, while it is fresh:

| Runs | What to ski | Expected score direction |
|---|---|---|
| 3 | Your best carving. Clean edge-to-edge, no skidding, on a groomer that suits you. | Highest |
| 3 | Deliberate skidding. Brush every turn, never really set an edge. | Lowest |
| 2 | Very short radius turns, high cadence. | Tests the turn detector's lower bound |
| 2 | Very long radius turns, few per run. | Tests the minimum-turns gate |
| 2 | Deliberately asymmetric. Carve well one direction, skid the other. | Should tank the Symmetry sub-metric specifically |

Also useful if conditions allow:

- [ ] One run in **poor visibility or chop**, to see whether the chatter metric behaves.
- [ ] One **very short** run (under 15 seconds), which should honestly report "not enough data" rather than a number.

Your ratings are the ground truth. Without them the export is just numbers with nothing to fit against.

## Phase 4: endurance and cold

Let the day run its natural length. At the end:

- [ ] Note **final battery percentage** and total elapsed hours.
- [ ] Note whether the phone ever shut down unexpectedly. Lithium cells sag in the cold and iPhones can shut down at a nominally healthy charge; the app models battery as a percentage threshold only and has no notion of a cold shutdown.
- [ ] If it did die, note the percentage it died at and roughly the temperature.
- [ ] Note whether the phone felt hot at any point (thermal throttling drops the sample rate, which the score now gates on).
- [ ] Check Settings for a **frame count** and for any capture error banner on the Today tab.

Tap **End Day** deliberately rather than force-quitting, so orphan recovery is not exercised accidentally. If you want to test orphan recovery, force-quit mid-run **once**, on purpose, and note it.

## After the day: the labelling pass

1. **Settings, then Export runs for calibration.** Share the JSON files off the device (AirDrop to a Mac is simplest).
2. Each file carries the run's frames, the score the current model produced, and the model version that produced it.
3. Build a table: run number, your 1-to-5 rating, the app's score, and the three pillar scores.
4. Look for the two things that matter:
   - **Rank correlation.** Does the app order the runs roughly the way you did? This matters far more than absolute agreement. A model that ranks correctly but sits 20 points low is a rescaling job. A model that ranks wrongly is a design problem.
   - **Range use.** If every run lands between 55 and 70, the anchors are too wide and the score is not discriminating. If runs pin at 0 or 100, they are too narrow.
5. Refit the anchors in `CarvingScoreModel.v1` so the model's output tracks your ratings, bump the version string, and drop the `-provisional` suffix.
6. Update `docs/CARVING-SCORE.md` with the anchors used and the data they came from.

Keep the raw exports. They are the only labelled ski data this project has, and the next recalibration will want them too. Note that raw frames are pruned from the device after 30 days, so **export before then** or the data is gone.

## What this day cannot tell you

Being explicit so the results are not over-read:

- **One skier, one phone, one pocket.** Cross-device and cross-pocket comparability stays unproven. Two people's scores are not yet meaningfully comparable, and nothing in the app currently normalises for that.
- **One mountain, one snow condition.** Anchors fitted on a single day's groomers may not hold for spring slush or ice.
- **Your own ratings are subjective** and you know what the app scored, which biases them. Rate the run before looking at the score if you can manage it.

## Results log

Fill this in on the day.

```
Date:                      Mountain:
Phone / OS:                Build: Release / Debug
Pocket:                    Start battery:        End battery:
Elapsed hours:             Unexpected shutdowns:

Phase 1  runs recorded / runs skied: ____ / ____
Phase 2  phantom runs by lift type:
Phase 3  run log (number, technique, my rating 1-5, app score):

Capture errors seen:
Anything surprising:
```
