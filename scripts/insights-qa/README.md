# Isolated Insights UI verification

Build with `bash scripts/insights-qa/build.sh` from this checkout. The script prints
a fresh app path for each build, so it does not overwrite a running harness. This
is a development harness for the current checkout; keep its SwiftPM build directory
available for generated resource-bundle lookup. The production application entry
point, schedulers and provider clients are not started.

The actual Tasks, history, mapping, outcome, lineage and team views are compiled
with temporary query, binding, acceptance, policy and inbox stores. The fixture
contains 120 paging prompts, three sequential failed tool calls (360 request tokens),
Pi context observations, a file, a two-case JUnit report with one failure, and a
reviewed team report plus an invalid import file. No real credentials are configured.

`<app>/Contents/MacOS/AgentWatchInsightsReview --validate-fixture` validates fixture
creation without opening the review UI. It is not an interactive UI test.

## Interactive gates — still to execute

1. Open the harness. Confirm the selected day loads automatically; expand the advanced details; expect the
   `QA query` task, 360 tokens and explicit missing-source/partial coverage notices.
2. In history, keep today selected and search `Paging fixture`. Verify 100 rows on
   page one, 20 on page two, and identical range token totals. Widen the range and
   verify the unindexed-period warning. Search `truy vấn` to check Unicode FTS.
3. Edit the persisted session mapping, re-read and confirm the task label changes.
   Confirm historical results were invalidated, then rebuild them. Restore a prior
   mapping and check the same behavior. Try an overlapping new link and expect rejection.
4. Read outcome evidence. Verify separate test invocation/response and loop entries.
   Inspect `artifact.txt` and `synthetic-tests.xml` in the fixture folder. Confirm the
   JUnit observation says two testcases/one failure. Select evidence, enter a synthetic
   reviewer/note, save acceptance and re-read to confirm preserved evidence and run IDs.
5. Read lineage; this Claude fixture has no authoritative parent metadata, so the
   view must say unknown rather than invent a parent. Inspect the Pi context group's
   partial metrics and source references; do not expect a conclusive waste score.
6. Run the thorough source check. Confirm manifest counts and warnings distinguish
   inspected JSON validity from unsupported-schema coverage that remains unknown.
7. In team overview, import the fixture's `incoming` directory. Verify a valid member
   report, one missing member and the invalid-file error. Re-import and verify no
   duplicate report. Switch the harness-only identity picker to `qa-member` and
   confirm team access is rejected; switch back to `qa-owner` to recover.

Record actual observations/screenshots and failures. A successful build, fixture
validation or app launch does not satisfy these gates by itself. Keep the goal
incomplete if interactive verification remains unavailable.
