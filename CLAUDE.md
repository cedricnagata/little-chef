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
`team-identifier`, `beta-reports-active` and `get-task-allow`, losing iCloud, push and
the app group even though the embedded profile still grants all three. Build 18 shipped
exactly that and crashed on launch — see the entitlements row in the failure table
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
| **App launches from TestFlight and crashes immediately**, but the same code runs fine from Xcode | The IPA lost its entitlements — almost certainly because something made **Archive** stop signing. `codesign -d --entitlements :- Payload/little-chef.app`: if iCloud, `aps-environment` and the app group are absent, that's it. The crash is `LocalDataManager` opening the CloudKit-backed store in `App.init()`; its local-only fallback catches Swift errors and this arrives as an ObjC exception, so it aborts. **Not** a code bug — see the signing-style section |
| Any **certificate or profile** error at **Archive** | Archive signs manually against the profiles installed earlier in the job. Check the `Release` config of both targets still names its profile, that both profiles installed, and that no `-allowProvisioningUpdates`/`-authenticationKey*` crept back in. Do **not** "fix" this by disabling signing — that ships an app with no entitlements |
| `<target> does not support provisioning profiles` (an SPM package target) | A signing setting was put on the `xcodebuild` command line, where it hits every target. Per-target signing belongs in the project's `Release` configs |
| `is Xcode managed, but signing settings require a manually managed profile` | An Xcode-managed profile is installed under the name the `Release` config asks for. The App Store profiles in `IOS_PROFILE_*_BASE64` must be manually created |
| `Choose a certificate to revoke` | The account is at its certificate cap. Should now be unreachable from CI; if it appears, something is minting certificates again |
| `error: … doesn't include signing certificate` at **Export** | The stored profile predates the distribution certificate, or that certificate was revoked. Regenerate the profile against the current one and re-store both secrets |
| `security import` fails on empty input | Secrets set on an environment the job doesn't declare |
| `Cloud signing permission error` + `No profiles for '<id>' were found` at **Export** | Export fell back to cloud signing. Check `signingStyle` is `manual` and that no `-allowProvisioningUpdates`/`-authenticationKey*` reached `-exportArchive`. **Not** a missing-profile problem — the lookup was denied, not empty |
| `Invalid authentication key credential … invalidPEMDocument` at **Upload** | `ASC_KEY_P8_BASE64` decodes to something that isn't a PEM — usually the base64 body saved without its `-----BEGIN PRIVATE KEY-----` delimiters. **Not** an auth failure. Validate with `openssl pkey -noout -in key.p8` (not `openssl pkcs8 … -noout`, which has no such flag in LibreSSL or OpenSSL 3 and rejects every key) |
| Profile name mismatch at **Export** | `IOS_PROFILE_*_NAME` must be the profile's **Name** field, not its filename or UUID. The same name is also hardcoded as `PROVISIONING_PROFILE_SPECIFIER` in each target's `Release` config for the archive — rename a profile and **both** have to move |
| `doesn't support the Push Notifications capability` / `entitlement 'aps-environment' … not present in profile` | The App ID or the stored profile predates the Push Notifications capability CloudKit needs. See **CloudKit sync** below |
| `entitlement 'com.apple.developer.kernel.increased-memory-limit' … not present in profile` | The app's App Store profile predates the **Increased Memory Limit** capability. Enable it on the `NagataInc.little-chef` App ID, regenerate the profile under the same name and replace `IOS_PROFILE_APP_BASE64`. The widget doesn't carry this entitlement, so its profile is unaffected |

Inspect a run:

```sh
gh run view <id> --json jobs -q '.jobs[].steps[] | "\(.conclusion)\t\(.name)"'
gh run view <id> --log-failed
```

## MLX packages

On-device inference uses the stock `ml-explore/mlx-swift` and `ml-explore/mlx-swift-lm`.
Bonsai's 1-bit weights need `mlx-swift` **0.33.0** or later — the first release whose bundled
MLX has 1-bit quantization.

`mlx-swift-lm` is pinned to a **revision**, not a version, because no release yet accepts
`mlx-swift` 0.33: the latest tag, 3.32.3, caps it below. Move it to a version requirement once a
release declares `mlx-swift` 0.33 or later.

mlx-swift-lm 3 doesn't download or tokenize by itself. `HubModelLoading.swift` bridges it to
`swift-huggingface` and `swift-transformers` by hand rather than through the `MLXHuggingFace`
macros, because `xcodebuild` won't run a package's macros in CI until someone trusts them
interactively. Models are stored under Application Support in the hub's
`models--<org>--<name>` layout. Caches is not used, because iOS can empty it.

### The increased-memory-limit entitlement

`com.apple.developer.kernel.increased-memory-limit` is on the app target, not the widget. iOS caps
each app well below the RAM fitted, and the 27B's ~7 GB of weights can't load under the default
cap on any current device. `LLMService.onDeviceModelOptions` offers the 27B only when the app's
measured limit (`os_proc_available_memory()` plus the current footprint) is 9 GB or more. So the
entitlement is what makes the option appear at all, on devices that grant it. It also gives the
8B more room on 6–8 GB iPhones.

The entitlement has to be granted by the profile. Removing it from the App ID, or restoring an
older profile, fails the archive with the row in the table above.

### Which model a device gets, and what it can do

- **The default model goes by installed RAM.** `LLMService.supportedOnDeviceModel` reads
  `ProcessInfo.physicalMemory` in GiB: 6 or more gets the 8B, 4 or more the 4B, 3 or more the
  1.7B, and below that there is no on-device model and the provider is forced to BigBro.
- **The 27B goes by the measured app limit** (above), and is offered alongside the default rather
  than replacing it.
- **What the backend can do is `AICapability`.** `.full` (chat, timer and recipe tools, AI recipe
  parsing) needs the 27B, the 8B or a connected Mac. `.limited` (chat only) is the 4B and 1.7B.
  `.none` means no model or no Mac. Ask `capability(of:)` with the provider a cook pinned, not
  `capability`, which follows the app-wide setting.
- **DEBUG overrides the RAM check and the tiers**, though not the 27B's memory gate. A debug build
  reports the 8B and `.full` on every device, so every feature can be exercised on any phone.
  The limited and none paths can only be seen in a Release build: TestFlight, or a local Release
  run with the manual profiles installed.
- **The on-device model is per device; the provider syncs.** The chosen on-device model lives
  only in `UserDefaults` (`little-chef.on-device-model`), because what a device can run and has
  downloaded are facts about that device. The provider is in the synced preferences, and Settings
  applies it when it appears. `little-chef.llm-provider` in `UserDefaults` is the last provider
  used on this device, read at launch, so a cook started before Settings has been opened runs
  where the user asked.

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

### CRUD across two devices

Mirroring being wired up is not the same as the CRUD paths being correct on top of it. These
are the shapes that only break once a second device exists.

**Preferences are a singleton row that CloudKit cannot enforce.** `@Attribute(.unique)` is
rejected outright on a mirrored model, and every fresh device calls `fetchPreferences()`
before its first import lands, finds nothing, and inserts its own defaults — so two devices
means two rows. `fetchPreferences()` therefore resolves duplicates rather than trusting
`.first` on an unsorted fetch: newest `updatedAt` wins, ties broken on `id`, losers deleted.
Every device computes the same winner from the same set, so it converges. Left unresolved
this reads as settings that revert on their own.

**Deleting something already deleted is not an error.** `deleteRecipe(id:)` is idempotent.
The other device deleting it first, with the import landing before the user confirms, is
ordinary — surfacing `recipeNotFound` for it just puts "Recipe with ID <uuid> not found" in
front of someone whose recipe is, in fact, gone.

**`storeDidChange` is how anything holding a cached copy finds out.** Subscribers
(`RecipeManager`, `KitchenManager`) are refetch triggers for the two cases a caller can't see for
itself: a CloudKit import, and Delete All Data.

It is a `PassthroughSubject`, not a closure property, because there is more than one
subscriber and a single `var onRemoteChange: (() -> Void)?` silently let the last assignment
win. Do not send it for ordinary single-record writes: the caller already updated its own
state, and `ProfileSettingsView` writes a preference on every `onChange`, so echoing those
back puts it in a save/load loop with itself.

**One `RecipeManager`.** `MainView` owns it and passes it down; `RecipeListView` takes it from
the environment. It used to hold its own `@StateObject` as well, which is two managers and two
`recipes` arrays over one store — adding a recipe on one tab left the other's list stale.

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
- **Settings → Delete All Data deletes everything.** That means recipes, preferences, inventory
  and shopping list, row by row so the deletes mirror to iCloud and the user's other devices, plus
  every downloaded model, the model settings and every paired Mac. Anything new the app persists
  has to be added to it.

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

The Kitchen tab keeps two SwiftData models, `PantryItemEntity` and `ShoppingItemEntity`, mirrored to
iCloud with the recipes. **They are new CloudKit record types, so they need Deploy Schema to
Production too.** Until then TestFlight and App Store builds keep them on the device only.

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

- **Staples.** Common staples are seeded once per device (`KitchenManager.staplesSeededKey`, which
  Delete All Data clears), in the inventory's Staples section, and count as always on hand.
- **Why duplicates happen.** A second device seeds the staples again before iCloud has delivered
  the first device's, so duplicate names are expected.
- **How they're collapsed.** `fetchPantryItems()` and `fetchShoppingItems()` delete the losers as
  `fetchPreferences()` does, but keep the **oldest** row where preferences keep the newest. Ties
  break on `id`, so every device deletes the same rows and the store converges. Names are compared
  with `IngredientMatcher.sameItem`, so "Eggs" and "egg" are one item.
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
enumerated ingredient list would be printed on screen and read out loud.

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
