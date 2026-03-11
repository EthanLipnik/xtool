import ArgumentParser
import Dependencies
import Foundation
import PackLib
import XUtils

private struct BuiltAppInfo {
    let bundleID: String
    let version: String
    let shortVersion: String
    let name: String

    init(appURL: URL) throws {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let info = plist as? [String: Any] else {
            throw Console.Error("Archive Info.plist must be a dictionary")
        }

        guard let bundleID = info["CFBundleIdentifier"] as? String else {
            throw Console.Error("Archive is missing CFBundleIdentifier")
        }

        self.bundleID = bundleID
        version = info["CFBundleVersion"] as? String ?? "1"
        shortVersion = info["CFBundleShortVersionString"] as? String ?? version
        name = info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? appURL.deletingPathExtension().lastPathComponent
    }
}

struct ArchiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Build a release archive for the current xtool project"
    )

    @Option(
        name: .shortAndLong,
        help: "Build with configuration"
    ) var configuration: BuildConfiguration = .release
    @OptionGroup var productOptions: PackOperation.ProductOptions
    @OptionGroup var destinationOptions: DestinationOptions

    @Option(
        help: "Archive output path"
    ) var output: String?

    func run() async throws {
        let appURL = try await PackOperation(
            destination: try destinationOptions.resolvedDestination(),
            triple: destinationOptions.triple,
            toolchain: destinationOptions.toolchain,
            product: productOptions.product,
            buildOptions: .init(configuration: configuration)
        ).run()

        let appInfo = try BuiltAppInfo(appURL: appURL)
        let archiveName = appURL.deletingPathExtension().lastPathComponent + ".xcarchive"
        let archiveURL = URL(fileURLWithPath: output ?? "xtool/\(archiveName)")
        try? FileManager.default.removeItem(at: archiveURL)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)

        let applicationsURL = archiveURL
            .appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationsURL, withIntermediateDirectories: true)

        let archivedAppURL = applicationsURL.appendingPathComponent(appURL.lastPathComponent)
        try FileManager.default.copyItem(at: appURL, to: archivedAppURL)

        let archiveInfo: [String: Any] = [
            "ApplicationProperties": [
                "ApplicationPath": "Applications/\(appURL.lastPathComponent)",
                "CFBundleIdentifier": appInfo.bundleID,
                "CFBundleShortVersionString": appInfo.shortVersion,
                "CFBundleVersion": appInfo.version,
            ],
            "ArchiveVersion": 2,
            "CreationDate": Date(),
            "Name": appInfo.name,
            "SchemeName": appInfo.name,
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: archiveInfo, format: .xml, options: 0)
        try infoData.write(to: archiveURL.appendingPathComponent("Info.plist"))

        print("Wrote archive to \(archiveURL.path)")
    }
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export an ipa from an xtool archive or app bundle"
    )

    @Argument(
        help: "Path to a .xcarchive or .app bundle"
    ) var input: String

    @Option(
        help: "ipa output path"
    ) var output: String?

    func run() async throws {
        let finalURL = try await Self.exportIPA(
            from: URL(fileURLWithPath: input),
            output: output.map(URL.init(fileURLWithPath:))
        )
        print("Wrote ipa to \(finalURL.path)")
    }

    static func archiveApp(at sourceURL: URL) throws -> URL {
        if sourceURL.pathExtension == "app" {
            return sourceURL
        }

        guard sourceURL.pathExtension == "xcarchive" else {
            throw Console.Error("Expected a .xcarchive or .app input")
        }

        let applicationsURL = sourceURL
            .appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        guard let appURL = applicationsURL.implicitContents.first(where: { $0.pathExtension == "app" }) else {
            throw Console.Error("Archive does not contain an app bundle")
        }
        return appURL
    }

    static func exportIPA(from sourceURL: URL, output: URL? = nil) async throws -> URL {
        let appURL = try archiveApp(at: sourceURL)

        @Dependency(\.zipCompressor) var compressor
        let payloadDirectory = try TemporaryDirectory(name: "Payload")
        let payloadURL = payloadDirectory.url
        try FileManager.default.createDirectory(at: payloadURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: appURL, to: payloadURL.appendingPathComponent(appURL.lastPathComponent))

        let ipaURL = try await compressor.compress(directory: payloadURL) { _ in }
        let finalURL = output ?? sourceURL.deletingPathExtension().appendingPathExtension("ipa")
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: ipaURL, to: finalURL)

        withExtendedLifetime(payloadDirectory) {}
        return finalURL
    }
}

struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload an ipa or archive to App Store Connect"
    )

    @Argument(
        help: "Path to a .ipa, .xcarchive, or .app bundle"
    ) var input: String

    @Flag(
        help: "Wait for processing state after upload"
    ) var wait = false

    func run() async throws {
        #if os(macOS)
        let token = try AuthToken.saved()
        guard case .appStoreConnect(let auth) = token else {
            throw Console.Error("`xtool upload` requires App Store Connect API key auth (`xtool auth --mode key`).")
        }

        let ipaURL: URL
        let inputURL = URL(fileURLWithPath: input)
        switch inputURL.pathExtension {
        case "ipa":
            ipaURL = inputURL
        case "xcarchive", "app":
            ipaURL = try await ExportCommand.exportIPA(from: inputURL)
        default:
            throw Console.Error("Expected a .ipa, .xcarchive, or .app input")
        }

        let keyDirectory = try TemporaryDirectory(name: "asc-key")
        let keyURL = keyDirectory.url.appendingPathComponent("AuthKey_\(auth.id).p8")
        try auth.pem.write(to: keyURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "altool",
            "--upload-package", ipaURL.path,
            "--api-key", auth.id,
            "--api-issuer", auth.issuerID,
            "--p8-file-path", keyURL.path,
            "--output-format", "normal",
            "--show-progress",
        ] + (wait ? ["--wait"] : [])
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try await process.runUntilExit()

        withExtendedLifetime(keyDirectory) {}
        #else
        throw Console.Error("`xtool upload` is only supported on macOS right now.")
        #endif
    }
}
