defmodule Lemieux.Tools.Eval do
  @moduledoc """
  Lets the model write Elixir and get the answer back.

  **Not in `Lemieux.Tools.default/0`, and that is deliberate.** A session gets
  this only by being handed it — `lmx --elixir`, or a host putting it in
  `:tools` — because it is a different bargain from the other four and the
  person making it should know they made it.

  ## Why a tool that runs code at all

  The other tools are verbs the harness chose: read a file, replace a string,
  run a command. Each returns whatever its author decided to return. A `grep`
  that matches forty-seven files puts forty-seven filenames in the context
  window, formatted for a terminal rather than for a model, and correlating
  them with anything means another call and another dump.

  Given a language instead, the model writes the filter, the transformation
  and the shape of the answer together, and gets back four lines:

      Path.wildcard("lib/**/*.ex")
      |> Enum.map(&{&1, File.read!(&1)})
      |> Enum.filter(fn {_path, source} -> source =~ "GenServer" end)
      |> Enum.map(fn {path, _source} -> Path.basename(path) end)

  That is the argument [beamcore](https://github.com/beamcore/agent) makes for
  building an entire agent around one such tool, and it is a good one:
  multi-step work that costs ten calls collapses into one, and only what the
  model asked for enters the window. The boundary below explains where
  lemieux agrees and where it does not.

  ## Where lemieux does not follow beamcore

  beamcore evaluates in **its own VM**, which is what makes its most striking
  demos possible: the agent reconfigures itself, spawns sub-agents in-process,
  recompiles its own modules while running. Its own sandbox module is honest
  that this is not a security boundary.

  lemieux is a library other people embed, and its first host treats a prompt
  injected from a repository as a live path to code execution. In-VM
  evaluation hands such a prompt the host's own process: its ETS, its
  application environment, its API keys, and `Code.compile_string/1` pointed
  at the very tool about to report what happened.

  So the code runs on a node of its own — `Lemieux.Eval.Sandbox` — and what
  is given up is exactly the self-modification. That is the intended trade,
  not an unfinished part.

  ## What it does not promise

  The evaluating node is the same operating-system user, on the same
  filesystem, with the same network. This tool is no safer than
  `Lemieux.Tools.Bash` about what it may *do*; it is safer about what it may
  *reach*. Real confinement is the host's, as it is for bash.

  ## Not parallel-safe

  Arbitrary code can write anything, so it is scheduled alone in its wave —
  see `c:Lemieux.Tool.parallel_safe?/0`. The node evaluates one thing at a
  time in any case: the working directory is a property of a VM, and two
  evaluations sharing one would be reading each other's.
  """

  @behaviour Lemieux.Tool

  alias Lemieux.Eval.Sandbox

  @impl Lemieux.Tool
  def name, do: "elixir"

  @impl Lemieux.Tool
  def description do
    """
    Evaluate Elixir and return the value of the last expression, along with \
    anything written to standard output.

    Runs on a separate BEAM node, in the session's working directory, with the \
    full standard library available. Use it to read and transform files, run \
    commands via System.cmd/3, and compute an answer in one step instead of \
    several — filter and summarise in the code rather than returning \
    everything and reading it here.

    The node is not this agent's own: it holds no state between calls beyond \
    what you write to disk, and it cannot see the conversation. Modules you \
    define with defmodule persist on it for the session.
    """
  end

  @impl Lemieux.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "code" => %{
          "type" => "string",
          "description" =>
            "Elixir source. The value of the last expression is returned, " <>
              "inspected. Anything written to standard output is returned too."
        }
      },
      "required" => ["code"],
      "additionalProperties" => false
    }
  end

  @impl Lemieux.Tool
  def parallel_safe?, do: false

  @impl Lemieux.Tool
  def metadata do
    %{
      effects: %{class: "arbitrary", resource_types: ["operating_system", "beam_node"]},
      policy: %{default_off_shared: true},
      runtime: %{max_output_bytes: 32_000, concurrency: %{class: "exclusive"}}
    }
  end

  @impl Lemieux.Tool
  def run(%{"code" => code}, context) when is_binary(code) and code != "" do
    Sandbox.eval(code, context)
  end

  def run(_args, _context), do: {:error, "elixir needs code to evaluate"}
end
