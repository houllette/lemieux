defmodule Lemieux.Learning.Extension.Build do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A pinned source tree, configuration and dependency runtime for local evaluation.

  `freeze/4` preserves the extension's declared files and snapshots dependency
  BEAM directories. Pass `:runtime_paths` explicitly to restrict the runtime;
  the default captures non-system code paths, excluding the extension's own
  precompiled application. Pass `:runtime_assets` as a list
  of `{runtime_index, directory}` pairs for required `priv` trees (model catalogs,
  NIFs, templates). By default dependency `priv` directories are copied, excluding
  Lemieux's development PLT cache. Assets must contain regular files, not symlinks. Credentials
  belong in the consumer environment, never in the profile or packaged assets.

  Each `run/3` starts a separate BEAM, compiles all frozen `lib/**/*.ex`, and calls
  the extension's `configure/1`, then `Lemieux.Agent.run/3`. `configure/1` returns
  `{:ok, options, effective_profile}`; the effective profile must equal the
  frozen JSON profile. This is a trusted extension contract, not a proof that
  arbitrary Elixir obeys its options. The profile records `execution`, `model`,
  `tools` and `options`; configuration code must resolve all behavioral defaults
  there and keep runtime credentials separate.

  Consumers use two schedulers. Starting a full host-sized scheduler pool for
  every independent attempt oversubscribes machines during paired evaluation.
  This execution setting is included in the frozen compatibility record.

  Dependency identity covers compiled bytes, assets and the declared mix.lock
  when present. This does not claim a reproducible dependency build from a lock
  file. Elixir/OTP versions are pinned as compatibility requirements. The clean
  consumer supports ordinary Elixir source and explicit runtime assets, not Mix
  custom compilers or implicit application startup/configuration. Such extensions
  need a host-specific build/sandbox lane before qualification.

  A subprocess is not an OS sandbox. Extensions and configuration remain trusted
  code. Builds grant no activation capability and have no efficacy verdict.
  """

  alias Lemieux.Benchmark.Command
  alias Lemieux.Learning.Extension.Export
  alias Lemieux.Learning.Extension.Tree

  @type t :: %__MODULE__{root: Path.t(), sha256: String.t()}
  @enforce_keys [:root, :sha256]
  defstruct [:root, :sha256]

  @doc "Freezes declared source, a JSON profile and dependency runtime into a new directory."
  @spec freeze(source :: Path.t(), destination :: Path.t(), profile :: map(), opts :: keyword()) ::
          {:ok, t()} | {:error, term()}
  def freeze(source, destination, profile, opts \\ []) do
    destination = Path.expand(destination)

    with :ok <- validate_profile(profile),
         :ok <- File.mkdir(destination) do
      result = freeze_into(source, destination, profile, opts)
      if match?({:error, _}, result), do: File.rm_rf(destination)
      result
    end
  end

  @doc "Checks every frozen byte and the current Elixir/OTP compatibility requirements."
  @spec verify(build :: t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = build) do
    with {:ok, receipt} <- Tree.verify(build.root, "build.json", build.sha256),
         true <- receipt["runtime"] == versions(),
         :ok <- Export.verify(Path.join(build.root, "source")) do
      :ok
    else
      false -> {:error, :incompatible_frozen_runtime}
      error -> error
    end
  end

  @doc "Opens a build only against a separately retained expected digest."
  @spec open(root :: Path.t(), digest :: String.t()) :: {:ok, t()} | {:error, term()}
  def open(root, digest) do
    build = %__MODULE__{root: Path.expand(root), sha256: digest}
    with :ok <- verify(build), do: {:ok, build}
  end

  @doc "Returns the frozen, non-secret execution profile."
  @spec profile(build :: t()) :: {:ok, map()} | {:error, term()}
  def profile(%__MODULE__{} = build), do: Tree.read(Path.join(build.root, "profile.json"))

  @doc "Compiles and executes frozen source in a fresh consumer; live dispatch is explicit."
  @spec run(build :: t(), input :: Lemieux.Agent.input(), opts :: keyword()) ::
          Lemieux.Agent.result()
  def run(%__MODULE__{} = build, input, opts \\ []) do
    with :ok <- verify(build),
         {:ok, profile} <- profile(build),
         :ok <- authorize(profile, opts) do
      consume(build, input)
    end
  end

  defp freeze_into(source, root, profile, opts) do
    with {:ok, receipt} <- Export.export(source, Path.join(root, "source")),
         {:ok, paths} <- selected_paths(opts, receipt["module"]),
         :ok <- Tree.write(Path.join(root, "profile.json"), profile),
         :ok <- copy_runtime(paths, root),
         :ok <-
           copy_assets(
             Keyword.get_lazy(opts, :runtime_assets, fn -> runtime_assets(paths) end),
             paths,
             root
           ),
         {:ok, sealed} <-
           Tree.seal(root, "build.json", %{
             "schema_version" => 1,
             "module" => receipt["module"],
             "runtime" => versions(),
             "source_sha256" => receipt["sha256"]
           }) do
      {:ok, %__MODULE__{root: root, sha256: sealed["sha256"]}}
    end
  end

  defp selected_paths(opts, module) do
    contains_module? = &File.regular?(Path.join(&1, "Elixir." <> module <> ".beam"))

    case Keyword.fetch(opts, :runtime_paths) do
      {:ok, paths} ->
        if Enum.any?(paths, contains_module?),
          do: {:error, :extension_module_in_runtime},
          else: {:ok, paths}

      :error ->
        {:ok, Enum.reject(runtime_paths(), contains_module?)}
    end
  end

  defp runtime_assets(paths) do
    paths
    |> Enum.with_index()
    |> Enum.flat_map(fn {path, index} ->
      priv = Path.join(Path.dirname(path), "priv")

      if runtime_name(path) != "lemieux" and File.dir?(priv),
        do: [{index, resolve_asset_root(priv, 10)}],
        else: []
    end)
  end

  # Mix normally symlinks priv into _build. Resolve this explicitly selected
  # root only; nested links remain forbidden by the frozen tree copier.
  defp resolve_asset_root(path, remaining) when remaining > 0 do
    case File.read_link(path) do
      {:ok, target} -> resolve_asset_root(Path.expand(target, Path.dirname(path)), remaining - 1)
      _other -> path
    end
  end

  defp resolve_asset_root(path, 0), do: path

  defp validate_profile(
         %{"execution" => mode, "model" => model, "tools" => tools, "options" => options} =
           profile
       )
       when mode in ["scripted", "live"] and is_binary(model) and model != "" and is_list(tools) and
              is_map(options) do
    if Enum.sort(Map.keys(profile)) == ~w(execution model options tools) and
         Enum.all?(tools, &is_binary/1) and json_profile?(options) and live_cap?(profile),
       do: :ok,
       else: {:error, :invalid_frozen_profile}
  end

  defp validate_profile(_other), do: {:error, :invalid_frozen_profile}

  defp live_cap?(%{"execution" => "scripted"}), do: true

  defp live_cap?(%{
         "options" => %{
           "usage_mode" => "quota",
           "max_cost_usd" => nil,
           "max_requests" => requests,
           "max_tokens" => tokens,
           "max_turns" => turns
         }
       }),
       do:
         is_integer(requests) and requests > 0 and is_integer(tokens) and tokens > 0 and
           is_integer(turns) and turns > 0

  defp live_cap?(%{"options" => %{"usage_mode" => "quota"}}), do: false

  defp live_cap?(%{"options" => %{"max_cost_usd" => cap}}) when is_number(cap) and cap > 0,
    do: true

  defp live_cap?(_profile), do: false

  defp json_profile?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} ->
      is_binary(key) and
        String.downcase(key) not in ~w(api_key access_token authorization password credentials secret) and
        json_profile?(item)
    end)
  end

  defp json_profile?(value) when is_list(value), do: Enum.all?(value, &json_profile?/1)

  defp json_profile?(value),
    do: is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  defp authorize(%{"execution" => "scripted"}, _opts), do: :ok

  defp authorize(_profile, opts) do
    if opts[:allow_live] == true, do: :ok, else: {:error, :live_confirmation_required}
  end

  defp consume(build, input) do
    scratch = Path.join(System.tmp_dir!(), "lemieux-consumer-" <> Lemieux.ID.generate())
    File.mkdir!(scratch)
    File.chmod!(scratch, 0o700)

    try do
      input_path = Path.join(scratch, "input.json")
      output_path = Path.join(scratch, "output.json")

      :ok =
        Tree.write(
          input_path,
          Map.new(Map.take(input, [:prompt, :cwd, :timeout_ms]), fn {key, value} ->
            {to_string(key), value}
          end)
        )

      paths = Path.wildcard(Path.join(build.root, "runtime/*/ebin"))
      args = Enum.flat_map(paths, &["-pa", &1])
      script = "Lemieux.Learning.Extension.Consumer.run(System.argv())"

      with {:ok, result} <-
             Command.run(
               ["elixir", "--erl", "+S 2:2 +SDcpu 1 +SDio 1" | args] ++
                 ["-e", script, build.root, input_path, output_path],
               cwd: scratch,
               timeout: input.timeout_ms,
               max_output_bytes: 16_000,
               env:
                 Map.new(
                   ~w(ERL_LIBS ELIXIR_ERL_OPTIONS ERL_AFLAGS ERL_FLAGS ERL_ZFLAGS),
                   &{&1, ""}
                 )
             ),
           :ok <- consumer_status(result),
           :ok <- verify(build),
           {:ok, result} <- Tree.read(output_path) do
        outcome(result, build.sha256)
      end
    after
      File.rm_rf(scratch)
    end
  end

  defp outcome(%{"ok" => true, "observation" => observation}, digest),
    do: {:ok, Map.put(observation, "frozen_build_sha256", digest)}

  defp outcome(%{"ok" => false, "error" => error, "observation" => observation}, digest),
    do: {:error, {:frozen_agent, error}, Map.put(observation, "frozen_build_sha256", digest)}

  defp outcome(%{"ok" => false, "error" => error}, _digest), do: {:error, {:frozen_agent, error}}
  defp outcome(_other, _digest), do: {:error, :invalid_consumer_result}

  defp consumer_status(%{"exit_status" => 0, "timed_out" => false}), do: :ok

  defp consumer_status(result),
    do: {:error, {:consumer_failed, Map.take(result, ~w(exit_status timed_out))}}

  defp copy_runtime(paths, root) do
    paths
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case Tree.copy(path, Path.join([root, "runtime", runtime_name(paths, path), "ebin"])) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp copy_assets(assets, paths, root) do
    Enum.reduce_while(assets, :ok, fn {index, path}, :ok ->
      name = runtime_name(paths, Enum.fetch!(paths, index))

      case Tree.copy(path, Path.join([root, "runtime", name, "priv"])) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp runtime_name(path), do: path |> Path.dirname() |> Path.basename()

  # Two paths on the VM's code path may share a parent name — a host that
  # loaded an extension from a directory called like a shipped application,
  # or a test suite that prepended two throwaway `ebin`s — and the frozen
  # layout only needs each to land somewhere `runtime/*/ebin` finds. Every
  # path after the first with a given name gets a digest of its own path as
  # a suffix, the same way for its `ebin` and its `priv`, rather than the
  # whole freeze being refused.
  defp runtime_name(paths, path) do
    name = runtime_name(path)

    case Enum.find(paths, &(runtime_name(&1) == name)) do
      ^path -> name
      _earlier -> name <> "-" <> short_digest(path)
    end
  end

  defp short_digest(path),
    do: :sha256 |> :crypto.hash(path) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  defp runtime_paths do
    system = [
      :code.root_dir() |> List.to_string(),
      :code.lib_dir(:elixir) |> List.to_string() |> Path.dirname()
    ]

    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(fn path ->
      Path.basename(path) == "ebin" and
        not Enum.any?(system, &String.starts_with?(path, &1 <> "/"))
    end)
    |> Enum.sort()
  end

  defp versions,
    do: %{
      "elixir" => System.version(),
      "consumer_schedulers" => 2,
      "otp" => otp_version(),
      "erts" => List.to_string(:erlang.system_info(:version)),
      "architecture" => List.to_string(:erlang.system_info(:system_architecture))
    }

  defp otp_version do
    [
      List.to_string(:code.root_dir()),
      "releases",
      List.to_string(:erlang.system_info(:otp_release)),
      "OTP_VERSION"
    ]
    |> Path.join()
    |> File.read!()
    |> String.trim()
  end
end
