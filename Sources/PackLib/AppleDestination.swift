import Foundation

public enum ApplePlatformFamily: String, CaseIterable, Codable, Sendable {
    case iOS = "ios"
    case macOS = "macos"
    case tvOS = "tvos"
    case watchOS = "watchos"
    case visionOS = "visionos"

    public var packageManifestNames: Set<String> {
        switch self {
        case .iOS: ["ios"]
        case .macOS: ["macos", "macosx"]
        case .tvOS: ["tvos"]
        case .watchOS: ["watchos"]
        case .visionOS: ["visionos", "xros"]
        }
    }

    public var packageDescriptionCase: String {
        switch self {
        case .iOS: "iOS"
        case .macOS: "macOS"
        case .tvOS: "tvOS"
        case .watchOS: "watchOS"
        case .visionOS: "visionOS"
        }
    }

    public var defaultDeploymentTarget: String {
        switch self {
        case .iOS, .tvOS:
            "13.0"
        case .macOS:
            "13.0"
        case .watchOS:
            "7.0"
        case .visionOS:
            "1.0"
        }
    }

    public var defaultDeviceFamilies: [Int]? {
        switch self {
        case .iOS:
            [1, 2]
        case .tvOS:
            [3]
        case .watchOS:
            [4]
        case .visionOS:
            [7]
        case .macOS:
            nil
        }
    }

    public var defaultBundleSupportedPlatform: String {
        switch self {
        case .iOS:
            "iPhoneOS"
        case .macOS:
            "MacOSX"
        case .tvOS:
            "AppleTVOS"
        case .watchOS:
            "WatchOS"
        case .visionOS:
            "XROS"
        }
    }
}

public enum AppleDestination: String, CaseIterable, Codable, Sendable {
    case iOS = "ios"
    case iOSSimulator = "ios-simulator"
    case macOS = "macos"
    case tvOS = "tvos"
    case tvOSSimulator = "tvos-simulator"
    case watchOS = "watchos"
    case watchOSSimulator = "watchos-simulator"
    case visionOS = "visionos"
    case visionOSSimulator = "visionos-simulator"

    public var platformFamily: ApplePlatformFamily {
        switch self {
        case .iOS, .iOSSimulator:
            .iOS
        case .macOS:
            .macOS
        case .tvOS, .tvOSSimulator:
            .tvOS
        case .watchOS, .watchOSSimulator:
            .watchOS
        case .visionOS, .visionOSSimulator:
            .visionOS
        }
    }

    public var isSimulator: Bool {
        switch self {
        case .iOSSimulator, .tvOSSimulator, .watchOSSimulator, .visionOSSimulator:
            true
        case .iOS, .macOS, .tvOS, .watchOS, .visionOS:
            false
        }
    }

    public var bundleSupportedPlatform: String {
        if isSimulator {
            return switch platformFamily {
            case .iOS: "iPhoneSimulator"
            case .macOS: "MacOSX"
            case .tvOS: "AppleTVSimulator"
            case .watchOS: "WatchSimulator"
            case .visionOS: "XRSimulator"
            }
        }
        return platformFamily.defaultBundleSupportedPlatform
    }

    public var defaultArchitecture: String {
        if self == .watchOS {
            return "arm64_32"
        }
        if isSimulator || self == .macOS {
            return Self.currentHostArchitecture() ?? "arm64"
        }
        return "arm64"
    }

    public func defaultTriple(hostArchitecture: String? = Self.currentHostArchitecture()) -> String {
        let architecture = if isSimulator || self == .macOS {
            hostArchitecture ?? defaultArchitecture
        } else {
            defaultArchitecture
        }

        return switch self {
        case .iOS:
            "\(architecture)-apple-ios"
        case .iOSSimulator:
            "\(architecture)-apple-ios-simulator"
        case .macOS:
            "\(architecture)-apple-macosx"
        case .tvOS:
            "\(architecture)-apple-tvos"
        case .tvOSSimulator:
            "\(architecture)-apple-tvos-simulator"
        case .watchOS:
            "\(architecture)-apple-watchos"
        case .watchOSSimulator:
            "\(architecture)-apple-watchos-simulator"
        case .visionOS:
            "\(architecture)-apple-xros"
        case .visionOSSimulator:
            "\(architecture)-apple-xros-simulator"
        }
    }

    public var packageDescriptionSnippet: String {
        ".\(platformFamily.packageDescriptionCase)"
    }

    public static func currentHostArchitecture() -> String? {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #elseif arch(arm64_32)
        "arm64_32"
        #else
        nil
        #endif
    }

    public init(triple: String) throws {
        let triple = try AppleTriple(triple)
        self = try triple.destination()
    }
}
