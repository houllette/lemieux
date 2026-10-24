# Learned skill witness

This owner-written `Lemieux.Agent` packages a real archived text skill in an
ordinary Mix project. The provider is restricted to a named Scripted profile.
It reads the packaged `SKILL.md` through the actual skill tool and writes a
digest witness from that returned content. The witness establishes complete
loading, not whether a model can follow the procedure or improve a task.

From the repository root, pass a complete `Asset.Source` archive from an
explicitly authorized study:

```sh
mix run examples/learned_skill_export.exs --source PATH_TO_ARCHIVED_SOURCE \
  --output tmp/new-learned-skill-review
```

The command requires a new output directory. It validates the original source
as archival data and preserves its complete files, original ID, content digest
and creation timestamp. That source cannot load under the receiving example's
current scope. The command explicitly creates a new unconfirmed version bound
to this host, preserving every learned file byte and recording both identities.
No confirmation or approval is inherited.

The exported package contains both sources, provenance and this fixed host
code. A baseline frozen build, an adapted frozen build and the baseline again
show exact harness rollback. A fresh Mix consumer verifies the separately
supplied package digest, supplies current exact-digest approval for this
offline run, loads the derived identity and witnesses the same complete bytes.
It checks that neither the library nor this example has an application callback.

`review.json` retains package/build digests, before/applied/rollback witnesses,
consumer evidence and missing CodeGate evidence. The result stays unassessed.
Independent effectiveness testing, the remaining CodeGate evidence and human
release approval remain separate requirements. This example sends no hosted
model requests and activates nothing outside its temporary sessions.
