import XCTest
@testable import Ibili

final class MessageNavigationTests: XCTestCase {
    func testVideoNotificationKeepsVideoIDAndCommentTargetSeparate() throws {
        let item = try messageItem(
            nativeURI: "bilibili://video/777?comment_root_id=888&comment_secondary_id=999"
        )

        let destination = try XCTUnwrap(MessageLinkMapper.playerDestination(for: item))
        XCTAssertEqual(destination.item.aid, 777)
        XCTAssertEqual(destination.commentTarget?.oid, 777)
        XCTAssertEqual(destination.commentTarget?.rootRpid, 888)
        XCTAssertEqual(destination.commentTarget?.replyRpid, 999)
    }

    func testCommentDetailUsesEnterURIForVideoAndPathForReply() throws {
        let enterURI = "bilibili://video/BV1abc123456"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let item = try messageItem(
            nativeURI: "bilibili://comment/detail/1/123/456/?anchor=789&enterUri=\(enterURI)"
        )

        let destination = try XCTUnwrap(MessageLinkMapper.playerDestination(for: item))
        XCTAssertEqual(destination.item.aid, 123)
        XCTAssertEqual(destination.item.bvid, "BV1abc123456")
        XCTAssertEqual(destination.commentTarget?.rootRpid, 456)
        XCTAssertEqual(destination.commentTarget?.replyRpid, 789)
    }

    func testReplyStructuredSubjectOverridesNativeVideoOID() throws {
        let item = try messageItem(
            nativeURI: "bilibili://video/999?comment_root_id=456",
            subjectID: 123,
            businessID: 1
        )

        let destination = try XCTUnwrap(MessageLinkMapper.playerDestination(for: item))
        XCTAssertEqual(destination.item.aid, 123)
        XCTAssertEqual(destination.commentTarget?.oid, 123)
    }

    func testBVPathDigitsAreNotMistakenForAnAid() throws {
        let item = try messageItem(nativeURI: "bilibili://video/BV1abc123456")

        let destination = try XCTUnwrap(MessageLinkMapper.playerDestination(for: item))
        XCTAssertEqual(destination.item.aid, 0)
        XCTAssertEqual(destination.item.bvid, "BV1abc123456")
    }

    private func messageItem(
        nativeURI: String,
        subjectID: Int64? = nil,
        businessID: Int64? = nil
    ) throws -> MessageItemDTO {
        var json: [String: Any] = [
            "id": "1",
            "kind": "reply",
            "user_mid": 2,
            "user_name": "user",
            "user_avatar": "",
            "action": "reply",
            "title": "",
            "content": "",
            "secondary_content": "",
            "image": "",
            "native_uri": nativeURI,
            "timestamp": 0,
            "time_text": "",
            "count": 1,
        ]
        if let subjectID { json["subject_id"] = subjectID }
        if let businessID { json["business_id"] = businessID }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(MessageItemDTO.self, from: data)
    }
}
