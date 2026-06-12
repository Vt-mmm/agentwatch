import XCTest
@testable import ClaudeWatchCore

final class PromptScorerTests: XCTestCase {

    func testFollowUpPromptIsNotTaskPrompt() {
        let s = PromptScorer.score("test giúp anh đi em")
        XCTAssertFalse(s.isTaskPrompt)
        XCTAssertEqual(s.stars, 0)
        XCTAssertTrue(s.sectionsPresent.isEmpty)
    }

    func testFullSpecPromptGetsFiveStars() {
        let prompt = """
        ## 1. Mục tiêu
        Thêm chức năng redeem voucher. Lý do: shop cần xác nhận giao dịch
        đã hoàn tất để giải ngân, mục đích để giảm gian lận voucher.

        ## 2. User Role
        Shop được dùng, Customer không được dùng. Permission cần check.

        ## 3. Input
        - voucher_code (bắt buộc)
        - Validation: length 8 ký tự

        ## 4. Output
        - Success response: 200 + voucher status
        - Error response: 400 nếu code không hợp lệ

        ## 5. Flow chính
        1. Validate code
        2. Check status
        3. Mark redeemed

        ## 7. Edge Case
        - voucher đã redeem
        - voucher expired

        ## 8. constrained_by
        - Voucher chỉ redeem khi status = active.

        ## 10. Definition of Done
        - Pass test, không phá tính năng cũ, có audit log.

        <example>
        <input>{"voucher_code": "ABC12345"}</input>
        <output>{"status": "redeemed"}</output>
        </example>
        """
        let s = PromptScorer.score(prompt)
        XCTAssertTrue(s.isTaskPrompt)
        XCTAssertEqual(s.stars, 5)
        XCTAssertTrue(s.sectionsPresent.contains(.mucTieu))
        XCTAssertTrue(s.sectionsPresent.contains(.userRole))
        XCTAssertTrue(s.sectionsPresent.contains(.constrainedBy))
        XCTAssertTrue(s.sectionsPresent.contains(.definitionDone))
        XCTAssertTrue(s.sectionsPresent.contains(.examples))
        XCTAssertTrue(s.sectionsPresent.contains(.motivation))
        XCTAssertTrue(s.sectionsPresent.contains(.xmlStructure))
    }

    func testExamplesDetectedViaCodeFences() {
        let prompt = """
        ## Mục tiêu
        Build API.

        Sample input:
        ```
        POST /api/login
        {"email": "a@b.com"}
        ```

        Sample output:
        ```
        {"token": "xyz"}
        ```

        Còn lại em tự xử nhé, đây là các yêu cầu cơ bản cho task này.
        """
        let s = PromptScorer.score(prompt)
        XCTAssertTrue(s.sectionsPresent.contains(.examples),
                      "Code fences should trigger examples detection")
    }

    func testMotivationDetected() {
        let prompt = """
        ## Mục tiêu
        Cache token vì cần giảm latency khi check permission lặp lại
        nhiều lần trong cùng request, mục đích để chạy <100ms p95.
        """
        let s = PromptScorer.score(prompt)
        XCTAssertTrue(s.sectionsPresent.contains(.motivation))
    }

    func testXmlStructureDetectsPairedTag() {
        let p1 = "Hi <context>some background</context> end"
        XCTAssertTrue(PromptScorer.score(p1).sectionsPresent.contains(.xmlStructure)
                      || !PromptScorer.score(p1).isTaskPrompt)   // short → not task

        let long = String(repeating: "x ", count: 150) + "<context>here</context>"
        XCTAssertTrue(PromptScorer.score(long).sectionsPresent.contains(.xmlStructure))
    }

    func testSelfClosingTagAloneDoesNotCount() {
        // <br/> alone is not enough — need a paired tag.
        let p = String(repeating: "x ", count: 150) + " <br/> end"
        XCTAssertFalse(PromptScorer.score(p).sectionsPresent.contains(.xmlStructure))
    }

    func testPartialSpecLandsBetweenStars() {
        let prompt = """
        ## Mục tiêu
        Sửa bug login.

        ## Input
        - email
        - password

        ## Output
        - 200 nếu đúng
        - 401 nếu sai

        Còn lại em tự xử nhé.
        """
        let s = PromptScorer.score(prompt)
        XCTAssertTrue(s.isTaskPrompt)
        XCTAssertGreaterThanOrEqual(s.sectionsPresent.count, 3)
        XCTAssertLessThan(s.stars, 5)
        XCTAssertTrue(s.sectionsMissing.contains(.edgeCase))
    }

    func testLongPromptWithoutSpecStructureGetsLowStars() {
        // 600 ký tự nhưng không có heading nào — chỉ là 1 mô tả dài.
        let prompt = String(repeating: "Hôm nay em làm 1 task UI rất to. ", count: 20)
        let s = PromptScorer.score(prompt)
        XCTAssertTrue(s.isTaskPrompt)            // đủ dài
        XCTAssertEqual(s.sectionsPresent.count, 0)
        XCTAssertLessThanOrEqual(s.stars, 1)
    }

    func testShortPromptWithHeadingStillRespectsLengthPenalty() {
        // Có heading + 5 mục nhưng prompt dưới 400 char → stars bị cap về 2.
        let prompt = """
        ## Mục tiêu
        x
        ## Role
        y
        ## Input
        a
        ## Output
        b
        ## Flow
        c
        """
        let s = PromptScorer.score(prompt)
        XCTAssertTrue(s.isTaskPrompt)
        XCTAssertLessThanOrEqual(s.stars, 2)
    }
}
