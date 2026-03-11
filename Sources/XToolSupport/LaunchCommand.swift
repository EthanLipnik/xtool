import Foundation
import XKit
import SwiftyMobileDevice
import ArgumentParser

struct LaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch an installed app"
    )

    #if os(macOS)
    @Flag(
        name: .shortAndLong,
        help: "Target the iOS Simulator instead of a connected device"
    ) var simulator = false

    @Option(
        name: .long,
        help: "Simulator device identifier to use when launching in Simulator"
    ) var simulatorID = "booted"
    #endif

    @OptionGroup var connectionOptions: ConnectionOptions

    @Argument(
        help: "The app to launch"
    ) var bundleID: String

    @Argument(
        help: .init(
            "Launch arguments to pass to the app",
            valueName: "arg"
        )
    ) var args: [String] = []

    func run() async throws {
        #if os(macOS)
        if simulator {
            try await AppRunner(destination: .simulator(simulatorID)).launch(bundleID: bundleID, arguments: args)
            return
        }
        #endif

        let client = try await connectionOptions.client()
        try await AppRunner(destination: .device(client)).launch(bundleID: bundleID, arguments: args)
    }
}
