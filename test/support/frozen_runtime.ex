defmodule LemieuxTest.FrozenRuntime do
  @moduledoc false

  # These fixtures execute only Agent.run plus the frozen consumer's integrity
  # checks. Copying the entire harness (including TUI/provider code) into every
  # build multiplies filesystem traversal and hashing without exercising it.
  # The builder/security integration tests still freeze the complete runtime.
  @modules [
    Lemieux.Agent,
    Lemieux.Learning.Extension.Export,
    Lemieux.Learning.Extension.Build,
    Lemieux.Learning.Extension.Consumer,
    Lemieux.Learning.Extension.Tree,
    Lemieux.Contract,
    Lemieux.JSON
  ]

  @spec create() :: [Path.t()]
  def create do
    root =
      Path.join(
        System.tmp_dir!(),
        "lmx-frozen-runtime-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    ebin = Path.join(root, "lemieux/ebin")
    File.mkdir_p!(ebin)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    for module <- @modules do
      file = "#{module}.beam"
      # :code.which/1 returns :cover_compiled under mix test --cover. The
      # independent consumer needs the original on-disk BEAMs in either mode.
      File.cp!(Application.app_dir(:lemieux, "ebin/#{file}"), Path.join(ebin, file))
    end

    [ebin]
  end

  # A real scripted session also starts req_llm and reads YAML skills. Keep
  # their required application closure, including priv data, rather than the
  # entire Mix code path: dev tools and optional TUI NIFs once made the typed
  # confirmation fixture copy and hash roughly 90 MB for each build. All
  # Lemieux modules remain available for dynamic harness/extension dispatch.
  # Default-runtime freezing is still exercised by the builder, security and
  # documented portable-asset example tests.
  @spec session_paths() :: [Path.t()]
  def session_paths do
    system = [
      :code.root_dir() |> List.to_string(),
      :code.lib_dir(:elixir) |> List.to_string() |> Path.dirname()
    ]

    [:req_llm, :yaml_elixir]
    |> required_apps([:lemieux])
    |> Enum.map(&Application.app_dir(&1, "ebin"))
    |> Enum.reject(fn path -> Enum.any?(system, &String.starts_with?(path, &1 <> "/")) end)
    |> Enum.sort()
  end

  @spec required_apps(apps :: [atom()], seen :: [atom()]) :: [atom()]
  defp required_apps([], seen), do: seen

  defp required_apps([app | rest], seen) do
    if app in seen do
      required_apps(rest, seen)
    else
      required =
        Application.spec(app, :applications) --
          (Application.spec(app, :optional_applications) || [])

      included = Application.spec(app, :included_applications) || []
      required_apps(required ++ included ++ rest, [app | seen])
    end
  end
end
