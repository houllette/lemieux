# Restart decision from the signed, published 0.12.0 archives.
# See upgrades/AGENTS.md and RELEASING.md, "Upgrade decisions".
#
# All four predecessor archives were verified against the signed 0.12.0
# SHA256SUMS. The local Apple Silicon inspection uses predecessor build
# e90d99d691132c3679a9ec0906d2326461a34241b28e086b5afb9d852be5681b.
# Its initial 1.0.0 candidate adds five Lemieux modules, changes 39 Lemieux
# modules and two lmx modules, and removes none. Release.compatible?/2 is
# false even though ERTS 17.1 and Elixir 1.20.4 match on that host. These
# observations do not qualify the other platforms or the final archives.
#
# Lifecycle/callback review:
# - CLI.Learning.Loop now captures workspace-operation locking in its prepare,
#   stop and session-end callbacks. Retention and Capture.Storage add process
#   owner claims, a capture cutoff and pruning of active applications. Existing
#   callbacks are not replaced in running sessions. Transcript accounting and
#   recovery documents remain append-only and are reauthorized on resume.
# - Changes since 0.12.0 include TUI.Updates/Lifecycle restart preparation,
#   current session/working-directory selection and on_exit receipts, planning
#   reducer state, provider fast-mode callbacks and structured-output handling.
#   No live state/message/closure migration or hot downgrade is implemented.
# - New modules and changed dependency/native identities independently rule out
#   the supported hot path. Lmx.Update's retained-callback guard is scoped, not
#   a proof over arbitrary host processes. Restart is the reviewed decision.
#
# Every target must still qualify its actual predecessor/candidate archives.
# Restart archives omit relup and advertise empty upgrade_from/hot_modules.
%{
  schema_version: 1,
  version: "1.0.0",
  from: "0.12.0",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "New retention/host modules, changed learning and TUI callbacks and " <>
          "dependency identities have no live state/message/closure migration. " <>
          "Restart the complete runtime and resume under current host policy. " <>
          "Qualify the exact static-OTP Linux archive; no hot path is declared."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "Workspace retention claims/cutoffs, changed session/TUI callbacks and " <>
          "dependency/native code require fresh initialization. No callback " <>
          "replacement or hot downgrade is implemented. Qualify the Intel " <>
          "archives and use restart/resume."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "The actual 0.12.0/initial-candidate inspection adds five Lemieux " <>
          "modules and changes 39 Lemieux and two lmx modules. Compatibility " <>
          "identities differ; retained learning/TUI callbacks have no live " <>
          "migration. Restart and resume; qualify the final exact archive."
    },
    "windows" => %{
      mode: :restart,
      reason:
        "Windows uses manual restart/resume. New retention modules and changed " <>
          "host callbacks/dependencies also require fresh initialization. " <>
          "Qualify the exact Windows archives; no automatic installation or " <>
          "hot update/downgrade is declared."
    }
  }
}
