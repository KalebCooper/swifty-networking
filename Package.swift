// swift-tools-version:6.2

import PackageDescription

// Four products, one dependency direction: HTTPCore knows nothing about any network stack,
// HTTPURLSession binds it to Apple's, HTTPPortable binds it to SwiftNIO's behind a trait, and
// HTTPTesting ships the test types and fixtures as a real product instead of trapping them in a test
// target.
let package = Package(
  name: "swifty-networking",
  platforms: [
    .iOS(.v26), .macOS(.v26), .tvOS(.v26), .visionOS(.v26), .watchOS(.v26),
  ],
  products: [
    .library(name: "HTTPCore", targets: ["HTTPCore"]),
    .library(name: "HTTPPortable", targets: ["HTTPPortable"]),
    .library(name: "HTTPTesting", targets: ["HTTPTesting"]),
    .library(name: "HTTPURLSession", targets: ["HTTPURLSession"]),
  ],
  traits: [
    // Nothing is on by default, stated at the declaration site rather than left to SwiftPM's implicit
    // empty default: a consumer who wants swift-log or the NIO stack opts in, and everyone else pays
    // for no such thing.
    .default(enabledTraits: []),
    .trait(
      name: "HTTPPortable",
      description: "Ship the AsyncHTTPClient transport and the SwiftNIO stack beneath it."
    ),
    .trait(
      name: "Logging",
      description: "Ship the swift-log adapter for TransportObserver."
    ),
  ],
  dependencies: [
    // The portable transport sends through AsyncHTTPClient, and its tests answer from a SwiftNIO
    // server, so both packages are declared here; every edge into them is guarded by the
    // `HTTPPortable` trait, and SwiftPM resolves neither for a consumer who leaves it off.
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.1"),
    // Default traits are taken as they come: the Darwin transport needs `HTTPTypesFoundation`, which
    // is written against the URL conveniences the `FoundationURL` trait guards and does not compile
    // without them. HTTPCore reads `HTTPRequest.url` from that trait to build the URL its events
    // carry. `URL` lives in FoundationEssentials, so the core stays portable while taking one.
    .package(url: "https://github.com/apple/swift-http-types.git", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.102.0"),
  ],
  targets: [
    .target(
      name: "HTTPCore",
      dependencies: [
        .product(name: "HTTPTypes", package: "swift-http-types"),
        // The two `Logging`s are unrelated: the condition names this package's trait, the product names
        // swift-log's library. Guarding the edge is what keeps swift-log off a default consumer's build.
        .product(
          name: "Logging",
          package: "swift-log",
          condition: .when(traits: ["Logging"])
        ),
      ],
      swiftSettings: swiftSettings
    ),
    // Every file inside is under `#if HTTPPortable`, so with the trait off the target builds to an
    // empty module and none of these edges is followed. `AsyncHTTPClient` sends the request;
    // `NIOCore` is the `ByteBuffer` its bodies are made of and `NIOFoundationCompat` turns one into
    // `Data`; `NIOHTTP1` is the header and method vocabulary its requests are written in; `NIOPosix`
    // names the connection failure the client reports; `_NIOFileSystem` reads a file body from disk
    // as it is sent.
    .target(
      name: "HTTPPortable",
      dependencies: [
        .product(
          name: "AsyncHTTPClient", package: "async-http-client",
          condition: .when(traits: ["HTTPPortable"])),
        "HTTPCore",
        .product(name: "NIOCore", package: "swift-nio", condition: .when(traits: ["HTTPPortable"])),
        .product(
          name: "NIOFoundationCompat", package: "swift-nio",
          condition: .when(traits: ["HTTPPortable"])),
        .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(traits: ["HTTPPortable"])),
        .product(name: "NIOPosix", package: "swift-nio", condition: .when(traits: ["HTTPPortable"])),
        .product(
          name: "_NIOFileSystem", package: "swift-nio", condition: .when(traits: ["HTTPPortable"])),
      ],
      swiftSettings: swiftSettings
    ),
    .target(name: "HTTPTesting", dependencies: ["HTTPCore"], swiftSettings: swiftSettings),
    .target(
      name: "HTTPURLSession",
      dependencies: [
        "HTTPCore", .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
      ],
      swiftSettings: swiftSettings
    ),
    // The swift-log edge is the suite for `LoggingObserver`, which is written against a `Logger` and
    // a `LogHandler` of its own; the file is under `#if Logging` like the observer it exercises, so
    // with the trait off neither the edge nor the suite is there.
    .testTarget(
      name: "HTTPCoreTests",
      dependencies: [
        "HTTPCore", "HTTPTesting",
        .product(name: "Logging", package: "swift-log", condition: .when(traits: ["Logging"])),
      ],
      swiftSettings: swiftSettings
    ),
    // The suite inside is guarded by the trait, matching the transport it exercises; with the trait
    // off the target builds to an empty binary rather than being absent, so every lane reports the
    // same target list. The suite answers requests from a loopback server written on `NIOPosix` and
    // `NIOHTTP1`, reaches for `AsyncHTTPClient` itself for the control leg that proves a client
    // left to its own devices follows a redirect, and names the `_NIOFileSystem` error a missing
    // body file surfaces.
    .testTarget(
      name: "HTTPPortableTests",
      dependencies: [
        .product(
          name: "AsyncHTTPClient", package: "async-http-client",
          condition: .when(traits: ["HTTPPortable"])),
        "HTTPCore", "HTTPPortable", "HTTPTesting",
        .product(name: "NIOCore", package: "swift-nio", condition: .when(traits: ["HTTPPortable"])),
        .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(traits: ["HTTPPortable"])),
        .product(name: "NIOPosix", package: "swift-nio", condition: .when(traits: ["HTTPPortable"])),
        .product(
          name: "_NIOFileSystem", package: "swift-nio", condition: .when(traits: ["HTTPPortable"])),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "HTTPTestingTests", dependencies: ["HTTPCore", "HTTPTesting"], swiftSettings: swiftSettings
    ),
    // The suite inside is Darwin-guarded, matching the transport it exercises; on Linux the target
    // builds to an empty binary rather than being absent, so the lane reports the same target list
    // everywhere.
    .testTarget(
      name: "HTTPURLSessionTests",
      dependencies: ["HTTPCore", "HTTPTesting", "HTTPURLSession"],
      swiftSettings: swiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)

// Library code is nonisolated by default (the inverse of an app target's MainActor default), async
// entry points run on the caller's actor until they truly suspend, and every `unsafe` is spelled out.
var swiftSettings: [SwiftSetting] {
  [
    .defaultIsolation(nil),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .strictMemorySafety(),
  ]
}
