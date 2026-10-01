import XCTest
@testable import Nudge

final class AppleMessagesLinkTests: XCTestCase {
    func testDirectConversationsKeepTheOriginalRecipient() throws {
        for service in ["iMessage", "SMS", "RCS", "any"] {
            for recipient in ["+15551234567", "avery+work@example.com"] {
                let url = try XCTUnwrap(AppleMessagesLink.url(threadExternalId: "\(service);-;\(recipient)"))
                XCTAssertEqual(url.scheme, "sms")
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, recipient)
                XCTAssertNil(url.query)
                XCTAssertNil(url.fragment)
            }
        }
    }

    func testGroupLinksTargetTheExistingChatIdentifier() throws {
        for service in ["iMessage", "SMS", "RCS", "any"] {
            let url = try XCTUnwrap(AppleMessagesLink.url(threadExternalId: "\(service);+;chat123456789"))
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.scheme, "sms")
            XCTAssertEqual(components.host, "open")
            XCTAssertEqual(components.queryItems, [URLQueryItem(name: "groupid", value: "chat123456789")])
        }
    }

    func testIdentifiersCannotInjectMessageTextOrURLParameters() throws {
        let identifier = "avery&body=hello?#%+@example.com"
        let direct = try XCTUnwrap(AppleMessagesLink.url(threadExternalId: "iMessage;-;\(identifier)"))
        XCTAssertNil(direct.query)
        XCTAssertNil(direct.fragment)
        XCTAssertEqual(URLComponents(url: direct, resolvingAgainstBaseURL: false)?.path, identifier)

        let group = try XCTUnwrap(AppleMessagesLink.url(threadExternalId: "iMessage;+;\(identifier)"))
        let components = try XCTUnwrap(URLComponents(url: group, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "groupid", value: identifier)])
        XCTAssertNil(components.fragment)
    }

    func testSampleAndMalformedIdentifiersHaveNoLink() {
        for value in ["", "thread-1", "iMessage;-;", "iMessage;?;123", "other;-;123", "iMessage;-;a;b", "iMessage;-;\n123", "iMessage;-;Avery Smith"] {
            XCTAssertNil(AppleMessagesLink.url(threadExternalId: value), value)
        }
    }
}
