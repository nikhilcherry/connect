# 48-hour finals plan (Oct 9–11)

**First, check the rules.** If the finals require code written during the event, or want pre-existing work declared, say plainly in the pitch what existed before (the app, scan page, backend, the three on-device features, the new coordination features) and what is built live. Everything in `git log` before the event is the baseline.

## Baseline going in (all verified, see README)
QR tag → masked chat, plate-as-QR, on-device plate OCR, photo labelling (conservative), on-device translation, voice reply, replies in the stranger's language, seen receipt, offline send, family "who's on it", multi-car, account deletion, CI, 130 backend checks, 53 app tests.

## Build during the event, in this order
| # | Feature | Why | Rough size | Verify with |
|---|---|---|---|---|
| 1 | **Proof of plate ownership**: owner photographs the RC, on-device OCR reads the plate, matches the car, marks it `verified`; the plate lookup prefers verified over unverified | Closes the plate-squatting gap; strong on-device AI story | 4–6 h | `integration_test` with a rendered RC image + e2e for the lookup rule |
| 2 | **Account recovery**: one-time backup code (no email, no phone) restores the car after a reinstall | Reinstall currently loses the car | 4–5 h | e2e + emulator reinstall |
| 3 | **Weekly "back by" schedule**: set office hours once; the scan page shows the return time without the owner setting it | Owners forget to set "back by" | 3–4 h | e2e + unit test on the schedule maths |
| 4 | **Duplicate-alert guard** for a retry after a lost reply | Hardens the offline send | 1–2 h | e2e |
| 5 | **Stronger photo understanding** (only if a better on-device model fits) | The current labeller is deliberately conservative | open | measure on real photos first |

## Where this stands (early on 10 Oct)
| Planned | State |
|---|---|
| 1. Proof of plate ownership | An RC check runs when a car is added, but on demo data with a simulated comparison. Nothing is marked `verified` on the server and the plate lookup rule is unchanged |
| 2. Account recovery | Not started. A build pointed at a new server address now keeps the account, which was the way phones were losing their cars during the event |
| 3. Weekly "back by" schedule | Not started |
| 4. Duplicate-alert guard | Done: `alerts.client_ref`, 9 e2e checks, and the scan page sends a reference with every alert |
| 5. Stronger photo understanding | Not started |

Built instead, because the venue showed what was missing (see `APP_FEATURES.md`): the app opening with no connection, *Say it with sound* (alerts carried between phones by ultrasound where there is no signal), *Witness mode*, and `scripts/demo-up.sh` to keep the laptop backend up.

Still owed before the demo: publish the scan page (`scripts/demo-up.sh --publish`), try *Say it with sound* between two real phones, and try Witness mode with a real knock.

## Timeline
- **Hour 0–2:** install the APK on the iQOO phone, run `docs/demo-runbook.md` end to end, write down what breaks. Fix those first.
- **Hour 2–14:** features 1 and 2.
- **Hour 14–20:** sleep, or feature 3.
- **Hour 20–34:** features 3 and 4, then re-run the runbook on the phone.
- **Hour 34–42:** polish, record the demo video with real device footage, update the deck.
- **Hour 42–48:** freeze. No new features. Rehearse twice. Push, confirm CI is green, build the arm64 APK.

## Suggested split (team: Nikhil, Shreyas, Koustav, Deekshitha)
- **Nikhil:** features 1 and 2 (app + backend).
- **Shreyas:** feature 3 and the e2e tests for it.
- **Koustav:** real-device testing, demo video, narration.
- **Deekshitha:** deck, Q&A prep, translation review with a native speaker (Kannada and Tamil are unreviewed).

## Rules for the 48 hours
- One feature at a time, committed and pushed when its test passes. Never leave `main` red.
- Run `node supabase/tests/e2e.mjs` and `flutter test` before every push.
- Anything not verified on the phone gets labelled that way in the pitch, as in the runbook.
