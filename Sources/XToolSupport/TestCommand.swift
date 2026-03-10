import ArgumentParser
import Foundation
import PackLib

private struct PackageManifestSummary: Decodable {
    let name: String
}

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run Swift package tests with Xcode's iOS simulator test flow"
    )

    @Option(
        name: .shortAndLong,
        help: "Build with configuration"
    ) var configuration: BuildConfiguration = .debug

    @Option(
        help: "Scheme to test. Defaults to '<package>-Package'."
    ) var scheme: String?

    @Option(
        name: .long,
        help: "Explicit xcodebuild destination specifier."
    ) var destination: String?

    @Option(
        name: .long,
        help: "Simulator device identifier to target."
    ) var simulatorID: String?

    @Option(
        name: .long,
        help: "Write the xcodebuild result bundle to this path."
    ) var resultBundlePath: String?

    @Flag(
        name: .long,
        help: "Enable code coverage."
    ) var enableCodeCoverage = false

    @Option(
        name: .long,
        help: "Additional xcodebuild argument. Repeat to pass multiple values."
    ) var xcodebuildArguments: [String] = []

    func run() async throws {
        #if os(macOS)
        let resolvedScheme = try await resolvedScheme()
        let resolvedDestination = destination
            ?? simulatorID.map { "platform=iOS Simulator,id=\($0)" }
            ?? "platform=iOS Simulator"

        var arguments = [
            "-scheme", resolvedScheme,
            "-configuration", configuration.rawValue,
            "-destination", resolvedDestination,
        ]

        if enableCodeCoverage {
            arguments += ["-enableCodeCoverage", "YES"]
        }
        if let resultBundlePath {
            arguments += ["-resultBundlePath", resultBundlePath]
        }

        arguments += xcodebuildArguments
        arguments.append("test")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = arguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try await process.runUntilExit()
        #else
        let buildSettings = try await BuildSettings(
            configuration: configuration,
            triple: PackOperation.defaultTriple
        )
        let process = try await buildSettings.swiftPMInvocation(
            forTool: "test",
            arguments: []
        )
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try await process.runUntilExit()
        #endif
    }

    #if os(macOS)
    private func resolvedScheme() async throws -> String {
        if let scheme {
            return scheme
        }
        return try await defaultPackageScheme()
    }

    private func defaultPackageScheme() async throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["package", "dump-package"]
        process.standardOutput = pipe
        try await process.runUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let manifest = try JSONDecoder().decode(PackageManifestSummary.self, from: data)
        return "\(manifest.name)-Package"
    }
    #endif
}
