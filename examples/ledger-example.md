# Example ledger

A filled row set for a control/compiler change, showing all four verdicts and a
non-claims section. The numbers come from the same kinds of measurements the discipline
was designed around; they are illustrative of the *shape*, not a claim about any current
build.

## Rows

| id | requirement | design | interface | tests | evidence | verdict |
| --- | --- | --- | --- | --- | --- | --- |
| R1 | Closed-loop tracking matches the oracle: max abs output difference 0.0 over 2000 ticks from 5 seeds | KF + LQR, `inv(A)@b` written in the component (no fused solve) | ports `in=[y x_ref u_prev x_hat P]`, `out=[u]`, `state_out=[x_hat P u_prev]` unchanged | `test_closed_loop_parity`, `test_state_feedback_seeded` | `run_oracle --closed-loop --ticks 2000` | `proved` |
| R2 | Anchored trajectory: mean CTE ≤ 0.05 m, max ≤ 0.10 m over 48 s at stride 12 | anchor captured on the first write after a pose read; path frame `p' = R(−θ)(p − anchor)` | none | `test_tracking_cte_bounds`, `test_anchor_captured_once` | `run_tracking --anchor --duration 48 --stride 12` | `conditional` (dev host; a different scheduler changes the envelope) |
| R3 | Identity `add(x, 0) → x` may be folded | canonicalize identity, applied only when the surviving operand carries the node's full shape | graph only; ports verbatim ⇒ C-ABI unchanged | `test_fold_identity_shape_guard`, `test_no_fold_on_broadcast` | `fvai equiv --lhs add(x,0) --rhs x --relation ieee` | `conditional` (IEEE-exact; **not** bitwise, `x = −0.0` flips the sign of zero) |
| R4 | Graph optimisation preserves the C-ABI: same port count, order, shapes | fold + canonicalize + DCE run inside lowering; port lists emitted verbatim | manifest `ports` and `state_*` order | `test_manifest_ports_unchanged`, `test_symbol_signature` | `shinro build <scenario> --out /tmp/x && jq .ports /tmp/x/*.manifest.json` | `structural` |
| R5 | The emitted Zig computes the same function as the source component | claimed via the interpreter/oracle at the graph level | — | — | — | `declared` (Zig → LLVM → `.so` is the trusted base) |

## Not established

- **R3 is not bitwise equivalence.** `add(x, 0)` is IEEE-exact but changes `−0.0` to
  `+0.0`. Any row claiming bitwise equality here is false.
- **R5 is not proved.** A per-pass refinement obligation with a named trusted base is the
  only thing that would move it off `declared`; a green parity run does not.
- **R2 was measured on one host.** Same code on the board is a different row.
- **Torque re-enable after a recovery is the child's behaviour**, not the supervisor's:
  the protocol carries no torque concept. Unclosed boundary, stated rather than implied.

## Lane partition for these rows

| lane | rows | write scope | interface touched | generated paths | serialized behind |
| --- | --- | --- | --- | --- | --- |
| L1 | R1, R3 | `src/shinro/runtime/` | C-ABI (verified unchanged), graph | `graph_data.zig` | — |
| L2 | R2 | `src/shinro/controllers/` | none | none | L1 (graph inputs) |
| L3 | R4, R5 | `src/shinro/runtime/`, gate scripts | ports, manifest | `.zig-cache/`, `build/` | L1 (interface) |

L1 and L3 both touch `src/shinro/runtime/` and the generated graph: they are one lane, or
they serialize. Recorded here precisely because it is the collision the partition step
exists to find — not during the wave.
