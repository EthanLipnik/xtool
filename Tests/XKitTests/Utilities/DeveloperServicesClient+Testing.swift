//
//  DeveloperServicesTestClient.swift
//  XKitTests
//
//  Created by Kabir Oberai on 06/11/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import XCTest
import Dependencies
@testable import XKit

#if false

extension TCPAnisetteDataProvider {

    static func test() -> TCPAnisetteDataProvider {
        TCPAnisetteDataProvider(localPort: 4321)
    }

}

extension NetcatAnisetteDataProvider {

    static func test() -> NetcatAnisetteDataProvider {
        NetcatAnisetteDataProvider(localPort: 4322, deviceInfo: Config.current.deviceInfo)
    }

}

#endif

extension ADIDataProvider {

    static func test(storage: KeyValueStorage) throws -> ADIDataProvider {
        _ = storage
        return ADIDataProvider()
    }

}

extension GrandSlamClient {

    static func test(storage: KeyValueStorage) throws -> GrandSlamClient {
        _ = storage
        return GrandSlamClient()
    }

}

extension DeveloperServicesClient {

    static func test(storage: KeyValueStorage) throws -> DeveloperServicesClient {
        _ = storage
        return DeveloperServicesClient(loginToken: Config.current.appleID.token)
    }

}

@MainActor
func withIntegrationDependencies<R>(
    storage: KeyValueStorage,
    operation: @escaping () async throws -> R
) async throws -> R {
    let anisetteProvider = withDependencies {
        $0.keyValueStorage = storage
        $0.httpClient = HTTPClientDependencyKey.liveValue
        $0.deviceInfoProvider = DeviceInfoProvider(fetch: { Config.current.deviceInfo })
        $0.rawADIProvider = integrationRawADIProvider()
    } operation: {
        ADIDataProvider()
    }

    return try await withDependencies {
        $0.keyValueStorage = storage
        $0.httpClient = HTTPClientDependencyKey.liveValue
        $0.deviceInfoProvider = DeviceInfoProvider(fetch: { Config.current.deviceInfo })
        $0.rawADIProvider = integrationRawADIProvider()
        $0.anisetteDataProvider = anisetteProvider
    } operation: {
        try await operation()
    }
}

private func integrationRawADIProvider() -> any RawADIProvider {
    #if os(Linux)
    XADIProvider()
    #else
    OmnisetteADIProvider()
    #endif
}
