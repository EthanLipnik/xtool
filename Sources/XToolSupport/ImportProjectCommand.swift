import ArgumentParser
import Foundation
import PackLib

struct ImportProjectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-project",
        abstract: "Import supported Xcode target metadata into xtool.yml"
    )

    @Argument(
        help: "Path to a .xcodeproj or .xcworkspace"
    ) var input: String

    @Option(
        name: .long,
        help: "Build configuration to inspect while importing settings"
    ) var configurationName: String?

    @Option(
        name: .shortAndLong,
        help: "Output path for the generated xtool.yml"
    ) var output = "xtool.yml"

    @Flag(
        name: .long,
        help: "Overwrite the output file if it already exists"
    ) var overwrite = false

    func run() async throws {
        let outputURL = URL(fileURLWithPath: output)
        if outputURL.exists && !overwrite {
            throw Console.Error("Refusing to overwrite existing file at '\(outputURL.path)'. Pass --overwrite to replace it.")
        }

        let result = try XcodeProjectImporter().importSchema(
            from: URL(fileURLWithPath: input),
            configurationName: configurationName
        )
        let yaml = try result.schema.encodedYAML()
        try yaml.write(to: outputURL, atomically: true, encoding: .utf8)

        result.warnings.forEach { print($0) }
        print("Wrote imported project metadata to \(outputURL.path)")
    }
}
