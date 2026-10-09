defmodule Lemieux.CLI.Extensions do
  @moduledoc """
  Loading a person's own extension into the shipped `lmx`, by name and with
  consent.

  An embedder adds a Mix dependency and names the module. The installed
  `lmx` is a sealed OTP release: there is no `mix.exs` to add to, and no
  way for the person who has a compiled `Lemieux.Extension` to get it into
  the binary. This is that way. A directory holds a manifest and the code,
  the person selects it, and the loader puts the code on the path and hands
  `Lemieux.Harness.assemble/2` the same `{module, opts}` an embedder would
  have written.

  ## The directory

  `~/.lmx/extensions/NAME/` — or any directory named with `--extension-dir`
  — holding an `extension.json`:

      {
        "schema_version": 1,
        "name": "audit",
        "module": "MyApp.Audit",
        "ebin": ["lib/my_app/ebin", "lib/jason/ebin"],
        "versions": {"lemieux": "0.8.0", "elixir": "1.20.4", "otp": "29"},
        "options": {"log": "/var/log/agents.log"}
      }

  `ebin` lists compiled directories, relative to the extension's own, that
  go on the code path with `Code.prepend_path/1`; `mix lmx.extension.build`
  writes this form from a Mix project. `script` names one `.exs` file
  instead, compiled from the bytes whose digest was checked — the compiler is in every
  release, and `Lemieux.Eval.Runner` already relies on that — for an
  extension small enough to be a file. Exactly one of the two. `options` is
  passed to the module's `c:Lemieux.Extension.init/1` as `[config: map]`,
  string keys and all: they are the person's data, and turning them into
  atoms would be turning a file into code. The name distinguishes this
  manifest from `lemieux-extension.json`, which the learning lane's export
  writes for a source tree and which never loads anything.

  The module is a `Lemieux.Extension`, a `Lemieux.Extension.Routes`, or
  both: one that exports `apply/2` shapes the harness, one that exports
  `routes/1` offers model routes for `Lemieux.CLI.Routes` to register, and
  `routes/1` receives the same `[config: map]`. A module exporting neither
  is refused, since there is nothing to load it for. What is loaded says
  which it was: `spec` is `nil` for a route-only module, `routes` is `nil`
  for a harness-only one.

  Options may also come from the person's configuration: `load_all/2`'s
  `:options` maps an extension's manifest name to a JSON object merged over
  the manifest's own `options`. That is where a person keeps settings they
  chose, because a rebuild replaces the whole directory — manifest included
  — and options kept only in the manifest were wiped by every
  `mix lmx.extension.build`.

  A script extension compiles in the running VM, so its manifest names only
  the Lemieux it was written for, as a version (`"0.8.0"`, meaning that
  release line) or a requirement (`"~> 0.8"`):

      {
        "schema_version": 1,
        "name": "planning",
        "module": "LemieuxPlanningExample",
        "script": "planning.exs",
        "versions": {"lemieux": "~> 0.8"}
      }

  ## Two rules this keeps

  **Configuration never names code.** `~/.lmx/config.json` and `--extension`
  carry a *name*, and the name is a directory the person populated. The
  manifest that names a module lives inside that directory, exactly as
  `lemieux-extension.json` does today, so a config file cannot be edited into
  loading a module that happens to be on the path.

  **A repository never runs code because an agent noticed it.** Nothing here
  looks for a `.lmx/extensions/` in the working directory. A project-level
  extension is loaded only through `--extension-dir PATH`, typed by the
  person, which is the same trust decision `--hooks` asks for. `lmx` opening
  a checkout must not execute its setup, and `docs/why-lemieux.md` says so
  in as many words.

  ## Refusals

  Every failure here is an error that stops the start, not a skipped
  extension: the person asked for this one, and a session without it is
  worse than no session. A manifest that does not validate, a path that is
  not a canonical relative path inside the directory or crosses a symlink
  (the rules `Lemieux.Learning.Extension.Export` applies to a source tree), a
  module the code does not define, a module without `apply/2`, and code
  built for a runtime it cannot run on are each refused in a sentence that
  names both sides.

  What "cannot run on" means depends on the form:

    * a **script** needs the running Lemieux to satisfy the version or
      requirement its manifest names — nothing else, because it is compiled
      here, by this Elixir, against this OTP;
    * a **compiled bundle** with an `"extension_api"` needs the same
      `Lemieux.Extension.api_version/0`, the same OTP major (a beam from
      another OTP may not load at all, and the failure is a crash in the code
      server rather than a sentence), and an Elixir of the same major no
      newer than the one running (older compiled code keeps working; newer
      compiled code may call what this runtime does not have). The Lemieux
      release number itself is not compared: the API version is what says
      whether the contract the bundle was compiled against moved;
    * a **compiled bundle without `"extension_api"`** was written before the
      API version existed and keeps the old rule: Lemieux, Elixir and OTP
      must all match exactly. Rebuilding it records the API version.

  ## Provenance

  `load/1` returns, beside the spec, what `Lemieux.CLI.Runtime` records under
  `harness_context["extensions"]["loaded"]`: the name, the directory, the
  manifest's SHA-256, and for the ebin form three facts about the beams it
  carries — `"module_digest"`, the md5 of the extension module's own beam,
  which is the digest `Lemieux.Harness.assemble/2` records under `"applied"`
  so the two lists can be read against each other; `"beam_count"`; and
  `"beams_sha256"`, one SHA-256 over every `Module:md5` pair in the
  directories, sorted. Every beam is still read to compute it. What is no
  longer recorded is the list itself: it was one line per module of every
  dependency the extension carried, in a harness snapshot every request
  writes, and a reader of the snapshot wants to know *whether* what came
  along changed, not to have it enumerated. A transcript therefore says
  which extension shaped the session, which build of it, and whether any of
  its dependencies moved. The script form records the script's path and
  SHA-256 instead.

  Manifest options are private initialization inputs and never copied into
  this record. Only the extension's `describe/1` opts into recording selected
  configuration under `"applied"`. Authors must keep that description free
  of credentials; arbitrary extension code is trusted and can itself write
  secrets into any harness field.

  ## Once per VM

  Prepending a path twice is harmless; compiling a script twice redefines its
  module, with a warning on standard error every time the TUI resumes a
  session. A script is therefore compiled once per directory and content —
  its digest and the modules it actually defined are kept in `:persistent_term` — and a
  second `load/1` of the same directory returns the same result without
  touching the compiler. Code loading is VM-global state anyway; the cache
  only mirrors it. A cached file must still define the manifest's entry
  module; naming a preloaded module does not establish ownership.

  Loads through this loader are serialized within the local VM. Every
  carried beam is checked against both loaded code and code available on
  the existing path before any new path is installed, then eagerly loaded
  from the checked bytes. Different versions of one helper cannot coexist
  by winning a lazy-load race. A conflict requires compatible bundles and
  a restart; hot replacement and dependency isolation are not promised.
  Scripts similarly reject ordinary declarations that collide with existing
  modules. They remain trusted Elixir, able to call the code server directly.
  """

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Startup
  alias Lemieux.Contract

  @manifest "extension.json"
  @schema_version 1
  @version_keys ~w(lemieux elixir otp)
  @name_pattern ~r/^[A-Za-z0-9_][A-Za-z0-9_-]*$/
  @module_pattern ~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/

  @typedoc """
  How the command line and the config file select an extension: a name under
  the personal root, or an explicit directory.
  """
  @type selection :: {:name, String.t()} | {:dir, Path.t()}

  @typedoc """
  A loaded extension: the spec `Lemieux.Harness.assemble/2` takes (`nil` for
  a module without `apply/2`), the module and options `Lemieux.CLI.Routes`
  asks for routes (`nil` for one without `routes/1`), and the JSON-shaped
  provenance the runtime records.
  """
  @type loaded :: %{
          spec: {module(), [config: map()]} | nil,
          routes: {module(), [config: map()]} | nil,
          provenance: map()
        }

  @doc "The manifest's file name inside an extension directory."
  @spec manifest_file() :: String.t()
  def manifest_file, do: @manifest

  @doc """
  Where `--extension NAME` and the config file's `"extensions"` look:
  `$LMX_EXTENSIONS_DIR`, else `~/.lmx/extensions`.

  A blank `LMX_EXTENSIONS_DIR` counts as unset, as every path variable does
  (`Lemieux.CLI.Options.env/1`). Read literally, `LMX_EXTENSIONS_DIR=` was the
  root `""`, a name joined onto it was a relative path, and `--extension NAME`
  loaded `./NAME` from the working directory — trusted code taken from
  whatever repository `lmx` was opened in.
  """
  @spec default_root() :: Path.t()
  def default_root do
    Options.env("LMX_EXTENSIONS_DIR") || Path.expand("~/.lmx/extensions")
  end

  @doc """
  The versions this VM is running, in the manifest's shape: what
  `mix lmx.extension.build` writes and what `load/1` compares against.
  """
  @spec versions() :: %{String.t() => String.t()}
  def versions do
    %{"lemieux" => Lemieux.version(), "elixir" => System.version(), "otp" => System.otp_release()}
  end

  @doc """
  Whether `name` may select an extension: one directory name, letters, digits,
  `-` and `_`. Never a path, never a module — both are refused so that a name
  in a config file cannot be a way of pointing at code.
  """
  @spec valid_name?(name :: term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_pattern, name)
  def valid_name?(_name), do: false

  @doc """
  Loads every selection, in order, each directory once.

  `:root` is the personal root a name resolves under; it defaults to
  `default_root/0`. `:options` maps an extension's manifest name to a JSON
  object of options — the person's configured `"extension_options"` —
  merged over the manifest's own `options`, key by key, configuration
  winning. The first failure stops the list with its sentence.

  `:startup_step`, when supplied, is a host callback `(id, text, status)`
  observing each unique directory before and after loading, including failures.
  """
  @spec load_all(
          selections :: [selection()],
          opts :: keyword()
        ) :: {:ok, [loaded()]} | {:error, String.t()}
  def load_all(selections, opts \\ []) when is_list(selections) and is_list(opts) do
    root = Keyword.get_lazy(opts, :root, &default_root/0)

    with {:ok, configured} <- configured_options(Keyword.get(opts, :options, %{})),
         {:ok, loaded} <- load_selections(selections, root, opts) do
      {:ok, Enum.map(loaded, &configure(&1, configured))}
    end
  end

  defp load_selections(selections, root, opts) do
    selections
    |> Enum.reduce_while({:ok, []}, fn selection, {:ok, loaded} ->
      case load_selection(selection, root, loaded, opts) do
        {:ok, loaded} -> {:cont, {:ok, loaded}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      {:error, message} -> {:error, message}
    end
  end

  defp load_selection(selection, root, loaded, opts) do
    with {:ok, directory} <- directory(selection, root), do: load_once(directory, loaded, opts)
  end

  # Every value is checked before anything loads: a malformed entry for an
  # extension that is selected later would otherwise surface only after the
  # earlier ones had put code on the path.
  defp configured_options(options) when is_map(options) do
    Enum.find_value(options, {:ok, options}, fn
      {name, value} when is_binary(name) and is_map(value) ->
        nil

      {name, _value} ->
        {:error,
         "extension_options #{inspect(name)} must map an extension name to a JSON object " <>
           "of its options"}
    end)
  end

  defp configured_options(_options),
    do: {:error, "extension_options must map extension names to JSON objects of options"}

  defp configure(%{provenance: provenance} = loaded, configured) do
    case Map.fetch(configured, provenance["name"]) do
      {:ok, options} ->
        %{
          loaded
          | spec: configured(loaded.spec, options),
            routes: configured(loaded.routes, options)
        }

      :error ->
        loaded
    end
  end

  defp configured(nil, _options), do: nil

  defp configured({module, [config: config]}, options),
    do: {module, [config: Map.merge(config, options)]}

  defp load_once(directory, loaded, opts) do
    if Enum.any?(loaded, &(&1.provenance["directory"] == directory)) do
      {:ok, loaded}
    else
      with {:ok, one} <- load_step(directory, opts),
           do: {:ok, [one | loaded]}
    end
  end

  defp load_step(directory, opts) do
    id = "load:" <> Base.encode16(:crypto.hash(:sha256, directory), case: :lower)

    Startup.step(opts, id, "Load extension #{Path.basename(directory)}", fn -> load(directory) end)
  end

  defp directory({:dir, path}, _root) when is_binary(path), do: {:ok, Path.expand(path)}

  defp directory({:name, name}, root) do
    directory = Path.expand(Path.join(root, name))

    cond do
      not valid_name?(name) ->
        {:error, "#{inspect(name)} is not an extension name: " <> name_rule(root)}

      File.dir?(directory) ->
        {:ok, directory}

      true ->
        {:error,
         "no extension named #{name}: #{directory} does not exist. " <>
           "Build one there with mix lmx.extension.build, or take #{name} out of " <>
           "--extension and the config file's \"extensions\"."}
    end
  end

  @doc """
  The sentence a refused name gets: what a name is, and where it looks.
  """
  @spec name_rule(root :: Path.t()) :: String.t()
  def name_rule(root) do
    "a name is one directory under #{root}, letters, digits, - and _; " <>
      "a directory anywhere else is --extension-dir PATH"
  end

  @typedoc """
  One installed extension as `list/1` reports it: `status` is whether this
  `lmx` would load it, judged from the manifest alone.
  """
  @type listed :: %{
          name: String.t(),
          directory: Path.t(),
          module: String.t() | nil,
          kind: :script | :ebin | :unknown,
          status: :ok | {:error, String.t()}
        }

  @doc """
  The extensions under `:root` (default `default_root/0`), sorted by
  directory, each with whether this `lmx` could load it.

  Read from the manifests alone — validation and the version rules, never
  the code — so listing compiles no script and puts no beam on the path. A
  bundle that lists as `:ok` can still fail to load for what only loading
  reveals: a symlinked path, a module its beams do not define, a conflict
  with code already in this VM.
  """
  @spec list(opts :: [root: Path.t()]) :: [listed()]
  def list(opts \\ []) when is_list(opts) do
    root = Keyword.get_lazy(opts, :root, &default_root/0)

    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&listed/1)

      {:error, _reason} ->
        []
    end
  end

  defp listed(directory) do
    fallback = %{
      name: Path.basename(directory),
      directory: directory,
      module: nil,
      kind: :unknown
    }

    with {:ok, bytes} <- read_manifest(directory),
         {:ok, manifest} <- decode(bytes, directory) do
      status = with :ok <- validate(manifest, directory), do: compatible(manifest, directory)

      %{
        name: text(manifest["name"]) || fallback.name,
        directory: directory,
        module: text(manifest["module"]),
        kind: kind(manifest),
        status: status
      }
    else
      {:error, message} -> Map.put(fallback, :status, {:error, message})
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp kind(%{"script" => _script}), do: :script
  defp kind(%{"ebin" => _ebin}), do: :ebin
  defp kind(_manifest), do: :unknown

  @doc """
  Loads the extension in `directory`.

  Reads and validates the manifest, checks the versions, puts the code on
  the path or compiles the script, and confirms the named module is now
  defined and exports `apply/2`. Returns the spec and the provenance, or a
  sentence saying what was wrong.
  """
  @spec load(directory :: Path.t()) :: {:ok, loaded()} | {:error, String.t()}
  def load(directory) when is_binary(directory) do
    :global.trans({__MODULE__, self()}, fn -> do_load(directory) end, [node()])
  end

  defp do_load(directory) do
    directory = Path.expand(directory)

    with :ok <- directory?(directory),
         {:ok, bytes} <- read_manifest(directory),
         {:ok, manifest} <- decode(bytes, directory),
         :ok <- validate(manifest, directory),
         :ok <- compatible(manifest, directory),
         {:ok, code} <- load_code(manifest, directory),
         {:ok, module, contracts} <- extension_module(manifest, directory, code) do
      options = Map.get(manifest, "options", %{})
      spec = {module, [config: options]}

      provenance =
        Map.merge(
          %{
            "name" => manifest["name"],
            "directory" => directory,
            "module" => manifest["module"],
            "manifest_sha256" => Contract.sha256(bytes)
          },
          code
        )

      provenance = if contracts.routes?, do: Map.put(provenance, "routes", true), else: provenance

      {:ok,
       %{
         spec: if(contracts.apply?, do: spec),
         routes: if(contracts.routes?, do: spec),
         provenance: provenance
       }}
    end
  end

  defp directory?(directory) do
    if File.dir?(directory),
      do: :ok,
      else: {:error, "#{directory} is not a directory, so there is no extension to load there"}
  end

  defp read_manifest(directory) do
    path = Path.join(directory, @manifest)

    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, "#{directory} has no #{@manifest}, so it is not an extension"}
      {:error, reason} -> {:error, "cannot read #{path} (#{reason})"}
    end
  end

  defp decode(bytes, directory) do
    case Contract.decode(bytes) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, _reason} -> {:error, "#{manifest_path(directory)} must be a JSON object"}
    end
  end

  defp manifest_path(directory), do: Path.join(directory, @manifest)

  # Every problem is reported against the manifest's path, so the person can
  # open the right file; the value is not echoed beyond what names it.
  defp validate(manifest, directory) do
    Enum.find_value(
      [
        {manifest["schema_version"] == @schema_version,
         "schema_version must be #{@schema_version}"},
        {valid_name?(manifest["name"]),
         "name must be one directory name: letters, digits, - and _"},
        {valid_module?(manifest["module"]), "module must be a module name such as MyApp.Audit"},
        {one_loader?(manifest),
         "exactly one of \"ebin\" (a list of directories) or \"script\" (an .exs file) must say how to load it"},
        {valid_versions?(manifest), versions_rule(manifest)},
        {valid_api?(Map.get(manifest, "extension_api")),
         "extension_api must be a positive integer (Lemieux.Extension.api_version/0)"},
        {is_map(Map.get(manifest, "options", %{})), "options must be a JSON object"}
      ],
      :ok,
      fn
        {true, _problem} -> nil
        {false, problem} -> {:error, "#{manifest_path(directory)}: #{problem}"}
      end
    )
  end

  defp valid_module?(module) when is_binary(module), do: Regex.match?(@module_pattern, module)
  defp valid_module?(_module), do: false

  defp one_loader?(%{"ebin" => ebin} = manifest) when is_list(ebin),
    do: ebin != [] and Enum.all?(ebin, &is_binary/1) and not Map.has_key?(manifest, "script")

  defp one_loader?(%{"script" => script} = manifest) when is_binary(script),
    do: not Map.has_key?(manifest, "ebin")

  defp one_loader?(_manifest), do: false

  # A script is compiled here, so only the Lemieux it was written for is
  # its manifest's business; a compiled bundle carries beams, and the
  # runtime they were compiled on is part of whether they load.
  defp valid_versions?(%{"script" => _script, "versions" => %{"lemieux" => lemieux}}),
    do: is_binary(lemieux)

  defp valid_versions?(%{"script" => _script}), do: false

  defp valid_versions?(%{"versions" => versions}) when is_map(versions),
    do: Enum.all?(@version_keys, &is_binary(versions[&1]))

  defp valid_versions?(_manifest), do: false

  defp versions_rule(%{"script" => _script}),
    do:
      "versions must name the lemieux version or requirement the script was written for, " <>
        "such as {\"lemieux\": \"~> 0.8\"}"

  defp versions_rule(manifest),
    do:
      "versions must name the lemieux, elixir and otp versions it was built against" <>
        missing_versions(manifest["versions"])

  defp missing_versions(versions) when is_map(versions) do
    case Enum.reject(@version_keys, &is_binary(versions[&1])) do
      [] -> ""
      missing -> " (missing #{Enum.join(missing, ", ")})"
    end
  end

  defp missing_versions(_versions), do: ""

  defp valid_api?(nil), do: true
  defp valid_api?(api), do: is_integer(api) and api > 0

  # See "Refusals" in the module documentation for why each form is checked
  # the way it is.
  defp compatible(%{"script" => _script} = manifest, directory) do
    with :ok <- lemieux_requirement(manifest, directory), do: api(manifest, directory)
  end

  defp compatible(%{"extension_api" => _api} = manifest, directory) do
    with :ok <- api(manifest, directory),
         :ok <- otp(manifest, directory),
         do: elixir(manifest, directory)
  end

  defp compatible(manifest, directory), do: exact(manifest, directory)

  defp lemieux_requirement(%{"versions" => %{"lemieux" => wanted}} = manifest, directory) do
    ours = Lemieux.version()

    case requirement(wanted) do
      {:ok, requirement} ->
        if Version.match?(ours, requirement),
          do: :ok,
          else:
            {:error,
             "extension #{manifest["name"]} in #{directory} was written for lemieux #{wanted}; " <>
               "this lmx is lemieux #{ours}. Update the script and its manifest's " <>
               "\"versions\" for this release."}

      :error ->
        {:error,
         "#{manifest_path(directory)}: versions.lemieux #{inspect(wanted)} is neither a " <>
           "version such as \"0.8.0\" nor a requirement such as \"~> 0.8\""}
    end
  end

  # A bare version names the release line it was written against: the same
  # minor before 1.0, where a minor release may change the contract, and the
  # same major after it.
  defp requirement(wanted) do
    case Version.parse(wanted) do
      {:ok, version} -> Version.parse_requirement(release_line(version))
      :error -> Version.parse_requirement(wanted)
    end
  end

  defp release_line(%Version{major: 0, minor: minor} = version),
    do: ">= #{version} and < 0.#{minor + 1}.0"

  defp release_line(%Version{major: major} = version),
    do: ">= #{version} and < #{major + 1}.0.0"

  defp api(%{"extension_api" => theirs} = manifest, directory) do
    ours = Lemieux.Extension.api_version()

    if theirs == ours,
      do: :ok,
      else:
        {:error,
         "extension #{manifest["name"]} in #{directory} was built for extension API " <>
           "#{theirs}; this lmx speaks extension API #{ours}. Rebuild it with " <>
           "mix lmx.extension.build."}
  end

  defp api(_manifest, _directory), do: :ok

  defp otp(%{"versions" => %{"otp" => theirs}} = manifest, directory) do
    ours = System.otp_release()

    if theirs == ours,
      do: :ok,
      else:
        {:error,
         "extension #{manifest["name"]} in #{directory} was built on OTP #{theirs}; this lmx " <>
           "runs OTP #{ours}, and a beam compiled for another OTP may not load. Rebuild it " <>
           "with mix lmx.extension.build."}
  end

  defp elixir(%{"versions" => %{"elixir" => theirs}} = manifest, directory) do
    ours = System.version()

    with {:ok, built} <- Version.parse(theirs),
         {:ok, running} <- Version.parse(ours),
         true <- built.major == running.major and Version.compare(built, running) != :gt do
      :ok
    else
      _incompatible ->
        {:error,
         "extension #{manifest["name"]} in #{directory} was built with Elixir #{theirs}; this " <>
           "lmx runs Elixir #{ours}. Compiled code runs only on the Elixir it was built with " <>
           "or a newer one of the same major. Rebuild it with mix lmx.extension.build."}
    end
  end

  # The rule for a bundle built before the API version existed: exact, on
  # all three. A lemieux that moved may have changed the harness the
  # extension writes to, and nothing in the manifest says whether it did.
  defp exact(%{"versions" => theirs} = manifest, directory) do
    ours = versions()

    if Map.take(theirs, @version_keys) == ours do
      :ok
    else
      {:error,
       "extension #{manifest["name"]} in #{directory} was built against #{describe(theirs)}; " <>
         "this lmx is #{describe(ours)}. Rebuild it against these versions with " <>
         "mix lmx.extension.build."}
    end
  end

  defp describe(versions),
    do: "lemieux #{versions["lemieux"]}, Elixir #{versions["elixir"]} and OTP #{versions["otp"]}"

  # The ebin form: every directory on the path, and every beam's md5 read
  # from the file — not from a loaded module, because a dependency's modules
  # are loaded lazily and may never be. A module the beams do not define is
  # refused before anything goes on the path.
  defp load_code(%{"ebin" => ebins, "module" => name}, directory) do
    with {:ok, paths} <- inside_all(directory, ebins, :directory),
         {:ok, beams} <- __MODULE__.Code.install(paths, name),
         {:ok, module_digest} <- own_digest(beams, name, directory) do
      {:ok,
       %{
         "ebin" => ebins,
         "module_digest" => module_digest,
         "beam_count" => length(beams),
         "beams_sha256" => beams_sha256(beams)
       }}
    end
  end

  defp load_code(%{"script" => script} = manifest, directory) do
    with {:ok, path} <- inside(directory, script, :regular),
         {:ok, bytes} <- read_script(path),
         digest = Contract.sha256(bytes),
         :ok <- compile_once(directory, manifest, path, bytes, digest) do
      {:ok, %{"script" => script, "script_sha256" => digest}}
    end
  end

  defp read_script(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, "cannot read #{path} (#{reason})"}
    end
  end

  defp compile_once(directory, manifest, path, bytes, digest) do
    key = {__MODULE__, directory}
    module = module(manifest)

    case :persistent_term.get(key, nil) do
      {^digest, modules} ->
        if compiled_modules?(modules, module),
          do: :ok,
          else: {:error, "#{path}'s compiled modules changed in this VM; restart to load it"}

      _ ->
        with {:ok, modules} <- __MODULE__.Code.compile(path, bytes, module) do
          :persistent_term.put(key, {digest, modules})
        end
    end
  end

  defp compiled_modules?(modules, module) do
    Map.has_key?(modules, module) and
      Enum.all?(modules, fn {mod, md5} ->
        Code.ensure_loaded?(mod) and mod.module_info(:md5) == md5
      end)
  end

  defp inside_all(directory, paths, kind) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, found} ->
      case inside(directory, path, kind) do
        {:ok, absolute} -> {:cont, {:ok, found ++ [absolute]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  # A manifest path is a canonical relative path — no `.`, no `..`, not
  # absolute, spelt the one way — whose every component is a real directory
  # or file, never a symlink, and which `Path.safe_relative/2` then agrees
  # stays inside. The symlink rule is stricter than `Path.safe_relative/2`
  # alone, and checked before it so the refusal says "symlink": a link that
  # points inside today can be repointed tomorrow without the manifest's
  # digest changing, and this loader is about to put what it finds on the
  # code path.
  defp inside(directory, path, kind) do
    with :ok <- canonical(path),
         :ok <- real_components(directory, Path.split(path), kind),
         {:ok, ^path} <- Path.safe_relative(path, directory) do
      {:ok, Path.join(directory, path)}
    else
      {:error, :symlink} ->
        {:error,
         "#{path} in #{manifest_path(directory)} is or crosses a symlink; " <>
           "an extension's code must be real files inside #{directory}"}

      {:error, {:not, kind, found}} ->
        {:error,
         "#{path} in #{manifest_path(directory)} must be #{article(kind)} inside " <>
           "#{directory}, not #{found}"}

      _other ->
        {:error,
         "#{path} in #{manifest_path(directory)} must be a canonical relative path inside " <>
           "#{directory}"}
    end
  end

  defp article(:directory), do: "a directory"
  defp article(:regular), do: "a file"

  defp canonical(path) do
    parts = Path.split(path)

    if Path.type(path) == :relative and parts != [] and
         Enum.all?(parts, &(&1 not in [".", "..", ""])) and Path.join(parts) == path,
       do: :ok,
       else: {:error, :not_canonical}
  end

  defp real_components(parent, [name], kind) do
    case File.lstat(Path.join(parent, name)) do
      {:ok, %{type: ^kind}} -> :ok
      {:ok, %{type: :symlink}} -> {:error, :symlink}
      {:ok, %{type: found}} -> {:error, {:not, kind, found}}
      {:error, reason} -> {:error, {:not, kind, reason}}
    end
  end

  defp real_components(parent, [name | rest], kind) do
    directory = Path.join(parent, name)

    case File.lstat(directory) do
      {:ok, %{type: :directory}} -> real_components(directory, rest, kind)
      {:ok, %{type: :symlink}} -> {:error, :symlink}
      _other -> {:error, :missing}
    end
  end

  defp own_digest(beams, name, directory) do
    case List.keyfind(beams, name, 0) do
      {^name, digest} -> {:ok, digest}
      nil -> {:error, "#{name} is not defined by the code in #{directory}"}
    end
  end

  # One digest over the sorted `Module:md5` pairs, so a dependency that
  # changed still changes the record although no dependency is named in it.
  defp beams_sha256(beams) do
    beams
    |> Enum.map_join("\n", fn {module, md5} -> "#{module}:#{md5}" end)
    |> Contract.sha256()
  end

  # The module is an atom made from the manifest — one atom, for the one
  # name the person wrote — and it has to be defined by the code just
  # loaded, not by something that happened to share its name in this VM. For
  # the ebin form the loaded module's md5 is checked against the beam's, so
  # the "applied" record cannot name one build while another is running.
  defp extension_module(manifest, directory, code) do
    module = module(manifest)

    with :ok <- defined(module, manifest, directory, code),
         {:ok, contracts} <- exports_contract(module) do
      {:ok, module, contracts}
    end
  end

  defp module(%{"module" => name}), do: Module.concat([name])

  defp defined(module, %{"module" => name}, directory, %{"module_digest" => digest}) do
    case Code.ensure_loaded(module) do
      {:error, reason} ->
        {:error, "#{name} could not be loaded from #{directory} (#{reason})"}

      {:module, ^module} ->
        loaded = module.module_info(:md5) |> Base.encode16(case: :lower)

        if loaded == digest do
          :ok
        else
          {:error,
           "#{name} is already loaded in this VM as a different build " <>
             "(#{loaded} here, #{digest} in #{directory})"}
        end
    end
  end

  defp defined(module, %{"module" => name}, directory, %{"script" => script}) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> :ok
      {:error, _reason} -> {:error, "#{name} is not defined by #{Path.join(directory, script)}"}
    end
  end

  # Which of the two contracts the module speaks; neither is nothing to load.
  defp exports_contract(module) do
    contracts = %{
      apply?: function_exported?(module, :apply, 2),
      routes?: function_exported?(module, :routes, 1)
    }

    if contracts.apply? or contracts.routes?,
      do: {:ok, contracts},
      else:
        {:error,
         "#{inspect(module)} does not export apply/2 (a Lemieux.Extension) or routes/1 " <>
           "(a Lemieux.Extension.Routes), so there is nothing to load it for"}
  end
end
