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
            try Self.appDeclaration(in: productDeclarations)
        }
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
        let apps = declarations.filter { $0.kind == .application }
        guard let app = apps.first else {
            throw StringError("xtool.yml: Expected exactly one application product.")
        }
        guard apps.count == 1 else {
            throw StringError("xtool.yml: Expected exactly one application product.")
        }
        return app
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

        let requiresDefaultID = declarations.contains { $0.bundleID == nil }

        if requiresDefaultID {
            switch (base.bundleID, base.orgID) {
            case (let bundleID?, _):
                idSpecifier = .bundleID(bundleID)
            case (nil, let orgID?):
                idSpecifier = .orgID(orgID)
            case (nil, nil):
                throw StringError("xtool.yml: Must specify either orgID or bundleID")
            }
        } else {
            idSpecifier = switch (base.bundleID, base.orgID) {
            case (let bundleID?, _):
                .bundleID(bundleID)
            case (nil, let orgID?):
                .orgID(orgID)
            case (nil, nil):
                nil
            }
        }

        try validateIconPath(base.iconPath, field: "iconPath")
        for (index, product) in declarations.enumerated() {
            try validateIconPath(product.iconPath, field: "products[\(index)].iconPath")
            try validateEntryPoint(product.entryPoint, kind: product.kind, index: index)
            if base.version == .v2, product.packageProduct?.isEmpty != false {
                throw StringError("xtool.yml: products[\(index)].packageProduct is required in schema version 2")
            }
        }

        _ = try Self.appDeclaration(in: declarations)
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
