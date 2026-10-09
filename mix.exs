defmodule Lemieux.MixProject do
  use Mix.Project

  # Dependabot evaluates a temporary copy of mix.exs without copying VERSION.
  # Keep this literal in sync with VERSION; MixProjectTest enforces the pair.
  @version "0.10.0"
  @source_url "https://github.com/houllette/lemieux"
  @description "The Elixir runtime behind the lmx coding agent: runs the model/tool loop " <>
                 "itself and records every session as an append-only transcript you can " <>
                 "resume, fork and replay. Embeds in any OTP app."

  # Built-in :cover observes the current BEAM node. These modules either run
  # on a child/remote node or only dispatch into an optional host, so counting
  # them measures test topology rather than exercised product logic. Protocol,
  # session, persistence, policy, tool, MCP, subagent and TUI implementation
  # modules remain in the report.
  @coverage_ignored_modules [
    Lemieux.A2A.Transport.Distribution,
    Lemieux.CLI.TUI,
    Lemieux.Eval.Attach,
    Lemieux.Eval.Runner,
    Mix.Tasks.Lemieux.Eval,
    Mix.Tasks.Lemieux.Eval.Bless,
    Mix.Tasks.Lmx,
    Mix.Tasks.Lmx.Tui
  ]

  def project do
    [
      app: :lemieux,
      version: @version,
      elixir: "~> 1.19",
      # `test/support` carries helpers that have to be *compiled*, not merely
      # loaded: `Lemieux.A2A`'s tests stand a second BEAM node up and call
      # into it, and a module defined in a `.exs` has no object code for
      # another node to resolve. Anything only one test needs still belongs
      # in that test.
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [&String.starts_with?(&1, "test/package_consumer/")],
      test_coverage: [
        ignore_modules: coverage_ignored_modules(),
        summary: [threshold: 80]
      ],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [
        # Under _build, not priv: a release copies the library's whole priv
        # tree, so a PLT at priv/plts shipped nine megabytes of cache in every
        # local lmx archive and changed its build identity on each Dialyzer run.
        #
        # Keyed by the Erlang installation, core PLT included: a reinstalled or
        # rebuilt Erlang of the same version (Homebrew's `_N` revisions) moves
        # its root, and a PLT built against the old one fails with "File not
        # found" instead of being rebuilt.
        plt_core_path: plt_dir(),
        plt_file: {:no_warn, Path.join(plt_dir(), "dialyzer.plt")},
        # CI runs Dialyzer under MIX_ENV=test, which compiles the test tree;
        # without :ex_unit in the PLT that fails with unknown_function.
        # :tribunal is declared runtime: false, which keeps it out of the
        # default PLT — without it every `@behaviour Tribunal.Judge` and
        # `Tribunal.Assertions` call is reported as unknown.
        plt_add_apps: [:ex_unit, :mix, :tribunal]
      ],
      # AGENTS.md is read into every agent session. Inlining every package's
      # rules put 16 KB of TUI-widget and provider-API guidance in front of
      # work that touches neither, so the two large sets are linked (read them
      # when working on the TUI or a provider) while the short Elixir and OTP
      # rules stay inline. A new dependency's rules must be added here by
      # name; `:all` no longer picks them up.
      usage_rules: [
        file: "AGENTS.md",
        usage_rules: [
          {:ex_ratatui, link: :markdown},
          {:req_llm, link: :markdown},
          :usage_rules
        ]
      ],
      name: "lemieux",
      description: @description,
      source_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  # No `mod:` on purpose — lemieux starts nothing when it is added as a
  # dependency. Hosts mount `Lemieux.Supervisor` into their own tree; see its
  # @moduledoc for why the decision belongs to the embedder.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Tests need MIX_ENV=test; without this the aliases would run in :dev.
  def cli do
    [
      preferred_envs: [
        precommit: :test,
        "precommit.full": :test,
        ci: :test,
        "test.distributed": :test,
        "test.fast": :test,
        "test.full": :test,
        "lemieux.eval": :test,
        "lemieux.eval.bless": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # The scripted test hosts are matched by pattern. The regex lives here, not
  # in the module attribute above: a compiled regex in a module attribute is
  # an ArgumentError on older Elixir/OTP pairs, which hid Mix's own "requires
  # Elixir ~> 1.19" message behind a stack trace.
  defp coverage_ignored_modules, do: @coverage_ignored_modules ++ [~r/^LemieuxTest\./]

  defp plt_dir,
    do: "_build/plts/otp-#{System.otp_release()}-#{:erlang.phash2(:code.root_dir())}"

  defp deps do
    [
      # The only provider seam there is. Every model call in this library goes
      # through req_llm; hand-rolled provider adapters are out of scope by
      # decision, so "add a provider" is an upstream concern rather than a
      # module in this tree.
      {:req_llm, "~> 1.27"},
      # Already in the tree through req_llm, and declared here because the MCP
      # client's HTTP transport calls it directly. Depending on a transitive
      # dependency works right up until the package that brought it swaps it
      # out.
      {:req, "~> 0.7"},
      # Agent Skills use YAML frontmatter. This is a direct runtime dependency
      # rather than an accidental ride through mix_audit: lmx reads SKILL.md in
      # production, where development-only transitive dependencies do not
      # exist, and a partial hand-written YAML parser would reject valid skills.
      {:yaml_elixir, "~> 2.12"},
      # Local shell output is model-controlled and can arrive much faster than
      # the tool consumer reads it. ExCmd keeps that path demand-driven instead
      # of letting an ordinary Port fill an unbounded BEAM mailbox. Its helper
      # executable is packaged in the standalone release's real `priv` tree.
      {:ex_cmd, "~> 0.18"},
      # Harness lifecycle telemetry is a public contract. req_llm already
      # brings this transitively, but calling it directly requires Lemieux to
      # declare it directly rather than relying on another package's tree.
      {:telemetry, "~> 1.3"},
      # The terminal UI, and `optional: true` is the whole of the argument.
      # This is a Rust NIF: it forces a native artifact, a supported triple
      # and a build-time download onto whoever depends on it, which is the
      # same category of imposition as a web or database dependency and is
      # ruled out for the same reason. Optional means this project resolves
      # it — the standalone `lmx` host and these tests get the real thing — while a host that
      # adds `{:lemieux, "~> 0.8"}` gets no NIF unless it asks by name.
      #
      # `Lemieux.TUI` is the only module that references it, nothing in the
      # core references `Lemieux.TUI`. The standalone host under `dist/lmx`
      # packages its NIF in a real release `priv` directory.
      {:ex_ratatui, "~> 0.17", optional: true},
      {:ascii, "~> 0.4.1", optional: true},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.8", only: [:dev, :test], runtime: false},
      # Evaluation assertions belong to the development and test toolchain,
      # not the embedded runtime. The release-grade comparison policy remains
      # Lemieux code because Tribunal's single-suite threshold cannot express
      # hard safety gates or paired model/version regressions.
      {:tribunal, "~> 3.0", only: [:dev, :test], runtime: false},
      # :test is required, not a typo — CI runs with MIX_ENV=test, and a
      # :dev-only dep makes mix usage_rules.sync unavailable there.
      {:usage_rules, "~> 1.2", only: [:dev, :test], runtime: false}
    ]
  end

  # The terminal UI and the slash commands are some seventy modules no host
  # calls, and the module list used to show every one of them beside the
  # supported API, so a screen helper read like a contract. Now only the seams
  # a host or extension implements are listed, together with every module
  # their public types, specs and callbacks name: those are part of the seam's
  # contract, and a visible type naming a hidden module fails
  # `docs --warnings-as-errors`. Computing that closure from the compiled
  # typespecs, rather than listing it, keeps a refactor that moves a type
  # between modules from breaking the docs build. A guide that names an
  # internal module still shows it as code, just not as a link.
  @documented_interface_modules [
    Lemieux.TUI,
    Lemieux.TUI.Followup,
    Lemieux.TUI.Keys,
    Lemieux.TUI.Layout,
    Lemieux.TUI.Renderer,
    Lemieux.TUI.Status,
    Lemieux.TUI.Theme,
    Lemieux.Conversation,
    Lemieux.Conversation.Command
  ]

  # CI builds docs in :test; its scripted hosts are fixtures, not library APIs.
  defp documented_module?(module, _metadata),
    do: not String.starts_with?(inspect(module), "LemieuxTest.") and not hidden_module?(module)

  # Terms arrive as written in backticks: `Mod`, `Mod.fun/1`, `t:Mod.t/0`.
  defp internal_reference?(term) do
    case Regex.run(~r/^(?:[a-z]:)?((?:[A-Z][A-Za-z0-9_]*\.)*[A-Z][A-Za-z0-9_]*)/, term) do
      [_match, name] -> hidden_module?(Module.concat([name]))
      nil -> false
    end
  end

  defp hidden_module?(module),
    do: implementation_namespace?(module) and not MapSet.member?(documented_interface(), module)

  # Host internals and implementation submodules: hidden unless a visible
  # contract (a public type, spec or callback) names them. `lmx`'s own
  # command modules are a host, not an API; the support policy already says
  # "private CLI assembly" is not an extension surface.
  defp implementation_namespace?(module),
    do:
      String.match?(
        inspect(module),
        ~r/^Lemieux\.(TUI|Conversation|CLI|Tools\.Search|Tools\.ApplyPatch|Tools\.Edit|Tools\.AskUser)\.|^Lemieux\.A2A\.(JSONRPC|SSE|Journal)$/
      )

  # ExDoc calls the filter from many processes; the closure is computed once.
  defp documented_interface do
    key = {__MODULE__, :documented_interface}

    with nil <- :persistent_term.get(key, nil) do
      seams = MapSet.new(@documented_interface_modules)
      closure = expose(@documented_interface_modules, seams)
      :persistent_term.put(key, closure)
      closure
    end
  end

  defp expose([], visible), do: visible

  defp expose(frontier, visible) do
    named =
      frontier
      |> Enum.flat_map(&contract_modules/1)
      |> Enum.filter(&implementation_namespace?/1)
      |> Enum.reject(&MapSet.member?(visible, &1))
      |> Enum.uniq()

    expose(named, Enum.into(named, visible))
  end

  # Modules named by what ExDoc renders for `module`: public types, and the
  # specs and callbacks that are not `@doc false`.
  defp contract_modules(module) do
    hidden =
      case Code.fetch_docs(module) do
        {:docs_v1, _, _, _, _, _, docs} ->
          for {{kind, name, arity}, _, _, :hidden, _} <- docs, do: {kind, name, arity}

        _no_docs ->
          []
      end

    types =
      for {:type, {name, _, args} = type} <- fetched(Code.Typespec.fetch_types(module)),
          {:type, name, length(args)} not in hidden,
          do: type

    specs =
      for {{name, arity}, spec} <- fetched(Code.Typespec.fetch_specs(module)),
          {:function, name, arity} not in hidden,
          do: spec

    callbacks =
      for {_name_arity, callback} <- fetched(Code.Typespec.fetch_callbacks(module)), do: callback

    remote_types([types, specs, callbacks], [])
  end

  defp fetched({:ok, entries}), do: entries
  defp fetched(:error), do: []

  defp remote_types({:remote_type, _, [{:atom, _, module}, _name, args]}, acc),
    do: remote_types(args, [module | acc])

  defp remote_types(term, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> remote_types(acc)

  defp remote_types(term, acc) when is_list(term), do: Enum.reduce(term, acc, &remote_types/2)
  defp remote_types(_term, acc), do: acc

  defp docs do
    [
      main: "guides",
      filter_modules: &documented_module?/2,
      skip_code_autolink_to: &internal_reference?/1,
      assets: %{"docs/assets" => "docs/assets"},
      extra_section: "Guides",
      extras: [
        {"docs/index.md", filename: "guides", title: "Overview"},
        "docs/why-lemieux.md",
        "docs/getting-started.md",
        "docs/everyday.md",
        "docs/first-embedded-agent.md",
        "docs/customization.md",
        "docs/first-extension.md",
        "docs/releases.md",
        "docs/desktop.md",
        "docs/cli.md",
        "docs/configuration.md",
        "docs/troubleshooting.md",
        "docs/embedding.md",
        "docs/transcript-compatibility.md",
        "docs/telemetry.md",
        "docs/extensions.md",
        "docs/tool-contracts.md",
        "docs/hooks.md",
        "docs/compaction.md",
        "docs/workflows.md",
        "docs/subagents.md",
        {"docs/terminal-ui.md", title: "Customizing the terminal UI"},
        "docs/providers.md",
        "docs/ixway.md",
        "docs/mcp.md",
        "docs/web-tools.md",
        "docs/a2a.md",
        "docs/support.md",
        "docs/roadmap.md",
        "docs/agent-extensions.md",
        "docs/reflection.md",
        "docs/harness-learning.md",
        "docs/benchmarking.md",
        "docs/evaluations.md",
        "docs/host-integration.md",
        "docs/acceptance.md",
        "README.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "CHANGELOG.md",
        "LICENSE"
      ],
      groups_for_modules: [
        "Start here": [
          ~r/^Lemieux$/,
          ~r/^Lemieux\.(Supervisor|Session|Harness|Extension|Tool|Hooks|Store|Provider|Environment|Testing)$/,
          ~r/^Lemieux\.Providers\.(Scripted|ReqLLM)$/
        ],
        "Sessions and transcripts": [
          ~r/^Lemieux\.(Turn|Request|Usage|Reference|Entry|RequestSnapshot)$/,
          ~r/^Lemieux\.(Session|Clock|ID|JSON|Store|Transcript|Checkpoint)(\.|$)/
        ],
        "Harnesses and shipped extensions": [~r/^Lemieux\.(Extension|Extensions|Harness)(\.|$)/],
        "Hooks and policy": [~r/^Lemieux\.Hooks/],
        "Context and compaction": [~r/^Lemieux\.(Context|Compaction|Messages|Prompt)(\.|$)/],
        "Tools and environments": [
          ~r/^Lemieux\.(Tool|Tools|Environment|WebSearch|WebFetch|Background)/
        ],
        "Providers and routing": [
          ~r/^Lemieux\.(Provider|ProviderLimiter|Providers|ModelSpec|ModelCatalog|Ixway)/
        ],
        "Subagents (delegation)": [~r/^Lemieux\.(Subagent|Progress)/],
        "MCP integration": [~r/^Lemieux\.MCP/],
        "Agent-to-agent (A2A)": [~r/^Lemieux\.A2A/],
        "Running Elixir": [~r/^Lemieux\.Eval/],
        Observability: [~r/^Lemieux\.(Telemetry|OpenTelemetry)/],
        "Terminal UI customization": [~r/^Lemieux\.(CLI|Conversation|TUI|Clipboard|Terminal)/],
        "Experimental: benchmarking and agent extensions": [
          ~r/^Lemieux\.(Benchmark|Agent)(\.|$)/
        ],
        "Experimental: feedback and harness learning": [
          ~r/^Lemieux\.(Learning|Evidence|Reflection|Feedback|Asset|Experiment|Contract)(\.|$)/
        ],
        "Mix tasks": [~r/^Mix\.Tasks\./]
      ],
      groups_for_extras: [
        "Start here": [
          "docs/index.md",
          "docs/why-lemieux.md",
          "docs/getting-started.md",
          "docs/everyday.md",
          "docs/first-embedded-agent.md",
          "docs/customization.md",
          "docs/first-extension.md"
        ],
        "Using lmx": [
          "docs/releases.md",
          "docs/desktop.md",
          "docs/cli.md",
          "docs/configuration.md",
          "docs/troubleshooting.md"
        ],
        "Embedding Lemieux": [
          "docs/embedding.md",
          "docs/transcript-compatibility.md",
          "docs/telemetry.md"
        ],
        "Customizing Lemieux": [
          "docs/extensions.md",
          "docs/tool-contracts.md",
          "docs/hooks.md",
          "docs/compaction.md",
          "docs/workflows.md",
          "docs/subagents.md",
          "docs/terminal-ui.md"
        ],
        Integrations: [
          "docs/providers.md",
          "docs/ixway.md",
          "docs/mcp.md",
          "docs/web-tools.md",
          "docs/a2a.md"
        ],
        "Support and roadmap": [
          "docs/support.md",
          "docs/roadmap.md"
        ],
        # Last before the project files: these change in any 0.x release, and a
        # newcomer browsing the sidebar should meet the supported surface first.
        "Experimental: learning and evaluation": [
          "docs/agent-extensions.md",
          "docs/reflection.md",
          "docs/harness-learning.md",
          "docs/benchmarking.md",
          "docs/evaluations.md",
          "docs/host-integration.md",
          "docs/acceptance.md"
        ],
        Project: [
          "README.md",
          "CONTRIBUTING.md",
          "SECURITY.md",
          "CHANGELOG.md",
          "LICENSE"
        ]
      ],
      source_url: @source_url,
      # HexDocs' "view source" links point at the tag the package was built
      # from, not at a main branch that moves on after publishing.
      source_ref: System.get_env("LEMIEUX_DOCS_REF", "v#{@version}")
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "priv/skills",
        # `lmx desktop install` copies the icon from here.
        "priv/desktop",
        "priv/a2ui",
        # Publish current guides; campaign artifacts stay outside the package.
        "docs/**/*.md",
        "VERSION",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "LICENSE",
        "NOTICE"
      ],
      maintainers: ["Holden Oullette"],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => @source_url <> "/blob/main/CHANGELOG.md",
        "GitHub" => @source_url,
        "Security policy" => @source_url <> "/blob/main/SECURITY.md"
      }
    ]
  end

  defp aliases do
    [
      precommit: [
        "deps.unlock --check-unused",
        # The audits read mix.lock only, and MUST precede compile: `mix
        # compile` drops the Hex archive from the code path for the rest of
        # the alias, so a later hex.audit dies with "task could not be found".
        "hex.audit",
        "deps.audit",
        # The installed binary resolves its own lock, so it is audited too. In
        # its own process: Mix runs a task once per invocation, so a second
        # `deps.audit` here would silently do nothing.
        "cmd env MIX_ENV=test mix deps.audit --path dist/lmx",
        "deps.drift",
        "compile --warnings-as-errors",
        "format",
        "credo --strict",
        # Igniter-backed and interactive: bare, it prompts and hangs a
        # non-interactive shell. --yes writes, --check (what CI runs) doesn't.
        "usage_rules.sync --yes",
        "xref graph --label compile-connected --fail-above 0",
        "docs --warnings-as-errors",
        # --raise: without it a failing suite only sets the exit status at
        # exit, and the alias ran on to end on the release host's green
        # "35 passed" line.
        "test --warnings-as-errors --raise",
        # The first run builds a PLT cache under _build/plts and is slow; with
        # the cache in place the check is fast enough for the edit loop, and
        # keeping it here keeps "green precommit means green CI" true.
        "dialyzer",
        # The installed executable is a deliberately separate Mix project so
        # the library can remain mod-free. Keep its small gate inside the root
        # precommit so "green here means green in CI" remains true.
        "cmd --cd dist/lmx mix deps.get",
        "cmd --cd dist/lmx mix deps.unlock --check-unused",
        "cmd --cd dist/lmx mix hex.audit",
        "cmd --cd dist/lmx mix compile --warnings-as-errors",
        "cmd --cd dist/lmx mix format",
        "cmd --cd dist/lmx mix test --warnings-as-errors"
      ],
      # The same gate with nothing rewritten, for pipelines. `precommit`
      # formats and regenerates the usage rules so a contributor can commit
      # the result; a release job that ran it validated a tree it had just
      # changed, and would have passed an unformatted tag.
      ci: [
        "deps.unlock --check-unused",
        "hex.audit",
        "deps.audit",
        "cmd env MIX_ENV=test mix deps.audit --path dist/lmx",
        "deps.drift",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "usage_rules.sync --check",
        "xref graph --label compile-connected --fail-above 0",
        "docs --warnings-as-errors",
        "test --warnings-as-errors --raise",
        "dialyzer",
        "cmd --cd dist/lmx mix deps.get",
        "cmd --cd dist/lmx mix deps.unlock --check-unused",
        "cmd --cd dist/lmx mix hex.audit",
        "cmd --cd dist/lmx mix compile --warnings-as-errors",
        "cmd --cd dist/lmx mix format --check-formatted",
        "cmd --cd dist/lmx mix test --warnings-as-errors"
      ],
      # Everything CI runs beyond `precommit`: the multi-node suite, the Hex
      # package consumer, every example project CI checks, and the Python
      # release helpers. It needs network access (audits and each example's
      # own deps.get) and python3, and it is slow; run it before a release or
      # when a change reaches the examples or the package boundary.
      "precommit.full": [
        "precommit",
        # Its own process: Mix runs a task once per invocation, and
        # `precommit` has already run `test`.
        "cmd mix test.distributed",
        "cmd scripts/check_package.sh",
        "cmd scripts/check_example.sh builder capture computer_use hello research review security systemone_compaction verifier",
        "cmd python3 -m unittest discover -s test -p 'test_*.py'"
      ],
      # The release host is a separate Mix project with its own lock, so a
      # bump here never reaches the binary on its own. Drift is refused unless
      # reviewed: the bundled System One compaction extension's SDK pulls
      # in sinter 0.3.2, which pins jsv ~> 0.21.2 (and with it texture 1.x),
      # and pristine 0.4.0, which pins finch ~> 0.23.0. The library resolves
      # jsv 0.26.0 and finch 0.24.0. Drop each exception when its upstream
      # constraint relaxes; the check says when that happens.
      "deps.drift":
        "cmd elixir scripts/check_lock_drift.exs --allow finch,jsv,texture mix.lock dist/lmx/mix.lock",
      "test.distributed": [
        "cmd epmd -daemon",
        "test --only distributed --warnings-as-errors"
      ],
      "test.fast": "test --warnings-as-errors --raise",
      # The distributed suite runs as a second `mix` process. Mix runs a task
      # once per invocation, so a second `test` in the same alias was silently
      # skipped: this alias used to run only the ordinary suite.
      "test.full": ["test.fast", "cmd mix test.distributed"]
    ]
  end
end
