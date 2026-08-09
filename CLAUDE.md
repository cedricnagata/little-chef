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

### Signing style: unsigned archive, manual export — and why

This project has **two signable targets**, `little-chef`
(`NagataInc.little-chef`) and `TimerWidgetExtension`
(`NagataInc.little-chef.TimerWidget`). Each needs its own provisioning profile.

`xcodebuild` command-line build settings apply to *every target at once*, so manual
signing cannot hand the app and its widget different profiles from the command line.
`ExportOptions.plist` is the only place that per-target mapping can be expressed —
so **export owns signing outright, and archive does none at all**:

```
CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="" PROVISIONING_PROFILE_SPECIFIER="" \
CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

All five matter. `CODE_SIGNING_ALLOWED=NO` on its own still leaves automatic signing
to resolve a profile — and fail — before it gets as far as not signing; blanking the
identity and specifier under `Manual` is what stops the lookup happening.

Archive used to sign automatically, via `-allowProvisioningUpdates` and the
`-authenticationKey*` trio. That asks Apple to mint an **Apple Development**
certificate over the API — an account-global, *capped* mutation performed on every
run, for an identity the build never ships, since export re-signs everything minutes
later anyway. The account duly reached its certificate limit and every archive
failed with `Choose a certificate to revoke`, followed by
`No profiles for '<id>' were found` as the downstream symptom. Not signing needs no
certificate, so the cap cannot be reached.

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
| Any **certificate or profile** error at **Archive** | Archive signs nothing. Something regressed the signing style — check all five `CODE_SIGN*` settings are still on the `xcodebuild archive` line, and that no `-allowProvisioningUpdates`/`-authenticationKey*` crept back in |
| `Choose a certificate to revoke` | The account is at its certificate cap. Should now be unreachable from CI; if it appears, something is minting certificates again |
| `error: … doesn't include signing certificate` at **Export** | The stored profile predates the distribution certificate, or that certificate was revoked. Regenerate the profile against the current one and re-store both secrets |
| `security import` fails on empty input | Secrets set on an environment the job doesn't declare |
| `Cloud signing permission error` + `No profiles for '<id>' were found` at **Export** | Export fell back to cloud signing. Check `signingStyle` is `manual` and that no `-allowProvisioningUpdates`/`-authenticationKey*` reached `-exportArchive`. **Not** a missing-profile problem — the lookup was denied, not empty |
| `Invalid authentication key credential … invalidPEMDocument` at **Upload** | `ASC_KEY_P8_BASE64` decodes to something that isn't a PEM — usually the base64 body saved without its `-----BEGIN PRIVATE KEY-----` delimiters. **Not** an auth failure. Validate with `openssl pkey -noout -in key.p8` (not `openssl pkcs8 … -noout`, which has no such flag in LibreSSL or OpenSSL 3 and rejects every key) |
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

**`storeDidChange` is how anything holding a cached copy finds out.** Subscribers are refetch
triggers for the two cases a caller can't see for itself: a CloudKit import, and a bulk local
write (`deleteRecipes(ids:)`) made from a screen that doesn't own the list.

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

### `inferTimerAction` is guarded on the word "timer"

It reads verbs out of ordinary prose and acts on them, and `deleteTimer` falls back to "the
only timer" when the name doesn't match. Once the assistant could talk about recipes,
"Removed 'garlic' from the ingredients" was one sentence away from cancelling the timer on the
oven. Do not loosen that guard.
