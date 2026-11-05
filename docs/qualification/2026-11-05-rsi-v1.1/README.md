# RSI 1.1 implementation qualification

This change advances [#47](https://github.com/houllette/lemieux/issues/47)
and its remaining children [#79](https://github.com/houllette/lemieux/issues/79),
[#80](https://github.com/houllette/lemieux/issues/80) and
[#81](https://github.com/houllette/lemieux/issues/81). It does not establish
independent efficacy or authorize new asset kinds in the default controller.

The implementation closes three observable gaps: a mechanism receipt could be
reused after changing task images or generation settings; a typed asset could
validate against tools absent from the eventual harness; and a source export
could omit files named by an embedded immutable asset. The new protocol also
requires use of every declared asset kind, rather than allowing profile-search
activity alone to supply its mechanism gate.

| Boundary | Verification |
| --- | --- |
| Frozen execution | v7/v2 mechanism tests reject changed images, isolation, request horizons, token limits, models, editor, transport and historical receipts. |
| Planning | The actual runner accepts a hosted model scope while Docker is deliberately unavailable; it creates registration/review documents and no credentials, allowance ledger, sessions or episode evidence. |
| Learned asset use | Scripted ordinary-harness integration proposes and reviews a procedure and tool description, loads their exact bytes, records actual use per kind and restores the baseline. A separate setting fixture exercises changed tool disclosure. |
| Unavailable authority | Assembly rejects stale required/affected tool lists; descriptions preserve schemas and apply to authorized host tools. Stored approval cannot authorize another scope. |
| Export closure | Incomplete or altered portable trees and missing graph edges refuse export. Existing confirmation, fresh Mix-consumer loading, CodeGate/human-review refusal and exact rollback tests remain in the gate. |
| Stock product path | Four CLI/TUI container-replay tests pass, including causal reuse, bounded refinement and cleanup. |
| Benchmark host | The [eight scripted canaries](benchmark-host.json) pass against the target checkout. They exercise actual disposable containers, without hosted inference. |
| Grader controls | The [cross-file fixture controls](benchmark-controls.json) retain a passing reference repair and failing untouched baseline. This is one development fixture, not a real-repository population. |

The local `lemieux-bench` checkout contains substantial unrelated changes. Its
working source was copied into an ignored task-local snapshot, and its dependency
lock aligned with the target library before execution. The primary checkout was
not changed. Current public fixture files and an existing immutable cached image
supplied the reference/no-op controls; no benchmark result was relabeled as
independent learning evidence.

The existing benchmark development manifests and exposure ledger remain
exposed. They cannot supply independent confirmation merely by repartitioning
their tasks. Fresh coding-task streams, preregistered power and separate execution
authorization remain necessary for #79. A combined arm also cannot establish
each contained asset kind's independent contribution; use isolated per-kind
studies before considering default enablement.

Initial failing regressions and intermediate apparatus failures were retained in
local test/Temper history. The frozen-consumer fixture needed the newly required
source-integrity module in its deliberately minimal runtime. The provider-free
planning test also caught atom-keyed allowance metadata whose digest changed
after JSON persistence; registration now stores string keys. These were fixed
before the final gate. Earlier dirty-tree observations are development records,
not independent flake or efficacy evidence.

A separately approved hosted mechanism pilot is limited to GPT-6 Luna/low task
execution and GPT-6 Sol/high proposal/reflection, one seed plus twelve comparison
episodes, at most 800 shared requests, 8 million tokens and two hours. Its full
registered request envelope is 2,496, so the outer cap may interrupt the sample.
The raw records and durable allowance remain private under the task worktree's
ignored `tmp/`; a public result must retain exact digests and report incomplete,
inconclusive or failed outcomes without implying independent confirmation.
