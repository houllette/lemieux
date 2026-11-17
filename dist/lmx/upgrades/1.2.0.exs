# Reviewed restart decision from the signed, published 1.1.3 archives.
# All four predecessor archives were verified against signed SHA256SUMS and
# unpacked. This source/state review is separate from qualification of the
# final 1.2.0 archives; reports belong on the release PR, not in release notes.
#
# The local macos_silicon inspection uses predecessor build
# 12b80ff88294e13f1b1dfb761dd63535866fdc57f4524b3a37aa4531ce9e6a8d.
# It adds five ACP modules, CLI.Tasks.Verification and Extensions.Verify.Work,
# changes 30 Lemieux modules and one lmx module, and removes none. ExRatatui
# changes from 0.20.0 to 0.21.0, NimblePool from 1.1.0 to 1.2.0 and Telemetry
# from 1.4.2 to 1.4.3. Release.compatible?/2 is false. This inspection locates
# review work; it proves neither hot compatibility nor another host's results.
#
# State/message/callback review:
# - ACP.Server initializes negotiated filesystem, elicitation and authentication
#   fields. Its session maps now hold queued prompts, MCP servers, config options
#   and diffs; pending filesystem requests retain callers, monitors and timeout
#   messages. Tool adapters capture the server/session bridge in local functions.
#   Loading new code cannot initialize old server/session maps or migrate pending
#   replies. Connection teardown cancels work; reconnect initializes the bridge.
# - Verify.Work adds a temporary GenServer under the background supervisor and
#   registers per-session verification identities. It retains task/owner/session
#   monitors and record callbacks, with progress, cancellation and expiry messages.
#   CLI.Tasks reads that process; TUI.Events/Lifecycle restore its explicit phase
#   from extension documents. Old hooks cannot be converted to this ownership
#   model in place. Restart cancels old work and resume keeps durable evidence.
# - TUI.Setup adds native?/suspended? hover fields. Hover and TUI editor handoff
#   call ExRatatui's new pointer lifecycle API; its native library changes too.
#   Composer, Tasks and event callbacks can be retained by the running screen;
#   CLI.TUI's local signal trap also retains code. No whole-VM callback replacement,
#   state conversion or hot rollback is implemented. Seven added modules and
#   changed runtime dependencies independently require restart under today's rules.
# - Session.Calls accepts fast-mode changes while busy; Prompts reconciles held
#   preparation requests before dispatch. In-flight requests keep their parameters.
#   Supported 1.x APIs, transcript schemas, personal config version 1 and extension
#   API 1 remain compatible. Draft ACP v2's experimental shapes/namespace change
#   is documented; v1 keeps its namespace. Ordinary restart/resume retains budgets.
# - No live downgrade is declared. Each final archive must qualify cold boot,
#   packaged tools and old-transcript resume against its exact signed predecessor.
#   Linux's static OTP/native build and Intel macOS need their own qualification;
#   neither is inferred from Apple Silicon. Windows remains manual restart/resume.
# See upgrades/AGENTS.md and RELEASING.md, "Upgrade decisions".
%{
  schema_version: 1,
  version: "1.2.0",
  from: "1.1.3",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "New ACP/verification modules, pending client replies, retained TUI " <>
          "callbacks and native hover state have no live migration. ExRatatui, " <>
          "NimblePool and Telemetry change. Restart/resume and qualify the exact " <>
          "static-OTP Linux archive against signed 1.1.3; no hot downgrade."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "ACP server/session maps, verification ownership, TUI hover fields " <>
          "and captured callbacks need fresh initialization. Seven modules " <>
          "and the ExRatatui native update have no live migration. Qualify " <>
          "restart/resume with the Intel archive and signed 1.1.3 separately " <>
          "from the Apple Silicon inspection; no hot downgrade."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "The inspection adds seven modules and changes 30 Lemieux and one " <>
          "lmx module; runtime dependencies differ. Old ACP maps and TUI hover " <>
          "state lack new fields, verifier ownership changes and callbacks " <>
          "retain old code. No live conversion or rollback exists. Qualify " <>
          "restart/resume with the final archive against signed 1.1.3."
    },
    "windows" => %{
      mode: :restart,
      reason:
        "Windows requires manual restart/resume with Git Bash. New ACP and " <>
          "verification modules, retained server/TUI state and callbacks, " <>
          "and changed native/runtime dependencies have no live migration " <>
          "or hot downgrade. Qualify cold boot, packaged tools and old-transcript " <>
          "resume with the exact Windows archive and signed 1.1.3."
    }
  }
}
