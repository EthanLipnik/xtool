import Foundation
import Testing
@testable import PackLib

@Test func importSupportInfersOrganizationIdentifier() {
    #expect(XcodeProjectImportSupport.organizationIdentifier(
        from: ["com.example.PhoneApp", "com.example.PhoneApp.Widget"]
    ) == "com.example")
    #expect(XcodeProjectImportSupport.organizationIdentifier(from: ["PhoneApp"]) == nil)
}

@Test func importSupportExpandsCommonBuildSettingMacros() {
    let projectDirectoryURL = URL(fileURLWithPath: "/tmp/MyProject")
    let expanded = XcodeProjectImportSupport.expand(
        "com.example.$(PRODUCT_NAME:rfc1034identifier).$(TARGET_NAME)",
        projectDirectoryURL: projectDirectoryURL,
        targetName: "Widget Extension",
        productName: "Phone App"
    )

    #expect(expanded == "com.example.phone-app.Widget Extension")
}

@Test func importSupportSkipsCompiledResources() {
    let currentDirectoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)

    #expect(XcodeProjectImportSupport.importableResourcePath(
        for: URL(fileURLWithPath: "/tmp/Resources/GoogleService-Info.plist"),
        currentDirectoryURL: currentDirectoryURL
    ) == "Resources/GoogleService-Info.plist")

    #expect(XcodeProjectImportSupport.importableResourcePath(
        for: URL(fileURLWithPath: "/tmp/Base.lproj/Main.storyboard"),
        currentDirectoryURL: currentDirectoryURL
    ) == nil)

    #expect(XcodeProjectImportSupport.importableResourcePath(
        for: URL(fileURLWithPath: "/tmp/Resources/App.xcassets"),
        currentDirectoryURL: currentDirectoryURL
    ) == nil)
}
