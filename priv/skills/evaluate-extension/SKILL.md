---
name: evaluate-extension
description: Test and compare a Lemieux extension with representative cases, bounded provider use, and honest evidence.
argument-hint: "extension and acceptance cases"
---

# Evaluate a Lemieux extension

Use this after an extension has real behavior to assess. Keep implementation
checks separate from model efficacy. Do not make live provider calls until the
user has selected the candidates and authorized a bounded comparison.

1. Capture the job, intended host, representative inputs, observable acceptance
   criteria and failure costs. Preserve existing decisions. A deterministic
   function or scripted provider test should fail before a claimed fix and pass
   after it; neither establishes agent quality by itself.
2. Test native code, schemas, loading and host integration locally first. For
   the installed binary, `lmx explain --extension NAME` checks the prepared
   harness without an inference request. Inspect the resulting catalog and
   limits before any live run.
3. If live comparison is requested, use the same cases and grader for each
   selected model and effort. State the planned cases, repetitions, maximum
   attempts and direct requests. Metered routes require a user budget and
   valid price estimates; quota routes require explicit request bounds.
   Unknown cost is never zero. Keep authoring use separate from evaluation use.
4. Record failed attempts, latency, usage and outcome alongside successes.
   Refine only on development cases. Keep confirmation cases hidden until the
   implementation and candidate are frozen. A tie at a perfect baseline is
   not an improvement.
5. Report what the checks and runs actually showed, including what was not
   measured. Export or activate only when requested.

In a Lemieux source checkout, `docs/agent-extensions.md` documents the
optional comparison, workbench, freeze and confirmation tasks. Use those tools
when the extra rigor serves the user's task; ordinary extension creation does
not require that lane.
