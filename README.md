# SleepBridge

Bridges Google Nest Hub sleep-sensing data (stored in Google Fit) into Apple
Health, since there's no direct/native path between the two.

A small iOS app fetches your sleep sessions from the Google Fit API, converts
them into Apple HealthKit's sleep format, and writes them into Apple Health.
It runs on a schedule via a Shortcuts automation — no manual app-opening
required day to day.

## Development note

I used AI-assisted tools to accelerate early scaffolding, implementation
exploration, and documentation. I directed the architecture and integrations,
reviewed and revised the resulting work, and remain responsible for the code
and project decisions in this repository.

## Disclaimer

SleepBridge is an experimental personal project and is provided “as is,” without warranties of any kind.

It is not a medical device and does not provide medical advice, diagnosis, or treatment. Do not use its sleep data or recommendations as a substitute for advice from a qualified healthcare professional.

SleepBridge may access health-related data only with the permissions you grant. You are responsible for reviewing the app’s privacy practices and for protecting any accounts, credentials, or exported data used with the app.

This project is not affiliated with or endorsed by Apple, HealthKit, Google, or any connected service.


## How it works

```
1. Google Fit (sessions + per-minute stage points)
↓
2. Merge consecutive statges (per-minute points)
↓
3. Format to Apple Health structure + categories
↓
4. Check Duplicates (skip anything already saved to Apple Health)
↓
5. Save (write to HealthKit)
```

Five independent stages, each doing exactly one job:

| Stage | Does |
|---|---|
| **Fetch Raw** | Pulls sleep sessions + per-minute stage points from Google Fit — no interpretation |
| **Merge Stages** | Collapses consecutive identical-value, back-to-back points into single runs (Google Fit reports roughly one point per minute; you don't want a HealthKit sample per minute) |
| **Format** | Maps Google Fit's stage values onto Apple's `HKCategoryValueSleepAnalysis` values |
| **Check Duplicates** | Compares against what's already in Apple Health, skips exact matches |
| **Save** | Writes the remaining (new) samples to HealthKit |

`SyncRunner` runs all five automatically, back to back — that's what the
Shortcuts automation and the "Sync Now" button both call. The Diagnostics
screen in the app exposes each stage individually with a manual date range,
for debugging one layer at a time without the others in the way.

**→ See [`docs/SLEEP_DATA_SCHEMA.md`](docs/SLEEP_DATA_SCHEMA.md)** for exactly
what Google Fit and Apple Health each store, and the full field-by-field
mapping between them.

## Project structure

```
SleepBridge/
  App/            — entry point, entitlements, Info.plist, assets
  Pipeline/        — the five-stage sync logic (SleepPipeline, SyncRunner)
  Networking/      — Google Fit API client + credential storage
  HealthKit/       — HealthKit writer + the Google Fit → Apple stage mapping
  Intents/         — the App Intent Shortcuts calls to trigger a sync
  DevMode/         — diagnostics screen, one button per pipeline stage
```

## Requirements

- A Google Cloud project with the Fitness API (Google Fit REST API) enabled
- Xcode, an Apple ID (a free Personal Team is enough — no paid Developer
  Program required)
- An iPhone to install it on
- The Shortcuts app, for the scheduling automation

## Setup

**→ See [`SETUP.md`](SETUP.md)** for the full walkthrough: Xcode project
creation, HealthKit capability setup, the one-time Google OAuth token
exchange, installing on your phone, and configuring the Shortcuts automation.

## Known limitations

- **Google Fit API sunset**: Google is winding down the Fitness API family by the end of 2026. This project bridges you through that window, not indefinitely.
- **Free Personal Team signing**: provisioning expires every 7 days, meaning the app (and therefore the scheduled sync) will silently stop working until you tether your phone to your Mac and rebuild. The $99/year Apple Developer Program removes this if the weekly rebuild becomes annoying.
- **Credentials**: Google OAuth credentials are entered once in-app and stored in iOS Keychain — never committed to this repo. See `.gitignore` if you fork this and add any local config files of your own.
