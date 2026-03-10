import ArgumentParser
import Foundation
import PackLib

private enum BundleScaffolder {
    static func scaffold(
        kind: PackSchema.BundleKind,
        name explicitName: String?
    ) async throws {
        let productName = try await Console.promptRequired("Product name: ", existing: explicitName)
        let targetName = productName.replacingOccurrences(of: "-", with: "_")
        let infoFileName = "\(productName)-Info.plist"

        try updatePackage(productName: productName, targetName: targetName)
        try updateSchema(kind: kind, productName: productName, infoFileName: infoFileName)
        try createSources(kind: kind, productName: productName, targetName: targetName, infoFileName: infoFileName)

        print("Scaffolded \(kind.displayName) '\(productName)'.")
    }

    private static func updatePackage(productName: String, targetName: String) throws {
        let packageURL = URL(fileURLWithPath: "Package.swift")
        var contents = try String(contentsOf: packageURL, encoding: .utf8)

        let productSnippet = """
                .library(
                    name: "\(productName)",
                    targets: ["\(targetName)"]
                ),
        """
        let targetSnippet = """
                .target(
                    name: "\(targetName)"
                ),
        """

        guard let productsRange = contents.range(of: "products: [") else {
            throw Console.Error("Could not locate the products array in Package.swift")
        }
        contents.insert(contentsOf: "\n\(productSnippet)", at: productsRange.upperBound)

        guard let targetsRange = contents.range(of: "targets: [") else {
            throw Console.Error("Could not locate the targets array in Package.swift")
        }
        contents.insert(contentsOf: "\n\(targetSnippet)", at: targetsRange.upperBound)

        try contents.write(to: packageURL, atomically: true, encoding: String.Encoding.utf8)
    }

    private static func updateSchema(
        kind: PackSchema.BundleKind,
        productName: String,
        infoFileName: String
    ) throws {
        let schemaURL = URL(fileURLWithPath: "xtool.yml")
        var contents = try String(contentsOf: schemaURL, encoding: .utf8)

        let bundleSnippet = """
          - kind: \(kind.rawValue)
            product: \(productName)
            infoPath: \(infoFileName)
        """

        if let bundlesRange = contents.range(of: "\nbundles:\n") {
            contents.insert(contentsOf: "\(bundleSnippet)\n", at: bundlesRange.upperBound)
        } else {
            if !contents.hasSuffix("\n") {
                contents.append("\n")
            }
            contents.append("""
            
            bundles:
            \(bundleSnippet)
            """)
            contents.append("\n")
        }

        try contents.write(to: schemaURL, atomically: true, encoding: String.Encoding.utf8)
    }

    private static func createSources(
        kind: PackSchema.BundleKind,
        productName: String,
        targetName: String,
        infoFileName: String
    ) throws {
        let sourcesDirectory = URL(fileURLWithPath: "Sources").appendingPathComponent(targetName, isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)

        let sourceURL = sourcesDirectory.appendingPathComponent(sourceFileName(for: kind, targetName: targetName))
        let sourceContents = sourceTemplate(for: kind, targetName: targetName)
        try sourceContents.write(to: sourceURL, atomically: true, encoding: String.Encoding.utf8)

        let infoURL = URL(fileURLWithPath: infoFileName)
        try infoTemplate(for: kind, productName: productName).write(
            to: infoURL,
            atomically: true,
            encoding: String.Encoding.utf8
        )
    }

    private static func sourceFileName(for kind: PackSchema.BundleKind, targetName: String) -> String {
        switch kind {
        case .appClip:
            "\(targetName)App.swift"
        case .appExtension, .extensionKitExtension:
            "\(targetName).swift"
        }
    }

    private static func sourceTemplate(for kind: PackSchema.BundleKind, targetName: String) -> String {
        switch kind {
        case .appClip:
            """
            import SwiftUI

            @main
            struct \(targetName)App: App {
                var body: some Scene {
                    WindowGroup {
                        Text("\(targetName)")
                    }
                }
            }
            """
        case .appExtension, .extensionKitExtension:
            """
            import Foundation

            // Add the extension entry point for \(targetName) here.
            """
        }
    }

    private static func infoTemplate(for kind: PackSchema.BundleKind, productName: String) -> String {
        switch kind {
        case .appExtension:
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>NSExtension</key>
                <dict>
                    <key>NSExtensionPointIdentifier</key>
                    <string>com.apple.widgetkit-extension</string>
                </dict>
            </dict>
            </plist>
            """
        case .extensionKitExtension:
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>EXAppExtensionAttributes</key>
                <dict>
                    <key>EXExtensionPointIdentifier</key>
                    <string>com.apple.widgetkit-extension</string>
                </dict>
            </dict>
            </plist>
            """
        case .appClip:
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleDisplayName</key>
                <string>\(productName)</string>
            </dict>
            </plist>
            """
        }
    }
}

private extension PackSchema.BundleKind {
    var displayName: String {
        switch self {
        case .appExtension:
            "app extension"
        case .extensionKitExtension:
            "ExtensionKit extension"
        case .appClip:
            "App Clip"
        }
    }
}

struct DevAddExtensionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-extension",
        abstract: "Add a new embedded extension target to the current xtool project"
    )

    @Argument var name: String?

    @Flag(
        name: .long,
        help: "Generate an ExtensionKit extension instead of a legacy Foundation extension"
    ) var extensionKit = false

    func run() async throws {
        try await BundleScaffolder.scaffold(
            kind: extensionKit ? .extensionKitExtension : .appExtension,
            name: name
        )
    }
}

struct DevAddAppClipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-app-clip",
        abstract: "Add a new App Clip target to the current xtool project"
    )

    @Argument var name: String?

    func run() async throws {
        try await BundleScaffolder.scaffold(kind: .appClip, name: name)
    }
}
