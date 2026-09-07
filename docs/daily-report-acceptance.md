# Daily report — acceptance audit

Implementation is complete for the agreed local desktop scope. This matrix distinguishes automated/local evidence from acceptance requiring the operator's Google configuration. No real Google OAuth, upload or email was performed by the coding agent.

## Contract cases

| Case from approved contract | Implementation and evidence |
|---|---|
| Fractional last second vs midnight | `UsageAccountingTests.testHalfOpenVietnamDayIncludesFractionalLastSecond`; shared half-open `ReportTime`/`DailyReportPeriod` |
| Session across days, missing baseline | `testCodexMissingBaselineKeepsLaterKnownDelta`; selected-range fixtures in `AgentInventoryTests` |
| Counter reset/correction | `testCodexResetPreservesKnownSegmentsAndMarksPartial` |
| Duplicate streaming revision | `testDuplicateRequestReplacesStreamingRevisionAndModelsPriceSeparately`; stable request upsert |
| Child logs and source mirrors | `testFullScanFindsChildLogsAndOldMtimeCopyWithoutCountingChildPrompt`; `SessionAccounting.canonical` merges duplicate source records by request identity |
| Codex/Pi inherited fork history | `testCodexForkInheritedHistoryIsNotNewConsumption`, `testPiForkExcludesInheritedMessagesAndSessionLocalIDsDoNotCollide` |
| Legitimate repeated prompt | Usage identity is request ID, not prompt text. Prompt text is never used to deduplicate usage; fallback is canonical source record with session scope |
| Model/tier changes | Per-entry exact model/provider/tier pricing, `testLongContextRequestAndCounterDeltaHaveDifferentPriceCertainty`, model-change inventory fixtures |
| Missing Pi cost | Partial known subtotal and coverage in `testPartialCostRetainsKnownSubtotalAndUnknownModelNeverGetsFamilyFallback` |
| Unknown model price | Unknown cost remains unavailable, tokens retained; same coverage fixture |
| Reasoning and cache-write sub-buckets | `testBreakdownNormalizationDoesNotCountReasoningOrCacheTwice`, `testCacheWriteTTLPricesOnlyOneHourSubsetAtOneHourRate` |
| Task across sessions / multiple tasks in a session | Explicit task journal binding and `testTaskJournalPartitionsSessionUsageAndConservesTotals`; manual merge conservation test; unlinked usage remains unallocated |
| Agent says done without accepted evidence | `testCompletionRequiresConfirmationAndResultEvidence`, `testModelCannotEditMetricsOrApproveCompletedWork`; no parser currently issues toolVerified completion |
| No agent log | Empty daily report is valid with missing-source warnings; editor permits manual work items and notes |
| Quota absent/stale/account/reset | Six `QuotaSnapshotTests` plus bounded mapping/latest-bucket test in `ReportTeamTests`; percentages never summed |
| Search/filter/page does not truncate report | Daily editor calls full `CoachingScan.scan` with captured period; no list search/page parameters are forwarded |
| Date/scope changes during build | Editor captures profile/day/project selection before async scan; immutable snapshot seals content/time/revision; source manifest rechecked after extraction |
| Script/CSV formula/secret input | `testManagerExportsExcludeLocalPathsAndRawSecretsAndEscapeHTMLCSV`; email header injection tests and independent MIME parsing |
| Recipient changes after approval | New destination digest/job, approval bound to payload/destination/employee; durable prepare test and policy Bcc allowlist test |
| Double click/restart | Outbox transactional claims; Drive duplicate-worker test; Gmail abandoned sending lease test; schedule one-worker test |
| Drive timeout after create | `testDriveTimeoutRecoveryVerifiesSameIDWithoutSecondUpload`, folder preallocated-ID recovery test |
| Drive complete, Gmail fails | `testGmailFailureDoesNotChangeCompletedDriveReceiptOrPayload`; separate durable stores/services |
| Gmail accepted but response lost | `testTimeoutNeverAutomaticallyResendsAndRequiresExplicitReconciliation`; malformed-success and 5xx uncertain tests |
| Missing folder/app/recipient permissions | Drive preflight and changed-ACL rejection; Gmail defaults to PDF attachment rather than an unverified link. Actual recipient Drive access remains a live gate |
| 401/revoked, 403, 429 | Scope/identity/refresh fixtures, permission rejection, persisted quota backoff and Retry-After tests. Real grant revocation/refresh requires live acceptance |
| Offline/sleep | Local snapshots/drafts/outboxes; `testOfflinePastDeadlineIsMissedInsteadOfCatchUpSend`; interrupted schedule and Gmail claim are review-only |

Additional checks cover closed snapshot/policy schemas, hash tampering, malformed usage allowing an explicitly partial report, integer overflow, backfilled notes with actual entry time, changed policy blocking network, managed-policy fail-closed behavior, source/account/time-bound mapping, incompatible reconciliation bases/UTC periods and retention preserving pending work/receipts.

## Local output checks

- Swift package regression suite and Debug macOS app build; no dependency upgrades required.
- Synthetic one-page PDF and all pages of the expanded report rendered with Poppler and visually inspected. Vietnamese remains selectable; no clipping or overlap.
- MIME parsed by Python's independent email parser: UTF-8 subject, separate To/Cc/Bcc, plain and HTML alternatives, one intact PDF, no MIME defects.
- Working-tree whitespace check; no token/auth/session fixtures committed or staged. Existing unrelated rename/product work remains in place.

## Explicit implementation choices

- PDF binary up to 5 MB, no Google Docs conversion or large resumable upload.
- Gmail attachment delivery, no unverified Drive-link email, no send-as aliases, no inbox-reading scope.
- Optional model narrative via operator copy/paste of a redacted packet plus strict JSON validation; no automatic model API call or repeated model repair loop.
- Team policy/account mapping/reconciliation are local or admin-provisioned desktop capabilities; no centralized identity server, billing collector or backend scheduler.
- Schedules authorize a fixed reviewed job once, within a reviewed deadline. Recurring delivery of future reports requires a separate standing-authorization contract.
- Pi runtime/journal contracts were sufficient for this integration; no employee or Google logic added to Pi Platform.

## Pending live acceptance — intentionally deferred

The operator will provide Google Desktop OAuth client, authorized test account/folder and explicit test recipient after implementation. Then verify browser login/cancel, Keychain refresh across app restart, revoked permissions, Drive recipient access, one approved synthetic Gmail delivery into Sent and recipient inbox, and one approved scheduled delivery while the app is active. Test email receipt is not a read receipt. No production-ready/live certification is claimed before those checks.

Actual Claude/Codex account quota payloads should also be checked during pilot; fixture/schema support does not guarantee a particular subscription exposes every optional field.
