# Versioned delegated-tree transcripts

Real transcripts from one depth-one fan-out, written by the build named in
`expected.json`'s sibling history entry and read back by
`Lemieux.Subagent.TranscriptFixtureTest` without being regenerated.

They exist because every other subagent test writes and reads in one process,
which proves the two halves agree with each other and nothing about whether
either agrees with bytes already on disk. A host resuming a session started
last month is reading exactly these.

- `<parent id>.jsonl` — the parent transcript: two spawn intents, two child
  results and the group result.
- `<child id>.jsonl` — each child's own transcript. One answered inside the
  result schema; the other answered in prose, which the envelope keeps and
  labels rather than discarding.
- `expected.json` — the ids and the terminal facts the test asserts.

`v2` is the entry schema version these were written under
(`lemieux.transcript.entries/v2`). Do not edit them by hand: regenerate under
a new directory if the durable shape changes, and say why in
`docs/transcript-compatibility.md`.
