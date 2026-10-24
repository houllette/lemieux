---
name: verify-generated-runtime-repairs
description: Use when a repository runs a generated runtime rather than editable source, when source and CLI behavior disagree, or when immutable tests and tooling must be preserved during a repair.
---

## Evidence and applicability

This is an unconfirmed reusable workflow hypothesis. In the observed repair, development instructions identified separate source and generated-runtime trees. Reading the CLI confirmed that it imported the generated tree; inspecting both implementations exposed stale output. Editing source, running the existing build, and then running immutable checks succeeded. Independent checks exercised direct calls and the JSON boundary, and a final file-set and byte comparison established agreement for the copy-based build.

An optional Git inspection also failed because Git was unavailable, preventing later commands in an `&&` chain from running. This supports separating optional environment inspection from required verification, not assuming that verification occurred.

Apply the procedure only after confirming the repository's actual build and import paths. Byte equality is appropriate for copied source, not arbitrary compiled or transformed artifacts.

## Procedure tree

1. **Identify the execution path before changing code.**
   - Read the issue, development instructions, behavioral contract, entry point, relevant source, and build implementation. Batch independent reads.
   - Record editable locations, immutable locations, the project interpreter, build command, and verification command.
   - Trace the entry point's imports. If it executes generated output, inspect the corresponding output as well as source. Do not infer runtime behavior from source alone.
   - If a rebuild deletes its output directory, confirm that the directory is designated generated output and contains no unrelated work before running it.

2. **Establish a bounded baseline.**
   - Run the existing checks before edits when practical, and record which artifact they exercised.
   - Keep optional version-control inspection separate from required checks so unavailable Git cannot suppress testing.
   - Inspect command exit status and error text, not just tool-call success. If a command chain stops, explicitly run the still-needed commands separately.
   - Where feasible, capture a pre-edit inventory or hashes of immutable files without leaving new repository artifacts.

3. **Repair the authoritative source.**
   - Make the smallest contract-driven change in the allowed implementation files.
   - Do not patch generated output alone or move implementation into immutable runners, tests, documentation, or build tooling.
   - Do not broaden behavior merely to satisfy speculative inputs.

4. **Rebuild, then verify serially.**
   - Run the documented build only after source edits finish. Run immutable checks only after a successful build.
   - If checks fail, distinguish a build/import-path problem from a behavioral mismatch before editing again.
   - If the feature has a tractable finite domain, supplement the suite with bounded enumeration or deterministic sampling and a structurally different reference derived from the contract. Keep this verification temporary; do not alter immutable tests.
   - Exercise both direct calls and the real serialization boundary in fresh processes where necessary to avoid import-cache confusion. For large CLI inputs, use bounded batches rather than exceeding argument-size limits.

5. **Check delivery consistency.**
   - For copy-based generation, compare relative file sets in both directions and then compare corresponding bytes. Checking only that each source file exists in output misses stale extra files.
   - For transforming builds, use the repository's artifact validation or reproducibility checks instead of demanding byte equality with source.
   - Prevent verification caches where practical. Remove only artifacts known to have been created by the current work; do not blanket-delete existing caches or unrelated files.
   - Review the allowed change scope and immutable-file preservation using available evidence. Without a baseline or version-control diff, acknowledge the narrower review.

## Reporting and uncertainty

Report source changes, regeneration, commands actually executed, observed results, and the precise coverage of supplemental checks. Separate behavioral evidence from artifact consistency: matching files do not prove correctness, and passing source tests do not prove the CLI ran the updated artifact. Bounded enumeration does not establish correctness for larger inputs, and a reference implementation can share a mistaken contract interpretation.
