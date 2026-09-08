import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct JUnitSummary: Sendable, Equatable {
    public let tests: Int
    public let failures: Int
    public let errors: Int
    public let skipped: Int
}

/// Counts testcase outcomes rather than summing nested suite totals. Only UTF-8
/// reports without DTD/entities are accepted; no external resource is resolved.
public enum JUnitEvidence {
    public static func parse(_ data: Data) throws -> JUnitSummary {
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else {
            throw ReportValidationError.invalid("Cần báo cáo JUnit UTF-8 tối đa 4 MiB, không có DTD/entity.")
        }
        let delegate = Reader(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.tests > 0 else {
            throw ReportValidationError.invalid("Báo cáo JUnit thiếu testcase, lỗi cấu trúc hoặc tổng số không khớp; không xác nhận pass.")
        }
        return JUnitSummary(tests: delegate.tests, failures: delegate.failures, errors: delegate.errors, skipped: delegate.skipped)
    }
    private final class Reader: NSObject, XMLParserDelegate {
        var tests = 0, failures = 0, errors = 0, skipped = 0, depth = 0
        var invalid = false, currentCase = false, failed = false, errored = false, skippedCase = false
        struct Suite { let depth: Int; let before: [Int]; let expected: [Int?] }
        var suites: [Suite] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            if depth > 64 || (depth == 1 && !["testsuite", "testsuites"].contains(name)) { invalid = true; parser.abortParsing(); return }
            if ["testsuite", "testsuites"].contains(name) {
                if currentCase { invalid = true }
                let expected = ["tests", "failures", "errors", "skipped"].map { key -> Int? in
                    guard let raw = attributes[key] else { return nil }
                    guard let value = Int(raw), value >= 0, value <= 1_000_000 else { invalid = true; return nil }
                    return value
                }
                suites.append(Suite(depth: depth, before: [tests, failures, errors, skipped], expected: expected))
            }
            if name == "testcase" {
                if currentCase || suites.isEmpty { invalid = true }
                currentCase = true; failed = false; errored = false; skippedCase = false
            }
            if ["failure", "error", "skipped"].contains(name) {
                if !currentCase { invalid = true }
                if name == "failure" { failed = true }
                if name == "error" { errored = true }
                if name == "skipped" { skippedCase = true }
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "testcase" {
                if skippedCase && (failed || errored) { invalid = true }
                tests += 1
                if errored { errors += 1 } else if failed { failures += 1 } else if skippedCase { skipped += 1 }
                currentCase = false
            }
            if ["testsuite", "testsuites"].contains(name) {
                guard let suite = suites.popLast(), suite.depth == depth else { invalid = true; return }
                let values = [tests, failures, errors, skipped]
                for index in values.indices {
                    if let expected = suite.expected[index], values[index] - suite.before[index] != expected { invalid = true }
                }
            }
            depth -= 1
        }
    }
}
