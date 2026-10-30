# Lemieux 1.0 announcement draft

Publish after the signed release, Hex package/docs and install checks are complete.
Link the final release's qualification packet and use its actual demo asset.

---

Lemieux 1.0 is out.

It's an open-source coding agent you can take apart: `lmx`, the terminal app,
and Lemieux, the Elixir runtime underneath it. It runs the model/tool loop,
reads and edits files, runs your project's checks, and keeps an append-only
transcript you can inspect, resume or fork.

The pieces are useful on their own. You can use `lmx` for everyday
coding, embed the same loop in an Elixir application, or write an extension that
changes its tools, hooks or compaction. The terminal app uses the same public
API an embedding application uses.

For 1.0, the supported API and CLI automation contracts get a compatibility
promise through 1.x. There are executable examples that need no model account,
explicit host control over credentials and policy, and qualified native release
archives. The default `auto` mode allows workspace edits and runs commands in an
available OS sandbox; the startup banner tells you the actual policy.

Learning and research tooling are still experimental. The release makes no
claim that learning improves coding outcomes or lowers cost. You can inspect
retained experience, turn it off, or forget the workspace's captures and recalled
guidance while preserving its transcript and accounting history.

Try the terminal app, read the loop, or build something with the library:

- [Repository and installation](https://github.com/houllette/lemieux)
- [First embedded agent](https://hexdocs.pm/lemieux/first-embedded-agent.html)
- [First extension](https://hexdocs.pm/lemieux/first-extension.html)
- [Support and compatibility](https://github.com/houllette/lemieux/blob/main/docs/support.md)

I'd love to hear what you build with it, and what gets in your way.

---

The companion demo should show one small real edit, the unchanged test passing,
`/undo` and `/redo`, restart/resume, and request inspection. Label the model and
transport. Show the provider-free embedding and extension examples separately.
Do not present a scripted model response as real inference or turn a small smoke
check into a comparative quality claim. The terminal recordings in this packet
use synthetic fixture content; they are qualification recordings, not a polished
visual review of every supported terminal or platform.
