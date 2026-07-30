# SleepBridge (iOS) — setup steps

These steps assume no prior setup — if you already have a Google Cloud
project with the Fitness API enabled, skip to Step 2.

## 1. Google Cloud project + OAuth client

1. Go to [Google Cloud Console](https://console.cloud.google.com/) → create
   a new project (or pick an existing one)
2. **APIs & Services → Library** → search **Fitness API** → **Enable**
3. **APIs & Services → Credentials → Create Credentials → OAuth client ID**
   - Application type: **Web application**
   - Under **Authorized redirect URIs**, add:
     ```
     https://developers.google.com/oauthplayground
     ```
   - Click **Save** at the bottom of the page, then give it a couple minutes
     to propagate
4. Note the **Client ID** and **Client Secret** shown after creation — you'll
   need both in the next step and again when setting up the app

## 2. One-time Google OAuth token exchange (via OAuth Playground)

This gets you a long-lived **refresh token** — the one credential the app
actually needs at runtime to keep pulling new sleep data without you signing
in again.

1. Go to [Google's OAuth 2.0 Playground](https://developers.google.com/oauthplayground)
2. Click the **gear icon** (top right) → check **"Use your own OAuth
   credentials"** → paste in the **Client ID** and **Client Secret** from
   Step 1 → close the settings panel
3. In the left panel, under **"Step 1: Select & authorize APIs"**, find the
   **"Input your own scopes"** field and paste in:
   ```
   https://www.googleapis.com/auth/fitness.sleep.read
   ```
4. Click **Authorize APIs** — sign in with the Google account tied to your
   Nest Hub / Google Fit data, and grant access. You'll be redirected back to
   the Playground with an authorization code already filled in
5. Click **"Exchange authorization code for tokens"** (Step 2) — the
   Playground handles the token exchange for you, no terminal needed
6. Copy the **Refresh token** value shown — that's what you'll paste into the
   app later. The access token shown alongside it is short-lived and not
   needed; the app generates its own as needed using the refresh token

Equivalent auth URL, if you want to see what's happening under the hood
(the Playground constructs and follows this for you automatically):
```
https://accounts.google.com/o/oauth2/v2/auth?client_id=YOUR_CLIENT_ID&redirect_uri=https://developers.google.com/oauthplayground&response_type=code&scope=https://www.googleapis.com/auth/fitness.sleep.read&access_type=offline&prompt=consent
```

**If you get `Error 400: redirect_uri_mismatch`:** confirm the redirect URI
registered on your OAuth client in Step 1 is exactly
`https://developers.google.com/oauthplayground` (no trailing slash), that you
clicked **Save** on the credentials page, and give it a couple minutes to
propagate before retrying.

## 3. Create the Xcode project

1. Xcode → **File → New → Project → iOS → App**
2. Product Name of your choice (e.g. `SleepBridge`), Interface: **SwiftUI**
3. Delete the auto-generated `ContentView.swift` and app-entry `.swift` file
4. Drag in all six source files: `SleepBridgeApp.swift`, `SyncRunner.swift`,
   `SyncSleepDataIntent.swift`, `GoogleFitClient.swift`,
   `SleepStageMapper.swift`, `HealthKitWriter.swift`, `CredentialStore.swift`

## 4. Sign it with a free Personal Team

1. Target → **Signing & Capabilities** → Team: your **Personal Team** (sign
   into Xcode with an Apple ID first if you haven't: Xcode → Settings →
   Accounts — no paid Developer Program needed)
2. **+ Capability → HealthKit**
3. Confirm the generated entitlements file contains
   `com.apple.developer.healthkit`
4. Add the two HealthKit privacy usage keys to `Info.plist` (via the
   target's **Info** tab if there's no physical Info.plist file to edit
   directly)

## 5. Install on a device

1. Plug the iPhone into the Mac, trust the computer on the phone
2. Select the iPhone as the run destination in Xcode
3. **Build & Run** (`⌘R`)
4. First launch will prompt to trust the developer certificate:
   **Settings → General → VPN & Device Management** on the phone

## 6. One-time app setup (the only manual step, ever)

1. Open the app on the phone
2. Enter the **Client ID**, **Client Secret** (both from Step 1), and
   **Refresh Token** (from Step 2) → tap **Save Credentials**
3. Tap **Sync Now** once — this triggers the HealthKit permission prompt
   (approve read + write for Sleep Analysis) and confirms the whole pipeline
   works end to end
4. Check the log panel for confirmation

The app never needs to be opened again after this — everything from here on
runs through the Shortcuts automation below.

## 7. Set up the Shortcuts automation

1. **Shortcuts app → Automation tab → + → Create Personal Automation**
2. Choose **Time of Day** → set a preferred time → **Daily**
3. Under "Actions," search for the app's name — the **Sync Sleep Data**
   action (from `SyncSleepDataIntent.swift`) will appear
4. Add it as the automation's action
5. On the confirmation screen, turn **off** "Ask Before Running" — this is
   what allows it to run with zero interaction
6. Save

## 8. Known things to watch for

- **7-day Personal Team signing expiry**: applies to iOS apps on a real
  device. After a week, the app — and therefore the automation — will
  silently stop working until the phone is tethered to a Mac and rebuilt. If
  that cadence is annoying, the $99/year Apple Developer Program removes it
  (year-long provisioning instead of 7 days).
- **Google Fit API sunset**: Google is winding down the Fitness API family by
  end of 2026 — this bridges you through that window, not indefinitely.
- **Background execution**: "Ask Before Running" off is required for the
  automation to fire without a tap. If it starts prompting again, check that
  setting hasn't reset (can happen after iOS updates).