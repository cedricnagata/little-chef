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

### Signing style: manual at both archive and export — and why

This project has **two signable targets**, `little-chef`
(`NagataInc.little-chef`) and `TimerWidgetExtension`
(`NagataInc.little-chef.TimerWidget`). Each needs its own provisioning profile.

**Both steps sign, both manually, and neither asks Apple for anything.** The
distribution certificate and both App Store profiles are put on the runner by earlier
steps, so signing consumes what is already there and mints nothing.

**Archive must not skip signing.** Entitlements live *inside* a code signature, so an
unsigned archive carries none — and `-exportArchive` re-signs from the bundle's
**existing** entitlements rather than reading them out of the profile. Given an empty
set it emits an empty set: the IPA ships with only `application-identifier`,
`team-identifier`, `beta-reports-active` and `get-task-allow`, losing the app group and
the increased memory limit even though the embedded profile still grants them. Build 18
shipped exactly that and crashed on launch — see the entitlements row in the failure table
below. Check any build with
`codesign -d --entitlements :- Payload/little-chef.app` on the exported IPA; the
artifact upload keeps one from every run.

The **per-target profile mapping lives in the project**, on the `Release` config of
each of the two targets (`CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = "Apple
Distribution"`, `PROVISIONING_PROFILE_SPECIFIER` = the profile name). It cannot go on
the `xcodebuild` command line: build settings there apply to *every* target at once,
including the SPM package targets, which reject it outright with `<target> does not
support provisioning profiles`. Ad-hoc signing is not an escape hatch either —
`Ad Hoc code signing is not allowed with SDK 'iOS 26.x'` — and signing with a real
certificate but no profile fails on `requires a provisioning profile with the App
Groups, iCloud, and Push Notifications features`, since entitlements have to be backed
by a profile that grants them.

Only `Release` is manual. `Debug` stays on automatic signing with a development
certificate, so ordinary development needs none of this. A local *Release* build or an
Xcode archive does: it needs the two manually-managed App Store profiles installed, and
an Xcode-managed profile for the same App ID will not substitute — it fails with `is
Xcode managed, but signing settings require a manually managed profile`.

Archive used to sign automatically, via `-allowProvisioningUpdates` and the
`-authenticationKey*` trio. That asks Apple to mint an **Apple Development**
certificate over the API — an account-global, *capped* mutation performed on every
run, for an identity the build never ships, since export re-signs everything minutes
later anyway. The account duly reached its certificate limit and every archive
failed with `Choose a certificate to revoke`, followed by
`No profiles for '<id>' were found` as the downstream symptom. Manual signing against
an already-installed profile mints nothing, so the cap cannot be reached. **Do not
reintroduce `-allowProvisioningUpdates` or `-authenticationKey*` at archive** — those,
not signing as such, were the cause. Skipping signing altogether also fixes the cap,
and is what shipped build 18 without entitlements; that cure is worse than the disease.

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

Net effect: **CI creates nothing at Apple.** No certificates of either kind, no
profiles. The only signing identity in play is the Apple Distribution certificate
imported from `IOS_DIST_CERT_P12_BASE64` — so revoking that one breaks the deploy,
where revoking anything else no longer can.

The App Store Connect key is still needed, but only for `altool` at the **upload**
step. Nothing in archive or export authenticates to Apple any more.

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

Their **Name** fields are currently `NagataInc.little-chef` and
`NagataInc.little-chef.TimerWidget` — the same strings the two `Release` configs carry
as `PROVISIONING_PROFILE_SPECIFIER`, since archive resolves profiles by name from the
project while export resolves them by name from these secrets.

Both profiles must be **App Store** distribution profiles bound to the Apple
Distribution certificate above, and must **not** be Xcode-managed. Verify one before
wiring it into a secret with
`~/.claude/skills/ios-testflight-pipeline/scripts/verify-profile.sh <file> <bundle-id>`,
which checks the App ID, that the embedded certificate's private key is in your
keychain, and that no devices are provisioned (devices ⇒ Development/Ad Hoc, not App
Store).

The bundle IDs are plain `env:` in the workflow, not secrets — they ship inside every
copy of the app.

### No test gate on the deploy, on purpose

The deploy path does not run tests; pull requests do (see **Pull request checks** below). The
deploy only runs after a PR has merged, and `little-chefUITests` needs a booted simulator and
touches the app's gated model-download paths — slow and flaky ahead of an archive.

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
| **App launches from TestFlight and crashes immediately**, but the same code runs fine from Xcode | The IPA lost its entitlements — almost certainly because something made **Archive** stop signing. `codesign -d --entitlements :- Payload/little-chef.app`: if the app group and the increased memory limit are absent, that's it (build 18, when the app still had iCloud, crashed opening its CloudKit store). **Not** a code bug — see the signing-style section |
| Any **certificate or profile** error at **Archive** | Archive signs manually against the profiles installed earlier in the job. Check the `Release` config of both targets still names its profile, that both profiles installed, and that no `-allowProvisioningUpdates`/`-authenticationKey*` crept back in. Do **not** "fix" this by disabling signing — that ships an app with no entitlements |
| `<target> does not support provisioning profiles` (an SPM package target) | A signing setting was put on the `xcodebuild` command line, where it hits every target. Per-target signing belongs in the project's `Release` configs |
| `is Xcode managed, but signing settings require a manually managed profile` | An Xcode-managed profile is installed under the name the `Release` config asks for. The App Store profiles in `IOS_PROFILE_*_BASE64` must be manually created |
| `Choose a certificate to revoke` | The account is at its certificate cap. Should now be unreachable from CI; if it appears, something is minting certificates again |
| `error: … doesn't include signing certificate` at **Export** | The stored profile predates the distribution certificate, or that certificate was revoked. Regenerate the profile against the current one and re-store both secrets |
| `security import` fails on empty input | Secrets set on an environment the job doesn't declare |
| `Cloud signing permission error` + `No profiles for '<id>' were found` at **Export** | Export fell back to cloud signing. Check `signingStyle` is `manual` and that no `-allowProvisioningUpdates`/`-authenticationKey*` reached `-exportArchive`. **Not** a missing-profile problem — the lookup was denied, not empty |
| `Invalid authentication key credential … invalidPEMDocument` at **Upload** | `ASC_KEY_P8_BASE64` decodes to something that isn't a PEM — usually the base64 body saved without its `-----BEGIN PRIVATE KEY-----` delimiters. **Not** an auth failure. Validate with `openssl pkey -noout -in key.p8` (not `openssl pkcs8 … -noout`, which has no such flag in LibreSSL or OpenSSL 3 and rejects every key) |
| Profile name mismatch at **Export** | `IOS_PROFILE_*_NAME` must be the profile's **Name** field, not its filename or UUID. The same name is also hardcoded as `PROVISIONING_PROFILE_SPECIFIER` in each target's `Release` config for the archive — rename a profile and **both** have to move |
| `entitlement 'com.apple.developer.kernel.increased-memory-limit' … not present in profile` | The app's App Store profile predates the **Increased Memory Limit** capability. Enable it on the `NagataInc.little-chef` App ID, regenerate the profile under the same name and replace `IOS_PROFILE_APP_BASE64`. The widget doesn't carry this entitlement, so its profile is unaffected |

Inspect a run:

```sh
gh run view <id> --json jobs -q '.jobs[].steps[] | "\(.conclusion)\t\(.name)"'
gh run view <id> --log-failed
```

## MLX packages

On-device inference runs PrismML's **Bonsai 2** family through `ml-explore/mlx-swift` (exactly
**0.33.0**) and **a fork of `mlx-swift-lm`**.

### The mlx-swift-lm fork, and how to retire it

Bonsai 2 packs are `model_type: prism_hadamard_qwen35`: ternary weights stored as MLX 2-bit
(group 128) with a signed, blockwise Walsh–Hadamard rotation folded into each projection's input.
The loader has to rotate the activations to match. Loaded as plain `qwen3_5`, they decode
nonsense. Upstream mlx-swift-lm can't load them yet. Support is
[ml-explore/mlx-swift-lm#630](https://github.com/ml-explore/mlx-swift-lm/pull/630) by spokvulcan,
open and unreviewed since 2026-10-14. Python mlx-lm merged the equivalent (#1941) on 2026-10-08.

So the app pins **`github.com/cedricnagata/mlx-swift-lm`, branch `little-chef/bonsai-2`,
revision `bf55422`**. That revision is exactly:

- upstream `691a19a`, the revision the app pinned before (the first one to accept mlx-swift 0.33),
- plus PR #630's single commit `a3596e4`, cherry-picked unchanged (`-x`, author kept),
- plus our own `bf55422`: the Qwen3.5 text models leave the vision tower unread
  (`excludedCheckpointNamespaces`). Upstream read every tensor in the file and dropped the
  tower afterwards, so a load peaked at the whole file, 0.85 GiB above the 9B's weights.

Nothing else differs. The fork is public because GitHub forks of public repos can't be private,
and that is also what lets CI fetch it with no extra secret. Pinning the PR's own branch instead
would have gone back to mlx-swift 0.32, since #630 is based on upstream as of 2026-10-13.

**Check on it** when touching MLX: `gh pr view 630 -R ml-explore/mlx-swift-lm --json state,mergedAt`.

**Retiring the fork, once #630 (or an equivalent) is merged upstream:**

1. Find the first upstream commit or release with `prism_hadamard_qwen35` in
   `Libraries/MLXLLM/LLMModelFactory.swift` that still accepts mlx-swift 0.33, **and** that
   doesn't read the vision tower for a text model (`excludedCheckpointNamespaces` on
   `Qwen35Model`; offer `bf55422` upstream if it isn't there). Without it, the 9B's load peaks
   0.85 GiB higher, which got the app killed on an iPhone 14 Pro.
2. In `project.pbxproj`, point the `mlx-swift-lm` package reference back at
   `https://github.com/ml-explore/mlx-swift-lm`: that revision, or a version requirement once a
   tagged release has both. Update `Package.resolved` to match (`tools/mac-test` saves Xcode's
   own copy when resolution changes it).
3. Check on the Mac that every Bonsai 2 size still loads and answers, then a TestFlight build.
4. Remove this section's fork notes and the README's fork row. Archive or delete the fork
   (`gh repo archive cedricnagata/mlx-swift-lm`).

If upstream needs something else of the app first, such as a newer mlx-swift, the fork can be
rebased instead: cherry-pick `a3596e4` (or the PR's latest commit) onto the new upstream
revision, push it as a new commit on `little-chef/bonsai-2`, and repin. Never put the app's own
changes on the fork.

mlx-swift-lm 3 doesn't download or tokenize by itself. `HubModelLoading.swift` bridges it to
`swift-huggingface` and `swift-transformers` by hand rather than through the `MLXHuggingFace`
macros, because `xcodebuild` won't run a package's macros in CI until someone trusts them
interactively. Models are stored under Application Support in the hub's
`models--<org>--<name>` layout. Caches is not used, because iOS can empty it.

### The models

| Choice | Repository | Download | Weights in memory | Peak at 8.6k tokens | Needs an app limit of |
| --- | --- | --- | --- | --- | --- |
| `bonsai2_27B` | `prism-ml/Ternary-Bonsai-2-27B-mlx-2bit` | 8.6 GB | 7.10 GiB | 8.51 GiB | 9.0 GiB |
| `bonsai2_9B` | `prism-ml/Ternary-Bonsai-2-9B-mlx-2bit` | 3.6 GB | 2.36 GiB | 3.22 GiB | 3.75 GiB |
| `bonsai2_4B` | `prism-ml/Ternary-Bonsai-2-4B-mlx-2bit` | 2.0 GB | 1.11 GiB | 1.94 GiB | 2.5 GiB |
| `bonsai2_2B` | `prism-ml/Ternary-Bonsai-2-2B-mlx-2bit` | 1.2 GB | 0.50 GiB | 0.98 GiB | 1.5 GiB |

- **Downloads include a vision tower** (0.6–0.9 GiB) in the same safetensors file, and the 9B and
  4B also carry an `mtp/` speculative-decoding head. The text loader leaves both unread: `mtp/`
  is never selected, and the fork's `bf55422` excludes the tower from the read. Before it the
  tower was read and then dropped, so every load peaked at the whole file (9B: 3.23 GiB, against
  2.39 without the tower). Nothing in the app needs it: photo import reads text with Vision OCR
  on the device and gives the model only text (Cedric, 2026-11-12).
- **On an iPhone 14 Pro (6 GB, limit 4.0 GiB, iOS 26.6) the 9B got the app killed** before
  that fix (2026-11-12): once at the 4.0 GiB limit (`highwater`), and once at 3.77 GiB for the
  device running out of pages (`vm-pageshortage`), each time with dozens of other apps killed.
  The second came from a reload straight after a memory warning had unloaded the model. On a
  6 GB phone the limit isn't the only ceiling: the whole device runs short first. The 4B ran
  there without a warning (1.84 GiB peak) but its advice was poor: pancetta replaced by "an equal
  amount" of olive oil, "150 ml, roughly 1 cup". Cedric judged it not good enough to use.
- **A memory warning keeps the model** unless the app has under 0.75 GiB of headroom left
  (`memoryWarningUnloadHeadroom`); it clears MLX's buffer cache either way. Unloading on every
  warning, as before, threw the 9B and its kept prompt away every few minutes of a cook on a 6 GB
  phone, and the next question waited 30-40 s (Release, iPhone 14 Pro, 2026-11-13: 1.5-2 s to
  the first token with the prompt kept, 31-40 s without; full prefill ~83 tok/s, decode ~14.5).
- **Timing is in the unified log**, Release builds included: subsystem `NagataInc.little-chef`,
  category `llm-timing`, numbers only. Each on-device reply (load, settled part, prompt and kept
  tokens, first token, prefill and decode speed, footprint, thermal state), each load, unload
  and memory warning. From a device: `sudo log collect --device-udid <udid>`, then `log show
  --predicate 'subsystem == "NagataInc.little-chef"'` on the archive.
- **A load waits for memory** (`waitForMemory(toLoad:)`): 5 s after a memory warning, then up
  to 10 s for `os_proc_available_memory()` to cover the model's `memoryNeeded` less the app's
  0.5 GiB, which the footprint already counts. Failing that, the question fails with "There
  isn't enough free memory…", not a terminated app. Debug builds log the limit, footprint and
  what is left at launch and after each load (`🤖 [LLM] Memory …`).
- **What each threshold covers** (`CookingModelChoice.memoryNeeded`): MLX's peak while reading
  an 8.6k-token prompt, plus about 0.5 GiB for the rest of the app. Measured on a Mac with
  `tools/bonsai-check` (2026-11-09). The app never sends more than about that: recipe source text
  is capped at 12,000 characters (`RecipeExtraction.maxSourceCharacters`) and chat at 20 messages.
  The 0.5 GiB for the app is an estimate to confirm on a device.
- **The prompt is read 128 tokens at a time** (`prefill.stepSize`), not mlx-swift-lm's 512. Most
  of the peak beyond the weights is that step's working memory: at 8.6k tokens, 512 → 128 took
  the 9B from 3.87 to 3.22 GiB and the 27B from 9.30 to 8.51, for 5–10% slower prefill and the
  same decode speed (the 27B's went from ~27 to ~25 tok/s on the Mac). The thresholds assume it.
- **Measured tool use** (bonsai-check, Mac): every size passed chat, a timer call, a recipe call
  and JSON. The 4B's tool calls were right in 3 of 3 runs, so it is a candidate for `.full`;
  it stays `.limited` until that is checked on a device. The 2B made small mistakes (steps given
  as ingredients, a wrong amount).
- **Thinking is off for every model** (`templateContext`, `enable_thinking: false`). Qwen3.5's
  template thinks by default, and PrismML notes even simple prompts can spend 3,000 tokens on it.
- **Sampling** is PrismML's non-thinking settings (`topP` 0.8, `topK` 20) at the caller's
  temperature, without their presence penalty of 1.5, which would fight the repeated keys of JSON
  output.
- **The first family is retired.** Its cases are gone. `CookingModelChoice(storedValue:)` maps
  the old names in `UserDefaults` and exported profiles to their successors (8B → 9B, 4B → 4B,
  1.7B → 2B, 27B → 27B), and `removeLegacyDownloads` deletes their downloads at launch
  (`retiredModelIds`).
- **BigBro is separate.** The Mac still serves the first-family 27B (`bigBroModel`,
  `bonsai-27b-ternary`) from its own catalog, in the bigbro repo.

### The increased-memory-limit entitlement

`com.apple.developer.kernel.increased-memory-limit` is on the app target, not the widget. iOS caps
each app well below the RAM fitted. The entitlement raises that cap on devices that grant it,
which is what lets the 27B appear at all and the 9B fit on more iPhones.

The entitlement has to be granted by the profile. Removing it from the App ID, or restoring an
older profile, fails the archive with the row in the table above.

### Which model a device gets, and what it can do

- **Every tier goes by the measured app limit**, not installed RAM: `os_proc_available_memory()`
  plus the current footprint, sampled once at launch. `supportedOnDeviceModel` is the largest of
  9B, 4B and 2B whose `memoryNeeded` fits; below 1.5 GiB there is no on-device model and the
  provider is forced to BigBro. `ProcessInfo.physicalMemory` is not used: it can read under the
  nominal RAM, which put devices a tier down under the old `>= 6` GiB check. The limit is 0 on
  the Simulator, so a Release build there gets no model.
- **The 27B is offered alongside the default** where the limit allows, rather than replacing it.
- **What the backend can do is `AICapability`.** `.full` (chat, timer and recipe tools, AI recipe
  parsing) needs the 27B, the 9B or a connected Mac. `.limited` (chat only) is the 4B and 2B.
  `.none` means no model, a model not downloaded yet, or no Mac: nothing that needs the model is
  offered until it is on the device (`downloadedModelIds`), and `unavailableReason(of:)` says
  what to do about it where the assistant would be. Ask `capability(of:)` with the provider a
  cook pinned, not `capability`, which follows the app-wide setting.
- **DEBUG overrides the tiers**, though not the 27B's memory gate. A debug build reports the 9B
  on every device, so every feature can be exercised on any phone once its model is downloaded,
  and `.full` in the Simulator, which has no model. The limited path, and none in the Simulator,
  can only be seen in a Release build: TestFlight, or a local Release run with the
  manual profiles installed.
- **The on-device model is per device.** It lives in `UserDefaults`
  (`little-chef.on-device-model`), because what a device can run and has downloaded are facts
  about that device; an imported profile restores it only where this device can run it.
  `little-chef.llm-provider` is the last provider used on this device, read at launch, so a cook
  started before Settings has been opened runs where the user asked.

## Storage

Recipes, preferences, the inventory and the shopping list live in SwiftData **on the device
only**, in `LocalDataManager`. There is no sync and no server.

Through build 60 the store was mirrored to the user's private iCloud database. That was dropped
before 1.0 (2026-11): every new model or field needed Deploy Schema to Production in the CloudKit
Console, a missed deploy made TestFlight saves fail silently, and mirroring forbids unique
constraints and required values. So:

- **`cloudKitDatabase: .none` is spelled out.** The default, `.automatic`, mirrors whenever the
  app carries an iCloud entitlement. The app no longer has the iCloud or Push Notifications
  entitlements, nor the `remote-notification` background mode, and doesn't register for remote
  notifications. The App Store profiles still grant iCloud and push; a profile may grant more than
  the app uses.
- **Existing stores open as they are.** Same store file, same models. Rows synced from iCloud
  before the change stay on the device; nothing is uploaded or downloaded any more.
- **Leftovers from sync, kept on purpose.** Every attribute still has a default, nothing is
  `@Attribute(.unique)`, the unused `UserPreferencesEntity` fields stay, and
  `fetchPreferences()`, `fetchPantryItems()` and `fetchShoppingItems()` still collapse duplicates,
  which old synced stores can hold. Changing any of that is a migration for no gain.
- **`storeDidChange`** tells `RecipeManager` and `KitchenManager` to refetch after Delete All Data
  or an import. Do not send it for ordinary single-record writes: the caller already updated its
  own state, and `ProfileSettingsView` writes a preference on every `onChange`.
- **One `RecipeManager`.** `MainView` owns it and passes it down; `RecipeListView` takes it from
  the environment. Two managers over one store left one tab's list stale.
- The `iCloud.com.littlechef.app` container still exists in the developer account, unused.

### Export Profile and Import Profile

Settings → Your Data. One JSON file (`ProfileBackup.swift`, format `littlechef-profile`, version
1) holds the recipes, inventory, shopping list and settings, plus the on-device model choice. Not
in it: downloaded models, paired Macs, or a cook in progress. It is how a user moves to a new
device or survives deleting the app.

- **Import merges, it never deletes.** Recipes match by id: added when new, replaced only when the
  file's `updatedAt` is later. Inventory and shopping items match by name with
  `IngredientMatcher.sameItem`, as adding one by hand does. Settings are replaced. Recipes keep
  their exported ids and dates, so importing the same file twice adds nothing.
- **The on-device model is restored only where this device can run it**
  (`LLMService.onDeviceModelOptions`).
- **`decode` checks the header first**: anything without `format: littlechef-profile` is refused,
  and a higher `version` says the app needs updating rather than failing on a field it doesn't
  know. A new field must bump `currentVersion` or be optional.
- **Anything new the app persists goes in the file too**, as it goes in Delete All Data.
- The format and the merge are Foundation-only and tested on Linux (`ProfileBackupTests`).

## Privacy promises the code keeps

`docs/privacy.md` is the published policy, and three things in it are enforced in code. Change
the code and the policy together.

- **Audio stays on the device in on-device mode.** Both speech paths, the hands-free loop and
  push-to-talk, transcribe through `OnDeviceTranscriber`. It sets `requiresOnDeviceRecognition`
  and throws `onDeviceRecognitionUnsupported` when `supportsOnDeviceRecognition` is false, and
  `LocalVoiceSession` checks `isSupported` before it starts. Falling back to Apple's servers would
  make the policy untrue.
- **Models download only when the user chooses.** Every on-device generation (chat, recipe
  import, the Suggested ranking) goes through `downloadedModelContainer`, which throws
  `modelNotDownloaded` rather than fetching, and the session warm-up skips a model that isn't on
  disk. Only Settings' download button, behind its size and cellular prompts, calls
  `downloadModel`.
- **Data stays on the device.** Nothing the user keeps is uploaded anywhere. It leaves the device
  only in a profile the user exports (see Storage).
- **Settings → Delete All Data deletes everything.** That means recipes, preferences, inventory
  and shopping list, plus every downloaded model, the model settings and every paired Mac.
  Anything new the app persists has to be added to it.

## Permission prompts: one at launch, the rest when first used

Launch asks for notifications (timer alerts) and nothing else. iOS does not queue prompts from
separate requests, so asking for speech recognition and the microphone at the same moment put all
three on screen at once, each answered before the one beneath it. Speech recognition and the
microphone are asked for when voice is first used: push-to-talk in `VoiceAssistant.startRecording()`
(speech only when the utterance will be transcribed on the device), the on-device loop in
`LocalVoiceSession.start()`, and the Mac loop inside BigBroKit. `VoiceAssistant.isAvailable` only
goes false once the microphone has been refused, and is re-read when the app comes back to the
front. Do not add a permission request to an `init` or a launch `.task`.

## Inventory, shopping list and suggestions

The Kitchen tab keeps two SwiftData models, `PantryItemEntity` and `ShoppingItemEntity`, in the
store with the recipes.

`KitchenManager` is the one instance `MainView` owns, like `RecipeManager`. It is the inventory the
recipe filters and the pre-cook check read.

### Matching is deterministic, not AI

`IngredientMatcher` decides what a recipe is missing. It runs for every recipe on every redraw of
the list, with or without an AI backend, so it has to be instant and give the same answer twice.

- **Reducing a line to names.** A line is cut at its first comma (the rest is preparation), and
  asides, quantities, units and size or preparation words are stripped. "2 cloves garlic, minced"
  becomes `garlic`.
- **Several ingredients, or a choice.** "Salt and pepper" is two ingredients. "Butter or oil" is
  one ingredient with two acceptable alternatives.
- **What is skipped.** Optional, garnish and serving lines are never counted as missing. Water and
  section headers ("For the sauce:") are dropped.
- **When two names match.** One side's words must be a subset of the other's. "Garlic" covers
  "garlic cloves", but "black pepper" doesn't cover "bell pepper". This is lenient on purpose:
  "cinnamon" also covers "ground cinnamon". A wrong "you have it" costs a substitution, while a
  wrong "missing" hides a recipe the user could have made.

### Staples and duplicates

- **Staples.** Common staples are seeded once (`KitchenManager.staplesSeededKey`, which Delete All
  Data clears), in the inventory's Staples section, and count as always on hand.
- **Duplicates.** Adding and importing both match by name with `IngredientMatcher.sameItem`, so
  "Eggs" and "egg" are one item. Stores from the iCloud builds can still hold duplicates (a second
  device seeded the staples before the first's arrived), so `fetchPantryItems()` and
  `fetchShoppingItems()` delete the losers as `fetchPreferences()` does, keeping the **oldest** row
  where preferences keep the newest, ties broken on `id`.
- **No warnings until the inventory is in use.** Recipes show have and missing, and the pre-cook
  warning appears, only once the user has added an item beyond the staples
  (`isTrackingInventory`). Before that, every recipe would report everything missing.

### Suggested ranking

`RecipeSuggester` asks the active AI provider to order recipes for the current meal period
(breakfast, lunch, dinner or late night), given what each is missing.

- **Numbers, not UUIDs.** Recipes are given to the model by number, so it never has to reproduce a
  UUID. `parseOrder` accepts `{"order": [...]}` or a bare list of numbers.
- **Never an error.** No AI, a model that isn't downloaded, or an unusable answer all fall back to a
  deterministic order: fewest missing, then meal keywords, then title. The header says when that
  happened.
- **Cached.** The ranking is reused until the meal period, inventory or recipe list changes.

## Editing the recipe mid-cook

A cooking session holds its own copy of the recipe and the assistant is free to rewrite it —
`add_ingredients`, `update_steps`, `set_recipe_details` and the rest, in `CookingTools`. Nothing
it does reaches the store. `CookingSession.recipe` is the working copy, and it is written back
only when the user ends the cook and approves the changes in `SessionChangesView`.

That order is the whole design. Asking before each edit would make the feature useless with
your hands in a bowl; saving without asking would let a model rewrite someone's recipe on the
strength of a sentence it half heard over an extractor fan. So it edits freely and asks once.

### The baseline moves with the servings stepper

`CookingSession.baselineRecipe` is what saving would be a no-op against, and `RecipeDiff`
compares the two. It is *not* frozen at the start of the cook: scaling servings rewrites every
ingredient line, so a frozen baseline would report a serving nudge as a dozen edited
ingredients and put a save prompt in front of someone who changed nothing.
`updateServings(newServings:)` therefore scales both sides through the same arithmetic — a pure
scale cancels out, a real edit either side of one still shows.

For the same reason `set_recipe_details` treats `servings` two ways, and it is not a judgement
call: following a recipe it routes through `updateServings` (cook more of it, amounts scale),
writing one down it sets the number flat (the amounts are what the user said they used, and
rescaling them corrupts the only record of what went in the pan).

`RecipeDiff` runs a real LCS rather than comparing position by position — the assistant can
insert a step in the middle, and a positional compare reports that as every step below it
having been rewritten.

### Cooking without a recipe

`startFreestyleSession()` opens a cook on a blank `RecipeBase` with `sourceRecipeID == nil`.
That one nil is the whole difference: it picks the system prompt (record what the user says
they used, rather than record what they say they changed), it makes the exit sheet show the
recipe instead of a diff — a change list is the wrong way to show someone a recipe they have
never seen written down — and it decides update-that-recipe versus create-a-new-one on save.

Saving falls back to a create when the target recipe has gone: the only way that happens
mid-cook is another device deleting it, and answering an hour of edits with "recipe not found"
loses them to a race the user never saw.

### Every recipe tool takes a list

One call per kind of edit, not per line. A cook names three things in one breath, and a per-line
tool answers that with three round trips — three full re-prefills of the conversation, each one
another chance for a small model to lose track of what it has already recorded and start over.
That is how a gpt-oss recipe-builder turn became an unbounded run of `add_ingredient` calls.

Split by section rather than collapsed into one `edit_recipe`: a whole-recipe tool makes the
model re-emit every untouched line to change one, and `RecipeDiff` then reports its paraphrase of
all of them as the user's edits. Separate calls also fail separately.

The lists are `string` in the schema, one entry per line, because
`BigBroTool.Definition.Parameters.Property` is a `type` and a `description` with no `items` to
describe an array with. `lines(from:keys:)` reads a real JSON array too — models send one anyway
— and never splits on commas, since "two cloves of garlic, minced" is one ingredient.

Repeating a batch is **not** an error. A duplicate add reports `alreadyPresent` and removing
something absent says there was nothing to remove, both as ordinary success. Answering a retry
with a correction tells the model its work didn't land, and a model that believes that retries —
which is the loop, not a report of it. Same reasoning as `deleteRecipe(id:)`.

### Tool results are told twice

`CookingTools.execute` returns a `ToolOutcome`, because a result has two possible audiences.
`forModel` ends with the resulting list and the not-saved reminder: the recipe in the system
prompt is a snapshot from when the user's message arrived, so mid-turn it still says "none
written down yet" while three ingredients are recorded, and that contradiction is what makes a
model record them again. `forUser` is what happened and nothing else — the on-device path returns
tool results *as the reply* (`LLMService`, native calls and the `<tool_call>` fallback), where an
enumerated ingredient list would be printed on screen and read out loud. The timer tools are
split the same way: "tell the user it is ready and wait" steers the model, and was shown and
spoken to the user until it moved to `forModel` alone.

### One tool list, two backends

`CookingTools.toolSpecs` is the single source; `mlxToolSpec` projects it for on-device and
`LLMService.bigBroTools(from:)` for the Mac. These used to be two hand-written lists in two
files. A tool added to one and forgotten in the other is a capability that silently exists
on-device and not over BigBro — in a feature whose entire point is working hands-free.

The singular tool names (`add_ingredient`, `update_step`, …) still resolve, as `set_timer` does:
models copy names out of their training data and out of earlier turns, and the text-tool-call
fallback executes whatever name it parses. A singular call is a batch of one.

### A capped tool loop is not a failed turn

BigBroKit stops the agentic loop at `maxToolRounds` (8) with `BigBroError.toolLoopLimit`. The
LLMService BigBro paths catch it rather than rethrowing: the tools already ran, so the edits are
in the working copy and will be offered for saving at the end of the cook. Rethrowing would put
"Failed to get response" in front of someone whose recipe did change.

### Timer inference is guarded on the word "timer"

`TimerActionInference` (in `ModelReplyText.swift`) reads verbs out of ordinary prose and acts on
them, and `deleteTimer` falls back to "the only timer" when the name doesn't match. Once the
assistant could talk about recipes, "Removed 'garlic' from the ingredients" was one sentence
away from cancelling the timer on the oven. Do not loosen that guard; `ReplyTextTests` holds it.

### What streams is what the user sees

On-device replies stream through `StreamingReplyFilter`, which keeps `<think>` reasoning and
`<tool_call>` text out of the chat bubble and the speech queue while they generate. The finished
reply (`ModelReplyText.strippingThinking`, then the tool calls run) replaces the streamed text,
and whatever it adds at the end, typically tool results, is streamed too so it is also spoken.
Spoken text is cut into sentences by `SentenceSplitter`, which never splits at the end of a chunk:
"Use 1." followed by "5 cups" is one sentence.

### The agent keeps no history of its own

`LocalCookingAgent.reply(to:recipe:history:)` builds every prompt from the session's transcript.
That transcript includes turns a hands-free loop on the Mac mirrored in, which a private copy in
the agent never saw.

## The cooking prompt, and reusing it between questions

Before 2026-11, the phone re-read the whole prompt before every answer. That was about 2,600
tokens, measured with the 9B's tokenizer: 1,809 for the 12 tool definitions, about 280 for a
6-step recipe, and about 500 for the rules. On an iPhone 14 Pro that was a long wait before the
first word.

### What the prompt holds

`CookingPrompt` builds it (Foundation only, so the Linux tests and `bonsai-check eval` use the
app's own prompt), and holds a rule only where nothing else does its job.

- **Replies are short:** "one to three short sentences unless they ask for more detail", and
  `LocalCookingAgent` caps a cooking reply at 512 tokens, room for a tool call that records a
  whole method.

- **The speech rules are BigBro only.** The phone's voices get every sentence through
  `SpokenText.forSpeech`, in `OnDeviceSpeaker.speak` and before `bigBroClient.speak` in
  `VoiceAssistant`. It writes out "tbsp", "350°F", "1 1/2" and "e.g.". The on-screen text keeps the
  short forms. Hands-free on the Mac (`BigBroVoiceSession`) speaks the Mac's own text with no such
  pass, so the Mac still gets the rules.
- **There is no timer paragraph.** "Created, not started" is in `create_timer`'s description and
  its result, and `ToolLoopGuard` refuses a start in the same turn.
- **The kitchen is one line**, worked out in code when the cook starts: "the user's inventory
  doesn't have heavy cream and shallots. It has everything else." (`IngredientMatcher`, as the
  missing-ingredients check). Nothing when the user keeps no inventory. A tool to look things up
  would have cost a model turn per question, since the phone runs no tool loop.
- **The tool-result rules are BigBro only.** "Trust the result over the recipe below" and "don't
  send it again" are about reading results, which only the Mac's loop does. The phone gets "one
  call per tool".
- **Ingredients are listed one per line.** They carry commas of their own.
- **Timers ride on the newest question** (`timersNote`), not the system prompt. The Mac's
  hands-free briefing, built once, still includes them.

### `PromptPrefixCache`

`LLMService` keeps the model's cache for the settled part of one cooking conversation, everything
before the newest question, and feeds a question only what came after. A cook's agent passes a
`promptCacheKey`, the same for every cook (`LocalCookingAgent.promptCacheKey`). Recipe import and
the Suggested ranking pass none, so they are read from the start and leave the kept cache alone.
The key needs no cook in it: only a prompt that starts with exactly the kept tokens reuses them.

- **The copy is kept at the boundary, before the newest question.** Bonsai 2's linear-attention
  layers keep a running state that can't be rewound, so a cache can only be extended. Next turn's
  prompt always starts with this turn's settled part, but not with this turn's reply as generated:
  the template renders past replies differently. So last turn's question and answer are read
  again each turn as history, a few dozen tokens.
- **Finding the boundary.** The conversation is rendered a second time with a placeholder
  (`"\u{1}"`) as the newest question; the two token lists agree up to where the question's text
  begins. A placeholder rather than leaving the question out, because Qwen3.5's template refuses
  a conversation with no user message.
- **What starts it over:**
  - another model, or an unload;
  - a prompt that doesn't start with the kept tokens: the recipe edited mid-cook, or history
    dropping off the front;
  - the history window (20 messages), which moves 8 at a time so the second case is rare.
- **The cook's prompt is read ahead, while the recipe is open.** `RecipeDetailView` calls
  `CookingSessionManager.readAhead(for:)`, which after 1.5 seconds on the page loads the model and
  reads in the prompt that recipe's cook will build. Leaving the page during the wait reads
  nothing; once started it runs to the end, since leaving the page is usually the cook starting.
  The cook's own read-ahead (`LocalCookingAgent.prewarm`, once the model and the agent exist)
  then finds it all there. A cook started some other way still reads ahead at its start.
- **Memory:** the kept copy and the working cache exist side by side while a reply generates.
  At 2k tokens that is about 0.1 GiB on the 9B, inside the 0.5 GiB the thresholds leave for the
  app.
- **Measured on the Mac** with bonsai-check's conversation probe (2026-11-10), four questions
  with the app's 12 tools and a recipe. Average time to first word:

  | Model | Before | Kept | Read-ahead at the cook's start |
  | --- | --- | --- | --- |
  | 9B | 4.63s | 0.33s | 4.5s |
  | 4B | 2.63s | 0.22s | 2.5s |

  A phone is several times slower than the Mac on both.

## The cooking tools

Twelve recipe and timer tools, one per action (`create_timer`, `start_timer`...,
`add_ingredients`, `update_ingredients`, `remove_steps`...), plus `add_to_shopping_list` when the
cook has a kitchen. Their definitions are about 1,800 tokens, the largest part of the prompt.

**Merging them was tried and measured worse** (2026-11-10, `bonsai-check eval`, 3 runs a case):
five tools (`timer` with an action; `edit_ingredients` and `edit_steps`, each with add, change
and remove) cut the prompt from about 2,220 tokens to 1,660, and took the 9B from 94% to 75% and
the 4B from 90% to 83%. The 9B mostly said "I've removed the parmesan" and called nothing. Since
the prompt is read ahead while the recipe is open, 560 tokens buys almost no speed, so the one
tool per action stays. Re-measure before trying again.

## Commands answered without the model

`CookingCommand` answers the commonest things said mid-cook in code, before the model is asked,
from `CookingSessionManager.sendQueryStreaming` (typed and spoken alike): timer create, start,
stop and cancel; "how long is left"; "repeat that"; "what's step 3"; "how much salt". Timer
commands go through `CookingTools.execute`, so the wording and rules (created stopped) are the
model's. The turn is added to the conversation like any other.

It is deliberately strict: a pattern has to match everything said, and anything that could mean
two things goes to the model. Bare "stop" and "cancel" are never timer commands (they as often
mean the voice or the alarm); bare "start" is, because the create reply says to say it. A timer is
found by its label, or the one label containing the name said, never a label merely mentioned in
a longer phrase ("stop the chicken from sticking"). There is no "next step": the app doesn't
know which step the cook is on.

## The cooking test set

`swift run -c release bonsai-check eval [model...]` in `tools/bonsai-check`, on the Mac (put it
on `caffeinate -i`: a Mac that sleeps mid-run inflates the timings, not the scores). 29 cases, each
one question in a cook asked with the app's prompt and tools, checked for the tool call or answer
it should produce: questions that must not edit, judgement (a bad swap, a silly amount, reading
an amount right), changes that must be recorded, timers, the kitchen line, the shopping list, and
writing a recipe from nothing. The judgement cases came after the 4B scored 70/75 here and still
gave advice Cedric couldn't use on the phone; their word checks are a rough proxy, so read what
fails. Each runs `EVAL_RUNS` times
(default 3) at the app's sampling. Run it before and after changing the prompt or the tools.

As shipped (2026-11-13, 29 cases): **9B 79/87, 4B 68/87.** The four judgement cases came in at
78/87 for both, with the bad swap (olive oil for cream) recorded as a change and milk for cream
called a plain yes. The two swap lines in `CookingPrompt` took the 9B's judgement cases to
11/12. On the cases that must record, the 9B's misses are mostly saying "I've recorded…" with
no call (batch, step made) and folding "a pinch of chili flakes" into the garlic line rather
than adding it. The 4B lost more there, and is chat-only in the app anyway. Before the judgement
cases (2026-11-10, 25 cases): 9B 75/75, 4B 70/75.

## Ingredient scaling

`IngredientScaler` scales the **leading** amount of a line and nothing else. In "1 (14 oz) can
tomatoes" the 1 is a count and the 14 a package size. A line with no leading amount ("salt to
taste") is left exactly as it is. Mixed numbers, unicode fractions, ranges and number words are
read; results snap to kitchen fractions below 10 and whole numbers above.

It must stay a pure function. `CookingSessionManager.updateServings` scales the working copy and
the baseline separately, and identical inputs giving identical outputs is what makes a serving
change cancel out instead of showing as unsaved recipe edits.

## Recipe import

`RecipeExtraction` reads schema.org JSON-LD and the import prompt's JSON, leniently: numbers as
strings, lists as one string, missing lists as empty, trailing commas. A strict decoder used to
throw the whole recipe away over any one of those.

- **Yields.** Servings come from the first number in a yield, so "4-6 servings" is 4. Joining
  every digit read it as 46.
- **One size limit.** `RecipeExtraction.maxSourceCharacters` caps both the text box and the prompt.
- **Typed scraper result.** `WebScraperService` returns a `ScrapedRecipePage`, not a string with a
  magic prefix.

## Pull request checks

Two workflows run on every pull request to `main`. Neither uses a secret.

- **`pr-build.yml`** builds the `little-chef` scheme in Release for `generic/platform=iOS`, with
  `CODE_SIGNING_ALLOWED=NO`, on `macos-26` with Xcode 26 picked the same way the deploy picks it.
  It is a device build rather than a simulator one because that is what the archive compiles, and
  MLX's Metal kernels are built for the device GPU. It catches a package bump or a missing import
  before merge.
  - **It cannot catch signing problems.** Nothing is signed, so a broken profile, a missing
    capability or a lost entitlement only shows at the deploy's Archive or Export. Prove a signing
    or entitlement change with the deploy itself (`workflow_dispatch` works without a merge).
- **`unit-tests.yml`** runs the unit tests on Linux (below). It also runs on every push to `main`.

## Testing

`little-chefTests` holds the unit tests, written with Swift Testing. They run two ways.

- **In Xcode:** ⌘U, against the app target.
- **On Linux, on every pull request:** `.github/workflows/unit-tests.yml` runs
  `swift test --package-path tools/linux-tests`. This also works locally on a Mac with a Swift
  toolchain, no simulator needed.

`tools/linux-tests` is a SwiftPM package whose sources are **symlinks** into the app target and
whose test target is a symlink to `little-chefTests`. So it is the same code and the same tests,
with no copies to keep in step. Two stand-ins cover what those files borrow from iOS-only code:
`Shims/LocalTimerStub.swift`, a minimal `LocalTimer` linked in like the app's files, and the
`MLXLMCommon` target, whose one file is MLX's `ToolSpec` typealias.

Only Foundation-only files can be linked. That is why the testable logic lives in files of its
own: `IngredientMatcher`, `IngredientScaler`, `RecipeExtraction`, `RecipeLineMatcher`,
`ModelReplyText`, `SpeechText`, `RecipeSuggester`, `RecipeDiff`, `HTMLText` and `ToolDefinition`.

- **Adding a test for an existing linked file** needs nothing extra.
- **Linking a new file:** keep it Foundation-only, and add its symlink under
  `tools/linux-tests/Sources/little_chef/`.
- **Test files** must import only Foundation and Testing, or the Linux job can't build them.

Linux's ICU is stricter than Apple's. An unescaped `}` in a regex is a syntax error there, and
`replacingOccurrences(…, options: .regularExpression)` then returns an **empty string**. Escape
`{` and `}` in patterns; the Linux job catches it if you don't.

`little-chefUITests` is separate: UI smoke tests (launch, a URL import from start to finish, the
Cook and Settings tabs) that need a simulator and run from Xcode only. They find controls by their
visible text, so renaming a button or a section header can break them.

## Testing on the Mac

Development can happen on a Linux machine (beepboop), which runs the Linux unit tests above and
nothing iOS. The build, the Simulator and the UI tests run on a Mac, through a Claude Code Remote
Control session there that the Linux session messages: push a branch, ask the Mac session to run
`tools/mac-test <branch>`, read back its summary.

- **A checkout kept for testing only.** `tools/mac-test` checks out whatever it is asked to test,
  detached, so it runs from a `git worktree` rather than the clone open in Xcode:
  `git worktree add --detach ../little-chef-test` from the main clone, and Remote Control serves
  that folder. It refuses to run in a checkout with uncommitted changes.
- **The Mac needs the Metal Toolchain.** MLX compiles Metal kernels, and since Xcode 26 the Metal
  compiler is a separate component: `xcodebuild -downloadComponent MetalToolchain`, once per Xcode.
  The script checks for it before building rather than failing on the first `.metal` file.
- **What it runs.** `little-chefTests` on an iPhone Pro Simulator, from the newest iOS that has one
  (else the newest iPhone; `MAC_TEST_SIMULATOR=<name>` picks another), in Debug; `--ui` adds
  `little-chefUITests`. It prints the pass and fail counts and each failure from the result bundle,
  and on a failed build the `error:` lines from the log. The log and result bundle are kept under
  `~/Library/Caches/little-chef-mac-test/`, with a DerivedData of its own there, so rebuilds are
  incremental and never disturb Xcode's.
- **The on-device models.** The Simulator can't run MLX, so `tools/bonsai-check` checks them on
  the Mac itself: `cd tools/bonsai-check && swift run -c release bonsai-check [model id ...]`.
  It loads each Bonsai 2 model the way the app does (the same mlx-swift-lm fork, the app's
  Hugging Face loader and tool definitions, symlinked in) and reports chat, a timer tool call, a
  recipe tool call and JSON output, pass or fail, with tokens per second, the weights' memory and
  the peak memory at an ~8k-token prompt. Downloads go to `~/Library/Application
  Support/huggingface/hub`, about 15 GB for all four. Keep its package pins equal to the app's.
- **App Store screenshots.** `tools/mac-test <branch> --screenshots` runs only `testScreenshots`
  (skipped in every other run): a Debug launch with `-ui-screenshots` puts the sample content in
  `ScreenshotFixtures.swift` in an in-memory store, never the Simulator's own, and stages
  the cooking screen's conversation and timer, since the Simulator runs no model. It picks the
  newest iPhone Pro Max (6.9", Apple's required iPhone size); `MAC_TEST_SIMULATOR="iPad Pro
  13-inch (M5)"` gives the iPad set. The status bar is set to 9:41, and the PNGs land in
  `~/Library/Caches/little-chef-mac-test/screenshots/<simulator>/`. They are uploaded with
  apple-dev's `upload_screenshot`, from beepboop's `~/.local/state/beep/apple-dev/uploads/`.
- **What it cannot see.** The Simulator runs no MLX, so on-device inference, speech and Live
  Activities still need a real iPhone. It also signs nothing for distribution: signing changes are
  still proven by the deploy (see **Pull request checks**).
- **The Mac must be awake** and the Claude app running; an unanswered message means it isn't.
