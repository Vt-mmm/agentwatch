# AgentWatch 0.15.19

A company task's run is closed in Studio even when Studio missed
the first close. When a close failed (Studio restarting or out of reach),
the broker dropped it as soon as the next task started, and Studio kept
showing the old run as running for days. Up to eight missed closes are now
kept and sent again right after the next task starts; one that fails again
waits for the start after that. Studio also closes a run nothing renewed for
a day, so older leftovers clear on their own.

Closing helper slot 1 no longer closes its sibling helpers (#20).

The full Swift test suite and the signed universal app packaging are release
gates.
