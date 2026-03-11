import Foundation
import Testing
@testable import PackLib

@Test func appleTripleDifferentiatesDeviceAndSimulator() throws {
    let device = try AppleTriple("arm64-apple-ios")
    #expect(!device.isSimulator)
    #expect(device.platformName == "ios")
    #expect(device.bundleSupportedPlatform == "iPhoneOS")
    #expect(device.requiredDeviceCapabilities == ["arm64"])

    let simulator = try AppleTriple("arm64-apple-ios-simulator")
    #expect(simulator.isSimulator)
    #expect(simulator.bundleSupportedPlatform == "iPhoneSimulator")
    #expect(simulator.requiredDeviceCapabilities == nil)
}

@Test func destinationsCoverWatchAndVisionDefaults() throws {
    #expect(AppleDestination.watchOS.defaultTriple() == "arm64_32-apple-watchos")
    #expect(try AppleDestination(triple: "x86_64-apple-xros-simulator") == .visionOSSimulator)
    #expect(AppleDestination.visionOS.bundleSupportedPlatform == "XROS")
}

@Test func legacyExtensionsBridgeIntoBundles() throws {
    let schema = try PackSchema(validating: .init(
        version: .v1,
        orgID: "com.example",
        extensions: [
            .init(
                product: "WidgetExtension",
                bundleID: "com.example.widget",
                infoPath: "Widget-Info.plist",
                resources: ["Resources/Widget.strings"],
                entitlementsPath: "Widget.entitlements"
            )
        ]
    ))

    #expect(schema.bundleDeclarations.count == 1)
    let bundle = try #require(schema.bundleDeclarations.first)
    #expect(bundle.kind == .appExtension)
    #expect(bundle.product == "WidgetExtension")
    #expect(bundle.bundleID == "com.example.widget")
    #expect(bundle.infoPath == "Widget-Info.plist")
    #expect(bundle.resources == ["Resources/Widget.strings"])
    #expect(bundle.entitlementsPath == "Widget.entitlements")
    #expect(schema.deprecationWarnings == [
        "warning: `xtool.yml` key `extensions` is deprecated; use `products` or `bundles` instead.",
        "warning: `xtool.yml` schema version 1 is deprecated; prefer schema version 2 with explicit `products`.",
    ])
}

@Test func bundlesKeyIsNotDeprecated() throws {
    let schema = try PackSchema(validating: .init(
        version: .v1,
        orgID: "com.example",
        bundles: [
            .init(
                kind: .appExtension,
                product: "WidgetExtension",
                bundleID: nil,
                infoPath: "Widget-Info.plist",
                resources: nil,
                entitlementsPath: nil
            )
        ]
    ))

    #expect(schema.deprecationWarnings == [
        "warning: `xtool.yml` schema version 1 is deprecated; prefer schema version 2 with explicit `products`.",
    ])
}

@Test func schemaV2SupportsExplicitProducts() throws {
    let schema = try PackSchema(validating: .init(
        version: .v2,
        orgID: "com.example",
        products: [
            .init(
                kind: .application,
                packageProduct: "MyApp",
                bundleID: nil,
                infoPath: nil,
                entitlementsPath: nil,
                iconPath: nil,
                resources: ["Resources/App.xcassets"],
                platforms: [.iOS, .macOS],
                entryPoint: .init(kind: .appKit, symbol: "AppDelegate"),
                signing: .init(mode: .none)
            ),
            .init(
                kind: .appExtension,
                packageProduct: "WidgetExtension",
                bundleID: "com.example.widget",
                infoPath: "Widget-Info.plist",
                entitlementsPath: "Widget.entitlements",
                iconPath: nil,
                resources: ["Resources/Widget.strings"],
                platforms: [.iOS],
                entryPoint: nil,
                signing: .init(mode: .developer)
            ),
        ]
    ))

    #expect(schema.deprecationWarnings.isEmpty)
    #expect(schema.productDeclarations.count == 2)
    let app = try #require(schema.productDeclarations.first)
    #expect(app.packageProduct == "MyApp")
    #expect(app.platforms == [.iOS, .macOS])
    #expect(app.entryPoint == .init(kind: .appKit, symbol: "AppDelegate"))
    #expect(app.signing?.mode == PackSchema.SigningMode.none)
    #expect(try schema.appDeclaration.packageProduct == "MyApp")
}

@Test func bundlePlacementFollowsBundleKind() {
    let appRoot = URL(fileURLWithPath: "/tmp/MyApp.app", isDirectory: true)
    let destination = AppleDestination.iOS

    let app = Plan.Product(
        type: .application,
        product: "MyApp",
        moduleName: "MyApp",
        deploymentTarget: "17.0",
        bundleID: "com.example.MyApp",
        infoPlist: [:],
        resources: [],
        iconPath: nil,
        entitlementsPath: nil,
        entryPoint: nil,
        signingMode: .adhoc
    )
    #expect(app.directory(inApp: appRoot, destination: destination).path == appRoot.path)

    let extensionProduct = Plan.Product(
        type: .appExtension,
        product: "WidgetExtension",
        moduleName: "WidgetExtension",
        deploymentTarget: "17.0",
        bundleID: "com.example.WidgetExtension",
        infoPlist: [:],
        resources: [],
        iconPath: nil,
        entitlementsPath: nil,
        entryPoint: nil,
        signingMode: .adhoc
    )
    #expect(
        extensionProduct.directory(inApp: appRoot, destination: destination).path == "/tmp/MyApp.app/PlugIns/WidgetExtension.appex"
    )

    let extensionKitProduct = Plan.Product(
        type: .extensionKitExtension,
        product: "ShareExtension",
        moduleName: "ShareExtension",
        deploymentTarget: "17.0",
        bundleID: "com.example.ShareExtension",
        infoPlist: [:],
        resources: [],
        iconPath: nil,
        entitlementsPath: nil,
        entryPoint: nil,
        signingMode: .adhoc
    )
    #expect(
        extensionKitProduct.directory(inApp: appRoot, destination: destination).path == "/tmp/MyApp.app/Extensions/ShareExtension.appex"
    )

    let appClip = Plan.Product(
        type: .appClip,
        product: "Clip",
        moduleName: "Clip",
        deploymentTarget: "17.0",
        bundleID: "com.example.Clip",
        infoPlist: [:],
        resources: [],
        iconPath: nil,
        entitlementsPath: nil,
        entryPoint: nil,
        signingMode: .adhoc
    )
    #expect(appClip.directory(inApp: appRoot, destination: destination).path == "/tmp/MyApp.app/AppClips/Clip.app")
}
