import Foundation
import XcodeProj

public struct XcodeProjectImportResult: Sendable {
    public let schema: PackSchemaBase
    public let warnings: [String]

    public init(schema: PackSchemaBase, warnings: [String]) {
        self.schema = schema
        self.warnings = warnings
    }
}

public struct XcodeProjectImporter {
    public init() {}

    public func importSchema(
        from inputURL: URL,
        configurationName: String? = nil
    ) throws -> XcodeProjectImportResult {
        let standardizedURL = inputURL.standardizedFileURL
        let currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL

        let importedProjects: [ImportedProject]
        switch standardizedURL.pathExtension {
        case "xcodeproj":
            importedProjects = [
                try importProject(
                    at: standardizedURL,
                    configurationName: configurationName,
                    currentDirectoryURL: currentDirectoryURL
                ),
            ]
        case "xcworkspace":
            importedProjects = try importWorkspace(
                at: standardizedURL,
                configurationName: configurationName,
                currentDirectoryURL: currentDirectoryURL
            )
        default:
            throw StringError("Expected a .xcodeproj or .xcworkspace input")
        }

        let products = importedProjects.flatMap(\.products)
        guard !products.isEmpty else {
            throw StringError("""
            No supported application, App Clip, or extension targets were found in '\(inputURL.lastPathComponent)'.
            """)
        }

        let missingBundleID = products.contains { $0.bundleID == nil }
        let schema = PackSchemaBase(
            version: .v2,
            orgID: missingBundleID ? "com.example" : nil,
            bundleID: nil,
            product: nil,
            infoPath: nil,
            entitlementsPath: nil,
            iconPath: nil,
            resources: nil,
            bundles: nil,
            extensions: nil,
            products: products
        )
        _ = try PackSchema(validating: schema)

        var warnings = importedProjects.flatMap(\.warnings)
        if missingBundleID {
            warnings.append(
                "warning: Some imported targets are missing PRODUCT_BUNDLE_IDENTIFIER. Using top-level orgID 'com.example'."
            )
        }

        return XcodeProjectImportResult(schema: schema, warnings: warnings.uniquedPreservingOrder())
    }
}

private extension XcodeProjectImporter {
    struct ImportedProject {
        let products: [PackSchemaBase.ProductDeclaration]
        let warnings: [String]
    }

    struct ImportedTarget {
        let targetName: String
        let packageProduct: String
        let kind: PackSchema.ProductKind
        let dependencyTargetNames: [String]
        let declaration: PackSchemaBase.ProductDeclaration
    }

    func importWorkspace(
        at workspaceURL: URL,
        configurationName: String?,
        currentDirectoryURL: URL
    ) throws -> [ImportedProject] {
        let workspace = try XCWorkspace(pathString: workspaceURL.path)
        let projectURLs = try workspaceProjectURLs(workspace: workspace, workspaceURL: workspaceURL)
        guard !projectURLs.isEmpty else {
            throw StringError("No .xcodeproj references were found in '\(workspaceURL.lastPathComponent)'.")
        }

        return try projectURLs.map {
            try importProject(
                at: $0,
                configurationName: configurationName,
                currentDirectoryURL: currentDirectoryURL
            )
        }
    }

    func workspaceProjectURLs(
        workspace: XCWorkspace,
        workspaceURL: URL
    ) throws -> [URL] {
        let workspaceDirectoryURL = workspaceURL.deletingLastPathComponent()
        var projectURLs: [URL] = []

        try collectWorkspaceProjectURLs(
            from: workspace.data.children,
            containerURL: workspaceDirectoryURL,
            groupURL: workspaceDirectoryURL,
            projectURLs: &projectURLs
        )

        return projectURLs.uniquedPreservingOrder()
    }

    func collectWorkspaceProjectURLs(
        from elements: [XCWorkspaceDataElement],
        containerURL: URL,
        groupURL: URL,
        projectURLs: inout [URL]
    ) throws {
        for element in elements {
            switch element {
            case .file(let fileRef):
                let resolvedURL = try resolveWorkspaceLocation(
                    fileRef.location,
                    containerURL: containerURL,
                    groupURL: groupURL
                )
                if resolvedURL.pathExtension == "xcodeproj" {
                    projectURLs.append(resolvedURL)
                }

            case .group(let group):
                let nextGroupURL = try resolveWorkspaceLocation(
                    group.location,
                    containerURL: containerURL,
                    groupURL: groupURL
                )
                try collectWorkspaceProjectURLs(
                    from: group.children,
                    containerURL: containerURL,
                    groupURL: nextGroupURL,
                    projectURLs: &projectURLs
                )
            }
        }
    }

    func resolveWorkspaceLocation(
        _ location: XCWorkspaceDataElementLocationType,
        containerURL: URL,
        groupURL: URL
    ) throws -> URL {
        switch location {
        case .absolute(let path):
            return URL(fileURLWithPath: path).standardizedFileURL

        case .container(let path):
            return URL(fileURLWithPath: path, relativeTo: containerURL).standardizedFileURL

        case .group(let path), .current(let path):
            return URL(fileURLWithPath: path, relativeTo: groupURL).standardizedFileURL

        case .developer(let path):
            throw StringError("""
            Developer-relative workspace reference '\(path)' is not supported during project import.
            """)

        case .other(let schema, let path):
            throw StringError("""
            Workspace reference schema '\(schema)' is not supported during project import ('\(path)').
            """)
        }
    }

    func importProject(
        at projectURL: URL,
        configurationName: String?,
        currentDirectoryURL: URL
    ) throws -> ImportedProject {
        let project = try XcodeProj(pathString: projectURL.path)
        guard let rootProject = project.pbxproj.rootObject else {
            throw StringError("Could not read the root project object from '\(projectURL.lastPathComponent)'.")
        }

        var warnings: [String] = []
        let defaultConfigurationName = configurationName ?? rootProject.buildConfigurationList.defaultConfigurationName
        let importedTargets = rootProject.targets.compactMap { target -> ImportedTarget? in
            guard let nativeTarget = target as? PBXNativeTarget,
                let kind = productKind(for: nativeTarget.productType) else {
                return nil
            }

            let buildConfiguration = selectedConfiguration(
                for: nativeTarget,
                requestedName: defaultConfigurationName
            )

            if let configurationName = defaultConfigurationName,
                buildConfiguration == nil {
                warnings.append("""
                warning: Target '\(nativeTarget.name)' does not define configuration '\(configurationName)'; using default values.
                """)
            }

            if buildConfiguration?.baseConfiguration != nil {
                warnings.append("""
                warning: Target '\(nativeTarget.name)' relies on an .xcconfig file. Verify imported paths and bundle identifiers.
                """)
            }

            let buildSettings = buildConfiguration?.buildSettings ?? [:]
            let projectDirectoryURL = projectURL.deletingLastPathComponent()
            let packageProduct = packageProductName(for: nativeTarget, buildSettings: buildSettings)

            return ImportedTarget(
                targetName: nativeTarget.name,
                packageProduct: packageProduct,
                kind: kind,
                dependencyTargetNames: nativeTarget.dependencies.compactMap { $0.target?.name },
                declaration: PackSchemaBase.ProductDeclaration(
                    kind: kind,
                    packageProduct: packageProduct,
                    hostApplication: nil,
                    bundleID: stringSetting("PRODUCT_BUNDLE_IDENTIFIER", in: buildSettings),
                    infoPath: resolvePathSetting(
                        "INFOPLIST_FILE",
                        buildSettings: buildSettings,
                        projectDirectoryURL: projectDirectoryURL,
                        currentDirectoryURL: currentDirectoryURL,
                        targetName: nativeTarget.name,
                        productName: packageProduct
                    ),
                    entitlementsPath: resolvePathSetting(
                        "CODE_SIGN_ENTITLEMENTS",
                        buildSettings: buildSettings,
                        projectDirectoryURL: projectDirectoryURL,
                        currentDirectoryURL: currentDirectoryURL,
                        targetName: nativeTarget.name,
                        productName: packageProduct
                    ),
                    iconPath: nil,
                    resources: nil,
                    platforms: supportedPlatforms(from: buildSettings),
                    entryPoint: nil,
                    signing: nil
                )
            )
        }

        let applicationTargetsByName = Dictionary(
            uniqueKeysWithValues: importedTargets
                .filter { $0.kind == .application }
                .map { ($0.targetName, $0.packageProduct) }
        )

        var hostApplicationsByTargetName: [String: String] = [:]
        for importedTarget in importedTargets where importedTarget.kind == .application {
            for dependencyTargetName in importedTarget.dependencyTargetNames {
                guard applicationTargetsByName[dependencyTargetName] == nil else {
                    continue
                }

                if let existingHost = hostApplicationsByTargetName[dependencyTargetName],
                    existingHost != importedTarget.packageProduct {
                    warnings.append("""
                    warning: Target '\(dependencyTargetName)' is embedded by multiple application targets. \
                    Using '\(existingHost)' as hostApplication.
                    """)
                    continue
                }

                hostApplicationsByTargetName[dependencyTargetName] = importedTarget.packageProduct
            }
        }

        let products = importedTargets.map { importedTarget in
            var declaration = importedTarget.declaration
            if importedTarget.kind != .application {
                declaration.hostApplication = hostApplicationsByTargetName[importedTarget.targetName]
            }
            return declaration
        }

        return ImportedProject(products: products, warnings: warnings.uniquedPreservingOrder())
    }

    func productKind(for productType: PBXProductType?) -> PackSchema.ProductKind? {
        switch productType {
        case .application:
            .application
        case .onDemandInstallCapableApplication:
            .appClip
        case .appExtension, .tvExtension, .watchExtension, .watch2Extension,
             .messagesExtension, .stickerPack, .intentsServiceExtension,
             .driverExtension, .systemExtension:
            .appExtension
        case .extensionKitExtension:
            .extensionKitExtension
        default:
            nil
        }
    }

    func selectedConfiguration(
        for target: PBXNativeTarget,
        requestedName: String?
    ) -> XCBuildConfiguration? {
        guard let configurationList = target.buildConfigurationList else {
            return nil
        }

        if let requestedName,
            let configuration = configurationList.configuration(name: requestedName) {
            return configuration
        }

        if let defaultConfigurationName = configurationList.defaultConfigurationName,
            let configuration = configurationList.configuration(name: defaultConfigurationName) {
            return configuration
        }

        return configurationList.buildConfigurations.first
    }

    func packageProductName(
        for target: PBXNativeTarget,
        buildSettings: [String: Any]
    ) -> String {
        let rawName = target.productName
            ?? stringSetting("PRODUCT_NAME", in: buildSettings)
            ?? target.name
        return URL(fileURLWithPath: rawName).deletingPathExtension().lastPathComponent
    }

    func stringSetting(
        _ key: String,
        in buildSettings: [String: Any]
    ) -> String? {
        switch buildSettings[key] {
        case let value as String:
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? nil : trimmedValue
        case let value as [String]:
            let joinedValue = value.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return joinedValue.isEmpty ? nil : joinedValue
        default:
            return nil
        }
    }

    func resolvePathSetting(
        _ key: String,
        buildSettings: [String: Any],
        projectDirectoryURL: URL,
        currentDirectoryURL: URL,
        targetName: String,
        productName: String
    ) -> String? {
        guard var value = stringSetting(key, in: buildSettings) else {
            return nil
        }

        let substitutions = [
            "$(SRCROOT)": projectDirectoryURL.path,
            "${SRCROOT}": projectDirectoryURL.path,
            "$(PROJECT_DIR)": projectDirectoryURL.path,
            "${PROJECT_DIR}": projectDirectoryURL.path,
            "$(TARGET_NAME)": targetName,
            "${TARGET_NAME}": targetName,
            "$(PRODUCT_NAME)": productName,
            "${PRODUCT_NAME}": productName,
        ]
        for (token, replacement) in substitutions {
            value = value.replacingOccurrences(of: token, with: replacement)
        }

        let resolvedURL = URL(fileURLWithPath: value, relativeTo: projectDirectoryURL).standardizedFileURL
        let currentDirectoryPath = currentDirectoryURL.path + "/"
        if resolvedURL.path.hasPrefix(currentDirectoryPath) {
            return String(resolvedURL.path.dropFirst(currentDirectoryPath.count))
        }
        return resolvedURL.path
    }

    func supportedPlatforms(from buildSettings: [String: Any]) -> [ApplePlatformFamily]? {
        let explicitPlatforms = arraySetting("SUPPORTED_PLATFORMS", in: buildSettings)
        let platformTokens = explicitPlatforms.isEmpty
            ? arraySetting("SDKROOT", in: buildSettings)
            : explicitPlatforms

        let platforms = platformTokens.compactMap { platformFamily(for: $0) }.uniquedPreservingOrder()
        return platforms.isEmpty ? nil : platforms
    }

    func arraySetting(
        _ key: String,
        in buildSettings: [String: Any]
    ) -> [String] {
        switch buildSettings[key] {
        case let value as String:
            return value.split(whereSeparator: \.isWhitespace).map(String.init)
        case let value as [String]:
            return value
        default:
            return []
        }
    }

    func platformFamily(for platform: String) -> ApplePlatformFamily? {
        let normalizedPlatform = platform.lowercased()

        if normalizedPlatform.contains("iphone") || normalizedPlatform == "ios" {
            return .iOS
        }
        if normalizedPlatform.contains("macos") || normalizedPlatform.contains("macosx") {
            return .macOS
        }
        if normalizedPlatform.contains("appletv") || normalizedPlatform == "tvos" {
            return .tvOS
        }
        if normalizedPlatform.contains("watch") {
            return .watchOS
        }
        if normalizedPlatform.contains("xros") || normalizedPlatform.contains("vision") {
            return .visionOS
        }
        return nil
    }
}

private extension Array where Element: Equatable {
    func uniquedPreservingOrder() -> [Element] {
        var result: [Element] = []
        for element in self where !result.contains(element) {
            result.append(element)
        }
        return result
    }
}
