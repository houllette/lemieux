---
name: verify-generated-runtime-repairs
description: Use when repairing a feature whose CLI imports a generated runtime, when source and runtime disagree, or when immutable tests and tooling require verification without edits.
---

## Hypothesis and observed evidence

Tracing the actual execution path, repairing authoritative source, and verifying both regeneration and the unchanged interface may prevent a source-only repair from leaving the delivered runtime stale.

In the observed workflow, development instructions identified source under `src/project` and a CLI importing `.build/project`. Reading both trees revealed different placeholders. The existing checks failed before repair. Editing source, running the existing build script, and rerunning checks succeeded; additional comparisons exercised both source and the JSON CLI. Byte comparisons checked generated Python against source, and protected-file hashes checked preservation. Git was unavailable. An initial recursive search of the repository parent encountered permission errors; repository-scoped discovery avoided that expansion.

These observations support trying this procedure, not assuming it transfers unchanged. Earlier authorized experience also suggests bounded independent-reference comparisons and input-preservation checks, but a failing check alone does not identify the defect.

## Procedure tree

### 1. Establish scope before editing

- Confirm the execution working directory and available project interpreter rather than assuming host paths match tool paths.
- Read repository instructions and the issue. Inspect applicable ancestor instruction files directly; keep recursive discovery inside the repository unless evidence requires broader scope.
- Read the behavior contract, entry point, imported implementation, and build instructions. Batch independent reads.
- Identify editable source, generated outputs, and protected files. Do not infer permission to change runners, tests, documentation, or build tooling.
- Before edits or builds, record protected-file paths and content hashes in session output or permitted temporary storage. Include directory membership when additions or deletions matter. A later snapshot only establishes preservation from that later point.

### 2. Trace the failing execution path

- Run existing verification and inspect its exit status and failure details.
- If the entry point imports generated files, inspect those files as well as their authoritative source.
- If source and runtime differ, distinguish stale generation from a source defect; both may exist.
- If there is no generated runtime, skip regeneration-specific steps rather than inventing a build requirement.

### 3. Repair the authoritative implementation

- Make the smallest contract-driven source change consistent with surrounding code.
- Preserve the public interface and protected files. Do not repair stale output by placing implementation in the runner or generator.
- Separate required behavior from unspecified malformed-input behavior; do not silently turn defensive choices into new contract requirements.

### 4. Rebuild and verify in dependency order

- Read the existing build command and its effects before running it. Use the repository's environment and existing tooling, without installations.
- Run the documented build, then existing checks. Stop and investigate a failed build before treating downstream results as meaningful.
- Exercise the unchanged entry point in a fresh subprocess so import caching cannot conceal stale generated code.
- For copy-based generation, compare relative file sets and bytes in both directions, excluding only justified transient artifacts. For transforming generators, use their documented consistency checks instead of assuming byte equality.

### 5. Supplement sparse checks without changing maintained tests

- When the input space is small, use bounded exhaustive enumeration against a simpler, independently written reference. Otherwise use deterministic samples and targeted boundaries.
- Derive checks from the current contract, not from observed implementation outputs. Apply permutations or duplicate-record transformations only when the contract makes them invariant.
- Check input preservation where required. Exercise multiple inputs through the real batch interface and bound serialized batch sizes to avoid command-line limits.
- Keep large-depth or scale checks separate, and state whether they ran against source or through the CLI. Use ephemeral standard-library verification rather than leaving scratch files behind.

### 6. Review and report evidence precisely

- Recheck protected hashes and membership, source/runtime consistency, and the allowed change scope.
- If Git is available, inspect the diff without modifying version-control state. If unavailable, report that limitation; hashes are not a substitute for an earlier snapshot or a full diff.
- Report commands actually run, comparison scope, and interface coverage. A finite reference comparison cannot establish correctness for all inputs; the reference can also be wrong. Preserve explicit uncertainty about unspecified behavior and untested environments.
