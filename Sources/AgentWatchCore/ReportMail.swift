import Foundation

public struct ReportMailDestination: Codable, Sendable, Equatable {
    public let accountKey: String
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public init(accountKey: String, from: String, to: [String], cc: [String] = [], bcc: [String] = [], subject: String) throws {
        self.accountKey = accountKey; self.from = from
        self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject
        try validate()
    }
    public func validate() throws {
        guard !accountKey.isEmpty, !to.isEmpty, recipients.count <= 50,
              Self.validAddress(from), recipients.allSatisfy(Self.validAddress),
              Set(recipients.map { $0.lowercased() }).count == recipients.count,
              !subject.trimmingCharacters(in: .whitespaces).isEmpty, subject.utf8.count <= 500,
              !subject.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ReportValidationError.invalid("Kiểm tra email người nhận (không kèm tên), tiêu đề và địa chỉ trùng nhau; tối đa 50 người nhận.")
        }
    }
    public var recipients: [String] { to + cc + bcc }
    public var digest: String { ReportEncoding.digest((try? ReportEncoding.encode(self)) ?? Data()) }
    // Deliberately supports unquoted ASCII mailboxes only; never guess a display
    // name, internationalized mailbox, group expansion or a send-as identity.
    public static func validAddress(_ value: String) -> Bool {
        guard value.utf8.count <= 254, value.unicodeScalars.allSatisfy({ $0.value < 128 }),
              value.range(of: #"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$"#, options: .regularExpression) != nil else { return false }
        let pieces = value.split(separator: "@")
        return pieces[0].utf8.count <= 64 && pieces[1].split(separator: ".").allSatisfy { $0.count <= 63 }
    }
    public static func parseAddresses(_ value: String) -> [String] {
        value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public struct ReportMailPayload: Sendable {
    public let messageID: String
    public let mime: Data
    public let pdf: Data
    public let text: String
}

public enum ReportMailRenderer {
    public static func render(snapshot: ReportSnapshot, destination: ReportMailDestination, pdf: Data? = nil,
                              now: Date = Date()) throws -> ReportMailPayload {
        try ReportSnapshotStore.validate(snapshot); try destination.validate()
        let attachment = try pdf ?? DailyReportRenderer.pdf(snapshot.report, revision: snapshot.revision)
        guard !attachment.isEmpty, attachment.count <= 5_000_000 else { throw GoogleServiceError.unsupportedSize }
        let identifier = UUID().uuidString.lowercased()
        let messageID = "<\(identifier)@\(destination.from.split(separator: "@").last!)>"
        let mixed = "agentwatch-mixed-\(identifier)", alternative = "agentwatch-alt-\(identifier)"
        let text = DailyReportRenderer.plainText(snapshot.report, revision: snapshot.revision)
        let html = DailyReportRenderer.html(snapshot.report, revision: snapshot.revision)
        let day = DailyReportRenderer.dateLabel(snapshot.report.period.start, zone: snapshot.report.period.timeZone, format: "yyyy-MM-dd")
        let filename = "daily-report-\(day)-v\(snapshot.revision).pdf"
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var lines = ["From: \(destination.from)", addresses("To", destination.to)]
        if !destination.cc.isEmpty { lines.append(addresses("Cc", destination.cc)) }
        if !destination.bcc.isEmpty { lines.append(addresses("Bcc", destination.bcc)) }
        lines += ["Subject: \(encodedSubject(destination.subject))", "Date: \(date.string(from: now))", "Message-ID: \(messageID)",
                  "MIME-Version: 1.0", "Content-Type: multipart/mixed; boundary=\"\(mixed)\"", "",
                  "--\(mixed)", "Content-Type: multipart/alternative; boundary=\"\(alternative)\"", ""]
        for (type, body) in [("text/plain", text), ("text/html", html)] {
            lines += ["--\(alternative)", "Content-Type: \(type); charset=UTF-8", "Content-Transfer-Encoding: base64", "", base64(Data(body.utf8))]
        }
        lines += ["--\(alternative)--", "", "--\(mixed)", "Content-Type: application/pdf; name=\"\(filename)\"",
                  "Content-Disposition: attachment; filename=\"\(filename)\"", "Content-Transfer-Encoding: base64", "",
                  base64(attachment), "--\(mixed)--", ""]
        return ReportMailPayload(messageID: messageID, mime: Data(lines.joined(separator: "\r\n").utf8), pdf: attachment, text: text)
    }
    private static func addresses(_ field: String, _ values: [String]) -> String { field + ": " + values.joined(separator: ",\r\n ") }
    private static func base64(_ data: Data) -> String {
        data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
    }
    static func encodedSubject(_ value: String) -> String {
        // Split at Unicode scalar boundaries before encoding, so each encoded
        // word is valid UTF-8 and stays within RFC 2047's 75-character limit.
        var chunks: [Data] = [], current = Data()
        for scalar in value.unicodeScalars {
            let bytes = Data(String(scalar).utf8)
            if current.count + bytes.count > 42 { chunks.append(current); current = Data() }
            current.append(bytes)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.map { "=?UTF-8?B?\($0.base64EncodedString())?=" }.joined(separator: "\r\n ")
    }
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
