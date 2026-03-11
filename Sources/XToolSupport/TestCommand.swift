import ArgumentParser
import Foundation
import PackLib

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Build or run Swift package tests for an Apple destination"
    )

    @Option(
        name: .shortAndLong,
        help: "Build with configuration"
    ) var configuration: BuildConfiguration = .debug

    @Flag(
        name: .long,
        help: "Enable code coverage."
    ) var enableCodeCoverage = false

    @Option(
        name: .long,
        help: "Only run tests whose names match the given filter."
    ) var filter: String?

    @OptionGroup var destinationOptions: DestinationOptions

    func run() async throws {
        let buildSettings = try await destinationOptions.buildSettings(configuration: configuration)
        let process: Process

        if canRunTestsNatively(using: buildSettings) {
            var arguments: [String] = []
            if enableCodeCoverage {
                arguments.append("--enable-code-coverage")
            }
            if let filter {
                arguments += ["--filter", filter]
            }
            process = try await buildSettings.swiftPMInvocation(
                forTool: "test",
                arguments: arguments
            )
        } else {
            if enableCodeCoverage {
                print("warning: code coverage is only available when tests can run natively")
            }
            if let filter {
                print("warning: test filtering is ignored when only compiling test bundles")
                _ = filter
            }
            process = try await buildSettings.swiftPMInvocation(
                forTool: "build",
                arguments: ["--build-tests"]
            )
            print("Building test bundles for \(buildSettings.destination.rawValue)...")
        }

        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try await process.runUntilExit()

        if !canRunTestsNatively(using: buildSettings) {
            print("Built tests for \(buildSettings.destination.rawValue); execution is not supported yet.")
        }
    }

    private func canRunTestsNatively(using buildSettings: BuildSettings) -> Bool {
        guard buildSettings.destination == .macOS,
            let hostArchitecture = AppleDestination.currentHostArchitecture()
        else {
            return false
        }

        let tripleComponents = buildSettings.triple.split(separator: "-")
        guard let architecture = tripleComponents.first else {
            return false
        }
        return architecture == hostArchitecture
    }
}
