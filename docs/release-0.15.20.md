# AgentWatch 0.15.20

The company broker carries the advisor and general helpers of the Studio
Harness to Piagent. Before, Agent Watch read only the helpers it knew
(scout, research, verify, review) and dropped the others, so a Harness with
advisor or general never reached Piagent. Now each one has its own grant and
its requests count apart in Studio.

Needs Agent Studio 0.51.0 and Piagent 1.52.0 to use them; with an older
Studio or Piagent nothing changes.

The full Swift test suite, a real company session through all six roles
against Studio 0.51.0, and the signed universal app packaging are release
gates.
