import Foundation
import ArgumentParser
import PackLib
import XKit
import Dependencies
import XUtils

struct PackOperation {
    struct BuildOptions: ParsableArguments {
        @Option(
            name: .shortAndLong,
            help: "Build with configuration"
        ) var configuration: BuildConfiguration = .debug

        init() {}

        init(configuration: BuildConfiguration) {
            self.configuration = configuration
        }
    }

    struct ProductOptions: ParsableArguments {
        @Option(
            name: .long,
            help: "Application package product to build in multi-application projects"
        ) var product: String?
    }

    static let defaultDestination: AppleDestination = .iOS

    var destination: AppleDestination = Self.defaultDestination
    var triple: String?
    var toolchain: String?
    var product: String?
    var buildOptions = BuildOptions(configuration: .debug)
    var xcode = false

    @discardableResult
    func run() async throws -> URL {
        print("Planning...")

        let schema: PackSchema
        let configPath = URL(fileURLWithPath: "xtool.yml")
        if FileManager.default.fileExists(atPath: configPath.path) {
            schema = try await PackSchema(url: configPath)
            schema.deprecationWarnings.forEach { print($0) }
        } else {
            schema = .default
            print("""
            warning: Could not locate configuration file '\(configPath.path)'. Using default \
            configuration with 'com.example' organization ID.
            """)
        }

        let buildSettings = try await BuildSettings(
            configuration: buildOptions.configuration,
            destination: destination,
            triple: triple,
            toolchain: toolchain,
            options: []
        )

        let planner = Planner(
            buildSettings: buildSettings,
            schema: schema
        )
        let plan = try await planner.createPlan(selectedApplication: product)

        #if os(macOS)
        if xcode {
            return try await XcodePacker(plan: plan).createProject()
        }
        #endif

        let packer = Packer(
            buildSettings: buildSettings,
            plan: plan
        )
        let bundle = try await packer.pack()

        let productsWithEntitlements = plan
            .allProducts
            .compactMap { p in p.entitlementsPath.map { (p, $0) } }
        if !productsWithEntitlements.isEmpty {
            let mapping = try await withThrowingTaskGroup(of: (URL, Entitlements).self) { group in
                for (product, path) in productsWithEntitlements {
                    group.addTask {
                        let data = try await Data(reading: URL(fileURLWithPath: path))
                        let decoder = PropertyListDecoder()
                        let entitlements = try decoder.decode(Entitlements.self, from: data)
                        return (product.directory(inApp: bundle, destination: plan.destination), entitlements)
                    }
                }
                return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
            }
            print("Pseudo-signing...")
            if plan.app.signingMode == .adhoc {
                try await Signer.first().sign(
                    app: bundle,
                    identity: .adhoc,
                    entitlementMapping: mapping,
                    progress: { _ in }
                )
            }
        }

        return bundle
    }
}

struct DevXcodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-xcode-project",
        abstract: "Generate Xcode project",
        discussion: "This option does nothing on Linux"
    )

    @OptionGroup var productOptions: PackOperation.ProductOptions

    func run() async throws {
        try await PackOperation(
            destination: .iOS,
            product: productOptions.product,
            xcode: true
        ).run()
    }
}

struct DevBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Build app with SwiftPM",
        discussion: """
        This command builds the SwiftPM-based iOS app in the current directory
        """
    )

    @OptionGroup var packOptions: PackOperation.BuildOptions
    @OptionGroup var productOptions: PackOperation.ProductOptions

    @Flag(
        help: "Output a .ipa file instead of a .app"
    ) var ipa = false

    @OptionGroup var destinationOptions: DestinationOptions

    func run() async throws {
        let url = try await PackOperation(
            destination: try destinationOptions.resolvedDestination(),
            triple: destinationOptions.triple,
            toolchain: destinationOptions.toolchain,
            product: productOptions.product,
            buildOptions: packOptions
        ).run()

        let finalURL: URL
        if ipa {
            @Dependency(\.zipCompressor) var compressor
            finalURL = url.deletingPathExtension().appendingPathExtension("ipa")
            let tmpDir = try TemporaryDirectory(name: "Payload")
            let payloadDir = tmpDir.url
            try FileManager.default.moveItem(at: url, to: payloadDir.appendingPathComponent(url.lastPathComponent))
            let ipaURL = try await compressor.compress(directory: payloadDir) { progress in
                if let progress {
                    let percent = Int(progress * 100)
                    print("\rPackaging... \(percent)%", terminator: "")
                } else {
                    print("\rPackaging...", terminator: "")
                }
            }
            print()
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: ipaURL, to: finalURL)
        } else {
            finalURL = url
        }

        print("Wrote to \(finalURL.path)")
    }
}

struct DevRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Build and run app with SwiftPM",
        discussion: """
        This command deploys the SwiftPM-based iOS app in the current directory
        """
    )

    @OptionGroup var packOptions: PackOperation.BuildOptions
    @OptionGroup var productOptions: PackOperation.ProductOptions
    @OptionGroup var destinationOptions: DestinationOptions

    #if os(macOS)
    @Flag(
        name: .shortAndLong,
        help: "Target the iOS Simulator"
    ) var simulator = false

    #else
    #endif

    @OptionGroup var connectionOptions: ConnectionOptions

    func run() async throws {
        let destination = try resolvedDestination()
        guard destination == .iOS || destination == .iOSSimulator else {
            throw Console.Error("""
            `xtool dev run` currently supports iOS device and simulator destinations only. \
            Use `xtool dev build --destination \(destination.rawValue)` to build other Apple platforms.
            """)
        }

        let output = try await PackOperation(
            destination: destination,
            triple: destinationOptions.triple,
            toolchain: destinationOptions.toolchain,
            product: productOptions.product,
            buildOptions: packOptions
        ).run()

        #if os(macOS)
        if destination == .iOSSimulator {
            try await SimInstallOperation(path: output).run()
            return
        }
        #endif

        let token = try AuthToken.saved()

        let client = try await connectionOptions.client()
        print("Installing to device: \(client.deviceName) (udid: \(client.udid))")

        let installDelegate = XToolInstallerDelegate()
        let installer = IntegratedInstaller(
            udid: client.udid,
            lookupMode: .only(client.connectionType),
            auth: try token.authData(),
            configureDevice: false,
            delegate: installDelegate
        )

        defer { print() }

        do {
            try await installer.install(app: output)
        } catch let error as CancellationError {
            throw error
        } catch {
            print("\nError: \(error)")
            throw ExitCode.failure
        }
    }

    private func resolvedDestination() throws -> AppleDestination {
        #if os(macOS)
        if simulator {
            return .iOSSimulator
        }
        #endif
        return try destinationOptions.resolvedDestination()
    }
}

struct DevCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Build and run an xtool SwiftPM project",
        subcommands: [
            DevXcodeCommand.self,
            DevBuildCommand.self,
            DevRunCommand.self,
            DevAddExtensionCommand.self,
            DevAddAppClipCommand.self,
        ],
        defaultSubcommand: DevRunCommand.self
    )
}

extension BuildConfiguration: ExpressibleByArgument {}

#if os(macOS)
struct SimInstallOperation {
    var path: URL

    // TODO: allow customizing this
    var simulator = "booted"

    func run() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "install", simulator, path.path]
        try await process.runUntilExit()
        print("Installed to simulator")
    }
}
#endif
