# Reviewed restart decision from the signed, published 1.1.0 archives.
# All four predecessor archives were verified against signed SHA256SUMS and
# unpacked; their release identities match the signed 1.1.0 update manifest.
# This records source/state review, not qualification of final 1.1.1 bytes.
#
# The local macos_silicon inspection compares predecessor build
# b77b5e76efd6ae4fcc35cc60abc5af383bf97481592f7ee9a61cb49e0f6aae10.
# It adds Lemieux.TUI.Hover, changes 25 Lemieux modules and one lmx module,
# and removes none. Release.compatible?/2 is false for that inspection.
# A binary diff locates review work; it does not establish state compatibility.
#
# State/message/callback review:
# - Context adds planning_window, compact_at, price_compaction? and
#   cache_reporting; Conversation adds cost_bases and cost_references. Retained
#   structs have no live conversion. Fresh replay/initialization reconstructs
#   reporting state without resetting consumed budgets or host authorization.
# - TUI.Setup installs terminal.hover (enabled?, shape and the prior event).
#   TUI handlers now pass through the new Hover module. Old process state
#   lacks that map, and retained input/render/transport callbacks are not
#   replaced by loading new BEAMs. New modules independently require restart.
# - Provider usage provenance and Session.Compacting context-policy fields
#   feed retained conversation/TUI accumulators and in-flight stream callbacks.
#   Retry classification and planning text also change existing callback code;
#   no live state/message/closure migration or hot downgrade is implemented.
# - MCP stderr isolation already shipped in 1.1.0. This patch's diagnostic
#   documentation/tests do not establish a new pipe-ownership migration.
# - Source fixes do not prove matching native/static-OTP identities on other
#   platforms. All targets restart into fresh state; Windows remains manual.
# See upgrades/AGENTS.md and RELEASING.md, "Upgrade decisions".
%{
  schema_version: 1,
  version: "1.1.1",
  from: "1.1.0",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "Context/conversation reporting structs and retained TUI state changed, " <>
          "and the new Hover module has no live migration. Restart/resume on " <>
          "the exact static-OTP candidate; no matching native identity or safe " <>
          "callback replacement is assumed. Qualify the final Linux archive."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "New terminal.hover state and Hover routing, context/cost accumulators " <>
          "and retained input/provider callbacks require fresh initialization. " <>
          "No live state/message/closure conversion or hot downgrade exists. " <>
          "Restart/resume and qualify the exact Intel archive."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "The inspection adds Hover and changes 25 Lemieux and one lmx module; " <>
          "compatibility identities differ. Old TUI state lacks terminal.hover " <>
          "and context/conversation structs lack reporting fields. No live " <>
          "migration exists. Restart/resume and qualify the final archive."
    },
    "windows" => %{
      mode: :restart,
      reason:
        "Windows requires manual restart/resume. New Hover routing and retained " <>
          "TUI/context/conversation state also need fresh initialization; no " <>
          "live migration or hot downgrade is declared. Qualify the exact " <>
          "Windows archive with Git Bash."
    }
  }
}
