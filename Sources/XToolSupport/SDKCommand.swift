import ArgumentParser
import Foundation
import PackLib
import Version
import XKit
import XUtils

struct SDKCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdk",
        abstract: "Manage the Darwin Swift SDK",
        subcommands: [
            DevSDKInstallCommand.self,
            DevSDKRemoveCommand.self,
            DevSDKBuildCommand.self,
            DevSDKStatusCommand.self,
            DevSDKVerifyCommand.self,
        ],
        defaultSubcommand: DevSDKInstallCommand.self
    )
}

struct DevSDKBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build the Darwin Swift SDK from Xcode.xip"
    )

    @Argument(
        help: "Path to Xcode.xip or Xcode.app",
        completion: .file(extensions: ["xip", "app"])
    )
    var path: String

    @Argument(
        help: "Output directory"
    )
    var outputDir: String

    @Option(
        help: ArgumentHelp(
            "The architecture of the Linux host the SDK is being built for.",
            discussion: "Defaults to 'auto', which attempts to match the current host architecture."
        )
    ) var arch: ArchSelection = .auto

    @Option(
        name: .long,
        help: "Toolchain identifier inside the Xcode bundle"
    ) var toolchain: String = SDKBuilder.defaultToolchain

    func run() async throws {
        let builder = SDKBuilder(
            input: try SDKBuilder.Input(path: path),
            outputPath: outputDir,
            arch: try arch.sdkBuilderArch,
            toolchain: toolchain
        )
        let sdkPath = try await builder.buildSDK()
        print("Built SDK at \(sdkPath)")
    }
}

enum ArchSelection: String, ExpressibleByArgument {
    case auto
    case x86_64
    case arm64

    var sdkBuilderArch: SDKBuilder.Arch {
        get throws {
            switch self {
            case .auto:
                #if arch(arm64)
                .aarch64
                #elseif arch(x86_64)
                .x86_64
                #else
                throw Console.Error("Could not auto-detect target architecture. Please specify one with '--arch'.")
                #endif
            case .arm64:
                .aarch64
            case .x86_64:
                .x86_64
            }
        }
    }
}

struct DevSDKInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the Darwin Swift SDK"
    )

    @Argument(
        help: "Path to Xcode.xip or Xcode.app",
        completion: .file(extensions: ["xip", "app"])
    )
    var path: String

    @Option(
        help: ArgumentHelp(
            "The architecture of the Linux host the SDK is being built for.",
            discussion: "Defaults to 'auto', which attempts to match the current host architecture."
        )
    ) var arch: ArchSelection = .auto

    @Option(
        name: .long,
        help: "Toolchain identifier inside the Xcode bundle"
    ) var toolchain: String = SDKBuilder.defaultToolchain

    func run() async throws {
        try await InstallSDKOperation(path: path, arch: arch, toolchain: toolchain).run()
    }
}

struct DevSDKRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove the Darwin Swift SDK"
    )

    func run() async throws {
        guard let sdk = try await DarwinSDK.current() else {
            throw Console.Error("Cannot remove SDK: no Darwin SDK installed")
        }
        try sdk.remove()
        print("Uninstalled SDK")
    }
}

struct DevSDKStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Get the status of the Darwin Swift SDK"
    )

    func run() async throws {
        guard let sdk = try await DarwinSDK.current() else {
            print("Not installed")
            return
        }

        print("Installed at \(sdk.bundle.path)")
        print("Version: \(sdk.version)")
        if let metadata = sdk.metadata {
            print("Toolchain: \(metadata.toolchain)")
            print("Swift: \(metadata.swiftVersion)")
            print("Triples: \(metadata.supportedTriples.joined(separator: ", "))")
        } else {
            print("Toolchain metadata: unavailable")
        }
    }
}

struct DevSDKVerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify that the installed Darwin SDK matches the current Swift toolchain"
    )

    @Option(
        name: .long,
        help: "Expected toolchain identifier inside the installed Darwin SDK bundle"
    ) var toolchain: String?

    func run() async throws {
        guard let sdk = try await DarwinSDK.current() else {
            throw Console.Error("Cannot verify SDK: no Darwin SDK installed")
        }

        let verification = try await sdk.verify(expectedToolchain: toolchain)
        print("Verified Darwin SDK at \(verification.bundle.path)")
        print("Configured triple: \(verification.configuredTriple)")
        print("Toolchain: \(verification.toolchain)")
        print("Bundled Swift: \(verification.bundledSwiftVersion)")
        print("Current Swift: \(verification.currentSwiftVersion)")
    }
}

struct DarwinSDK {
    struct Verification: Sendable {
        var bundle: URL
        var configuredTriple: String
        var toolchain: String
        var bundledSwiftVersion: String
        var currentSwiftVersion: String
    }

    let bundle: URL
    let version: String
    let metadata: SDKToolchainMetadata?

    init?(bundle: URL) {
        self.bundle = bundle

        if let version = try? Data(contentsOf: bundle.appendingPathComponent("darwin-sdk-version.txt")) {
            self.version = String(decoding: version, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if bundle.lastPathComponent == "darwin.artifactbundle" {
            self.version = "unknown"
        } else {
            return nil
        }

        self.metadata = try? JSONDecoder().decode(
            SDKToolchainMetadata.self,
            from: Data(contentsOf: bundle.appendingPathComponent("xtool-toolchain.json"))
        )
    }

    static func install(from path: String) async throws {
        let url = URL(fileURLWithPath: path)
        guard DarwinSDK(bundle: url) != nil else {
            throw Console.Error("Invalid Darwin SDK at '\(path)'")
        }

        let process = Process()
        process.executableURL = try await ToolRegistry.locate("swift")
        process.arguments = ["sdk", "install", url.path]
        try await process.runUntilExit()
    }

    static func current() async throws -> DarwinSDK? {
        try await current(configuredTriple: AppleDestination.iOS.defaultTriple())
    }

    static func current(configuredTriple: String) async throws -> DarwinSDK? {
        guard let configuration = try await showConfiguration(triple: configuredTriple) else {
            return nil
        }

        guard let resourcesPath = configuration["swiftResourcesPath"] else {
            return nil
        }

        var resourcesURL = URL(fileURLWithPath: resourcesPath)
        for _ in 0..<6 {
            resourcesURL = resourcesURL.deletingLastPathComponent()
        }

        return DarwinSDK(bundle: resourcesURL)
    }

    func verify(expectedToolchain: String? = nil) async throws -> Verification {
        guard let metadata else {
            throw Console.Error("""
            Installed Darwin SDK is missing xtool toolchain metadata.
              Rebuild it with `xtool sdk build` and reinstall it.
            """)
        }

        if let expectedToolchain, metadata.toolchain != expectedToolchain {
            throw Console.Error("""
            Installed Darwin SDK uses toolchain '\(metadata.toolchain)', not '\(expectedToolchain)'.
            """)
        }

        let toolchainRoot = bundle.appendingPathComponent("Developer/Toolchains/\(metadata.toolchain)")
        guard toolchainRoot.dirExists else {
            throw Console.Error("Missing toolchain directory '\(toolchainRoot.path)'")
        }

        let linker = bundle.appendingPathComponent("toolset/bin/ld64.lld")
        guard FileManager.default.fileExists(atPath: linker.path) else {
            throw Console.Error("Missing linker tool at '\(linker.path)'")
        }

        let currentSwiftVersion = try await SwiftVersion.current()
        if
            let bundledVersion = Self.parseSwiftVersion(metadata.swiftVersion),
            (bundledVersion.major, bundledVersion.minor) != (currentSwiftVersion.major, currentSwiftVersion.minor)
        {
            throw Console.Error("""
            Darwin SDK was built for Swift \(bundledVersion.major).\(bundledVersion.minor), but the current \
            toolchain is Swift \(currentSwiftVersion.major).\(currentSwiftVersion.minor).
            """)
        }

        let configuredTriple = metadata.supportedTriples.first ?? AppleDestination.iOS.defaultTriple()
        guard let configuration = try await Self.showConfiguration(triple: configuredTriple) else {
            throw Console.Error("Could not resolve Darwin SDK configuration for triple '\(configuredTriple)'")
        }
        guard let swiftResourcesPath = configuration["swiftResourcesPath"] else {
            throw Console.Error("Resolved Darwin SDK configuration is missing swiftResourcesPath")
        }
        guard swiftResourcesPath.hasPrefix(bundle.path) else {
            throw Console.Error("""
            Swift resolved a different Darwin SDK than the installed xtool bundle.
              Expected prefix: \(bundle.path)
              Actual path: \(swiftResourcesPath)
            """)
        }

        return Verification(
            bundle: bundle,
            configuredTriple: configuredTriple,
            toolchain: metadata.toolchain,
            bundledSwiftVersion: metadata.swiftVersion,
            currentSwiftVersion: currentSwiftVersion.description
        )
    }

    func remove() throws {
        try FileManager.default.removeItem(at: bundle)
    }

    private static func showConfiguration(triple: String) async throws -> [String: String]? {
        let output = Pipe()

        let process = Process()
        process.executableURL = try await ToolRegistry.locate("swift")
        process.arguments = ["sdk", "configure", "darwin", triple, "--show-configuration"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try await process.runUntilExit()
        } catch Process.Failure.exit {
            return nil
        }

        let outputString = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )

        return outputString
            .split(separator: "\n")
            .reduce(into: [:]) { configuration, line in
                guard let separator = line.firstIndex(of: ":") else { return }
                let key = String(line[..<separator])
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                configuration[key] = value
            }
    }

    private static func parseSwiftVersion(_ description: String) -> Version? {
        guard let range = description.range(of: #"Swift version \d+\.\d+(\.\d+)?"#, options: .regularExpression) else {
            return nil
        }
        let prefix = "Swift version "
        let versionString = description[range].dropFirst(prefix.count)
        return Version(tolerant: versionString)
    }
}

private enum SwiftVersion {}
extension SwiftVersion {
    static func current() async throws -> Version {
        let outPipe = Pipe()
        let errPipe = Pipe()
        let swift = Process()
        swift.executableURL = try await ToolRegistry.locate("swift")
        swift.arguments = ["--version"]
        swift.standardOutput = outPipe
        swift.standardError = errPipe
        async let outputTask = outPipe.fileHandleForReading.readToEnd()
        do {
            try await swift.runUntilExit()
        } catch is Process.Failure {
            throw Console.Error("Failed to obtain Swift version")
        }
        let outputData = try await outputTask
        var output = String(decoding: outputData ?? Data(), as: UTF8.self)[...]
        if output.hasPrefix("Apple ") {
            output = output.dropFirst("Apple ".count)
        }
        guard output.hasPrefix("Swift version ") else {
            throw Console.Error("Could not parse Swift version: '\(output)'")
        }
        output = output.dropFirst("Swift version ".count)
        guard let space = output.firstIndex(of: " ") else {
            throw Console.Error("Could not parse Swift version: '\(output)'")
        }
        output = output[..<space]
        guard let version = Version(tolerant: output) else {
            throw Console.Error("Could not parse Swift version: '\(output)'")
        }
        return version
    }
}

struct InstallSDKOperation {
    let path: String
    let arch: ArchSelection
    let toolchain: String

    func run() async throws {
        #if os(macOS)
        print("Skipping SDK install; the iOS SDK ships with Xcode on macOS")
        #else
        let input = try SDKBuilder.Input(path: path)

        if let sdk = try await DarwinSDK.current() {
            print("Removing existing SDK...")
            try sdk.remove()
        }

        let tempDir = try TemporaryDirectory(name: "DarwinSDKBuild")
        let builder = SDKBuilder(
            input: input,
            outputPath: tempDir.url.path,
            arch: try arch.sdkBuilderArch,
            toolchain: toolchain
        )
        let sdkPath = try await builder.buildSDK()

        try await DarwinSDK.install(from: sdkPath)

        guard let installed = try await DarwinSDK.current() else {
            throw Console.Error("Installed Darwin SDK could not be discovered after installation")
        }
        _ = try await installed.verify(expectedToolchain: toolchain)

        withExtendedLifetime(tempDir) {}
        #endif
    }
}
