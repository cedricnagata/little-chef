// swift-tools-version: 6.0
//
// The app's platform-independent logic, built and tested on Linux.
//
// The sources are symlinks into the app target and the tests are a symlink to
// little-chefTests, so this runs the same suite Xcode does without the iOS SDK — on any
// machine, and on every pull request (see .github/workflows/unit-tests.yml). Only files that
// need nothing beyond Foundation can be linked into Sources/little_chef. The two types they
// borrow from code that does are stood in for by Shims/LocalTimerStub.swift (linked in like the
// rest) and the one-file MLXLMCommon target below.

import PackageDescription

let package = Package(
    name: "LittleChefLogic",
    targets: [
        // `ToolSpec` is MLX's typealias for a tool definition; ToolDefinition.swift imports it.
        .target(name: "MLXLMCommon"),
        .target(name: "little_chef", dependencies: ["MLXLMCommon"]),
        .testTarget(name: "little_chefTests", dependencies: ["little_chef"]),
    ],
    swiftLanguageModes: [.v5]
)
