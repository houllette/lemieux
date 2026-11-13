# Reviewed restart decision from the signed, published 1.0.0 archives.
# This reviews source/runtime compatibility; it does not qualify final 1.1.0
# artifacts or substitute for the release rehearsal and human terminal checks.
# See upgrades/AGENTS.md and RELEASING.md, "Upgrade decisions".
#
# All four predecessor archives were unpacked against 1.0.0's SHA256SUMS,
# whose signature and update.json signature verified with the public key at
# v1.0.0. The macos_silicon predecessor build is
# f691bfcf409a50a03542307f2966718a47279b3165673e83fb38e11179a5c0c9.
# Its initial 1.1.0 inspection adds 26 Lemieux modules, changes 87 Lemieux
# modules and one lmx module, and removes none. Release.compatible?/2 is
# false; matching ERTS/Elixir version strings do not establish compatibility.
# The other candidate platforms and all final archive bytes remain unqualified.
#
# State/message/callback review:
# - Session.State/Questions/Approvals/Mailbox retain deferred question IDs,
#   deadlines, queued human input and terminal outcomes. Diagnostics retains
#   per-run fault IDs and summary ownership. These maps and pending messages
#   have no live state conversion; replay/resume reconstructs them in a fresh VM.
# - CLI.CodexModels.Watcher and ConfigReload add supervised process/task state,
#   cache scopes and timers. TUI catalogs retain account usage callbacks and
#   discovery data; references now cache the home directory. Existing runtime
#   state is not rewritten to install those fields or replace retained closures.
# - MCP.Client/Session.MCPServers change discovery/connect ownership, waiting
#   callers and cancellation cleanup; StderrCapture and the stdio launcher add
#   a bounded pipe/reader lifecycle. Existing clients and ports need fresh setup.
# - CLI.Learning callbacks and selective asset loaders retain changed policies,
#   evidence/runtime bindings and trusted code references. They are not safely
#   replaceable through a BEAM diff. Historical receipts grant no new authority.
# - ReqLLM 1.29 -> 1.30, LLMDB 2026.10 -> 2026.11, ExRatatui 0.17 -> 0.20 and
#   validator changes alter dependency/native identities on every platform.
#   New modules and changed NIF/dependency code independently require restart.
# - No live upgrade, closure replacement or hot downgrade is implemented.
#   Restart the entire runtime, resume append-only transcripts under current
#   policy/accounting, and use a saved transcript copy for an older reader.
%{
  schema_version: 1,
  version: "1.1.0",
  from: "1.0.0",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "New question/diagnostic state and MCP/discovery processes, retained host " <>
          "callbacks, and changed provider/native dependencies require fresh " <>
          "initialization. No live state/message/closure migration is implemented. " <>
          "Restart/resume and qualify the exact static-OTP Linux candidate."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "Session/TUI state, MCP task/pipe ownership and retained learning/config " <>
          "callbacks changed alongside ReqLLM and terminal NIF dependencies. " <>
          "No live callback replacement or hot downgrade is implemented. Restart " <>
          "the runtime and qualify the final Intel archive and resume path."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "The 1.0.0/initial-1.1.0 inspection adds 26 Lemieux modules and changes " <>
          "87 Lemieux and one lmx module; compatibility identities differ. " <>
          "Deferred questions, account caches, MCP ownership and retained " <>
          "callbacks have no live migration. Restart/resume; qualify final bytes."
    },
    "windows" => %{
      mode: :restart,
      reason:
        "Windows requires manual restart/resume. New session/discovery state, " <>
          "changed MCP pipe ownership and dependency/native code also require " <>
          "fresh initialization. Qualify the exact Windows archive with Git Bash; " <>
          "no automatic installation or hot upgrade/downgrade is declared."
    }
  }
}
