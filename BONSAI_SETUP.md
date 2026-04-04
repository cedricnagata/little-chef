# Running PrismML Bonsai 8B (1-bit) with mlx-swift-examples

This documents how to configure the [mlx-swift-examples](https://github.com/ml-explore/mlx-swift-examples) project to run the [PrismML Bonsai 8B 1-bit model](https://huggingface.co/prism-ml/Bonsai-8B-mlx-1bit) on iOS/macOS using the MLXChatExample app.

## Background

The Bonsai 8B model uses 1-bit quantization with custom Metal kernels. These kernels are not yet in the upstream `mlx-swift` package — they live in [PrismML's mlx-swift fork](https://github.com/PrismML-Eng/mlx-swift) on the `prism` branch.

Swapping in the fork directly causes two problems:

1. **Conflicting package identity** — The Xcode project depends on `mlx-swift-lm` (from `ml-explore`), which transitively depends on the *original* `ml-explore/mlx-swift`. Adding PrismML's fork creates two packages with the same identity `mlx-swift`, which SwiftPM rejects.

2. **C++20 `consteval` compilation errors** — PrismML's fork changed the C++ language standard from `gnucxx17` to `gnucxx20` in `Package.swift`. This causes the bundled `fmt` library's `FMT_STRING` macro to fail under stricter `consteval` enforcement in modern Xcode/Clang:
   ```
   Call to consteval function 'fmt::basic_format_string<...>::basic_format_string<FMT_COMPILE_STRING, 0>'
   is not a constant expression
   ```

## Solution

The fix uses local package overrides for both `mlx-swift` and `mlx-swift-lm`, forming a consistent dependency chain with no identity conflicts.

### Directory layout

After setup, the directory structure looks like this:

```
reference/
  mlx-swift-examples/    # The main project (this repo)
  mlx-swift/             # Local clone of PrismML's mlx-swift fork (patched)
  mlx-swift-lm/          # Local clone of ml-explore/mlx-swift-lm (patched)
```

### Step-by-step

#### 1. Clone PrismML's mlx-swift fork

```bash
cd /path/to/parent/directory   # the directory containing mlx-swift-examples
git clone --branch prism https://github.com/PrismML-Eng/mlx-swift.git mlx-swift
cd mlx-swift
git submodule update --init --recursive
```

#### 2. Fix the C++ language standard

In `mlx-swift/Package.swift`, change the last line of the `Package(...)` initializer:

```diff
-    cxxLanguageStandard: .gnucxx20
+    cxxLanguageStandard: .gnucxx17
```

This fixes the `fmt` consteval errors. The 1-bit kernel code does not require C++20.

#### 3. Clone mlx-swift-lm and redirect its dependency

```bash
cd /path/to/parent/directory
git clone --depth 50 https://github.com/ml-explore/mlx-swift-lm.git mlx-swift-lm
cd mlx-swift-lm
git checkout 2.30.6
git switch -c prism-local
```

In `mlx-swift-lm/Package.swift`, change the mlx-swift dependency from the remote URL to the local path:

```diff
-        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.30.6")),
+        .package(path: "../mlx-swift"),
```

This ensures `mlx-swift-lm` uses the PrismML fork instead of the upstream, eliminating the identity conflict.

#### 4. Update mlx-swift-examples

**`Package.swift`** — change the mlx-swift dependency to use the local path:

```diff
-        .package(url: "https://github.com/PrismML-Eng/mlx-swift", .upToNextMinor(from: "0.30.3")),
+        .package(path: "../mlx-swift"),
```

**Xcode project** — In `mlx-swift-examples.xcodeproj`, update both package references to local:

- Change `mlx-swift` from `XCRemoteSwiftPackageReference` to `XCLocalSwiftPackageReference` with `relativePath = "../mlx-swift"`
- Change `mlx-swift-lm` from `XCRemoteSwiftPackageReference` to `XCLocalSwiftPackageReference` with `relativePath = "../mlx-swift-lm"`

The easiest way to do this is through Xcode's UI:
1. Remove the existing `mlx-swift` and `mlx-swift-lm` package dependencies
2. Add Local Package Dependency > navigate to `../mlx-swift`
3. Add Local Package Dependency > navigate to `../mlx-swift-lm`
4. Re-add the required product dependencies (MLX, MLXNN, MLXFast, etc.) to each target

**Delete stale resolved files** so Xcode re-resolves from scratch:

```bash
rm -f mlx-swift-examples.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

#### 5. Add the Bonsai model to the app

In `Applications/MLXChatExample/Services/MLXService.swift`, add the model to `availableModels`:

```swift
LMModel(
    name: "bonsai:8b-1bit",
    configuration: ModelConfiguration(id: "prism-ml/Bonsai-8B-mlx-1bit"),
    type: .llm
),
```

#### 6. Build and run

Resolve packages and build:

```bash
xcodebuild -resolvePackageDependencies -project mlx-swift-examples.xcodeproj
```

Or in Xcode: **File > Packages > Resolve Package Versions**, then build.

Select "bonsai:8b-1bit" in the model picker. The model will download from HuggingFace on first use.

## Performance

From PrismML's benchmarks on iPhone 17 Pro Max:
- **44 tok/s** token generation
- **377 tok/s** prompt processing

## References

- [Bonsai 8B model card](https://huggingface.co/prism-ml/Bonsai-8B-mlx-1bit)
- [PrismML mlx-swift fork](https://github.com/PrismML-Eng/mlx-swift) (branch: `prism`)
- [PrismML Bonsai demo repo](https://github.com/PrismML-Eng/Bonsai-demo/)
