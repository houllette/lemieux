# Reviewed restart decision from the signed, published 1.1.2 archives.
# All four predecessor archives were verified against signed SHA256SUMS and
# unpacked; their release identities match the signed 1.1.2 update manifest.
# This is a source/state review, not qualification of final 1.1.3 bytes.
#
# The local macos_silicon inspection compares predecessor build
# 76e3aebdb1a2c2ebf77c1c0adf295ac5d997c6a43f1d38865307159e5363e5eb.
# It adds TUI.Chrome, TUI.PlanInspector and TUI.ProgramStatus, changes
# 32 Lemieux modules and one lmx module, and removes none. Runtime and
# dependency versions match, but compiled dependency identities differ and
# Release.compatible?/2 is false. A module diff locates review work; it
# establishes neither live compatibility nor another platform's qualification.
#
# State/message/callback review:
# - Conversation retains :fast_mode; Session.Catalog emits the additive
#   :fast_mode_changed event. Old conversation structs lack the field. TUI
#   hydration reconstructs it from session configuration after restart/resume;
#   there is no live struct conversion or reverse conversion for downgrade.
# - TUI.Setup initializes terminal chrome_since/chrome_timer/status_rotation,
#   program_status callback/title settings and deduplication fields, plus
#   session_view.plan_collapsed?. Old screens lack these fields. Chrome owns
#   token-fenced :chrome_tick timers and the plan inspector adds modal state;
#   loading code cannot initialize that retained state or queued messages.
# - ProgramStatus runs outside rendering and its default local closure has
#   two arguments. Existing one-argument host callbacks remain supported.
#   Input/render/provider callbacks and CLI.TUI's local signal trap can retain
#   old module code; no whole-VM replacement or closure migration exists.
#   The three new modules independently require restart under today's rules.
# - Existing plan/transcript schemas, personal config version 1, extension
#   API 1 and supported 1.x contracts remain compatible. Optional OSC title
#   metadata defaults off and changes no session identity or host authority.
#   Restart/resume uses the ordinary transcript seams and consumed budgets.
# - No hot rollback is declared. Restart installs a complete runtime; each
#   final archive must qualify cold boot, packaged tools and old-transcript
#   resume against its exact signed predecessor. Linux static-OTP/native
#   compatibility is not inferred from this macOS inspection. Windows keeps
#   manual restart/resume with Git Bash.
# See upgrades/AGENTS.md and RELEASING.md, "Upgrade decisions".
%{
  schema_version: 1,
  version: "1.1.3",
  from: "1.1.2",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "Conversation fast-mode state and TUI chrome/status/callback fields " <>
          "need fresh initialization. Three new presentation/status modules " <>
          "and queued chrome timers have no live migration. Restart/resume " <>
          "on the exact static-OTP candidate; qualify the final Linux archive " <>
          "against signed 1.1.2 without inferring native compatibility."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "Retained conversation/TUI state, chrome timers and local callbacks " <>
          "need fresh initialization. New Chrome, PlanInspector and " <>
          "ProgramStatus modules have no live migration or hot downgrade. " <>
          "Qualify restart/resume with the exact Intel archive and signed " <>
          "1.1.2 predecessor; the Apple Silicon inspection is separate."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "The inspection adds three TUI modules and changes 32 Lemieux and " <>
          "one lmx module; compiled dependency identities differ. Old screens " <>
          "lack chrome timers, status callbacks and Todo collapse state, and " <>
          "old conversations lack fast_mode. No live conversion or callback " <>
          "replacement exists. Restart/resume and qualify the final archive " <>
          "against signed 1.1.2."
    },
    "windows" => %{
      mode: :restart,
      reason:
        "Windows requires manual restart/resume with Git Bash. Conversation " <>
          "fast-mode state, TUI chrome/status state, retained callbacks and " <>
          "three new TUI modules have no live migration or hot downgrade. " <>
          "Qualify cold boot, packaged tools and old-transcript resume with " <>
          "the exact Windows archive and signed 1.1.2 predecessor."
    }
  }
}
