defmodule Lemieux.BoundaryTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The dependency direction between the core loop and everything built on it.

  Behaviours make an opinion replaceable; they do not stop the core from
  quietly acquiring a literal dependency on a host or on the learning
  toolchain next month. This test reads the compiled beams with OTP's `:xref`
  and asserts the direction, the same way `Lemieux.MixProjectTest` asserts
  the absence of a `mod:` entry: a contract that fails the suite rather than
  silently changing what every embedder codes against.

  Modules are classified by name. Core is whatever is left once hosts, the
  learning toolchain and the opt-in extras are taken out, so a new module is
  core until it is filed somewhere else. Core may depend only on core;
  learning and the extras may depend on core and on each other but never on
  a host; hosts may depend on anything.

  `@debt` lists the edges that exist today and are still to be cut. It is an
  exact set: cutting one fails the test until the entry is removed here, so
  the list stays honest, and adding a new forbidden edge fails it outright.
  """

  # Hosts: the screens and command lines built on the library.
  @hosts [
    ~r/^Lemieux\.CLI(\.|$)/,
    ~r/^Lemieux\.TUI(\.|$)/,
    ~r/^Lemieux\.Conversation(\.|$)/,
    ~r/^Lemieux\.Terminal$/,
    ~r/^Lemieux\.Clipboard$/,
    ~r/^Lemieux\.Extension\.CLI$/,
    ~r/^Mix\.Tasks\./
  ]

  # The offline self-improvement toolchain. It reads what the loop records
  # and produces files a host chooses to apply; the loop never calls it.
  @learning [
    ~r/^Lemieux\.Learning(\.|$)/,
    ~r/^Lemieux\.Benchmark(\.|$)/,
    ~r/^Lemieux\.Experiment(\.|$)/,
    ~r/^Lemieux\.Asset(\.|$)/,
    ~r/^Lemieux\.Feedback(\.|$)/,
    ~r/^Lemieux\.Reflection(\.|$)/,
    ~r/^Lemieux\.Extension\.Profile$/
  ]

  # Opt-in extras that ship in the library: the shipped extensions, a vendor
  # gateway, a compatibility table, a pool sizer, the agent-to-agent protocol,
  # the Elixir evaluator, and the runnable-agent behaviour.
  # `Lemieux.OpenTelemetry` is not here: it is a facade over an adapter
  # behaviour with no dependency of its own, and the loop calls it to carry
  # trace context, so it is core. `Lemieux.Extension` and `Lemieux.Harness`
  # are not here either: they are the contract the extras implement, and the
  # loop's own facade reads the struct, so they are core.
  @extras [
    ~r/^Lemieux\.Extensions(\.|$)/,
    ~r/^Lemieux\.Ixway$/,
    ~r/^Lemieux\.ModelCatalog$/,
    ~r/^Lemieux\.ProviderPool$/,
    ~r/^Lemieux\.A2A(\.|$)/,
    ~r/^Lemieux\.Eval(\.|$)/,
    ~r/^Lemieux\.Tools\.Eval$/,
    ~r/^Lemieux\.Agent(\.|$)/
  ]

  # Edges that exist today and are still to be cut: the loop calling opinions
  # that are not yet behind a seam.
  @debt []

  test "core depends only on core, and nothing below a host depends on a host" do
    edges = module_edges()

    violations =
      for {from, to} <- edges,
          from != to,
          source = layer(from),
          source in [:core, :learning, :extras],
          target = layer(to),
          forbidden?(source, target),
          uniq: true,
          do: {from, to}

    actual = MapSet.new(violations)
    expected = MapSet.new(@debt)

    new_edges = MapSet.difference(actual, expected) |> Enum.sort()
    paid_edges = MapSet.difference(expected, actual) |> Enum.sort()

    assert new_edges == [],
           "new dependencies cross the boundary; put the target behind a seam or file " <>
             "the source under a host: #{inspect(new_edges, pretty: true)}"

    assert paid_edges == [],
           "these edges no longer exist; remove them from @debt: " <>
             inspect(paid_edges, pretty: true)
  end

  test "every module is filed under exactly one layer" do
    for from <- module_edges() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() do
      layers =
        [hosts: @hosts, learning: @learning, extras: @extras]
        |> Enum.filter(fn {_layer, patterns} -> matches?(from, patterns) end)
        |> Enum.map(&elem(&1, 0))

      assert length(layers) <= 1,
             "#{inspect(from)} matches more than one layer: #{inspect(layers)}"
    end
  end

  defp forbidden?(:core, target), do: target != :core
  defp forbidden?(:learning, :hosts), do: true
  defp forbidden?(:extras, :hosts), do: true
  defp forbidden?(_source, _target), do: false

  defp layer(module) do
    cond do
      matches?(module, @hosts) -> :hosts
      matches?(module, @learning) -> :learning
      matches?(module, @extras) -> :extras
      true -> :core
    end
  end

  defp matches?(module, patterns) do
    name = inspect(module)
    Enum.any?(patterns, &Regex.match?(&1, name))
  end

  # Module-level edges among this application's own modules, read from each
  # beam's import table with `:beam_lib`. That table lists every remote call
  # the compiler emitted, which is what `:xref` reads in `:modules` mode; the
  # `:tools` application that ships `:xref` is not part of every OTP install,
  # and `:beam_lib` is in `:stdlib`. Dynamic calls through `apply/3` do not
  # appear, so an edge that has gone through an option or a behaviour is,
  # correctly, no longer an edge.
  defp module_edges do
    :lemieux
    |> Application.app_dir("ebin")
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      {:ok, {from, [imports: imports]}} = :beam_lib.chunks(String.to_charlist(path), [:imports])

      imports
      |> Enum.map(fn {to, _fun, _arity} -> {from, to} end)
      |> Enum.uniq()
    end)
    |> Enum.filter(fn {from, to} -> project_module?(from) and project_module?(to) end)
  end

  # Test support and protocol implementations are compiled into the same
  # directory and are nobody's layer.
  defp project_module?(module) do
    name = inspect(module)

    (String.starts_with?(name, "Lemieux") or String.starts_with?(name, "Mix.Tasks.")) and
      not String.starts_with?(name, "LemieuxTest") and
      not String.starts_with?(name, "Lemieux.TestSupport")
  end
end
