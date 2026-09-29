# Connect — Free Features Roadmap

_Researched 2026-09-17. Constraint: every feature must cost nothing to run._

## Free building blocks

| Service | What's free | Limit to watch |
| --- | --- | --- |
| Firebase Cloud Messaging (push) | Unlimited messages, no per-message charge | None |
| Supabase free plan | 50,000 monthly users, 500 MB database, 1 GB files, 500k function calls/month, 5 GB egress | **200 concurrent live (realtime) connections**; project pauses after 1 week with no activity |
| On-device (phone storage, sensors, PDF generation) | Everything | Phone storage only |
| Links out to other apps (Google Maps, Parivahan, WhatsApp) | Everything | None |

The 200-connection limit is the real ceiling. Once push is in, the app should
stop holding a live connection open all the time.

## Build next: makes the core loop stronger

1. **Push notifications.** Alerts arrive even when the app is closed. Free, and it keeps us under the 200-connection limit.
2. **"Back in 10 minutes" status.** The owner sets e.g. "Parked till 6:30" before walking away. The scan page shows it before the stranger writes anything. One database column.
3. **Share the car with family.** One tag alerts everyone in the household. Database changes only.
4. **Medical info for accidents.** Opt-in blood group and allergies, shown on the scan page only after someone picks "Accident". Free; the privacy wording needs care.
5. **Photos on alerts.** A stranger attaches a photo of the damage or blocked gate. Compressed on the phone, deleted after 7 days, stays well inside 1 GB.

## Reasons to open the app every week (stored on the phone)

6. **Where did I park.** Location, photo and note, plus a reminder before paid parking runs out. "Navigate back" opens Google Maps with a plain link.
7. **Fuel and expense log** with mileage (km/l). The user types the price at the pump; free fuel-price APIs are unofficial scrapers.
8. **Document wallet.** Photos of RC, insurance, PUC and licence, kept only on the phone. Must say it doesn't replace DigiLocker or mParivahan (the legally valid copies).
9. **Service history as a PDF.** Built on the phone; helps when selling the car.
10. **Challan check.** A link to the official Parivahan e-challan site. No paid API, no scraping.

## Growth

11. **WhatsApp-ready sticker image** plus a "protect a friend's car" share button.
12. **Housing society mode.** An admin sees how many cars are tagged and broadcasts notices ("Move cars for cleaning, Sunday 8am"). Free now; the natural paid product later.
13. **Hindi in the app,** then Kannada and Tamil. Translated text only; the scan page already has Hindi.
14. **Live trip sharing with family.** A link that updates your location. Uses live connections, so build it after push.

## Skip: not actually free

| Idea | Why |
| --- | --- |
| Google Maps / Places SDK | Billed per use. Link out to the Maps app instead |
| Phone-number login, SMS, masked calls | Paid per message or minute |
| Automatic RC lookup | About ₹3 per car |
| Open-Meteo weather | Free tier is non-commercial only |
| OpenStreetMap public tile / Overpass servers | Can cut off heavy apps without warning |
| Pothole and road-hazard reports | Google Maps and Mappls already do this |

## Status (2026-09-24)

Built, all of the list above:

- 1 Push notifications: FCM code on both sides (`services/push.dart`, `supabase/functions/_shared/push.ts`,
  `notify` function). Switched off until a Firebase project exists; see README "Push notifications".
  Realtime now disconnects in the background once push is on, for the 200-connection cap.
- 2 "Back by", 3 family sharing, 6 where-did-I-park: built 2026-09-17.
- 4 Medical info (Safety → Medical info), shown only on accident threads after the plate check.
- 5 Photos on alerts: shrunk in the browser, private bucket, signed URLs, swept after 7 days.
- 7 Fuel and expense log with full-to-full mileage and a 6-month spend chart (on the phone).
- 8 Document wallet (on the phone only, with the DigiLocker disclaimer).
- 9 Service history PDF, built on the phone.
- 10 Challan check: copies the plate and opens the Parivahan e-challan page.
- 11 Sticker image (PNG share) and "Protect a friend's car".
- 12 Housing society mode: admin join code, member/tagged counts, roster without plates, notices with push.
- 13 Hindi, Kannada and Tamil in the app (and on the scan and trip pages).
- 14 Live trip sharing: foreground-service location, `connect.example.com/trip#TOKEN`, polled, not realtime.

## Recommended next build

Push notifications, "back in 10 minutes", family sharing, where-did-I-park.
Together they make the tag work better and give people a reason to open the
app when nobody has scanned their car.

## Sources

- [Supabase free tier limits (Automation Atlas)](https://automationatlas.io/answers/supabase-free-tier-limits-2026/)
- [Firebase pricing](https://firebase.google.com/pricing)
- [Is FCM actually free? (PushEngage)](https://www.pushengage.com/firebase-push-notification-pricing/)
- [Open-Meteo terms](https://open-meteo.com/en/terms)
- [OSM tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
- [Overpass API (OSM Wiki)](https://wiki.openstreetmap.org/wiki/Overpass_API)
- [Fuel price API options (Nixinfo)](https://nixinfo.in/daily-fuel-price-api-india)
- [Eko RC verification pricing](https://eps.eko.in/products/vehicle-rc-verification-api)
