[中文](README.md) | **English**

<p align="center"><img src="Resources/icon-1024.png" width="96" alt="At-Home Sports"></p>

# At-Home Sports · fitcoach-ios



**Coaches schedule lessons and deduct lesson credits on their phones; students can check their remaining lessons anytime.**

![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white) ![SwiftUI](https://img.shields.io/badge/SwiftUI-0D84FF?logo=swift&logoColor=white) ![Platform](https://img.shields.io/badge/iOS%2018.0%2B%20·%20macOS%2015.0%2B-000?logo=apple) ![TestFlight](https://img.shields.io/badge/TestFlight-内测中-0D84FF) ![License](https://img.shields.io/badge/License-MIT-green)

The mobile client of a production system built for a real coach, sharing one backend and one dataset with the web and mini-program clients. Before release, the contract assertions (57 today) were exercised against a real temporary backend. This even uncovered a misleading green result: when the intended port was occupied, tests hit another server and all passed—a green more dangerous than a red.

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

## Command line (for agents)

The app is for people; the `fitcoach` command line is for agents. It compiles the app's own `Sources/Models.swift`, `TimeKit.swift`, `API.swift` and `QuickSetup.swift` together with `cli/*.swift` into a macOS command-line tool that calls the same `/coach/api/*` endpoints. It reads and changes the same data as the app, the web client and the mini program; business rules stay in the backend only.

Where it lives: the Mac build of the app compiles it into the bundle as `上门体育.app/Contents/Resources/bin/fitcoach` (the `FitCoachCLI` target in `project.yml`, macOS only; the iOS app does not carry it). With the Mac app installed, `bash cli/build.sh --link-app` points `~/.local/bin/fitcoach` into the bundle; without it, use the repo entry.

```bash
bash cli/build.sh --link-app # Mac app installed: ~/.local/bin/fitcoach -> Contents/Resources/bin/fitcoach in the bundle
bash cli/build.sh --link     # no Mac app: builds build/cli/fitcoach and links ~/.local/bin/fitcoach to the repo entry cli/fitcoach
printf '%s\n' "$PASSWORD" | fitcoach login --email coach@example.com --password-stdin
fitcoach status --json                                   # login state, account, server today/now
fitcoach schedule --range week --json                    # schedule and warning bar
fitcoach sessions options --student 3 --json             # get package_id / location_id before booking
fitcoach sessions add --package 5 --start '2026-10-08 10:00' --minutes 60 --location 1 --json
fitcoach sessions status 42 --to completed --json        # deduct a lesson
fitcoach students link 3 --reveal | fitcoach student-view --token-stdin --json   # check what the student actually sees
```

| What the app shows or does | Command |
|---|---|
| Login state and account | `status` · `login` · `logout` · `register` · `password` |
| Schedule: today / week / overdue, warning bar | `schedule [--range today\|week\|overdue] [--date D]` |
| Students: list, detail, link state | `students list` · `students show ID` · `students link ID [--reveal]` |
| Students: create, edit, activate / deactivate; issue / replace / revoke link | `students add` · `students update ID` · `students issue-link ID [--replace]` · `students revoke-link ID --reason R` |
| Booking options, book, backfill, edit, change status (deduct) | `sessions options` · `sessions add` · `sessions edit ID` · `sessions status ID --to S` · `sessions show ID` (with that session's change history) |
| Packages: create, edit, void / unvoid | `packages add` · `packages edit ID` · `packages void ID --yes` (use `--dry-run` first to see how many lessons it cancels) · `packages void ID --undo` |
| Locations, weekly availability rules and exceptions | `locations list\|add\|update` · `availability show\|add-rule\|rm-rule\|add-exception\|rm-exception` |
| Fitness metrics, growth, measurements | `metrics list\|add\|update\|seed` · `growth STUDENT_ID [--metric ID]` · `measurements add` · `measurements rm ID --yes` (`--dry-run` only reads that row) |
| Change log | `audit [--all] [--student ID]` |
| Student read-only view | `student-view --token-stdin` |
| Quick start (the same orchestration as the app) | `setup [--location NAME] [--days weekdays\|daily\|weekend]` |
| Delete account (whole tenant, irreversible) | `account delete --confirm delete-account` (check the target with `--dry-run` first) |

- Every command has `--help`; `--json` prints `{"ok": true, …}` and read commands pass the backend fields through unchanged (decimals in their shortest form, matching the backend text, e.g. `12.3`); failures print `{"ok": false, "code": …, "error": …}`.
- Exit codes: 0 success · 1 network, server 5xx (`server_error`, retry later) or decode · 2 usage · 3 signed out or student link invalid · 4 backend rejected (400 hard reject, `--force` does not override) · 5 needs `--force` (409 soft warning) or `--yes` / `--confirm` · 6 login failed or throttled (401 / 429) · 7 the record to read does not exist.
- 7 applies to reads, to the read-then-write `update` / `edit` commands and to `--dry-run`. Direct writes (`sessions status`, `packages void`, `measurements rm`, `availability rm-rule` and so on) on a missing id, or on another coach's id, get the backend's 400 "… does not exist" and exit 4.
- Deleting data needs explicit confirmation, matching the app's confirmation dialogs: `measurements rm` and `packages void` (which also cancels the package's scheduled lessons) exit 5 without `--yes`; `account delete` needs the literal `--confirm delete-account`. All three have a read-only `--dry-run`.
- `setup` is the app's Quick Start orchestration. It only fills blanks and never edits or deletes: when every existing rule is 09:00–18:00 on a chosen day (including rules left by an interrupted run), it adds only the missing days; any other time range, any day outside the choice or any exception leaves availability untouched.
- Edit commands read the current record first and resubmit every field: the backend's update endpoints clear the location, expiry date or unit price, or silently deactivate a student / location / metric, when a field is missing.
- Passwords and student tokens are read only from stdin or a no-echo terminal prompt, never from arguments; student links report only `has_link` unless `--reveal` is given.
- Credentials live in `~/Library/Application Support/FitCoach/cli/credentials.json` (directory 0700, file 0600, one entry per server, override with `FITCOACH_CLI_HOME`) and never touch the app's login. Backend sessions are stateless 30-day signatures, so `logout` can only delete the local copy.
- The server defaults to `https://fit.tianli.cyou`; change it with `--base URL` or `FITCOACH_BASE`.
- App only: trend charts, share sheet and copy link, pull to refresh, date / time pickers, changing the server address, screenshot launch arguments.
- Tests: `bash ref/run` runs `cli/test.sh` after the contract check (isolated local backend, temporary credential directory, success and failure paths of every command above); `FITCOACH_TEST_CLI=<bundled fitcoach> bash cli/test.sh` runs the same suite against the copy inside the Mac app.
- Resources (2026-09-30, Mac16,12 / macOS 27.2): `--help` about 11 ms and 2 MB peak memory; one read against a local backend about 40–75 ms and 4 MB; binary about 1.2 MB (the universal copy in the bundle about 1.4 MB); nothing stays resident. Details in the `cli` block of `perf/lightweight.json`.

## Related

- Product page: <https://apps.tianli.cyou/p/fitcoach-ios.html>
- App-fleet overview (how the 10 apps came about): <https://apps.tianli.cyou/ios.html>
- Tutorial: [From Zero to TestFlight: The Complete Path to Building an iPhone App Alone](https://blog-ai.tianli.cyou/nine-ios-apps-in-two-weeks)

## License

MIT © 2026 曾田力 (Tianli Zeng)

<!-- lightweight:start -->
## Resource use

Download size is App Store data; memory, CPU and launch time are iOS Simulator measurements, not physical-device figures.

| Download | Idle memory | Idle CPU | Simulator cold launch to first screen ready |
|---|---|---|---|
| **3.0 MB** (installed 4.1 MB) | **27.3 MB** | **0%** | **1.5 s** |

Sizes are read back for this exact distribution build. The physical device is not yet measured, so memory, CPU and launch time come from the iOS Simulator and are labelled as such.

<sub>v1.0 (5) · iPhone 17（iPhone18,3）；体积为 Apple 设备切片记录，运行性能尚未真机实测 · App Store; package sizes exclude user data and caches; installed phone version not verified · measured 2026-09-26. Sizes come from Apple App Store Connect device slices for this build. Memory, CPU and launch time were measured on iPhone 17 Pro / iOS 27.0 Simulator / Mac16,12 / Apple M4 / macOS 27.2 with a local Release build v1.0 (1) (2026-09-27), App process only; these are not physical-device figures, which are still unmeasured. Memory uses phys_footprint; CPU is CPU time ÷ wall time over a 60-second sampling window; sizes in decimal MB. Raw data: [perf/lightweight.json](perf/lightweight.json).</sub>
<!-- lightweight:end -->
