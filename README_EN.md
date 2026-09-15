[中文](README.md) | **English**

<p align="center"><img src="Resources/icon-1024.png" width="96" alt="At-Home Sports"></p>

# At-Home Sports · fitcoach-ios



**Coaches schedule lessons and deduct lesson credits on their phones; students can check their remaining lessons anytime.**

![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white) ![SwiftUI](https://img.shields.io/badge/SwiftUI-0D84FF?logo=swift&logoColor=white) ![Platform](https://img.shields.io/badge/iOS%2018.0%2B%20·%20macOS%2015.0%2B-000?logo=apple) ![TestFlight](https://img.shields.io/badge/TestFlight-内测中-0D84FF) ![License](https://img.shields.io/badge/License-MIT-green)

The mobile client of a production system built for a real coach, sharing one backend and one dataset with the web and mini-program clients. Before release, 38 contract assertions were exercised against a real temporary backend. This even uncovered a misleading green result: when the intended port was occupied, tests hit another server and all passed—a green more dangerous than a red.

<table><tr>
<td align="center" width="25%"><img src="docs/screenshots/01-01-schedule.png" alt="Schedule: overdue lessons awaiting action are flagged (sample data)"><br><sub>Schedule: overdue lessons awaiting action are flagged (sample data)</sub></td>
<td align="center" width="25%"><img src="docs/screenshots/02-04-student-detail.png" alt="Student page: lesson balance, attendance rate, and fitness progress (sample data)"><br><sub>Student page: lesson balance, attendance rate, and fitness progress (sample data)</sub></td>
<td align="center" width="25%"><img src="docs/screenshots/03-10-trend.png" alt="Fitness trend: a faster 50-meter run means a smaller value, which still counts as improvement"><br><sub>Fitness trend: a faster 50-meter run means a smaller value, which still counts as improvement</sub></td>
<td align="center" width="25%"><img src="docs/screenshots/04-07-student-mode.png" alt="Student view: read-only, with remaining lessons, the next lesson, and fitness progress on one screen (sample data)"><br><sub>Student view: read-only, with remaining lessons, the next lesson, and fitness progress on one screen (sample data)</sub></td>
</tr></table>

<details><summary>More screenshots</summary><table><tr>
<td align="center" width="25%"><img src="docs/screenshots/05-08-availability.png" alt="Availability: weekly rules + exceptions + the next two weeks; the backend rejects scheduling conflicts"><br><sub>Availability: weekly rules + exceptions + the next two weeks; the backend rejects scheduling conflicts</sub></td>
<td align="center" width="25%"><img src="docs/screenshots/06-09-audit.png" alt="Change log: every correction, exception, and backfilled entry that needs an explanation leaves a trace (sample data)"><br><sub>Change log: every correction, exception, and backfilled entry that needs an explanation leaves a trace (sample data)</sub></td>
</tr></table></details>

## What It Does

| Feature | Description |
|---|---|
| **One-handed scheduling and lesson deductions for coaches** | Schedule, mark completed, or mark absent directly from the calendar; overdue lessons awaiting action are flagged. All business rules (balances, state machines, conflicts) live in the backend, with no local client decisions—two copies of the same rules will eventually disagree. |
| **Read-only student access through a single link** | Students receive a read-only view of remaining lessons, their next lesson, and fitness improvements. Deactivating a student also revokes their link. |
| **Every change has an explanation** | Corrections, exceptions, and backfilled entries—all changes needing an explanation are recorded by default. Sensitive actions such as deducting an extra lesson are highlighted in red. For a production system serving a real client, reconciliation builds trust. |

## Availability

The iOS version is being prepared for App Store release and is not yet available for public download; the source code and product introduction are public.

The backend is `fit.tianli.cyou` (registration gives you your own ledger), sharing the same data with the web and mini-program clients. Clone and run it; after login, the data is yours.

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme FitCoach -destination 'generic/platform=iOS Simulator' build
```

- The repository's `*.sh` files are shims for the author's local app-fleet scripts (three-platform builds / physical-device installation / TestFlight). They depend on shared tools under `~/Dev` that are not in this repository, and exit explicitly if those tools are unavailable.
- `Shared/PlatformCompat.swift` is a byte-for-byte copy of a shared file (same-named no-ops on macOS for iOS-only SwiftUI modifiers); do not edit it here.

See [DEVELOPING.md](DEVELOPING.md) for development details (regression, validation channels, and constraints).

## Related

- Product page: <https://apps.tianli.cyou/p/fitcoach-ios.html>
- App-fleet overview (how the 10 apps came about): <https://apps.tianli.cyou/ios.html>
- Tutorial: [From Zero to TestFlight: The Complete Path to Building an iPhone App Alone](https://blog-ai.tianli.cyou/nine-ios-apps-in-two-weeks)

## License

MIT © 2026 曾田力 (Tianli Zeng)
