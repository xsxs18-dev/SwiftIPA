// swift-tools-version: 6.0
import PackageDescription

// For local builds with xtool (`xtool dev build`). The release IPA is still built
// from project.yml by GitHub Actions. Run Scripts/fetch-dependencies.sh first,
// it puts zsign (ZSignKit/zsign) and the OpenSSL headers in place.
let zsignCSettings: [CSetting] = [
    .define("SWIFTIPA_HAS_ZSIGN", to: "1"),
    .headerSearchPath("zsign"),
    .headerSearchPath("zsign/common"),
    .headerSearchPath("../Vendor/openssl-include"),
]
let zsignCXXSettings: [CXXSetting] = [
    .define("SWIFTIPA_HAS_ZSIGN", to: "1"),
    .headerSearchPath("zsign"),
    .headerSearchPath("zsign/common"),
    .headerSearchPath("../Vendor/openssl-include"),
]

let package = Package(
    name: "SwiftIPA",
    platforms: [.iOS(.v16)],
    products: [.library(name: "SwiftIPA", targets: ["SwiftIPA"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/krzyzanowskim/OpenSSL.git", exact: "3.6.5000"),
    ],
    targets: [
        .target(
            name: "ZSignKit",
            dependencies: [.product(name: "OpenSSL", package: "OpenSSL")],
            path: "ZSignKit",
            exclude: [
                "zsign/zsign.cpp",
                "zsign/certcheck.cpp",
                "zsign/certcheck.h",
                "zsign/metadata.cpp",
                "zsign/metadata.h",
                "zsign/third-party",
                "zsign/common/archive.cpp",
                "zsign/common/archive.h",
            ],
            publicHeadersPath: "include",
            cSettings: zsignCSettings,
            cxxSettings: zsignCXXSettings,
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "SwiftIPA",
            dependencies: ["ZSignKit", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "SwiftIPA",
            exclude: ["Resources", "Signing/ZSign"]
        ),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
