import Foundation
import XKit
import SwiftyMobileDevice

struct AppRunner {
    enum Destination {
        case device(ClientDevice)
        case simulator(String)
    }

    let destination: Destination

    func installAndLaunch(app: URL, arguments: [String] = []) async throws -> String {
        let bundleID = try Self.bundleID(forApp: app)

        switch destination {
        case .device:
            throw Console.Error("installAndLaunch is only supported for simulator destinations")
        case .simulator(let simulatorID):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "install", simulatorID, app.path]
            try await process.runUntilExit()

            try await launch(bundleID: bundleID, arguments: arguments)
        }

        return bundleID
    }

    func launch(bundleID: String, arguments: [String] = []) async throws {
        switch destination {
        case .device(let client):
            let installProxy = try InstallationProxyClient(device: client.device, label: "xtool-inst")
            let executable: URL
            do {
                executable = try installProxy.executable(forBundleID: bundleID)
            } catch {
                throw Console.Error("Could not find an installed app with bundle ID '\(bundleID)'")
            }

            let debugserver = try DebugserverClient(device: client.device, label: "xtool")
            guard try debugserver.launch(executable: executable, arguments: arguments) == "OK" else {
                throw Console.Error("Launch failed (!OK)")
            }

            // iOS 17+ can fail the qLaunchSuccess query even after the process was accepted.
            _ = try? debugserver.send(command: "qLaunchSuccess", arguments: [])
            try debugserver.send(command: "D", arguments: [])
        case .simulator(let simulatorID):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl", "launch", simulatorID, bundleID] + arguments
            try await process.runUntilExit()
        }
    }

    static func bundleID(forApp app: URL) throws -> String {
        let infoURL = app.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let info = plist as? [String: Any],
            let bundleID = info["CFBundleIdentifier"] as? String else {
            throw Console.Error("Could not determine bundle ID from '\(infoURL.path)'")
        }
        return bundleID
    }
}
