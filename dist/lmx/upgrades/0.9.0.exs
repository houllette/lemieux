# The release decision for 0.9.0, from 0.8.1 (RELEASING.md, "Upgrade
# decisions"; the review procedure is upgrades/AGENTS.md).
#
# Restart on every platform, for reasons any one of which rules out a hot
# path. `mix lmx.upgrade.draft` against the published 0.8.1 macos_silicon
# archive reported:
#
# - a new runtime: ERTS 17.0.2 to 17.1 and Elixir 1.20.2 to 1.20.4 (Erlang/OTP
#   29.0.2 to 29.1.1), with kernel, stdlib, ssl, crypto and the other OTP
#   applications moving with it, and a hot path needs ERTS, Elixir and
#   dependency code to match exactly;
# - a changed dependency set: the bundled lemieux_jev_compaction application is
#   gone and lemieux_systemone_compaction replaces it;
# - removed and added modules, which a hot path cannot carry
#   (Lmx.UpgradePlan.qualify!/3): Lemieux.CLI.JevCompaction is removed, and
#   Lemieux.CLI.Routes, Lemieux.CLI.SystemOne, Lemieux.CLI.SystemOneCompaction,
#   Lemieux.Extension.Routes and Lemieux.Extensions.Continuation are added;
# - Lemieux.CLI.TUI changed, and its SIGTERM trap is a local function the
#   signal server holds while a screen runs (RELEASING.md names it as always
#   needing a restart).
#
# A running 0.8.1 also reads its config under the old "jev_compaction" keys,
# which 0.9.0 refuses at startup; only a fresh start applies that check.
# Nothing about restart needs a relup, and the archives carry none.
%{
  schema_version: 1,
  version: "0.9.0",
  from: "0.8.1",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "0.9.0 runs a new ERTS and Elixir (Erlang/OTP 29.1.1, Elixir 1.20.4; 0.8.1 is " <>
          "29.0.2 and 1.20.2), replaces the bundled lemieux_jev_compaction application " <>
          "with lemieux_systemone_compaction, removes Lemieux.CLI.JevCompaction and adds five " <>
          "modules, and changes Lemieux.CLI.TUI. Linux stays restart until two builds from " <>
          "scratch have matched their OTP application digests."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "0.9.0 runs a new ERTS and Elixir (Erlang/OTP 29.1.1, Elixir 1.20.4; 0.8.1 is " <>
          "29.0.2 and 1.20.2), replaces the bundled lemieux_jev_compaction application " <>
          "with lemieux_systemone_compaction, removes Lemieux.CLI.JevCompaction and adds five " <>
          "modules, and changes Lemieux.CLI.TUI."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "0.9.0 runs a new ERTS and Elixir (Erlang/OTP 29.1.1, Elixir 1.20.4; 0.8.1 is " <>
          "29.0.2 and 1.20.2), replaces the bundled lemieux_jev_compaction application " <>
          "with lemieux_systemone_compaction, removes Lemieux.CLI.JevCompaction and adds five " <>
          "modules, and changes Lemieux.CLI.TUI."
    },
    "windows" => %{
      mode: :restart,
      reason: "Windows always restarts; the archive is installed by hand, and never hot."
    }
  }
}
