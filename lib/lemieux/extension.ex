defmodule Lemieux.Extension do
  @moduledoc """
  Code that shapes a `Lemieux.Harness` before a session starts.

  Every opinion the loop can be talked out of is a field on the harness: the
  prompt, the catalog, the hooks, how compaction is done, what the model is
  told when a call is denied, which MCP servers to start, how much may be
  spent. A host that writes those options by hand is already covered by
  `Lemieux.Session.start_link/1`. An extension is for the case where the
  opinion is somebody else's code — a Mix dependency, a file the binary
  loaded, the TUI's own defaults — and has to be applied without forking the
  host: it receives the harness as it stands and returns the harness as it
  should be.

  ## Overload and extend

  Two moves cover what an extension does, and the struct makes both plain:

    * **Overload** is replacing a field. `%{harness | compaction: {MyCompaction, opts}}`
      swaps the summariser; `%{harness | system: my_prompt}` swaps the prompt.
      Whatever an earlier extension put there is gone, which is the point.
    * **Extend** is wrapping what is there. `Lemieux.Harness.update_tools/2`
      with `Lemieux.Tool.decorate/2` puts an audit around `bash` and leaves
      the other tools alone; `Lemieux.Harness.append_hooks/2` adds a policy
      beside the host's; `Lemieux.Harness.append_host_tools/2` adds a loader.
      Whatever was there is still there, underneath.

  Because both read the harness before writing it, **order matters**: an
  extension that wraps `bash` must come after the one that put `bash` in the
  catalog, and one that replaces the catalog undoes every wrap before it.
  `Lemieux.Harness.assemble/2` applies a list left to right and says so in the
  provenance it records, so a surprising catalog can be read back to the
  extension that produced it rather than guessed at.

  Assembly chooses defaults. An explicit session option beside `harness:`
  is the host's final choice, including its hooks, environment and budgets.
  Extensions run as trusted code in the host VM; these composition rules
  prevent accidental overrides and are not a sandbox for hostile code.

  ## Size of the contract

  The extension contract is this behaviour, the documented harness fields
  and helpers, and the behaviours those fields select. An extension does
  not need the CLI loader, TUI implementation, session state structs, or
  transcript reconstruction machinery. Prefer an ordinary Mix dependency
  when embedding. Shipped extensions are defaults a host chooses, not
  dependencies the core requires. Internal host helpers marked
  `@moduledoc false` do not add an extension API to maintain.

  A message customization may implement one callback and inherit the rest.
  A compaction replacement implements the full strategy: its cut, projected
  conversation and summary must agree. The turn budget, append-only
  transcript and current host authorization remain session responsibilities.

  ## The TUI's opinions are extensions too

  `lmx` is the library plus a list of these: `Lemieux.Extensions.Interactive`
  puts `ask_user` in the catalog because somebody is there to answer,
  `Lemieux.Extensions.Workspace` composes the repository's instructions and
  skills into the prompt, `Lemieux.Extensions.Delegation` equips the scout.
  They go through this callback and no other door. That is the rule that
  `lmx` gets no privileged path into the library, extended one level up: a
  person who dislikes workspace discovery replaces that extension with their
  own, and the host cannot tell the difference.

  ## Provenance

  `Lemieux.Harness.assemble/2` records each extension's module, the digest of
  its compiled code and whatever `c:describe/1` returns, and
  `Lemieux.Harness.session_options/1` folds that list into
  `harness_context["extensions"]["applied"]`, which every request's harness
  snapshot already carries. A transcript therefore says which code shaped
  the session that wrote it, and a behaviour that changed between two runs
  can be traced to the extension whose digest changed.

  ## Writing one

      defmodule MyApp.AuditedBash do
        @behaviour Lemieux.Extension
        import Kernel, except: [apply: 2]

        alias Lemieux.Harness
        alias Lemieux.Tool

        @impl true
        def init(opts), do: {:ok, Keyword.fetch!(opts, :log)}

        @impl true
        def apply(harness, log) do
          Harness.update_tools(harness, fn tools ->
            Tool.decorate(tools, %{
              "bash" => &Tool.Override.new!(&1, digest: "audit-v1", after: audit(log))
            })
          end)
        end

        @impl true
        def describe(log), do: %{"log" => log}

        defp audit(log), do: fn return, args, _context -> MyApp.Audit.write(log, args); return end
      end

  `c:apply/2` is the one required callback. `c:init/1` turns the options a
  host wrote into the state `apply/2` and `describe/1` receive; an extension
  without one gets its options verbatim. `c:describe/1` is JSON-shaped
  provenance — the file that was read, the digest of the profile, never a
  credential — and defaults to an empty map.

  `Kernel.apply/2` is imported into every module, so a module defining
  `apply/2` says `import Kernel, except: [apply: 2]` first. The name is
  kept anyway, because it is what the callback does and what the design
  says; a synonym chosen to dodge the import would be the one nobody could
  find.

  ## The API version

  `api_version/0` is one integer for this contract: the callbacks above, the
  `Lemieux.Harness` fields and helpers, and the behaviours those fields
  select. It moves only when an extension compiled against the previous
  number could misbehave against this one — a harness field removed or
  retyped, a callback's arguments changed, a helper's meaning changed. Adding
  a field or a helper does not move it.

  It exists because the alternative was comparing exact versions. The loader
  in `lmx` used to refuse a compiled bundle unless its Lemieux, Elixir and OTP
  versions all matched the binary byte for byte, which turned every patch
  release into "rebuild every extension" and refused the repository's own
  script example on any Elixir but the one it was written on. What can
  actually break a compiled bundle is a different OTP major (the beam may
  not load), a newer Elixir than the one running (the beam may call what
  does not exist yet), and this contract moving — so those are what
  `Lemieux.CLI.Extensions` checks.
  """

  alias Lemieux.Harness

  @api_version 1

  @doc """
  The extension contract's version: see "The API version" above.

  `mix lmx.extension.build` records it in a bundle's manifest as
  `"extension_api"`, and the loader refuses a bundle whose number differs.
  """
  @spec api_version() :: pos_integer()
  def api_version, do: @api_version

  @typedoc "What `c:init/1` returns and `c:apply/2` and `c:describe/1` receive."
  @type state :: term()

  @typedoc """
  How a host names an extension to `Lemieux.Harness.assemble/2`: a module, or
  a module with the options its `c:init/1` receives.
  """
  @type spec :: module() | {module(), keyword()}

  @doc """
  Turns a host's options into the state the other callbacks receive.

  Optional. Absent, the options are the state. Return `{:error, reason}`
  for options that cannot be honoured — a file that does not exist, a
  profile that fails validation — and `Lemieux.Harness.assemble/2` stops
  there with `{:error, {module, reason}}` rather than starting a session
  without the behaviour somebody asked for.
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Returns the harness as it should be, given the harness as it stands.

  Pure: no process is started and nothing is read that `c:init/1` could have
  read, because `assemble/2` may apply the same state more than once — the
  TUI applies its list once for the screen and once for each session.
  """
  @callback apply(harness :: Harness.t(), state()) :: Harness.t()

  @doc """
  JSON-shaped provenance for the harness snapshot: what this extension was
  configured with, in terms a reader of the transcript can act on.

  Optional; defaults to `%{}`. A path, a digest, a count. Never a credential
  or a function — the snapshot is written to the transcript and read by
  whoever reads that.
  """
  @callback describe(state()) :: map()

  @optional_callbacks init: 1, describe: 1
end
