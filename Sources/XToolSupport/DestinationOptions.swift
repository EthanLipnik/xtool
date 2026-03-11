import ArgumentParser
import PackLib

extension AppleDestination: ExpressibleByArgument {}

struct DestinationOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Build destination"
    ) var destination: AppleDestination = .iOS

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Override the target triple directly.",
            discussion: "Prefer --destination unless you need a non-default architecture."
        )
    ) var triple: String?

    @Option(
        name: .long,
        help: "Alternate toolchain identifier inside the Darwin SDK bundle"
    ) var toolchain: String?

    func resolvedDestination() throws -> AppleDestination {
        if let triple {
            return try AppleDestination(triple: triple)
        }
        return destination
    }

    func buildSettings(
        configuration: BuildConfiguration,
        packagePath: String = ".",
        options: [String] = []
    ) async throws -> BuildSettings {
        let resolvedDestination = try resolvedDestination()
        return try await BuildSettings(
            configuration: configuration,
            destination: resolvedDestination,
            triple: triple,
            packagePath: packagePath,
            toolchain: toolchain,
            options: options
        )
    }
}
