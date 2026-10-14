# Release decision for 0.11.0 from the signed, published 0.10.0 archives.
# See upgrades/AGENTS.md and RELEASING.md, "Upgrade decisions".
#
# The inspection build compared with the exact macos_silicon 0.10.0 archive
# adds 78 Lemieux modules, changes 96 Lemieux modules and one lmx module,
# removes none, and fails Lmx.Release.compatible?/2 because dependency BEAM
# identities differ. ERTS, Elixir, dependency versions and native/config digests
# match on this local host; these observations do not qualify other build hosts.
# Module additions alone rule out the supported hot path on every target.
#
# Source/state review establishes further reasons to initialize a fresh VM:
# - Session.State now owns execution recovery, job-budget leases, current input
#   capture, scoped approval challenges, contribution runtime, document requests
#   and work-owner monitors. Session initialization creates these; no code_change
#   migration from 0.10.0 exists. Jobs and writers add host-owned supervision,
#   custody/recovery and lifecycle callbacks, never reconstructed authority.
# - Harness adds job limits, contributions, ingress and approval/capture options;
#   assembly records effective tool ownership and inactive contributions. Existing
#   hooks, captured callbacks and pending approvals are not migrated in place.
# - ManagedStdio/StdioLifecycle add bounded pending-frame, stderr and port/process
#   ownership. Existing 0.10.0 connections cannot acquire this lifecycle state by
#   replacing client code. The TUI's new plan/review/status and transcript rows
#   likewise have no live state migration.
#
# No hot state/message/closure migration or hot downgrade is declared. Restart
# archives omit relup and advertise empty upgrade_from/hot_modules. Actual old/new
# archives must pass matching-host restart/resume qualification; human terminal
# and provider checks remain part of the maintainer's procedure before tagging.
%{
  schema_version: 1,
  version: "0.11.0",
  from: "0.10.0",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "New ACP/job/writer/repository-context modules and session recovery, " <>
          "job-budget, input, approval and contribution state require fresh " <>
          "initialization. MCP stdio ownership and retained host callbacks have " <>
          "no live migration. The exact static-OTP/dependency identities must be " <>
          "qualified on Linux; no hot path or runtime replacement is declared."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "New modules and session/harness recovery, budget, input, approval and " <>
          "contribution state cannot be installed into a 0.10.0 process. MCP " <>
          "connections, TUI workflow rows and retained callbacks have no live " <>
          "migration. Qualify the Intel archives, then restart and resume."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "The actual 0.10.0/candidate inspection adds 78 Lemieux modules and " <>
          "changes dependency BEAM identities. New session recovery/job leases, " <>
          "input capture, scoped approvals, contributions and MCP lifecycle " <>
          "state have no live migration. Restart the complete runtime and resume."
    },
    "windows" => %{
      mode: :restart,
      reason:
        "Windows always uses manual restart/resume. New ACP/job/writer/context " <>
          "modules and session recovery, input, approval, contribution and MCP " <>
          "ownership state also require a fresh process. No automatic or hot " <>
          "Windows installation is declared."
    }
  }
}
