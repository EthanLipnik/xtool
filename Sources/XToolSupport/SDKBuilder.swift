import Foundation
import Dependencies
import SystemPackage
import libunxip
import XKit // HTTPClient, stdoutSafe
import PackLib // ToolRegistry

struct SDKBuilder {
    static let defaultToolchain = "XcodeDefault.xctoolchain"

    struct PlatformSpec: Sendable {
        let platform: String
        let sdkPrefix: String
        let targetTriples: [String]
    }

    enum Arch: String {
        case x86_64
        case aarch64
    }

    enum Input {
        case xip(String)
        case app(String)

        init(path: String) throws {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
                throw Console.Error("""
                Could not read file or directory at path '\(path)'.
                  See 'xtool help sdk' for usage.
                """)
            }

            let url = URL(fileURLWithPath: path)

            if isDir.boolValue {
                self = .app(path)
                let devDir = url.appendingPathComponent("Contents/Developer")
                guard devDir.dirExists else {
                    throw Console.Error("""
                    The provided directory at '\(path)' does not appear to be a version of Xcode: \
                    could not read '\(devDir.path)'.
                    """)
                }
            } else {
                self = .xip(path)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }

                let expectedMagic = "xar!".utf8
                let actualMagic = try handle.read(upToCount: expectedMagic.count) ?? Data()

                guard actualMagic.elementsEqual(expectedMagic) else {
                    throw Console.Error("""
                    The file at '\(path)' does not appear to be a valid XIP file.
                    """)
                }
            }
        }
    }

    static let platformSpecs: [PlatformSpec] = [
        .init(
            platform: "iPhoneOS",
            sdkPrefix: "iPhoneOS",
            targetTriples: ["arm64-apple-ios"]
        ),
        .init(
            platform: "iPhoneSimulator",
            sdkPrefix: "iPhoneSimulator",
            targetTriples: ["arm64-apple-ios-simulator", "x86_64-apple-ios-simulator"]
        ),
        .init(
            platform: "AppleTVOS",
            sdkPrefix: "AppleTVOS",
            targetTriples: ["arm64-apple-tvos"]
        ),
        .init(
            platform: "AppleTVSimulator",
            sdkPrefix: "AppleTVSimulator",
            targetTriples: ["arm64-apple-tvos-simulator", "x86_64-apple-tvos-simulator"]
        ),
        .init(
            platform: "WatchOS",
            sdkPrefix: "WatchOS",
            targetTriples: ["arm64_32-apple-watchos", "arm64-apple-watchos"]
        ),
        .init(
            platform: "WatchSimulator",
            sdkPrefix: "WatchSimulator",
            targetTriples: ["arm64-apple-watchos-simulator", "x86_64-apple-watchos-simulator"]
        ),
        .init(
            platform: "XROS",
            sdkPrefix: "XROS",
            targetTriples: ["arm64-apple-xros"]
        ),
        .init(
            platform: "XRSimulator",
            sdkPrefix: "XRSimulator",
            targetTriples: ["arm64-apple-xros-simulator", "x86_64-apple-xros-simulator"]
        ),
        .init(
            platform: "MacOSX",
            sdkPrefix: "MacOSX",
            targetTriples: ["arm64-apple-macosx", "x86_64-apple-macosx"]
        ),
    ]

    let input: Input
    let outputPath: String
    let arch: Arch
    let toolchain: String

    init(
        input: Input,
        outputPath: String,
        arch: Arch,
        toolchain: String = SDKBuilder.defaultToolchain
    ) {
        self.input = input
        self.outputPath = outputPath
        self.arch = arch
        self.toolchain = toolchain
    }

    @discardableResult
    func buildSDK() async throws -> String {
        let sdkVersion = "develop"
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            .appendingPathComponent("darwin.artifactbundle")

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(
            at: output,
            withIntermediateDirectories: true
        )

        try await installToolset(in: output)
        let dev = try await installDeveloper(in: output)

        func sdkName(for spec: PlatformSpec) throws -> String {
            let regex = try NSRegularExpression(pattern: #"^\#(spec.sdkPrefix)\d+\.\d+\.sdk$"#)
            let dir = dev.appendingPathComponent("Platforms/\(spec.platform).platform/Developer/SDKs")
            let names = try dir.contents().map(\.lastPathComponent)
            guard let name = names.first(where: {
                regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
            }) else {
                throw Console.Error("Could not find SDK for \(spec.platform)")
            }
            return name
        }

        func triple(spec: PlatformSpec, sdk: String) -> SDKDefinition.Triple {
            let toolchainRoot = "Developer/Toolchains/\(toolchain)"
            return SDKDefinition.Triple(
                sdkRootPath: "Developer/Platforms/\(spec.platform).platform/Developer/SDKs/\(sdk)",
                includeSearchPaths: ["Developer/Platforms/\(spec.platform).platform/Developer/usr/lib"],
                librarySearchPaths: ["Developer/Platforms/\(spec.platform).platform/Developer/usr/lib"],
                swiftResourcesPath: "\(toolchainRoot)/usr/lib/swift",
                swiftStaticResourcesPath: "\(toolchainRoot)/usr/lib/swift_static",
                toolsetPaths: ["toolset.json"]
            )
        }

        var targetTriples: [String: SDKDefinition.Triple] = [:]
        var resolvedSDKs: [String] = []
        var resolvedSDKNames: [String: String] = [:]
        for spec in Self.platformSpecs {
            let sdk = try sdkName(for: spec)
            resolvedSDKs.append("\(spec.platform): \(sdk)")
            resolvedSDKNames[spec.platform] = sdk
            for tripleName in spec.targetTriples {
                targetTriples[tripleName] = triple(spec: spec, sdk: sdk)
            }
        }

        try finalizeDeveloper(at: dev, resolvedSDKNames: resolvedSDKNames)

        print(resolvedSDKs.map { "- \($0)" }.joined(separator: "\n"))
        print("[Writing metadata]")

        try """
        {
            "schemaVersion": "1.0",
            "artifacts": {
                "darwin": {
                    "type": "swiftSDK",
                    "version": "0.0.1",
                    "variants": [
                        {
                            "path": ".",
                            "supportedTriples": ["aarch64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"]
                        }
                    ]
                }
            }
        }
        """.write(
            to: output.appendingPathComponent("info.json"),
            atomically: false,
            encoding: .utf8
        )

        try """
        {
            "schemaVersion": "1.0",
            "rootPath": "toolset/bin",
            "linker": {
                "path": "ld64.lld"
            },
            "swiftCompiler": {
                "extraCLIOptions": [
                    "-Xfrontend", "-enable-cross-import-overlays",
                    "-use-ld=lld"
                ]
            }
        }
        """.write(
            to: output.appendingPathComponent("toolset.json"),
            atomically: false,
            encoding: .utf8
        )

        let encoder = JSONEncoder()
        try encoder
            .encode(SDKDefinition(schemaVersion: "4.0", targetTriples: targetTriples))
            .write(to: output.appendingPathComponent("swift-sdk.json"))

        let metadata = SDKToolchainMetadata(
            toolchain: toolchain,
            swiftVersion: try await Self.currentSwiftVersionString(),
            supportedTriples: Self.platformSpecs.flatMap(\.targetTriples)
        )
        try encoder
            .encode(metadata)
            .write(to: output.appendingPathComponent("xtool-toolchain.json"))

        try Data("\(sdkVersion)\n".utf8)
            .write(to: output.appendingPathComponent("darwin-sdk-version.txt"))

        return output.path
    }

    private static func currentSwiftVersionString() async throws -> String {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = try await ToolRegistry.locate("swift")
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        try await process.runUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func installToolset(in output: URL) async throws {
        let darwinToolsVersion = "1.0.1"
        let toolsetDir = output.appendingPathComponent("toolset")

        try FileManager.default.createDirectory(
            at: toolsetDir,
            withIntermediateDirectories: false
        )

        let pipe = Pipe()
        let untar = Process()
        untar.currentDirectoryURL = toolsetDir
        untar.executableURL = try await ToolRegistry.locate("tar")
        untar.arguments = ["xzf", "-"]
        untar.standardInput = pipe.fileHandleForReading
        async let tarExit: Void = untar.runUntilExit()

        @Dependency(\.httpClient) var httpClient
        let url = URL(string: """
        https://github.com/xtool-org/darwin-tools-linux-llvm/releases/download/\
        v\(darwinToolsVersion)/toolset-\(arch.rawValue).tar.gz
        """)!
        let (response, body) = try await httpClient.send(HTTPRequest(url: url))
        guard response.status == 200, let body else { throw Console.Error("Could not fetch toolset") }
        let length: Int64? = switch body.length {
        case .known(let known): known
        case .unknown: nil
        }
        let writer = pipe.fileHandleForWriting
        var written: Int64 = 0
        do {
            defer { try? writer.close() }
            for try await chunk in body {
                try writer.write(contentsOf: chunk)
                written += Int64(chunk.count)
                if let length {
                    let progress = Int(Double(written) / Double(length) * 100)
                    print("\r[Downloading toolset] \(progress)%", terminator: "")
                    fflush(stdoutSafe)
                }
            }
        }
        print()
        try await tarExit
    }

    private func installDeveloper(in output: URL) async throws -> URL {
        let dev = output.appendingPathComponent("Developer")

        let appDir: URL
        let cleanupStageDir: URL?
        let wanted: Int?

        switch input {
        case .xip(let inputPath):
            let devStage = output.appendingPathComponent("DeveloperStage")
            try FileManager.default.createDirectory(at: devStage, withIntermediateDirectories: false)
            wanted = try await Task {
                try await extractXIP(inputPath: inputPath, outDir: devStage.path)
            }.value
            try Task.checkCancellation()
            let contents = try FileManager.default.contentsOfDirectory(
                at: devStage,
                includingPropertiesForKeys: nil
            )
            let apps = contents.filter { $0.pathExtension == "app" }
            switch apps.count {
            case 0:
                throw Console.Error("Unrecognized xip layout (Xcode.app not found)")
            case 1:
                appDir = apps[0]
            default:
                throw Console.Error("Unrecognized xip layout (multiple apps found)")
            }
            cleanupStageDir = devStage
        case .app(let appPath):
            wanted = nil
            appDir = URL(fileURLWithPath: appPath)
            cleanupStageDir = nil
        }

        let selectedToolchain = appDir.appendingPathComponent("Contents/Developer/Toolchains/\(toolchain)")
        guard selectedToolchain.dirExists else {
            throw Console.Error("Could not locate toolchain '\(toolchain)' inside '\(appDir.path)'")
        }

        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: false)

        var toDoDirs: [String] = ["Contents/Developer"]
        var count = 0
        let platforms = Set(Self.platformSpecs.map(\.platform))

        while let next = toDoDirs.popLast() {
            try Task.checkCancellation()

            let url = appDir.appendingPathComponent(next)
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            for child in contents {
                let path = "\(next)/\(child.lastPathComponent)"
                guard Self.isWanted(path[...], toolchain: toolchain, platforms: platforms) else { continue }

                count += 1
                if let wanted {
                    let progress = Int(Double(count) / Double(wanted) * 100)
                    print("\r[Installing SDKs] \(progress)%", terminator: "")
                    fflush(stdoutSafe)
                } else if count % 100 == 0 {
                    print("\r[Installing SDKs] Copied \(count) files", terminator: "")
                    fflush(stdoutSafe)
                    await Task.yield()
                }

                let insideDeveloper = path.dropFirst("Contents/Developer/".count)
                guard !insideDeveloper.isEmpty else { continue }
                let dest = dev.appendingPathComponent(String(insideDeveloper))

                if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    toDoDirs.append(path)
                    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
                } else {
                    try FileManager.default.copyItem(at: child, to: dest)
                }
            }
        }

        if wanted != nil {
            print("\r[Installing SDKs] 100%", terminator: "")
        }
        print()

        print("[Cleaning up]")
        if let cleanupStageDir {
            try? FileManager.default.removeItem(at: cleanupStageDir)
        }

        return dev
    }

    private func finalizeDeveloper(at dev: URL, resolvedSDKNames: [String: String]) throws {
        print("[Finalizing SDKs]")

        for platform in Self.platformSpecs.map(\.platform) {
            guard let sdkName = resolvedSDKNames[platform] else {
                throw Console.Error("Could not resolve finalized SDK name for \(platform)")
            }

            let lib = "../../../../../Library"
            let dest = dev.appendingPathComponent("""
            Platforms/\(platform).platform/Developer/SDKs/\(sdkName)\
            /System/Library/Frameworks
            """).path

            try FileManager.default.createSymbolicLink(
                atPath: "\(dest)/Testing.framework",
                withDestinationPath: "\(lib)/Frameworks/Testing.framework"
            )

            try FileManager.default.createSymbolicLink(
                atPath: "\(dest)/XCTest.framework",
                withDestinationPath: "\(lib)/Frameworks/XCTest.framework"
            )

            try FileManager.default.createSymbolicLink(
                atPath: "\(dest)/XCUIAutomation.framework",
                withDestinationPath: "\(lib)/Frameworks/XCUIAutomation.framework"
            )

            try FileManager.default.createSymbolicLink(
                atPath: "\(dest)/XCTestCore.framework",
                withDestinationPath: "\(lib)/PrivateFrameworks/XCTestCore.framework"
            )
        }
    }

    private func extractXIP(inputPath: String, outDir: String) async throws -> Int {
        let fd = try FileDescriptor.open(inputPath, .readOnly)
        defer { try? fd.close() }

        let length = try fd.seek(offset: 0, from: .end)
        try fd.seek(offset: 0, from: .start)

        let oldDirectory = FileManager.default.currentDirectoryPath
        guard FileManager.default.changeCurrentDirectoryPath(outDir) else {
            throw Console.Error("Could not change directory to '\(outDir)'")
        }
        defer { _ = FileManager.default.changeCurrentDirectoryPath(oldDirectory) }

        let inputStream = DataReader.data(readingFrom: fd.rawValue)
        let (observer, source) = inputStream.lockstepSplit()

        async let readTask: Void = {
            var read = 0
            for try await chunk in observer {
                read += chunk.count
                let progress = Int(Double(read) / Double(length) * 100)
                print("\r[Extracting XIP] \(progress)%", terminator: "")
                fflush(stdoutSafe)
                if read == length { break }
            }
        }()

        let xipToChunks = XIP.transform(
            DataReader(data: source),
            options: nil
        )
        let chunksToFiles = Chunks.transform(
            xipToChunks,
            options: nil
        )
        let filesToDisk = Files.transform(
            chunksToFiles,
            options: .init(
                compress: false,
                dryRun: false
            )
        )

        let platforms = Set(Self.platformSpecs.map(\.platform))
        var wanted = 0
        for try await file in filesToDisk {
            wanted += Self.isWanted(file.name[...], toolchain: toolchain, platforms: platforms) ? 1 : 0
        }
        _ = try await readTask

        print()

        return wanted
    }

    private static func isWanted(
        _ path: Substring,
        toolchain: String,
        platforms: Set<String>
    ) -> Bool {
        var components = path.split(separator: "/")[...]
        if components.first == "." {
            components.removeFirst()
        }
        if components.first?.hasSuffix(".app") == true {
            components.removeFirst()
        }
        return SDKEntry.wanted(toolchain: toolchain, platforms: platforms).matches(components)
    }
}

struct SDKDefinition: Encodable {
    struct Triple: Encodable {
        var sdkRootPath: String
        var includeSearchPaths: [String]
        var librarySearchPaths: [String]
        var swiftResourcesPath: String
        var swiftStaticResourcesPath: String
        var toolsetPaths: [String]
    }
    var schemaVersion: String
    var targetTriples: [String: Triple]
}

struct SDKToolchainMetadata: Codable, Sendable {
    var toolchain: String
    var swiftVersion: String
    var supportedTriples: [String]
}

struct SDKEntry {
    var names: Set<Substring>
    var values: [SDKEntry] = []

    init(_ names: Set<Substring>, _ values: [SDKEntry] = []) {
        self.names = names
        self.values = values
    }

    init(_ name: Substring, _ values: [SDKEntry] = []) {
        self.init([name], values)
    }

    func matches(_ path: ArraySlice<Substring>) -> Bool {
        guard let first = path.first else { return true }
        guard names.isEmpty || names.contains(first) else { return false }
        if values.isEmpty { return true }
        let afterName = path.dropFirst()
        for value in values where value.matches(afterName) {
            return true
        }
        return false
    }

    static func E(_ name: Substring?, _ values: [SDKEntry] = []) -> SDKEntry {
        guard let name else { return SDKEntry([], values) }
        let parts = name.split(separator: "/").reversed()
        return parts.dropFirst().reduce(SDKEntry(parts.first!, values)) { SDKEntry($1, [$0]) }
    }

    static func wanted(toolchain: String, platforms: Set<String>) -> SDKEntry {
        E("Contents/Developer", [
            E("Toolchains/\(toolchain)/usr", [
                E("lib", [
                    E("swift"),
                    E("swift_static"),
                    E("clang"),
                ]),
                E("bin", [
                    E("swift-plugin-server"),
                ]),
            ]),
            E("Platforms", platforms.sorted().map {
                E("\($0).platform/Developer", [
                    E("SDKs"),
                    E("Library", [
                        E("Frameworks"),
                        E("PrivateFrameworks"),
                    ]),
                    E("usr/lib"),
                ])
            }),
        ])
    }
}
