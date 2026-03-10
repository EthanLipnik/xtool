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
        "warning: `xtool.yml` key `extensions` is deprecated; use `bundles` with `kind: appExtension` instead."
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

    #expect(schema.deprecationWarnings.isEmpty)
}

@Test func bundlePlacementFollowsBundleKind() {
    let appRoot = URL(fileURLWithPath: "/tmp/MyApp.app", isDirectory: true)

    let app = Plan.Product(
        type: .application,
        product: "MyApp",
        deploymentTarget: "17.0",
        bundleID: "com.example.MyApp",
        infoPlist: [:],
        resources: [],
        iconPath: nil,
        entitlementsPath: nil
    )
    #expect(app.directory(inApp: appRoot).path == appRoot.path)

    let extensionProduct = Plan.Product(
        type: .appExtension,
        product: "WidgetExtension",
        deploymentTarget: "17.0",
        bundleID: "com.example.WidgetExtension",
        infoPlist: [:],
        resources: [],
        iconPath: nil,
        entitlementsPath: nil
    )
    #expect(extensionProduct.directory(inApp: appRoot).path == "/tmp/MyApp.app/PlugIns/WidgetExtension.appex")

    let extensionKitProduct = Plan.Product(
        type: .extensionKitExtension,
        product: "ShareExtension",
        deploymentTarget: "17.0",
        bundleID: "com.example.ShareExtension",
        infoPlist: [:],
        resources: [],
        iconPath: nil,
        entitlementsPath: nil
    )
    #expect(extensionKitProduct.directory(inApp: appRoot).path == "/tmp/MyApp.app/Extensions/ShareExtension.appex")

    let appClip = Plan.Product(
        type: .appClip,
        product: "Clip",
        deploymentTarget: "17.0",
        bundleID: "com.example.Clip",
        infoPlist: [:],
        resources: [],
        iconPath: nil,
        entitlementsPath: nil
    )
    #expect(appClip.directory(inApp: appRoot).path == "/tmp/MyApp.app/AppClips/Clip.app")
}
