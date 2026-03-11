import Foundation
import XUtils

public struct Packer: Sendable {
    public let buildSettings: BuildSettings
    public let plan: Plan

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.plan = plan
        self.buildSettings = buildSettings
    }

    private func build() async throws {
        let xtoolDir = URL(fileURLWithPath: "xtool")
        let packageDir = xtoolDir.appendingPathComponent(".xtool-tmp")
        try? FileManager.default.removeItem(at: packageDir)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        let packageSwift = packageDir.appendingPathComponent("Package.swift")
        let contents = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(plan.app.product)-Builder",
            platforms: [
                \(buildSettings.destination.packageDescriptionSnippet)("\(plan.app.deploymentTarget)"),
            ],
            dependencies: [
                .package(name: "RootPackage", path: "../.."),
            ],
            targets: [
                \(
                    plan.allProducts.map { product in
                        """
                        .executableTarget(
                            name: "\(product.targetName)",
                            dependencies: [
                                .product(name: "\(product.product)", package: "RootPackage"),
                            ],
                            linkerSettings: \(product.linkerSettings)
                        )
                        """
                    }
                    .joined(separator: ",\n")
                )
            ]
        )\n
        """
        try Data(contents.utf8).write(to: packageSwift)

        for product in plan.allProducts {
            let sources = packageDir.appendingPathComponent("Sources/\(product.targetName)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

            if let bootstrap = try product.bootstrapSource(for: plan.destination) {
                try Data(bootstrap.contents.utf8).write(to: sources.appendingPathComponent(bootstrap.filename))
            } else {
                try Data().write(to: sources.appendingPathComponent("stub.c", isDirectory: false))
            }
        }

        let builder = try await buildSettings.swiftPMInvocation(
            forTool: "build",
            arguments: [
                "--package-path", packageDir.path,
                "--scratch-path", ".build",
                "--disable-automatic-resolution",
            ]
        )
        builder.standardOutput = FileHandle.standardError
        try await builder.runUntilExit()
    }

    public func pack() async throws -> URL {
        if plan.destination.platformFamily == .macOS,
            plan.allProducts.contains(where: { $0.type == .appClip }) {
            throw StringError("App Clips are not supported for macOS destinations")
        }

        try await build()

        let output = try TemporaryDirectory(name: "\(plan.app.product).app")
        let outputURL = output.url

        let binDir = URL(
            fileURLWithPath: ".build/\(buildSettings.triple)/\(buildSettings.configuration.rawValue)",
            isDirectory: true
        )
        let triple = try AppleTriple(buildSettings.triple)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for product in plan.allProducts {
                let bundleURL = product.directory(inApp: outputURL, destination: plan.destination)
                let layout = BundleLayout(bundleURL: bundleURL, destination: plan.destination)
                try pack(
                    product: product,
                    triple: triple,
                    binDir: binDir,
                    layout: layout,
                    &group
                )
            }

            while !group.isEmpty {
                do {
                    try await group.next()
                } catch is CancellationError {
                    continue
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }

        let dest = URL(fileURLWithPath: "xtool").appendingPathComponent(outputURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try output.persist(at: dest)
        return dest
    }

    @Sendable private func pack(
        product: Plan.Product,
        triple: AppleTriple,
        binDir: URL,
        layout: BundleLayout,
        _ group: inout ThrowingTaskGroup<Void, Error>
    ) throws {
        try layout.prepare()

        @Sendable func copyFile(at srcURL: URL, to destURL: URL) async throws {
            try? FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: srcURL, to: destURL)
            try Task.checkCancellation()
        }

        @Sendable func packBuiltFile(srcName: String, destinationURL: URL) async throws {
            let srcURL = URL(fileURLWithPath: srcName, relativeTo: binDir)
            try await copyFile(at: srcURL, to: destinationURL)
        }

        for resource in product.resources {
            group.addTask {
                switch resource {
                case .bundle(let package, let target):
                    let name = "\(package)_\(target).bundle"
                    try await packBuiltFile(
                        srcName: name,
                        destinationURL: layout.resourcesRoot.appendingPathComponent(name)
                    )
                case .binaryTarget(_, let path):
                    guard let artifact = try BinaryArtifactResolver(
                        destination: plan.destination,
                        triple: triple
                    ).resolve(path: path) else {
                        break
                    }
                    try await copyFile(
                        at: artifact,
                        to: layout.frameworksRoot.appendingPathComponent(artifact.lastPathComponent)
                    )
                case .library(let name):
                    try await packBuiltFile(
                        srcName: "lib\(name).dylib",
                        destinationURL: layout.frameworksRoot.appendingPathComponent("lib\(name).dylib")
                    )
                case .root(let source):
                    let srcURL = URL(fileURLWithPath: source)
                    try await copyFile(
                        at: srcURL,
                        to: layout.resourcesRoot.appendingPathComponent(srcURL.lastPathComponent)
                    )
                }
            }
        }

        if let iconPath = product.iconPath {
            group.addTask {
                let srcURL = URL(fileURLWithPath: iconPath)
                try await copyFile(
                    at: srcURL,
                    to: layout.resourcesRoot.appendingPathComponent(srcURL.lastPathComponent)
                )
            }
        }

        group.addTask {
            try await packBuiltFile(
                srcName: product.targetName,
                destinationURL: layout.executableURL(named: product.product)
            )
        }

        group.addTask {
            var info = product.infoPlist

            if product.type.isApplicationBundle {
                if let requiredDeviceCapabilities = triple.requiredDeviceCapabilities {
                    info["UIRequiredDeviceCapabilities"] = requiredDeviceCapabilities
                } else {
                    info.removeValue(forKey: "UIRequiredDeviceCapabilities")
                }

                if plan.destination.platformFamily == .iOS {
                    info["LSRequiresIPhoneOS"] = true
                } else {
                    info.removeValue(forKey: "LSRequiresIPhoneOS")
                }

                info["CFBundleSupportedPlatforms"] = [plan.destination.bundleSupportedPlatform]
            }

            if let iconPath = product.iconPath {
                let iconName = URL(fileURLWithPath: iconPath).deletingPathExtension().lastPathComponent
                info["CFBundleIconFile"] = iconName
            }

            if plan.destination.platformFamily == .macOS {
                info.removeValue(forKey: "MinimumOSVersion")
            } else {
                info.removeValue(forKey: "LSMinimumSystemVersion")
            }

            let encodedPlist = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try encodedPlist.write(to: layout.infoPlistURL)
        }
    }
}

private struct BundleLayout {
    let bundleURL: URL
    let destination: AppleDestination

    var infoPlistURL: URL {
        if destination.platformFamily == .macOS {
            bundleURL.appendingPathComponent("Contents/Info.plist")
        } else {
            bundleURL.appendingPathComponent("Info.plist")
        }
    }

    var resourcesRoot: URL {
        if destination.platformFamily == .macOS {
            bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        } else {
            bundleURL
        }
    }

    var frameworksRoot: URL {
        if destination.platformFamily == .macOS {
            bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        } else {
            bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        }
    }

    var executableRoot: URL {
        if destination.platformFamily == .macOS {
            bundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        } else {
            bundleURL
        }
    }

    func executableURL(named name: String) -> URL {
        executableRoot.appendingPathComponent(name)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frameworksRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executableRoot, withIntermediateDirectories: true)
    }
}

private struct BootstrapSource {
    let filename: String
    let contents: String
}

private struct BinaryArtifactResolver {
    let destination: AppleDestination
    let triple: AppleTriple

    func resolve(path: String) throws -> URL? {
        let url = URL(fileURLWithPath: path)
        return try resolve(url: url)
    }

    private func resolve(url: URL) throws -> URL? {
        switch url.pathExtension.lowercased() {
        case "xcframework":
            return try resolveXCFramework(at: url)
        case "framework":
            return url
        case "dylib":
            return url
        case "a":
            return nil
        default:
            if url.hasDirectoryPath && url.lastPathComponent.hasSuffix(".framework") {
                return url
            }
            return url.pathExtension.isEmpty ? nil : url
        }
    }

    private func resolveXCFramework(at url: URL) throws -> URL? {
        let plistURL = url.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dict = plist as? [String: Any],
            let libraries = dict["AvailableLibraries"] as? [[String: Any]]
        else {
            throw StringError("Invalid xcframework metadata at '\(url.path)'")
        }

        let supportedPlatforms = destination.xcframeworkSupportedPlatformNames

        for library in libraries {
            guard let platform = (library["SupportedPlatform"] as? String)?.lowercased(),
                supportedPlatforms.contains(platform)
            else {
                continue
            }

            let variant = (library["SupportedPlatformVariant"] as? String)?.lowercased()
            if destination.isSimulator {
                guard variant == "simulator" else { continue }
            } else if variant == "simulator" {
                continue
            }

            if let architectures = library["SupportedArchitectures"] as? [String],
                !architectures.contains(triple.architecture) {
                continue
            }

            guard let libraryIdentifier = library["LibraryIdentifier"] as? String,
                let libraryPath = (library["LibraryPath"] as? String) ?? (library["BinaryPath"] as? String)
            else {
                continue
            }

            return try resolve(url: url
                .appendingPathComponent(libraryIdentifier, isDirectory: true)
                .appendingPathComponent(libraryPath))
        }

        return nil
    }
}

extension Plan.Product {
    fileprivate var linkerSettings: String {
        switch self.type {
        case .application, .appClip: """
        [
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),
        ]
        """
        case .appExtension, .extensionKitExtension: """
        [
            .linkedFramework("Foundation"),
            .unsafeFlags([
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),
        ]
        """
        }
    }

    fileprivate func bootstrapSource(for destination: AppleDestination) throws -> BootstrapSource? {
        guard let entryPoint else { return nil }

        switch entryPoint.kind {
        case .swiftUI:
            return nil
        case .uiKit:
            guard [.iOS, .tvOS, .visionOS].contains(destination.platformFamily) else {
                throw StringError("UIKit bootstrapping requires an iOS-family destination")
            }
            guard let symbol = entryPoint.symbol, !symbol.isEmpty else {
                throw StringError("UIKit entry points require a delegate symbol")
            }
            return BootstrapSource(
                filename: "main.swift",
                contents: """
                import UIKit
                import \(moduleName)

                @main
                struct \(targetName.replacingOccurrences(of: "-", with: "_"))Bootstrap {
                    static func main() {
                        UIApplicationMain(
                            CommandLine.argc,
                            CommandLine.unsafeArgv,
                            nil,
                            NSStringFromClass(\(symbol).self)
                        )
                    }
                }
                """
            )
        case .appKit:
            guard destination.platformFamily == .macOS else {
                throw StringError("AppKit bootstrapping requires a macOS destination")
            }
            guard let symbol = entryPoint.symbol, !symbol.isEmpty else {
                throw StringError("AppKit entry points require a delegate symbol")
            }
            return BootstrapSource(
                filename: "main.swift",
                contents: """
                import AppKit
                import \(moduleName)

                @main
                struct \(targetName.replacingOccurrences(of: "-", with: "_"))Bootstrap {
                    static func main() {
                        let application = NSApplication.shared
                        application.delegate = \(symbol)()
                        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
                    }
                }
                """
            )
        }
    }
}

private extension AppleDestination {
    var xcframeworkSupportedPlatformNames: Set<String> {
        switch platformFamily {
        case .iOS:
            ["ios"]
        case .macOS:
            ["macos"]
        case .tvOS:
            ["tvos"]
        case .watchOS:
            ["watchos"]
        case .visionOS:
            ["xros", "visionos"]
        }
    }
}

private extension Plan.ProductType {
    var isApplicationBundle: Bool {
        switch self {
        case .application, .appClip:
            true
        case .appExtension, .extensionKitExtension:
            false
        }
    }
}
