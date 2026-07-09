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

### Signing style: automatic — and why

This project has **two signable targets**, `little-chef`
(`NagataInc.little-chef`) and `TimerWidgetExtension`
(`NagataInc.little-chef.TimerWidget`). Each needs its own provisioning profile.

`xcodebuild` command-line build settings apply to *every target at once*, so
manual signing physically cannot hand the app and its widget different profiles.
The pipeline therefore uses `-allowProvisioningUpdates` with
`-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID`, and
`signingStyle: automatic` in the export options. xcodebuild mints each profile
through the App Store Connect API.

The tradeoff, accepted deliberately: **CI creates and mutates provisioning
profiles in the Apple account.** Certificates are not created — the Apple
Distribution identity is imported from `IOS_DIST_CERT_P12_BASE64` into a throwaway
keychain in `$RUNNER_TEMP`.

(Manual signing remains possible via per-target xcconfigs plus an
`ExportOptions.plist` mapping every bundle ID to a profile name. More moving
parts; only worth it if account mutation becomes unacceptable.)

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
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64` | account |
| `IOS_DIST_CERT_P12_BASE64`, `IOS_DIST_CERT_PASSWORD` | certificate |

Plus repository **variable** `BUILD_NUMBER_OFFSET`.

There are no `IOS_PROVISIONING_PROFILE_*` secrets: automatic signing resolves
profiles at build time. There is no `IOS_BUNDLE_ID` secret either — with
`signingStyle: automatic` the export options carry no bundle-ID→profile map.

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
| `Invalid authentication key credential … invalidPEMDocument` at **Archive** | `ASC_KEY_P8_BASE64` decodes to something that isn't a PEM — usually the bare base64 body saved without its `-----BEGIN PRIVATE KEY-----` delimiters. **Not** an auth failure. The `Prepare App Store Connect API key` step now catches this |
| `altool` **401** | Bad/expired App Store Connect key, or wrong issuer |
| **409 `INVALID_APP_STATE`** | App record deleted/removed in App Store Connect. **Not** a signing problem — check the bundle ID against the live record |
| **409 `VALIDATION_ERROR`**, "SDK version issue" | Runner's Xcode too old; see the `macos-26` invariant |
| **409**, "bundle version must be higher" | `BUILD_NUMBER_OFFSET` too low |
| `error: … is Xcode managed` at **Archive** | A managed profile met manual signing. This project signs automatically; something regressed the signing style |
| `error: … doesn't include signing certificate` at **Archive** | Profile predates the certificate. Delete the profile in the portal and let CI remint it |
| `security import` fails on empty input | Secrets set on an environment the job doesn't declare |

Validate a `.p8` locally with `openssl pkey -noout -in key.p8` — prints nothing and
exits 0 when the key is good. **Not** `openssl pkcs8 … -noout`: `pkcs8` has no `-noout`
flag in LibreSSL (`/usr/bin/openssl` on macOS) or in OpenSSL 3, so that spelling
rejects every key and tells you nothing.

Inspect a run:

```sh
gh run view <id> --json jobs -q '.jobs[].steps[] | "\(.conclusion)\t\(.name)"'
gh run view <id> --log-failed
```
