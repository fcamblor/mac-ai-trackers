import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("KeychainDiagnosticReport")
struct KeychainDiagnosticReportTests {
    @Test("pinnable OAuth entries must be addressable by account")
    func pinnableRequiresAccount() {
        let expiry = Date(timeIntervalSince1970: 1_715_000_000)
        let report = KeychainDiagnosticReport(
            credentialsServiceName: ClaudeTUICredentialLocator.defaultKeychainService,
            apiKeyServiceName: ClaudeTUICredentialLocator.apiKeyKeychainService,
            entries: [
                KeychainDiagnosticReport.Entry(account: nil, status: .expiredOAuthToken(expiresAt: expiry)),
                KeychainDiagnosticReport.Entry(account: "", status: .validOAuthToken(expiresAt: nil)),
            ],
            apiKeyDetected: false
        )

        #expect(report.hasPinnableOAuthEntry == false)
    }

    @Test("expired OAuth entry with account is pinnable")
    func expiredOAuthWithAccountIsPinnable() {
        let expiry = Date(timeIntervalSince1970: 1_715_000_000)
        let report = KeychainDiagnosticReport(
            credentialsServiceName: ClaudeTUICredentialLocator.defaultKeychainService,
            apiKeyServiceName: ClaudeTUICredentialLocator.apiKeyKeychainService,
            entries: [
                KeychainDiagnosticReport.Entry(account: "juherr", status: .expiredOAuthToken(expiresAt: expiry)),
            ],
            apiKeyDetected: false
        )

        #expect(report.hasPinnableOAuthEntry == true)
    }
}
