import XCTest
@testable import AICreditsApp

final class GeminiProviderTests: XCTestCase {
    func testBillingTableValidation() {
        XCTAssertTrue(GeminiBigQueryProvider.isValidTableName("my-project.billing.gcp_billing_export_v1_ABC_123"))
        XCTAssertFalse(GeminiBigQueryProvider.isValidTableName("project.dataset"))
        XCTAssertFalse(GeminiBigQueryProvider.isValidTableName("project.dataset.table`; DROP TABLE x"))
    }

    func testParsesBigQueryCostResponse() throws {
        let json = #"""
        {
          "jobComplete": true,
          "schema": {"fields": [{"name":"gross_cost"},{"name":"currency"}]},
          "rows": [{"f": [{"v":"42.75"},{"v":"USD"}]}]
        }
        """#
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = try GeminiBigQueryProvider.parseBillingResponse(Data(json.utf8), fetchedAt: date)
        XCTAssertEqual(usage.platform, .gemini)
        XCTAssertEqual(usage.cumulativeCost, Decimal(string: "42.75"))
        XCTAssertEqual(usage.currency, "USD")
        XCTAssertEqual(usage.fetchedAt, date)
    }

    func testRejectsIncompleteQuery() {
        let json = #"{"jobComplete":false}"#
        XCTAssertThrowsError(try GeminiBigQueryProvider.parseBillingResponse(Data(json.utf8), fetchedAt: .now)) { error in
            XCTAssertEqual(error.localizedDescription, GoogleCloudError.queryTimedOut.localizedDescription)
        }
    }

    func testServiceAccountDecoding() throws {
        let json = #"""
        {
          "project_id":"billing-project",
          "client_email":"reader@billing-project.iam.gserviceaccount.com",
          "private_key":"-----BEGIN PRIVATE KEY-----\ninvalid\n-----END PRIVATE KEY-----\n",
          "token_uri":"https://oauth2.googleapis.com/token"
        }
        """#
        let account = try JSONDecoder().decode(GoogleServiceAccount.self, from: Data(json.utf8))
        XCTAssertEqual(account.projectID, "billing-project")
        XCTAssertEqual(account.clientEmail, "reader@billing-project.iam.gserviceaccount.com")
    }

    func testImportsPKCS8ServiceAccountPrivateKey() throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let keyData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let pem = try XCTUnwrap(String(data: keyData, encoding: .utf8))
        XCTAssertNotNil(GeminiBigQueryProvider.privateKey(fromPEM: pem))
    }

    func testRejectsUntrustedTokenEndpointsBeforeSigningOrNetwork() async throws {
        let fixture = HTTPFixture([])
        let provider = GeminiBigQueryProvider(client: fixture.makeClient())
        for endpoint in [
            "https://example.invalid/token",
            "http://oauth2.googleapis.com/token",
            "https://oauth2.googleapis.com.example.invalid/token",
            "https://oauth2.googleapis.com/token?redirect=example.invalid",
            "https://[invalid"
        ] {
            let json = try JSONSerialization.data(withJSONObject: [
                "project_id": "billing-project",
                "client_email": "reader@billing-project.iam.gserviceaccount.com",
                "private_key": "invalid-test-key",
                "token_uri": endpoint
            ])
            do {
                _ = try await provider.fetchUsage(
                    serviceAccountJSON: String(decoding: json, as: UTF8.self),
                    billingTable: "billing-project.billing.costs",
                    since: .now
                )
                XCTFail("Untrusted token endpoint was accepted")
            } catch GoogleCloudError.invalidServiceAccount {
                // The imported endpoint is rejected before trying the invalid key.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }
}
