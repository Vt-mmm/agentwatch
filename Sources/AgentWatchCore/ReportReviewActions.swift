import Foundation

public enum ReportReviewActions {
    public static func merge(_ sourceID: String, into targetID: String, draft: DailyReportDraft) throws -> DailyReportDraft {
        guard sourceID != targetID,
              let source = draft.workItems.first(where: { $0.id == sourceID }),
              let targetIndex = draft.workItems.firstIndex(where: { $0.id == targetID }) else {
            throw ReportValidationError.invalid("Không tìm thấy hai đầu việc để gộp.")
        }
        var result = draft
        var target = result.workItems[targetIndex]
        target.sessionRefs = Array(Set(target.sessionRefs + source.sessionRefs)).sorted()
        target.taskRefs = Array(Set(target.taskRefs + source.taskRefs)).sorted()
        target.taskRunIDs = Array(Set(target.taskRunIDs + source.taskRunIDs)).sorted()
        target.evidenceIDs = Array(Set(target.evidenceIDs + source.evidenceIDs)).sorted()
        target.activities += source.activities.filter { !target.activities.contains($0) }
        target.claims += source.claims.filter { !target.claims.contains($0) }
        target.blockers = [target.blockers, source.blockers].filter { !$0.isEmpty }.joined(separator: "\n")
        target.nextActions = [target.nextActions, source.nextActions].filter { !$0.isEmpty }.joined(separator: "\n")
        target.status = .unknown; target.humanConfirmed = false
        target.claims = target.claims.map { WorkClaim(text: $0.text, basis: .agentReported, evidenceIDs: $0.evidenceIDs) }
        // Manual time may overlap; never sum or guess. Operator can enter a new total.
        target.manualMinutes = nil
        result.workItems[targetIndex] = target
        result.workItems.removeAll { $0.id == sourceID }
        for index in result.usage.indices where result.usage[index].workItemID == sourceID { result.usage[index].workItemID = targetID }
        if let count = result.dailyActivity?.prompts.count {
            for index in 0..<count where [sourceID, targetID].contains(result.dailyActivity?.prompts[index].workItemID ?? "") {
                result.dailyActivity?.prompts[index].workItemID = targetID
                result.dailyActivity?.prompts[index].taskBasis = .humanConfirmed
                result.dailyActivity?.prompts[index].scope = .unknown
                result.dailyActivity?.prompts[index].scopeReason = ""
            }
        }
        try ReportValidator.validate(result)
        return result
    }
}
