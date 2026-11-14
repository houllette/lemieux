# Reviewed restart decision from the signed, published 1.1.1 archives.
# All four predecessor archives were verified against signed SHA256SUMS and
# unpacked; their release identities match the signed 1.1.1 update manifest.
# This is a source/state review, not qualification of final 1.1.2 bytes.
#
# The local macos_silicon inspection compares predecessor build
# b0246bc7ee7137e42d8c4fd51032b1468b03e1a8f26d386365ecfaebbada95cc.
# It adds TUI.Cost, TUI.Responsive and TUI.Snippets, changes 32 Lemieux
# modules and one lmx module, and removes none. Release.compatible?/2 is
# false for that inspection. A binary diff locates review work; it does not
# establish state compatibility or qualify another platform's archive.
#
# State/message/callback review:
# - Environment.Sandbox adds :active. CLI.Runtime supplies a local closure
#   over the session's Permissions.Handle for the implicit sandbox. Existing
#   sandbox structs lack that field and existing harnesses lack the closure;
#   loading code does not rebuild either. Explicit host sandboxes keep their
#   authority. Already-selected command streams keep their original wrapper.
# - TUI turn usage adds :rate, status adds :scroll_frame, cursor-blink state
#   adds its frame counter and animation overlays add :boot?. Snippet source
#   metadata and pointer press/selection targets change retained presentation
#   state. No live state/message conversion or callback replacement exists.
# - The three added TUI modules independently require restart. Input, render,
#   pointer, clock and provider callbacks can retain old local code; soft
#   purge and the runtime callback guard are not a whole-VM closure inventory.
# - Planning restores old flat version-1 documents and optionally retains
#   parent_id for children. Restart/resume reconstructs derived parent state,
#   progress and presentation through the ordinary transcript/document seams;
#   it does not reset consumed budgets or grant host authorization.
# - No hot rollback is declared. Restart installation selects a complete new
#   runtime, with actual cold-boot/tool/resume qualification required for each
#   final archive. Source review does not prove matching native/static-OTP
#   identities on other platforms. Windows remains manual restart/resume.
# See upgrades/AGENTS.md and RELEASING.md, "Upgrade decisions".
%{
  schema_version: 1,
  version: "1.1.2",
  from: "1.1.1",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "The implicit sandbox needs a new activation field and session-owned " <>
          "closure; TUI state/callbacks and three new presentation modules " <>
          "have no live migration. Restart/resume on the exact static-OTP " <>
          "candidate; native compatibility is not inferred from source. " <>
          "Qualify the final Linux archive against signed 1.1.1."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "Sandbox activation closures, turn/status/overlay state and retained " <>
          "input/render/pointer callbacks require fresh initialization. New " <>
          "Cost, Responsive and Snippets modules also require restart. No " <>
          "live conversion or hot downgrade exists. Qualify restart/resume " <>
          "with the exact Intel archive and signed 1.1.1 predecessor."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "The inspection adds three TUI modules and changes 32 Lemieux and " <>
          "one lmx module; compatibility identities differ. Old sandbox " <>
          "state lacks :active and its permission closure, and TUI state " <>
          "and retained callbacks have no live conversion. Restart/resume " <>
          "and qualify the final archive against signed 1.1.1."
    },
    "windows" => %{
      mode: :restart,
      reason:
        "Windows requires manual restart/resume with Git Bash. New sandbox " <>
          "activation/TUI state, retained callbacks and the three new TUI " <>
          "modules have no live migration or hot downgrade. Qualify cold " <>
          "boot, packaged tools and old-transcript resume with the exact " <>
          "Windows archive and signed 1.1.1 predecessor."
    }
  }
}
