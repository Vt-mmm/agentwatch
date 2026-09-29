import XCTest
@testable import AgentWatchCore

final class ReportLocalIdentityTests: XCTestCase {
    func testNewMachineGetsStableReportIDWithoutEnrollmentOrAuthMaterial() throws {
        let suite = "local-report-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try ReportEnrollmentIdentity.local(defaults: defaults, deviceName: "Máy kiểm thử")
        let next = try ReportEnrollmentIdentity.local(defaults: defaults, deviceName: "Tên máy mới")
        XCTAssertEqual(first, next)
        XCTAssertTrue(first.employeeID.hasPrefix("member-"))
        XCTAssertNil(defaults.object(forKey: "supervisor.lock.enabled"))
        XCTAssertNil(defaults.object(forKey: "supervisor.lock.byLabel"))
    }
    func testExistingReportIdentityAndFolderBindingSurviveRetiredEnrollment() throws {
        let suite = "local-report-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = try ReportEnrollmentIdentity(enrollmentHash: String(repeating: "a", count: 64), label: "Existing member")
        defaults.set(legacy.employeeID, forKey: "dailyReport.employeeID")
        defaults.set(legacy.name, forKey: "dailyReport.displayName")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bindings = ReportFolderBindingStore(root: root)
        _ = try bindings.bind(organizationID: "org", identity: legacy, accountKey: "fixture-google",
            folder: DriveFolderAccess(id: "fixture-folder", name: "Report", permissions: [], permissionHash: "fixture", sharedDrive: false))
        let current = try ReportEnrollmentIdentity.local(defaults: defaults, deviceName: "Mac")
        XCTAssertEqual(current, legacy)
        XCTAssertEqual(try bindings.read(organizationID: "org", employeeID: current.employeeID, accountKey: "fixture-google")?.folderID, "fixture-folder")
    }
    func testManualReportIDIsPreservedAndInvalidExistingIDDoesNotSilentlyRebind() throws {
        let suite = "local-report-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("employee-42", forKey: "dailyReport.employeeID")
        defaults.set("Existing profile", forKey: "dailyReport.displayName")
        XCTAssertEqual(try ReportEnrollmentIdentity.local(defaults: defaults, deviceName: "Mac").employeeID, "employee-42")
        defaults.set("../invalid", forKey: "dailyReport.employeeID")
        XCTAssertThrowsError(try ReportEnrollmentIdentity.local(defaults: defaults, deviceName: "Mac"))
        XCTAssertEqual(defaults.string(forKey: "dailyReport.employeeID"), "../invalid")
    }
}
