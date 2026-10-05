defmodule Lemieux.CLI.Extensions.Build do
  @moduledoc """
  Writes the directory `Lemieux.CLI.Extensions` loads, from a compiled Mix
  project.

  `mix lmx.extension.build` is the entry point; this module is the part that
  can be tested against a `_build` tree made by hand, which is why it takes
  the build's `lib` directory and the dependency tree as arguments rather
  than asking Mix for them.

  ## What goes in

  The project's own `ebin`, then the `ebin` of every runtime application it
  reaches that the binary does not already carry. Runtime, not build-time:
  the set is walked through the `.app` files' `applications` the way a
  release walks them, so `credo` and the rest of a project's `runtime: false`
  tooling never ride along. What the binary carries is `shipped/0`,
  `:lemieux`'s own application tree closed transitively from
  `Application.spec/2` — computed, not listed, because a literal list would
  be wrong the first time lemieux gained or lost a dependency, and the
  failure would be a duplicate module on the path in somebody's transcript.

  Each application's `priv` comes along beside its `ebin`, under
  `lib/APP/priv`, which is where `:code.priv_dir/1` looks for it once the
  `ebin` is on the path.

  ## What is refused

  Native code. A `priv` holding a `.so`, `.dylib` or `.dll`, or a dependency
  on `rustler`, `elixir_make` or `rustler_precompiled`, stops the build: the
  shipped runtime cannot load a NIF built against another ERTS, and the
  failure that produces is a crash on load rather than anything the loader's
  version check can catch. An extension that needs one is a reason to build
  your own host from `dist/lmx`, which `docs/extensions.md` describes.

  ## The module

  The manifest names one module. Given `--module`, that one — it has to be
  in the project's `ebin`. Otherwise the single module in the project's
  `ebin` that exports `apply/2` and declared `@behaviour Lemieux.Extension`,
  read from the beams' attribute and export chunks without loading them.
  None or several is a question for the person, and the sentence says so.

  ## The output

  Replaced whole, never layered: a dependency the project dropped since the
  last build must not stay behind in the directory, or the manifest and the
  files disagree about what is loaded. The build is staged beside the
  destination and renamed into place, so a failure part-way leaves the
  previous build where it was.
  """

  alias Lemieux.CLI.Extensions

  @native_toolchains [:rustler, :elixir_make, :rustler_precompiled]
  @native_suffixes ~w(.so .dylib .dll)

  @typedoc """
  What `build/1` needs: the project's app, the `lib` directory of its build
  (`_build/ENV/lib`), and where to write. `:deps_tree` is
  `Mix.Project.deps_tree/0`'s shape and is read for the toolchain check;
  `:shipped` defaults to `shipped/0`; `:module` and `:name` override
  detection and the app name; `:versions` defaults to what this VM runs.
  """
  @type option ::
          {:app, atom()}
          | {:lib, Path.t()}
          | {:output, Path.t()}
          | {:shipped, MapSet.t(atom())}
          | {:deps_tree, %{optional(atom()) => [atom()]}}
          | {:module, String.t() | nil}
          | {:name, String.t() | nil}
          | {:versions, %{String.t() => String.t()}}

  @doc """
  Builds the extension directory. Returns where it was written and the
  manifest it holds, or a sentence saying why not.
  """
  @spec build(opts :: [option()]) ::
          {:ok, %{directory: Path.t(), manifest: map()}} | {:error, String.t()}
  def build(opts) when is_list(opts) do
    app = Keyword.fetch!(opts, :app)
    lib = opts |> Keyword.fetch!(:lib) |> Path.expand()
    name = Keyword.get(opts, :name) || Atom.to_string(app)
    shipped = Keyword.get_lazy(opts, :shipped, &shipped/0)
    deps_tree = Keyword.get(opts, :deps_tree, %{})
    versions = Keyword.get_lazy(opts, :versions, &Extensions.versions/0)
    output = opts |> Keyword.get_lazy(:output, fn -> default_output(name) end) |> Path.expand()

    with :ok <- valid_name(name),
         {:ok, apps} <- applications(app, lib, shipped),
         :ok <- portable(apps, lib, deps_tree),
         {:ok, module} <- extension_module(app, lib, Keyword.get(opts, :module)),
         manifest = manifest(name, module, apps, versions),
         :ok <- write(output, lib, apps, manifest) do
      {:ok, %{directory: output, manifest: manifest}}
    end
  end

  @doc """
  Where a build goes when nothing says otherwise: the personal root
  (`Lemieux.CLI.Extensions.default_root/0`, or `:root`) plus the name, which
  is exactly where `--extension NAME` will look for it.
  """
  @spec default_output(name :: String.t(), opts :: [root: Path.t()]) :: Path.t()
  def default_output(name, opts \\ []) when is_binary(name) do
    Path.join(Keyword.get_lazy(opts, :root, &Extensions.default_root/0), name)
  end

  @doc """
  The applications the binary already carries: `:lemieux` and everything its
  application tree reaches, transitively, from the `.app` files.
  """
  @spec shipped() :: MapSet.t(atom())
  def shipped, do: %{} |> closure([:lemieux]) |> Map.keys() |> MapSet.new()

  # A plain map while walking, and a set only at the end: Dialyzer's view of
  # `MapSet`'s internals differs between the Elixir that built the PLT and the
  # one compiling this, and reports an opaque mismatch on every `put` into an
  # accumulator that started as `MapSet.new/0`.
  defp closure(seen, []), do: seen

  defp closure(seen, [app | rest]) do
    if Map.has_key?(seen, app) do
      closure(seen, rest)
    else
      _loaded = Application.load(app)
      closure(Map.put(seen, app, true), children(app) ++ rest)
    end
  end

  defp children(app),
    do:
      (Application.spec(app, :applications) || []) ++
        (Application.spec(app, :included_applications) || [])

  defp valid_name(name) do
    if Extensions.valid_name?(name),
      do: :ok,
      else:
        {:error,
         "#{inspect(name)} is not an extension name: " <>
           Extensions.name_rule(Extensions.default_root())}
  end

  # The project first, then its runtime applications in the order they are
  # reached, each once. An application without a `.app` under `lib` is OTP's
  # or Elixir's, which the binary has.
  defp applications(app, lib, shipped) do
    case app_spec(lib, app) do
      {:ok, spec} ->
        {:ok, walk([app], MapSet.new([app]), spec_children(spec), lib, shipped)}

      :error ->
        {:error,
         "#{app} has no compiled application at #{app_file(lib, app)}; " <>
           "mix compile writes it, and mix lmx.extension.build runs in the project that does"}
    end
  end

  defp walk(apps, _seen, [], _lib, _shipped), do: Enum.reverse(apps)

  defp walk(apps, seen, [dep | rest], lib, shipped) do
    if dep in seen or dep in shipped do
      walk(apps, seen, rest, lib, shipped)
    else
      seen = MapSet.put(seen, dep)

      case app_spec(lib, dep) do
        {:ok, spec} -> walk([dep | apps], seen, rest ++ spec_children(spec), lib, shipped)
        :error -> walk(apps, seen, rest, lib, shipped)
      end
    end
  end

  defp app_file(lib, app), do: Path.join([lib, Atom.to_string(app), "ebin", "#{app}.app"])

  defp app_spec(lib, app) do
    case :file.consult(String.to_charlist(app_file(lib, app))) do
      {:ok, [{:application, ^app, properties}]} -> {:ok, properties}
      _other -> :error
    end
  end

  defp spec_children(properties),
    do:
      Keyword.get(properties, :applications, []) ++
        Keyword.get(properties, :included_applications, [])

  defp portable(apps, lib, deps_tree) do
    Enum.find_value(apps, :ok, fn app ->
      toolchains = Enum.filter(Map.get(deps_tree, app, []), &(&1 in @native_toolchains))
      natives = native_files(lib, app)

      cond do
        toolchains != [] ->
          {:error,
           "#{app} depends on #{Enum.join(toolchains, " and ")}, a NIF toolchain; " <>
             "the shipped lmx cannot load native code built elsewhere, so it cannot carry #{app}"}

        natives != [] ->
          {:error,
           "#{app} carries native code (#{Enum.join(natives, ", ")}); " <>
             "the shipped lmx cannot load a NIF built elsewhere, so it cannot carry #{app}"}

        true ->
          nil
      end
    end)
  end

  defp native_files(lib, app) do
    priv = Path.join([lib, Atom.to_string(app), "priv"])

    priv
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&(Path.extname(&1) in @native_suffixes))
    |> Enum.map(&Path.relative_to(&1, Path.join([lib, Atom.to_string(app)])))
  end

  defp extension_module(app, lib, nil) do
    case candidates(lib, app) do
      [module] ->
        {:ok, module}

      [] ->
        {:error,
         "no module in #{app} exports apply/2 and declares @behaviour Lemieux.Extension; " <>
           "name the extension module with --module"}

      several ->
        {:error,
         "several modules in #{app} are extensions: #{Enum.join(several, ", ")}; " <>
           "choose one with --module"}
    end
  end

  defp extension_module(app, lib, module) when is_binary(module) do
    beam = Path.join([lib, Atom.to_string(app), "ebin", "Elixir.#{module}.beam"])

    cond do
      not File.regular?(beam) ->
        {:error, "#{module} is not a module in #{app}'s ebin (#{beam})"}

      not exports_apply?(beam) ->
        {:error, "#{module} does not export apply/2, so it is not a Lemieux.Extension"}

      true ->
        {:ok, module}
    end
  end

  defp candidates(lib, app) do
    [lib, Atom.to_string(app), "ebin", "*.beam"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&(extension_behaviour?(&1) and exports_apply?(&1)))
    |> Enum.map(&(&1 |> Path.basename(".beam") |> String.replace_prefix("Elixir.", "")))
    |> Enum.sort()
  end

  # Read from the beam's chunks rather than by loading it: the project's
  # modules may not load in this VM at all if they depend on something the
  # task's environment lacks, and loading is not the question being asked.
  defp extension_behaviour?(beam) do
    case :beam_lib.chunks(String.to_charlist(beam), [:attributes]) do
      {:ok, {_module, [attributes: attributes]}} ->
        Lemieux.Extension in Keyword.get(attributes, :behaviour, []) or
          Lemieux.Extension in Keyword.get(attributes, :behavior, [])

      _other ->
        false
    end
  end

  defp exports_apply?(beam) do
    case :beam_lib.chunks(String.to_charlist(beam), [:exports]) do
      {:ok, {_module, [exports: exports]}} -> {:apply, 2} in exports
      _other -> false
    end
  end

  # `extension_api` is what lets the loader accept this build after a Lemieux
  # patch release or an Elixir upgrade within the major; without it the
  # loader falls back to demanding all three versions match exactly.
  defp manifest(name, module, apps, versions) do
    %{
      "schema_version" => 1,
      "name" => name,
      "module" => module,
      "ebin" => Enum.map(apps, &"lib/#{&1}/ebin"),
      "versions" => versions,
      "extension_api" => Lemieux.Extension.api_version()
    }
  end

  defp write(output, lib, apps, manifest) do
    stage = output <> ".staging-" <> Integer.to_string(System.unique_integer([:positive]))

    result =
      with :ok <- File.mkdir_p(Path.dirname(output)),
           :ok <- File.mkdir(stage) do
        try do
          with :ok <- copy_apps(stage, lib, apps),
               :ok <-
                 File.write(Path.join(stage, Extensions.manifest_file()), JSON.encode!(manifest)),
               :ok <- remove(output) do
            File.rename(stage, output)
          end
        after
          File.rm_rf(stage)
        end
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, "could not write #{output} (#{inspect(reason)})"}
    end
  end

  defp remove(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, file} -> {:error, {reason, file}}
    end
  end

  # `priv` under `_build` is usually a symlink into `deps/`; the copy has to
  # follow it, or the extension directory would carry a link to a checkout
  # that is not on the machine the binary runs on.
  defp copy_apps(stage, lib, apps) do
    Enum.reduce_while(apps, :ok, fn app, :ok ->
      source = Path.join(lib, Atom.to_string(app))
      target = Path.join([stage, "lib", Atom.to_string(app)])

      with :ok <- File.mkdir_p(target),
           {:ok, _copied} <- copy(Path.join(source, "ebin"), Path.join(target, "ebin")),
           {:ok, _copied} <- copy_if_present(Path.join(source, "priv"), Path.join(target, "priv")) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {reason, target}}}
        {:error, reason, file} -> {:halt, {:error, {reason, file}}}
      end
    end)
  end

  defp copy(source, target), do: File.cp_r(source, target, dereference_symlinks: true)

  defp copy_if_present(source, target) do
    if File.exists?(source), do: copy(source, target), else: {:ok, []}
  end
end
