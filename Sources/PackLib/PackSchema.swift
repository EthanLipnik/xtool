import Foundation
import Yams
import XUtils

public enum PackSchemaBundleKind: String, Codable, Sendable, CaseIterable {
    case appExtension
    case extensionKitExtension
    case appClip
}

public enum PackSchemaProductKind: String, Codable, Sendable, CaseIterable {
    case application
    case appExtension
    case extensionKitExtension
    case appClip
}

public enum PackSchemaSigningMode: String, Codable, Sendable, CaseIterable {
    case none
    case adhoc
    case developer
}

public struct PackSchemaProductSigning: Codable, Sendable, Equatable {
    public var mode: PackSchemaSigningMode

    public init(mode: PackSchemaSigningMode) {
        self.mode = mode
    }
}

public struct PackSchemaProductEntryPoint: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case swiftUI
        case uiKit
        case appKit
    }

    public var kind: Kind
    public var symbol: String?

    public init(kind: Kind, symbol: String? = nil) {
        self.kind = kind
        self.symbol = symbol
    }
}

public struct PackSchemaBase: Codable, Sendable {
    public enum Version: Int, Codable, Sendable {
        case v1 = 1
        case v2 = 2
    }

    public var version: Version

    public var orgID: String?
    public var bundleID: String?

    public var product: String?

    public var infoPath: String?
    public var entitlementsPath: String?

    public var iconPath: String?
    public var resources: [String]?

    public var bundles: [BundleDeclaration]?
    public var extensions: [Extension]?
    public var products: [ProductDeclaration]?

    public struct BundleDeclaration: Codable, Sendable {
        public var kind: PackSchemaBundleKind
        public var product: String
        public var bundleID: String?
        public var infoPath: String
        public var resources: [String]?
        public var entitlementsPath: String?
    }

    public struct Extension: Codable, Sendable {
        public var product: String
        public var bundleID: String?
        public var infoPath: String
        public var resources: [String]?
        public var entitlementsPath: String?
    }

    public struct ProductDeclaration: Codable, Sendable {
        public var kind: PackSchemaProductKind
        public var packageProduct: String?
        public var hostApplication: String?
        public var bundleID: String?
        public var infoPath: String?
        public var entitlementsPath: String?
        public var iconPath: String?
        public var resources: [String]?
        public var platforms: [ApplePlatformFamily]?
        public var entryPoint: PackSchemaProductEntryPoint?
        public var signing: PackSchemaProductSigning?
    }
}

@dynamicMemberLookup
public struct PackSchema: Sendable {
    public typealias BundleKind = PackSchemaBundleKind
    public typealias BundleDeclaration = PackSchemaBase.BundleDeclaration
    public typealias Extension = PackSchemaBase.Extension
    public typealias ProductDeclaration = PackSchemaBase.ProductDeclaration
    public typealias ProductKind = PackSchemaProductKind
    public typealias ProductSigning = PackSchemaProductSigning
    public typealias ProductEntryPoint = PackSchemaProductEntryPoint
    public typealias SigningMode = PackSchemaSigningMode

    public enum IDSpecifier: Sendable {
        case orgID(String)
        case bundleID(String)

        func formBundleID(product: String) -> String {
            switch self {
            case .orgID(let orgID): "\(orgID).\(product)"
            case .bundleID(let bundleID): bundleID
            }
        }
    }

    public let base: PackSchemaBase
    public let idSpecifier: IDSpecifier?

    public var deprecationWarnings: [String] {
        var warnings: [String] = []
        if base.extensions?.isEmpty == false {
            warnings.append(
                "warning: `xtool.yml` key `extensions` is deprecated; use `products` or `bundles` instead."
            )
        }
        if base.version == .v1 {
            warnings.append(
                "warning: `xtool.yml` schema version 1 is deprecated; prefer schema version 2 with explicit `products`."
            )
        }
        return warnings
    }

    public var bundleDeclarations: [BundleDeclaration] {
        Self.bundleDeclarations(for: base)
    }

    public var productDeclarations: [ProductDeclaration] {
        Self.productDeclarations(for: base)
    }

    public var appDeclaration: ProductDeclaration {
        get throws {
            try appDeclaration(named: nil)
        }
    }

    public var applicationDeclarations: [ProductDeclaration] {
        productDeclarations.filter { $0.kind == .application }
    }

    private static func bundleDeclarations(for base: PackSchemaBase) -> [BundleDeclaration] {
        let legacyExtensions = base.extensions?.map {
            BundleDeclaration(
                kind: .appExtension,
                product: $0.product,
                bundleID: $0.bundleID,
                infoPath: $0.infoPath,
                resources: $0.resources,
                entitlementsPath: $0.entitlementsPath
            )
        } ?? []
        return legacyExtensions + (base.bundles ?? [])
    }

    private static func productDeclarations(for base: PackSchemaBase) -> [ProductDeclaration] {
        if let products = base.products, !products.isEmpty {
            return products
        }

        var products: [ProductDeclaration] = [
            ProductDeclaration(
                kind: .application,
                packageProduct: base.product,
                hostApplication: nil,
                bundleID: base.bundleID,
                infoPath: base.infoPath,
                entitlementsPath: base.entitlementsPath,
                iconPath: base.iconPath,
                resources: base.resources,
                platforms: nil,
                entryPoint: nil,
                signing: nil
            )
        ]

        products += bundleDeclarations(for: base).map {
            ProductDeclaration(
                kind: $0.kind.productKind,
                packageProduct: $0.product,
                hostApplication: nil,
                bundleID: $0.bundleID,
                infoPath: $0.infoPath,
                entitlementsPath: $0.entitlementsPath,
                iconPath: nil,
                resources: $0.resources,
                platforms: nil,
                entryPoint: nil,
                signing: nil
            )
        }

        return products
    }

    private static func appDeclaration(in declarations: [ProductDeclaration]) throws -> ProductDeclaration {
        try appDeclaration(in: declarations, named: nil)
    }

    private static func appDeclaration(
        in declarations: [ProductDeclaration],
        named packageProduct: String?
    ) throws -> ProductDeclaration {
        let apps = declarations.filter { $0.kind == .application }
        guard !apps.isEmpty else {
            throw StringError("xtool.yml: Expected at least one application product.")
        }

        if let packageProduct {
            guard let app = apps.first(where: { $0.packageProduct == packageProduct }) else {
                throw StringError("""
                xtool.yml: Could not find application product '\(packageProduct)'. \
                Found: \(apps.compactMap(\.packageProduct)).
                """)
            }
            return app
        }

        guard let app = apps.first, apps.count == 1 else {
            throw StringError("""
            xtool.yml: Multiple application products were found (\(apps.compactMap(\.packageProduct))). \
            Pass --product to choose one.
            """)
        }
        return app
    }

    public func appDeclaration(named packageProduct: String?) throws -> ProductDeclaration {
        try Self.appDeclaration(in: productDeclarations, named: packageProduct)
    }

    public init(validating base: PackSchemaBase) throws {
        self.base = base

        let declarations = Self.productDeclarations(for: base)

        switch base.version {
        case .v1:
            break
        case .v2:
            guard base.products?.isEmpty == false else {
                throw StringError("xtool.yml: schema version 2 requires a non-empty `products` array")
            }
        }

        idSpecifier = try Self.resolveIDSpecifier(base: base, declarations: declarations)
        try validateDeclaredProducts(declarations, version: base.version)
        try validateApplicationTopology(declarations)
    }

    private static func resolveIDSpecifier(
        base: PackSchemaBase,
        declarations: [ProductDeclaration]
    ) throws -> IDSpecifier? {
        let requiresDefaultID = declarations.contains { $0.bundleID == nil }
        if requiresDefaultID {
            switch (base.bundleID, base.orgID) {
            case (let bundleID?, _):
                return .bundleID(bundleID)
            case (nil, let orgID?):
                return .orgID(orgID)
            case (nil, nil):
                throw StringError("xtool.yml: Must specify either orgID or bundleID")
            }
        }

        return switch (base.bundleID, base.orgID) {
        case (let bundleID?, _):
            .bundleID(bundleID)
        case (nil, let orgID?):
            .orgID(orgID)
        case (nil, nil):
            nil
        }
    }

    private func validateDeclaredProducts(
        _ declarations: [ProductDeclaration],
        version: PackSchemaBase.Version
    ) throws {
        try validateIconPath(base.iconPath, field: "iconPath")
        for (index, product) in declarations.enumerated() {
            try validateIconPath(product.iconPath, field: "products[\(index)].iconPath")
            try validateEntryPoint(product.entryPoint, kind: product.kind, index: index)
            if version == .v2, product.packageProduct?.isEmpty != false {
                throw StringError("xtool.yml: products[\(index)].packageProduct is required in schema version 2")
            }
        }
    }

    private func validateApplicationTopology(_ declarations: [ProductDeclaration]) throws {
        let applicationDeclarations = declarations.enumerated()
            .filter { $0.element.kind == .application }

        guard !applicationDeclarations.isEmpty else {
            throw StringError("xtool.yml: Expected at least one application product.")
        }

        let applicationNames = applicationDeclarations.compactMap(\.element.packageProduct)
        let uniqueApplicationNames = Set(applicationNames)
        if uniqueApplicationNames.count != applicationNames.count {
            let duplicates = Dictionary(grouping: applicationNames, by: { $0 })
                .filter { $0.value.count > 1 }
                .map(\.key)
                .sorted()
            throw StringError("""
            xtool.yml: Application products must have unique packageProduct values. \
            Duplicates: \(duplicates).
            """)
        }

        try validateBundleHosts(
            declarations: declarations,
            validApplicationNames: uniqueApplicationNames,
            requiresExplicitHosts: applicationDeclarations.count > 1
        )
    }

    private func validateBundleHosts(
        declarations: [ProductDeclaration],
        validApplicationNames: Set<String>,
        requiresExplicitHosts: Bool
    ) throws {
        for (index, product) in declarations.enumerated() where product.kind != .application {
            if requiresExplicitHosts, product.hostApplication?.isEmpty != false {
                throw StringError("""
                xtool.yml: products[\(index)].hostApplication is required when more than one application product is declared.
                """)
            }
            if let hostApplication = product.hostApplication,
                !validApplicationNames.contains(hostApplication) {
                throw StringError("""
                xtool.yml: products[\(index)].hostApplication '\(hostApplication)' does not match any application product.
                """)
            }
        }
    }

    private func validateEntryPoint(
        _ entryPoint: ProductEntryPoint?,
        kind: ProductKind,
        index: Int
    ) throws {
        guard let entryPoint else { return }

        switch (kind, entryPoint.kind) {
        case (.application, _), (.appClip, _):
            break
        case (.appExtension, _), (.extensionKitExtension, _):
            throw StringError("xtool.yml: products[\(index)].entryPoint is only supported for application products")
        }

        switch entryPoint.kind {
        case .swiftUI:
            break
        case .uiKit, .appKit:
            guard entryPoint.symbol?.isEmpty == false else {
                throw StringError("""
                xtool.yml: products[\(index)].entryPoint.symbol is required for '\(entryPoint.kind.rawValue)'.
                """)
            }
        }
    }

    private func validateIconPath(_ iconPath: String?, field: String) throws {
        guard let iconPath else { return }
        let ext = URL(fileURLWithPath: iconPath).pathExtension
        guard ext == "png" else {
            throw StringError("xtool.yml: \(field) should have a 'png' path extension. Got '\(ext)'.")
        }
    }

    // swiftlint:disable:next force_try
    public static let `default` = try! PackSchema(validating: .init(
        version: .v1,
        orgID: "com.example"
    ))

    public init(url: URL) async throws {
        let data = try await Data(reading: url)
        let base = try YAMLDecoder().decode(PackSchemaBase.self, from: data)
        try self.init(validating: base)
    }

    public subscript<Subject>(dynamicMember keyPath: KeyPath<PackSchemaBase, Subject>) -> Subject {
        self.base[keyPath: keyPath]
    }
}

public extension PackSchema.ProductDeclaration {
    var effectiveSigningMode: PackSchema.SigningMode {
        signing?.mode ?? .adhoc
    }

    var effectiveEntryPoint: PackSchema.ProductEntryPoint? {
        if let entryPoint {
            return entryPoint
        }

        switch kind {
        case .application, .appClip:
            return .init(kind: .swiftUI)
        case .appExtension, .extensionKitExtension:
            return nil
        }
    }
}

public extension PackSchemaBase {
    func encodedYAML() throws -> String {
        let encoder = YAMLEncoder()
        return try encoder.encode(self)
    }
}

private extension PackSchema.BundleKind {
    var productKind: PackSchema.ProductKind {
        switch self {
        case .appExtension:
            .appExtension
        case .extensionKitExtension:
            .extensionKitExtension
        case .appClip:
            .appClip
        }
    }
}
