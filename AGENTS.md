# Repository Guidelines

## Project Structure & Module Organization
`Package.swift` defines the workspace. Core platform logic lives in `Sources/XKit`, CLI-facing commands in `Sources/XToolSupport`, the executable entrypoint in `Sources/xtool`, packaging helpers in `Sources/PackLib`, and shared utilities in `Sources/XUtils`. Generated OpenAPI client code lives in `Sources/DeveloperAPI/Generated`; regenerate it instead of editing it by hand. Tests are split between `Tests/XKitTests` and `Tests/XToolTests`. Docs live in `Documentation/xtool.docc`; platform-specific assets and build scaffolding live under `macOS/` and `Linux/`.

## Build, Test, and Development Commands
Use `make` for the default host build: it routes to `make mac` on macOS and `make linux` elsewhere. Use `swift build --product xtool` for a fast SwiftPM-only build, and `swift test` to run the package test suite. Run `make lint` before opening a PR; CI treats SwiftLint warnings as failures. For docs, use `make docs-preview`. For Linux container work, `docker compose run --build --rm xtool bash` gives you a reproducible shell, and `make linux-dist` builds the AppImage.

## Coding Style & Naming Conventions
Follow SwiftLint in `.swiftlint.yml`: use four spaces, not tabs, and keep lines under 135 characters. Types use `UpperCamelCase`; methods, properties, and local values use `lowerCamelCase`. Prefer small focused extensions and keep generated code isolated. Do not edit `Sources/DeveloperAPI/Generated` directly; use `make api` or `make update-api`.

## Testing Guidelines
This repo uses both Swift Testing (`import Testing`) and XCTest. Add tests beside the affected module and follow the existing naming pattern, for example `XKitSigningTests.swift` or `testListTeams()`. No formal coverage threshold is enforced, but new behavior should ship with regression coverage. If a change is platform-sensitive, test on macOS and Linux when possible.

## Commit & Pull Request Guidelines
Match the existing history: short imperative commit subjects such as `Validate SDK before overwriting`, with optional issue or PR references like `(#192)`. PRs should explain the behavioral change, link the relevant issue, and call out platform validation performed. Include screenshots or terminal output when changing docs, CLI UX, or generated artifacts.

## Security & Configuration Tips
Never commit credentials, team IDs, or local config overrides. `macOS/Support/Private-Team.xcconfig` is machine-local setup. Report security issues through GitHub Security Advisories, not public issues.
