# Running PrismML Bonsai 8B (1-bit) via forked MLX Swift packages

LittleChef runs the [PrismML Bonsai 8B 1-bit model](https://huggingface.co/prism-ml/Bonsai-8B-mlx-1bit) on-device using [MLX Swift](https://github.com/ml-explore/mlx-swift). This documents how the dependency setup works and why.

## Background

The Bonsai 8B model uses 1-bit quantization with custom Metal kernels. These kernels are not yet in the upstream `mlx-swift` package — they live in [PrismML's mlx-swift fork](https://github.com/PrismML-Eng/mlx-swift) on the `prism` branch.

Depending on that fork directly (as a remote SwiftPM package) causes two problems:

1. **Conflicting package identity** — `mlx-swift-lm` (from `ml-explore`) transitively depends on the *original* `ml-explore/mlx-swift`. Adding PrismML's fork under a different URL creates two packages with the same identity `mlx-swift`, which SwiftPM rejects.

2. **C++20 `consteval` compilation errors** — PrismML's fork sets the C++ language standard to `gnucxx20` in `Package.swift`. This breaks the bundled `fmt` library's `FMT_STRING` macro under `consteval` enforcement in modern Xcode/Clang:
   ```
   Call to consteval function 'fmt::basic_format_string<...>::basic_format_string<FMT_COMPILE_STRING, 0>'
   is not a constant expression
   ```

Neither problem is fixable by configuration alone — both require a source patch, and SwiftPM has no mechanism to patch a remote dependency in place.

## Solution: pinned forks, referenced remotely

Rather than cloning and patching `mlx-swift` and `mlx-swift-lm` locally on every machine (the old approach — see git history if you need it), both patches are committed to two small forks under this project's GitHub account, tagged, and referenced as ordinary **remote** SwiftPM packages:

- [`cedricnagata/mlx-swift`](https://github.com/cedricnagata/mlx-swift) — forked from `PrismML-Eng/mlx-swift` (`prism` branch), with `cxxLanguageStandard` changed from `.gnucxx20` to `.gnucxx17`. Tagged `0.30.3-bonsai-ios`; default branch `prism`.
- [`cedricnagata/mlx-swift-lm`](https://github.com/cedricnagata/mlx-swift-lm) — forked from `ml-explore/mlx-swift-lm` (tag `2.30.6`), with its `mlx-swift` dependency repointed from `ml-explore/mlx-swift` to `cedricnagata/mlx-swift` at `0.30.3-bonsai-ios`. Tagged `2.30.6-bonsai`; default branch `bonsai-local`.

In both forks the patch lives on the **default branch**, not on `main` — `main` tracks unmodified upstream. Land changes on `prism` / `bonsai-local`.

Because both forks resolve to the **same package identity** (`mlx-swift`) via a **single URL** (`cedricnagata/mlx-swift`), there's no conflict — same as depending on any two ordinary packages that happen to share a transitive dependency.

**Result:** a fresh clone of this repo builds with no manual setup. No local package clones, no patching steps, no `Package.swift` edits. `xcodebuild -resolvePackageDependencies` (or Xcode's automatic resolution) fetches both forks like any other remote dependency.

### Xcode project wiring

`little-chef.xcodeproj` references both forks as `XCRemoteSwiftPackageReference`, pinned with `kind = exactVersion`:

```
mlx-swift     -> https://github.com/cedricnagata/mlx-swift     @ 0.30.3-bonsai-ios
mlx-swift-lm  -> https://github.com/cedricnagata/mlx-swift-lm  @ 2.30.6-bonsai
```

The app target's `packageProductDependencies` list the same products as before (`MLX`, `MLXLLM`, `MLXLMCommon`) — nothing in application code changes.

## Updating the forks

To pick up a new PrismML `prism` revision or a newer `mlx-swift-lm` release:

1. Pull the latest `prism` branch (or new `mlx-swift-lm` tag) into a local clone of the relevant fork.
2. Re-apply the one-line patch if it doesn't still apply cleanly (`gnucxx17`, or the dependency URL/version in `mlx-swift-lm`'s `Package.swift`).
3. Commit, tag with a new version (e.g. `0.30.4-bonsai-ios`), push.
4. Bump the `version` in the corresponding `XCRemoteSwiftPackageReference` requirement in `little-chef.xcodeproj/project.pbxproj`.
5. `xcodebuild -resolvePackageDependencies -project little-chef.xcodeproj` (or Xcode: File ▸ Packages ▸ Resolve Package Versions).

## Dropping the fork entirely

If upstream `ml-explore/mlx` merges [1-bit affine quantization support](https://github.com/ml-explore/mlx/pull/3161) and `ml-explore/mlx-swift` ships a release exposing it, point the Xcode project's package references back at the stock `ml-explore/mlx-swift` and `ml-explore/mlx-swift-lm` and drop the two forks.

**Status as of 2026-08-03:** not yet possible. PR #3161 is still open, PrismML's `prism` branch still sets `.gnucxx20` (including on its newer `v0.31.6_prism` branch), and PrismML publishes no `mlx-swift-lm` fork of its own — so both patches are still ours to carry.

## If a fork gets deleted

SwiftPM keeps full-history mirrors of every dependency, so a deleted fork is recoverable without re-doing the patch:

```sh
ls ~/Library/Caches/org.swift.swiftpm/repositories/            # find the mirror
gh repo fork ml-explore/mlx-swift-lm --clone=false             # recreate the fork
git clone --no-checkout ~/Library/Caches/org.swift.swiftpm/repositories/mlx-swift-lm-<hash> recover
git -C recover push https://github.com/cedricnagata/mlx-swift-lm.git \
    refs/heads/bonsai-local:refs/heads/bonsai-local \
    refs/tags/2.30.6-bonsai:refs/tags/2.30.6-bonsai
```

Check the recovered tag's commit against the `revision` in `Package.resolved` before trusting it.

## Performance

From PrismML's benchmarks on iPhone 17 Pro Max:
- **44 tok/s** token generation
- **377 tok/s** prompt processing

## References

- [Bonsai 8B model card](https://huggingface.co/prism-ml/Bonsai-8B-mlx-1bit)
- [PrismML mlx-swift fork](https://github.com/PrismML-Eng/mlx-swift) (branch: `prism`)
- [PrismML Bonsai demo repo](https://github.com/PrismML-Eng/Bonsai-demo/)
