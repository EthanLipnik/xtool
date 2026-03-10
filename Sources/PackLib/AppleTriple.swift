import Foundation
import XUtils

struct AppleTriple: Sendable {
    let architecture: String
    let vendor: String
    let operatingSystem: String
    let environment: [String]

    init(_ triple: String) throws {
        let components = triple.split(separator: "-").map(String.init)
        guard components.count >= 3 else {
            throw StringError("Unsupported Apple target triple '\(triple)'")
        }

        architecture = components[0]
        vendor = components[1]
        operatingSystem = components[2]
        environment = Array(components.dropFirst(3))

        guard vendor == "apple" else {
            throw StringError("Unsupported Apple target triple '\(triple)'")
        }
    }

    var isSimulator: Bool {
        environment.contains("simulator")
    }

    var platformName: String {
        operatingSystem.prefix { $0.isLetter }.lowercased()
    }

    var bundleSupportedPlatform: String {
        switch platformName {
        case "ios":
            isSimulator ? "iPhoneSimulator" : "iPhoneOS"
        case "tvos":
            isSimulator ? "AppleTVSimulator" : "AppleTVOS"
        case "watchos":
            isSimulator ? "WatchSimulator" : "WatchOS"
        case "xros":
            isSimulator ? "XRSimulator" : "XROS"
        case "macos", "macosx":
            "MacOSX"
        default:
            operatingSystem
        }
    }

    var requiredDeviceCapabilities: [String]? {
        guard !isSimulator else { return nil }
        return switch platformName {
        case "ios", "tvos", "watchos", "xros":
            [architecture]
        default:
            nil
        }
    }
}
