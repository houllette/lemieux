# Deep live research corpus, frozen 2026-09-28

The four prompts in `deep-live-manifest.json` ask for multiple facts from
recent primary sources. This file freezes the answer key **before** the live
model comparison. Neither arm can read local files; the grader reads only an
agent's returned answer. `deep_check.exs` awards factual completion, while the
post-run source audit examines citations, fetched URLs and whether the cited
pages actually support the answer. A cited domain alone is not proof.

| Task | Required facts | Primary sources checked at corpus freeze |
| --- | --- | --- |
| `beam-maintenance` | Elixir fixed `Task.yield_many/2` hanging when `:limit` exceeds task count. OTP 29.1 changed `beam_lib` error-tuple filenames from atoms to character lists; `beam_lib:chunks/2` is one example in the release note. | [Elixir v1.20.4 release](https://github.com/elixir-lang/elixir/releases/tag/v1.20.4), [OTP 29.1 release](https://www.erlang.org/news/191) |
| `postgres-logical-upgrade` | PostgreSQL 18.6 defaults `output_plugin_libraries` to `pgoutput` and `test_decoding`; `pg_upgrade --check` fails for a slot whose plugin is not allowed on the new cluster when migrating from 17 or later. 18.5 was never released due to a post-wrap regression. | [PostgreSQL 18.6 release notes](https://www.postgresql.org/docs/release/18.6/) |
| `kubernetes-136-upgrade` | Mixed Version Proxy gate `UnknownVersionInteroperabilityProxy` is beta and enabled by default. Service `.spec.externalIPs` is deprecated with warnings in 1.36; kube-proxy support may be disabled with opt-back-in in 1.40 at the earliest and fully disabled in 1.43 at the earliest. | [Mixed Version Proxy post](https://kubernetes.io/blog/2026/05/15/kubernetes-1-36-feature-mixed-version-proxy-beta/), [externalIPs deprecation post](https://kubernetes.io/blog/2026/05/14/kubernetes-v1-36-deprecation-and-removal-of-service-externalips/) |
| `python-315-rc2` | Python 3.15.0rc2 was released 2026-09-01; PEP 790 scheduled final for 2026-10-01. No further 3.15 ABI changes were planned, so RC-built wheels will work with later 3.15 versions; rc2 is not recommended for production. | [Python 3.15.0rc2 release](https://www.python.org/downloads/release/python-3150rc2/), [PEP 790 schedule](https://peps.python.org/pep-0790/) |

The questions are development cases selected with knowledge of their answers.
They are suitable for comparing paths on this fixed corpus, not an unseen
generalization claim. Version-specific facts and source URLs are frozen as of
the date above so a later release does not silently change the target.
