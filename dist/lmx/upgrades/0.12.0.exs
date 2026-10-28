# Release decision for 0.12.0 from the signed, published 0.11.0 archives.
# See upgrades/AGENTS.md and RELEASING.md, "Upgrade decisions".
#
# The local macos_silicon inspection against the exact 0.11.0 archive adds
# 93 Lemieux modules, changes 107 Lemieux modules and one lmx BEAM, and removes
# none. Lmx.Release.compatible?/2 is false. ERTS 17.1 and Elixir 1.20.4 match
# on this host, but dependency code identities do not. These observations do
# not qualify another platform or establish hot state compatibility. Module
# additions alone rule out the supported hot path on every target.
#
# Source/lifecycle review:
# - Session.Notification, CLI.Watches and the unified task view add observer
#   registration, durable delivery receipts, pending continuations and current
#   session ownership. Boot and request processing now account for this work;
#   no live installation of it into an existing 0.11.0 session is provided.
# - CLI learning installs host callbacks and process-local adaptation state;
#   controller reservations, exposure journals and transactional promotion bind
#   current policy, runtime and source identities. Restart/resume re-establishes
#   host authority instead of treating persisted evidence as executable state.
# - Changed TUI event/task/tool modules and harness hooks retain callbacks and
#   old references. No callback replacement, state/message migration or hot
#   rollback was implemented. ReqLLM 1.27 -> 1.29 and its LLMDB catalog also
#   change dependency code, which cannot be replaced by the supported hot path.
#
# Restart archives omit relup and advertise empty upgrade_from/hot_modules.
# Actual predecessor/candidate archives still require matching-host smoke and
# human terminal/provider qualification before tagging; this source decision
# is not a claim that those later checks have passed on every platform.
%{
  schema_version: 1,
  version: "0.12.0",
  from: "0.11.0",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "New watch/notification and learning modules, retained harness callbacks " <>
          "and ReqLLM/LLMDB dependency code require fresh initialization. No " <>
          "live state/message/callback migration or hot rollback is provided. " <>
          "Qualify the exact static-OTP/Linux archives; no hot path is declared."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "New session watch/learning lifecycles and changed TUI callbacks cannot " <>
          "be installed into existing 0.11.0 processes. Dependency code changed " <>
          "and no live migration or hot downgrade exists. Qualify the Intel " <>
          "archives, then restart and resume with current host authority."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "The actual 0.11.0/candidate inspection adds 93 Lemieux modules and " <>
          "changes dependency BEAM identities. Watch ownership, learning state " <>
          "and retained harness/TUI callbacks have no live migration. Restart " <>
          "the complete runtime and resume; no hot downgrade is declared."
    },
    "windows" => %{
      mode: :restart,
      reason:
        "Windows always requires manual restart/resume. New session watch and " <>
          "learning modules, retained callbacks and changed dependency code " <>
          "also require fresh process initialization. Qualify the Windows " <>
          "archives; no automatic or hot Windows installation is declared."
    }
  }
}
