# little-chef

## TestFlight deploy pipeline

`.github/workflows/deploy-ios-testflight.yml` archives the app and uploads it to
TestFlight.

### Trigger semantics

Two ways in, and nothing else:

- **A PR merged into `main` carrying the `deploy-ios` label.** The job is gated on
  `merged == true`, so closing a labelled PR without merging does nothing. Labels
  are used rather than git tags because tags don't attach to merge events.
- **`workflow_dispatch`** from the Actions tab — re-run a deploy without inventing
  a commit.

`concurrency: testflight-ios` with `cancel-in-progress: false` so two uploads can
never race for the same build number.

### Signing style: automatic archive, manual export — and why

This project has **two signable targets**, `little-chef`
(`NagataInc.little-chef`) and `TimerWidgetExtension`
(`NagataInc.little-chef.TimerWidget`). Each needs its own provisioning profile.

`xcodebuild` command-line build settings apply to *every target at once*, so manual
signing cannot hand the app and its widget different profiles from the command line.
**Archive** therefore signs automatically: `-allowProvisioningUpdates` with
`-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`. It signs
with an **Apple Development** identity (which it created via the API, and reuses) and
Xcode-managed `iOS Team Provisioning Profile`s. That is expected — an archive is not
the shipping artifact.

**Export** is where distribution signing happens, and it is **manual**. The two App
Store profiles are installed on the runner and named explicitly in
`ExportOptions.plist` via a bundle-ID→profile-name map, with
`signingCertificate: Apple Distribution` pinning the identity imported from
`IOS_DIST_CERT_P12_BASE64`.

Export must *not* use `signingStyle: automatic`, and must not be passed
`-allowProvisioningUpdates` or `-authenticationKey*`. Those enable **cloud signing**,
which mints an Apple-managed distribution certificate and requires an **Admin** App
Store Connect key. Our key is **App Manager**, which is allowed to create the
*development* certificate Archive uses but not the *distribution* one — so cloud
signing fails with `Cloud signing permission error`, followed by
`No profiles for '<bundle id>' were found` as a downstream symptom. Elevating the key
to Admin would fix it, at the cost of an account-wide credential in CI and a second,
cloud-managed distribution certificate. We chose explicit profiles instead.

Net effect: CI creates no distribution certificates and mints no distribution
profiles. Archive still reuses the API-created development certificate.

### Build numbers

`CURRENT_PROJECT_VERSION = github.run_number + BUILD_NUMBER_OFFSET`, passed on the
`xcodebuild` command line so it outranks the project setting, with
`manageAppVersionAndBuildNumber: false` in the export options so nothing rewrites
it afterwards.

Build numbers must **strictly increase within a `MARKETING_VERSION` train**
(currently `1.0`). Rules:

- Set `BUILD_NUMBER_OFFSET` (a repository *variable*) above the highest existing build.
- Bump it after any manual upload from Xcode.
- Reset it to `0` when you bump `MARKETING_VERSION`.
- Failed runs still consume run numbers. Harmless — the sequence just skips.

### Secrets

Repository secrets, **not** environment secrets. The job declares no
`environment:`, so environment-scoped secrets would resolve to empty strings and
fail confusingly mid-run.

| Secret | Scope |
| --- | --- |
| `APPLE_TEAM_ID` | account (`MJ3P95GLA4`) |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` | account (**App Manager** role) |
| `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_PASSWORD` | certificate |
| `IOS_PROFILE_APP_NAME`, `IOS_PROFILE_APP_BASE64` | per app target |
| `IOS_PROFILE_WIDGET_NAME`, `IOS_PROFILE_WIDGET_BASE64` | per widget target |

Plus repository **variable** `BUILD_NUMBER_OFFSET`.

Both profiles must be **App Store** distribution profiles bound to the Apple
Distribution certificate above, and must **not** be Xcode-managed. Verify one before
wiring it into a secret with
`~/.claude/skills/ios-testflight-pipeline/scripts/verify-profile.sh <file> <bundle-id>`,
which checks the App ID, that the embedded certificate's private key is in your
keychain, and that no devices are provisioned (devices ⇒ Development/Ad Hoc, not App
Store).

The bundle IDs are plain `env:` in the workflow, not secrets — they ship inside every
copy of the app.

### No test gate, on purpose

The deploy path does not run tests. `little-chefTests` is a placeholder (`@Test
func example()` asserting nothing), and `little-chefUITests` needs a booted
simulator and touches the app's gated model-download paths — slow and flaky ahead
of an archive. Gate correctness in a separate PR-check workflow if you want one.

### Invariants — change these only with a reason

- **`runs-on: macos-26`, Xcode 26 selected explicitly.** Apple rejects uploads built
  with an SDK older than iOS 26. `macos-15` images top out at Xcode 16 / iOS 18.5.
  The workflow picks the newest `Xcode_26*.app` and fails loudly if absent —
  otherwise the mistake surfaces at upload, after a full archive.
- **Throwaway keychain** in `$RUNNER_TEMP`, then `security set-key-partition-list`
  so `codesign` isn't blocked on an interactive prompt.
- **`altool` finds the API key by name** at `~/private_keys/AuthKey_<KEY_ID>.p8`.
  It is deleted afterwards, along with the keychain, in an `if: always()` step.
- **`if: always()` artifact upload** of the IPA and dSYMs, so a build Apple
  *rejected* is still inspectable. (Nothing is captured if the archive itself failed.)
- The scheme `little-chef` must stay **shared** (committed under
  `xcshareddata/xcschemes/`) or `xcodebuild -scheme` fails on a fresh clone.

### When it fails

Read the error before changing anything; these look alike and aren't.

| Symptom | Cause |
| --- | --- |
| `altool` **401** | Bad/expired App Store Connect key, or wrong issuer |
| **409 `INVALID_APP_STATE`** | App record deleted/removed in App Store Connect. **Not** a signing problem — check the bundle ID against the live record |
| **409 `VALIDATION_ERROR`**, "SDK version issue" | Runner's Xcode too old; see the `macos-26` invariant |
| **409**, "bundle version must be higher" | `BUILD_NUMBER_OFFSET` too low |
| `error: … is Xcode managed` at **Archive** | A managed profile met manual signing. This project signs automatically; something regressed the signing style |
| `error: … doesn't include signing certificate` at **Archive** | Profile predates the certificate. Delete the profile in the portal and let CI remint it |
| `security import` fails on empty input | Secrets set on an environment the job doesn't declare |
| `Cloud signing permission error` + `No profiles for '<id>' were found` at **Export** | Export fell back to cloud signing. Check `signingStyle` is `manual` and that no `-allowProvisioningUpdates`/`-authenticationKey*` reached `-exportArchive`. **Not** a missing-profile problem — the lookup was denied, not empty |
| `Invalid authentication key credential … invalidPEMDocument` at **Archive** | `ASC_KEY_P8_BASE64` decodes to something that isn't a PEM — usually the base64 body saved without its `-----BEGIN PRIVATE KEY-----` delimiters. **Not** an auth failure. Validate with `openssl pkey -noout -in key.p8` (not `openssl pkcs8 … -noout`, which has no such flag in LibreSSL or OpenSSL 3 and rejects every key) |
| Profile name mismatch at **Export** | `IOS_PROFILE_*_NAME` must be the profile's **Name** field, not its filename or UUID |
| `doesn't support the Push Notifications capability` / `entitlement 'aps-environment' … not present in profile` | The App ID or the stored profile predates the Push Notifications capability CloudKit needs. See **CloudKit sync** below |

Inspect a run:

```sh
gh run view <id> --json jobs -q '.jobs[].steps[] | "\(.conclusion)\t\(.name)"'
gh run view <id> --log-failed
```

## CloudKit sync

Recipes and preferences live in SwiftData, mirrored to the user's **private** database in
the `iCloud.com.littlechef.app` container by `LocalDataManager`.

### Three capabilities, not one

SwiftData's CloudKit mirroring is `NSPersistentCloudKitContainer` underneath, and it
refuses to set up unless **all three** of these are present. iCloud alone is not enough:

| Capability | Where it lives |
| --- | --- |
| iCloud → CloudKit | `com.apple.developer.icloud-container-identifiers` + `…icloud-services` in `little-chef.entitlements` |
| Push Notifications | `aps-environment` in `little-chef.entitlements` |
| Background Modes → Remote notifications | `UIBackgroundModes` = `remote-notification` in `Info.plist` |

Mirroring tracks the other devices' writes through **silent pushes** on a CloudKit
database subscription, which is why a sync feature needs push at all. Those pushes only
reach an app that asked for a device token, so `AppDelegate` calls
`registerForRemoteNotifications()` at launch — it prompts the user for nothing and is
unrelated to the timer-alert authorization request.

`aps-environment` is checked in as `development`. Do not change it: `xcodebuild
-exportArchive` rewrites it to `production` for the `app-store` method, and hardcoding
`production` breaks every local debug build instead.

Both App Store profiles in `IOS_PROFILE_*_BASE64` must therefore be minted from an App ID
with **Push Notifications enabled**. Enabling a capability does not update profiles that
already exist — regenerate them in the portal and re-store the secrets, or export fails
with the `aps-environment` row in the table above.

### The Production schema is a separate, manual deploy

TestFlight and App Store builds talk to the **Production** CloudKit environment; debug
builds from Xcode talk to Development. Record types created by mirroring appear in
Development automatically as you run the app, and **never cross to Production on their
own** — push them with *Deploy Schema to Production* in the CloudKit Console. A schema
that exists only in Development makes production saves fail per-record while the app
itself looks perfectly healthy.

### The local-only fallback

A container that can't set up mirroring is a launch crash, so `LocalDataManager` catches
that and reopens the store local-only. It is the right call and a data-loss trap in equal
measure: writes look like they worked, never reach iCloud, and die with the app on
delete. So it is never silent.

- It logs through `Logger`, **not `dprint`** — `dprint` compiles to nothing outside DEBUG,
  which is exactly how a local-only TestFlight build went unnoticed.
- It publishes `cloudSyncStatus`, surfaced as an iCloud row in Settings.

Reach for that row first when told "my recipes aren't syncing". It separates *mirroring
never started* — entitlements, no iCloud account, iCloud Drive off — from *mirroring
started and records aren't landing*, which is the Production schema above or plain
network. The two look identical from the recipe list and have nothing in common.
