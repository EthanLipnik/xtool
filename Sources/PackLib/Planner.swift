import Foundation
import XUtils

public struct Planner: Sendable {
    public var buildSettings: BuildSettings
    public var schema: PackSchema

    public init(
        buildSettings: BuildSettings,
        schema: PackSchema
    ) {
        self.buildSettings = buildSettings
        self.schema = schema
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func buildGraph() async throws -> PackageGraph {
        let dependencyRoot = try await dumpDependencies()

        let packages = try await withThrowingTaskGroup(
            of: (PackageDependency, PackageDump).self,
            returning: [String: PackageDump].self
        ) { group in
            var visited: Set<String> = []
            var dependencies: [PackageDependency] = [dependencyRoot]
            while let dependencyNode = dependencies.popLast() {
                guard visited.insert(dependencyNode.identity).inserted else { continue }
                dependencies.append(contentsOf: dependencyNode.dependencies)
                group.addTask { (dependencyNode, try await dumpPackage(at: dependencyNode.path)) }
            }

            var packages: [String: PackageDump] = [:]
            while let result = await group.nextResult() {
                switch result {
                case .success((let dependency, let dump)):
                    packages[dependency.identity] = dump
                case .failure(_ as CancellationError):
                    break
                case .failure(let error):
                    group.cancelAll()
                    throw error
                }
            }

            return packages
        }

        var packagesByProductName: [String: String] = [:]
        for (packageID, package) in packages {
            for product in package.products ?? [] {
                packagesByProductName[product.name] = packageID
            }
        }

        guard let rootPackage = packages[dependencyRoot.identity] else {
            throw StringError("Could not resolve root package metadata")
        }

        return PackageGraph(
            root: rootPackage,
            packages: packages,
            packagesByProductName: packagesByProductName
        )
    }

    public func createPlan() async throws -> Plan {
        let graph = try await buildGraph()

        let appDeclaration = try schema.appDeclaration
        let app = try await product(
            from: graph,
            declaration: appDeclaration,
            defaultIDSpecifier: schema.idSpecifier,
            appBundleID: nil
        )

        let bundleProducts = try await withThrowingTaskGroup(of: Plan.Product.self) { group in
            for declaration in schema.productDeclarations where declaration.kind != .application {
                group.addTask {
                    try await product(
                        from: graph,
                        declaration: declaration,
                        defaultIDSpecifier: schema.idSpecifier ?? .orgID(app.bundleID),
                        appBundleID: app.bundleID
                    )
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        return Plan(
            destination: buildSettings.destination,
            app: app,
            bundles: bundleProducts
        )
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    private func product(
        from graph: PackageGraph,
        declaration: PackSchema.ProductDeclaration,
        defaultIDSpecifier: PackSchema.IDSpecifier?,
        appBundleID: String?
    ) async throws -> Plan.Product {
        let library = try selectLibrary(
            from: graph.root.products?.filter(\.type.isLibrary) ?? [],
            matching: declaration.packageProduct
        )

        if let supportedPlatforms = declaration.platforms, !supportedPlatforms.isEmpty {
            guard supportedPlatforms.contains(buildSettings.destination.platformFamily) else {
                throw StringError("""
                Product '\(library.name)' does not support destination '\(buildSettings.destination.rawValue)'.
                """)
            }
        }

        var resources: [Plan.Resource] = []
        var visited: Set<String> = []
        var targets = library.targets.map { (graph.root, $0) }
        while let (targetPackage, targetName) = targets.popLast() {
            let visitKey = "\(targetPackage.name)::\(targetName)"
            guard visited.insert(visitKey).inserted else { continue }
            guard let target = targetPackage.targets?.first(where: { $0.name == targetName }) else {
                throw StringError("Could not find target '\(targetName)' in package '\(targetPackage.name)'")
            }

            if target.moduleType == "BinaryTarget" {
                resources.append(.binaryTarget(
                    name: targetName,
                    path: target.path ?? targetName
                ))
            }
            if target.resources?.isEmpty == false {
                resources.append(.bundle(package: targetPackage.name, target: targetName))
            }
            for targetName in target.targetDependencies ?? [] {
                targets.append((targetPackage, targetName))
            }
            for productName in target.productDependencies ?? [] {
                guard let (package, product) = graph.productIfPresent(name: productName) else {
                    continue
                }
                if product.type == .dynamicLibrary {
                    resources.append(.library(name: productName))
                }
                targets.append(contentsOf: product.targets.map { (package, $0) })
            }
        }

        if let rootResources = declaration.resources {
            resources += rootResources.map { .root(source: $0) }
        }

        let idSpecifier = declaration.bundleID.map(PackSchema.IDSpecifier.bundleID)
            ?? defaultIDSpecifier
            ?? appBundleID.map(PackSchema.IDSpecifier.orgID)
        guard let idSpecifier else {
            throw StringError("Could not resolve bundle ID for '\(library.name)'")
        }

        let deploymentTarget = graph.deploymentTarget(for: buildSettings.destination.platformFamily)
            ?? buildSettings.destination.platformFamily.defaultDeploymentTarget
        let bundleID = idSpecifier.formBundleID(product: library.name)
        let moduleName = library.targets.first ?? library.name
        var infoPlist: [String: Sendable] = [
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleIdentifier": bundleID,
            "CFBundleName": library.name,
            "CFBundleExecutable": library.name,
            "CFBundleDisplayName": library.name,
            "CFBundlePackageType": declaration.kind.planProductType.fourCharCode,
        ]

        switch buildSettings.destination.platformFamily {
        case .macOS:
            infoPlist["LSMinimumSystemVersion"] = deploymentTarget
        case .iOS, .tvOS, .watchOS, .visionOS:
            infoPlist["MinimumOSVersion"] = deploymentTarget
        }

        switch declaration.kind {
        case .application, .appClip:
            if let families = buildSettings.destination.platformFamily.defaultDeviceFamilies {
                infoPlist["UIDeviceFamily"] = families
            }
            if buildSettings.destination.platformFamily == .iOS {
                infoPlist["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait"]
                infoPlist["UISupportedInterfaceOrientations~ipad"] = [
                    "UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationPortraitUpsideDown",
                    "UIInterfaceOrientationLandscapeLeft",
                    "UIInterfaceOrientationLandscapeRight",
                ]
                infoPlist["UILaunchScreen"] = [:] as [String: Sendable]
            }
        case .appExtension:
            infoPlist["NSExtension"] = [:] as [String: Sendable]
        case .extensionKitExtension:
            infoPlist["EXAppExtensionAttributes"] = [:] as [String: Sendable]
        }

        if let plist = declaration.infoPath {
            let data = try await Data(reading: URL(fileURLWithPath: plist))
            let info = try PropertyListSerialization.propertyList(from: data, format: nil)
            if let info = info as? [String: Sendable] {
                infoPlist.merge(info, uniquingKeysWith: { $1 })
            } else {
                throw StringError("Info.plist has invalid format: expected a dictionary.")
            }
        }

        return Plan.Product(
            type: declaration.kind.planProductType,
            product: library.name,
            moduleName: moduleName,
            deploymentTarget: deploymentTarget,
            bundleID: bundleID,
            infoPlist: infoPlist,
            resources: resources,
            iconPath: declaration.iconPath,
            entitlementsPath: declaration.entitlementsPath,
            entryPoint: declaration.effectiveEntryPoint,
            signingMode: declaration.effectiveSigningMode
        )
    }
    // swiftlint:enable cyclomatic_complexity function_body_length

    private func dumpDependencies() async throws -> PackageDependency {
        let tempDir = try TemporaryDirectory(name: "xtool-dump")
        let tempFileURL = tempDir.url.appendingPathComponent("dump.json")

        _ = try await dumpAction(
            arguments: ["-q", "show-dependencies", "--format", "json", "-o", tempFileURL.path],
            path: buildSettings.packagePath
        )

        return try Self.decoder.decode(
            PackageDependency.self,
            from: Data(contentsOf: tempFileURL)
        )
    }

    private func dumpPackage(at path: String) async throws -> PackageDump {
        let data = try await dumpAction(arguments: ["-q", "describe", "--type", "json"], path: path)
        try Task.checkCancellation()

        let fromBrace = data.drop(while: { $0 != Character("{").asciiValue })
        return try Self.decoder.decode(PackageDump.self, from: fromBrace)
    }

    private func dumpAction(arguments: [String], path: String) async throws -> Data {
        let dump = try await buildSettings.swiftPMInvocation(
            forTool: "package",
            arguments: arguments,
            packagePathOverride: path
        )
        let pipe = Pipe()
        dump.standardOutput = pipe
        async let task = Data(reading: pipe.fileHandleForReading)
        try await dump.runUntilExit()
        return try await task
    }

    private func selectLibrary(
        from products: [PackageDump.Product],
        matching name: String?
    ) throws -> PackageDump.Product {
        switch products.count {
        case 0:
            throw StringError("No library products were found in the package")
        case 1:
            let product = products[0]
            if let name, product.name != name {
                throw StringError("""
                Product name ('\(product.name)') does not match the schema value ('\(name)')
                """)
            }
            return product
        default:
            guard let name else {
                throw StringError("""
                Multiple library products were found (\(products.map(\.name))). Please specify the product via \
                `products[].packageProduct` in schema version 2 or `product` in schema version 1.
                """)
            }
            guard let product = products.first(where: { $0.name == name }) else {
                throw StringError("""
                Schema declares a product name of '\(name)' but no matching product was found.
                Found: \(products.map(\.name)).
                """)
            }
            return product
        }
    }
}

public struct Plan: Sendable {
    public var destination: AppleDestination
    public var app: Product
    public var bundles: [Product]

    public var allProducts: [Product] {
        [app] + bundles
    }

    public enum Resource: Codable, Sendable, Hashable {
        case bundle(package: String, target: String)
        case binaryTarget(name: String, path: String)
        case library(name: String)
        case root(source: String)
    }

    public struct Product: Sendable {
        public var type: ProductType
        public var product: String
        public var moduleName: String
        public var deploymentTarget: String
        public var bundleID: String
        public var infoPlist: [String: any Sendable]
        public var resources: [Resource]
        public var iconPath: String?
        public var entitlementsPath: String?
        public var entryPoint: PackSchema.ProductEntryPoint?
        public var signingMode: PackSchema.SigningMode

        public var targetName: String {
            "\(self.product)-\(self.type.targetSuffix)"
        }

        public func directory(inApp baseDir: URL, destination: AppleDestination) -> URL {
            switch type {
            case .application:
                baseDir
            case .appExtension:
                if destination.platformFamily == .macOS {
                    baseDir
                        .appendingPathComponent("Contents", isDirectory: true)
                        .appendingPathComponent("PlugIns", isDirectory: true)
                        .appendingPathComponent(product, isDirectory: true)
                        .appendingPathExtension("appex")
                } else {
                    baseDir
                        .appendingPathComponent("PlugIns", isDirectory: true)
                        .appendingPathComponent(product, isDirectory: true)
                        .appendingPathExtension("appex")
                }
            case .extensionKitExtension:
                if destination.platformFamily == .macOS {
                    baseDir
                        .appendingPathComponent("Contents", isDirectory: true)
                        .appendingPathComponent("Extensions", isDirectory: true)
                        .appendingPathComponent(product, isDirectory: true)
                        .appendingPathExtension("appex")
                } else {
                    baseDir
                        .appendingPathComponent("Extensions", isDirectory: true)
                        .appendingPathComponent(product, isDirectory: true)
                        .appendingPathExtension("appex")
                }
            case .appClip:
                if destination.platformFamily == .macOS {
                    baseDir
                        .appendingPathComponent("Contents", isDirectory: true)
                        .appendingPathComponent("AppClips", isDirectory: true)
                        .appendingPathComponent(product, isDirectory: true)
                        .appendingPathExtension("app")
                } else {
                    baseDir
                        .appendingPathComponent("AppClips", isDirectory: true)
                        .appendingPathComponent(product, isDirectory: true)
                        .appendingPathExtension("app")
                }
            }
        }
    }

    public enum ProductType: Sendable {
        case application
        case appExtension
        case extensionKitExtension
        case appClip

        fileprivate var targetSuffix: String {
            switch self {
            case .application: "App"
            case .appExtension: "Extension"
            case .extensionKitExtension: "ExtensionKitExtension"
            case .appClip: "AppClip"
            }
        }

        fileprivate var fourCharCode: String {
            switch self {
            case .application: "APPL"
            case .appExtension, .extensionKitExtension: "XPC!"
            case .appClip: "APPL"
            }
        }
    }
}

private extension PackSchema.ProductKind {
    var planProductType: Plan.ProductType {
        switch self {
        case .application:
            .application
        case .appExtension:
            .appExtension
        case .extensionKitExtension:
            .extensionKitExtension
        case .appClip:
            .appClip
        }
    }
}

private struct PackageDependency: Decodable {
    let identity: String
    let name: String
    let path: String
    let dependencies: [PackageDependency]
}

private struct PackageDump: Decodable {
    enum ProductType: Decodable {
        case executable
        case dynamicLibrary
        case staticLibrary
        case autoLibrary
        case other

        private enum CodingKeys: String, CodingKey {
            case executable
            case library
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.executable) {
                self = .executable
            } else if let library = try container.decodeIfPresent([String].self, forKey: .library) {
                if library.count == 1 {
                    switch library[0] {
                    case "dynamic":
                        self = .dynamicLibrary
                    case "static":
                        self = .staticLibrary
                    case "automatic":
                        self = .autoLibrary
                    default:
                        self = .other
                    }
                } else {
                    self = .other
                }
            } else {
                self = .other
            }
        }

        var isLibrary: Bool {
            switch self {
            case .dynamicLibrary, .staticLibrary, .autoLibrary:
                true
            case .executable, .other:
                false
            }
        }
    }

    struct Product: Decodable {
        let name: String
        let targets: [String]
        let type: ProductType
    }

    struct Target: Decodable {
        let name: String
        let path: String?
        let moduleType: String
        let productDependencies: [String]?
        let targetDependencies: [String]?
        let resources: [Resource]?
    }

    struct Resource: Decodable {
        let path: String
    }

    struct Platform: Decodable {
        let name: String
        let version: String
    }

    let name: String
    let products: [Product]?
    let targets: [Target]?
    let platforms: [Platform]?
}

private struct PackageGraph {
    let root: PackageDump
    let packages: [String: PackageDump]
    let packagesByProductName: [String: String]

    func deploymentTarget(for family: ApplePlatformFamily) -> String? {
        root.platforms?.first(where: { family.packageManifestNames.contains($0.name.lowercased()) })?.version
    }

    func productIfPresent(name productName: String) -> (PackageDump, PackageDump.Product)? {
        guard let packageID = packagesByProductName[productName],
            let package = packages[packageID],
            let product = package.products?.first(where: { $0.name == productName })
        else {
            return nil
        }
        return (package, product)
    }
}
