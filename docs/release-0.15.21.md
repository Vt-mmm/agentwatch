# AgentWatch 0.15.21

Session costs now show for the GPT-6 family. GPT-6.2 Astra and Sol (released
2026-11-17) have their list prices: Astra $8 input, $40 output, $0.40 cached,
$10 cache write per 1M tokens; Sol $2, $10, $0.10, $2.50. GPT-6.1 Sol, GPT-6
Sol and GPT-6 Luna, which showed "price unavailable" before, use Agent
Studio's reviewed prices. Above 272k input tokens, input and cache cost 2x
and output 1.5x; Fast doubles the rate.

The pricing label changes, so cached coaching queries are rebuilt once.

Pairs with Agent Studio 0.55.0 and Piagent 1.55.0, which serve GPT-6.2 in
company sessions; Agent Watch's own behaviour does not depend on them.

The full Swift test suite and the signed universal app packaging are release
gates.
