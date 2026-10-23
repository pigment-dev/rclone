// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PigmentDevRClone",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PigmentDevRClone", targets: ["PigmentDevRClone"]),
        .library(name: "RCloneKit", targets: ["RCloneKit"])
    ],
    targets: [
        .target(name: "RCloneKit", path: "Sources/RCloneKit"),
        .executableTarget(
            name: "PigmentDevRClone",
            dependencies: ["RCloneKit"],
            path: "Sources/PigmentDevRClone",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("AppIntents")
            ]
        ),
        .testTarget(name: "RCloneKitTests", dependencies: ["RCloneKit"], path: "Tests/RCloneKitTests")
    ],
    swiftLanguageModes: [.v5]
)
