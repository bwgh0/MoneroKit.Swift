// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "MoneroKit.swift",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "MoneroKit",
            targets: ["MoneroKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "6.0.0")),
        .package(url: "https://github.com/horizontalsystems/HdWalletKit.Swift.git", .upToNextMajor(from: "1.2.1")),
        .package(url: "https://github.com/horizontalsystems/HsToolKit.Swift.git", .upToNextMajor(from: "2.0.5")),
    ],
    targets: [
        .target(
            name: "MoneroKit",
            dependencies: [
                "CMonero",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "HdWalletKit", package: "HdWalletKit.Swift"),
                .product(name: "HsToolKit", package: "HsToolKit.Swift"),
            ]

        ),
        .target(
            name: "CMonero",
            dependencies: ["MoneroBinary"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("."),
                .define("BOOST_ERROR_CODE_HEADER_ONLY"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        .binaryTarget(
            name: "MoneroBinary",
            path: "Monero.xcframework"
        ),
    ],
    cxxLanguageStandard: .cxx11
)
