defmodule Lemieux.Learning.Asset do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Immutable typed, non-executable learning candidates.

  A skill is a complete on-demand file tree, a tool description changes only
  already authorized personal tools, and configuration selects an allowlisted
  parameter of shipped code. These are ordinary `Lemieux.Asset.Version` values;
  creating one grants no activation or independent qualification. Profile and
  overlay campaigns retain their existing format.

  The host supplies current scope, binding, trust, tools and setting allowlists
  on every validation. Candidates cannot select modules, routes, credentials,
  environments, permissions, commands or evaluators. The validator identity and
  complete dependency bytes travel inside the version digest. New kinds must
  pass the host's qualification protocol before automatic selection is enabled.
  """
  alias Lemieux.Asset.Version
  alias Lemieux.Contract
  alias Lemieux.Extensions.Workspace.Skill
  alias Lemieux.Learning.Extension.Tree

  @fields ~w(kind payload files requires_tools triggers)
  @kinds %{
    "skill" => :workflow,
    "tool_description" => :tool_description,
    "configuration" => :configuration
  }

  @spec new(attrs :: map(), context :: map()) :: {:ok, Version.t()} | {:error, term()}
  def new(attrs, context) do
    with :ok <- validate(attrs, context) do
      Version.new(%{
        type: @kinds[attrs["kind"]],
        layer: :project,
        scope: :project,
        project_id: context.scope["id"],
        authored_by: %{"type" => "learning", "id" => "candidate"},
        content:
          Map.merge(attrs, %{
            "schema_version" => 1,
            "scope" => context.scope,
            "binding" => context.binding,
            "validator" => validator(),
            "qualification" => "unconfirmed"
          })
      })
    end
  end

  @spec verify(version :: Version.t(), context :: map()) :: :ok | {:error, term()}
  def verify(%Version{content: content} = version, context) when is_map(content) do
    with {:ok, rebuilt} <- new(Map.take(content, @fields), context),
         true <-
           rebuilt.content == content and rebuilt.digest == version.digest and
             rebuilt.type == version.type and rebuilt.scope == version.scope and
             rebuilt.layer == version.layer and rebuilt.project_id == version.project_id do
      :ok
    else
      _invalid -> {:error, :typed_asset_mismatch}
    end
  end

  def verify(_invalid, _context), do: {:error, :typed_asset_mismatch}

  @doc "Materializes a new tree and validates it through the actual skill loader; executes no code."
  @spec materialize(version :: Version.t(), root :: Path.t(), context :: map()) ::
          {:ok, Skill.t() | nil} | {:error, term()}
  def materialize(version, root, context) do
    with :ok <- verify(version, context), :ok <- File.mkdir(root) do
      result = write_tree(version, root)
      if match?({:error, _}, result), do: File.rm_rf(root)
      result
    end
  end

  @doc "Checks every installed byte, dependency and actual loader metadata before use."
  @spec installed(version :: Version.t(), root :: Path.t(), context :: map()) ::
          {:ok, Skill.t() | nil} | {:error, term()}
  def installed(version, root, context) do
    with :ok <- verify(version, context),
         {:ok, actual} <- Tree.files(root),
         true <- regular_files(actual) == hashes(version.content["files"]) do
      load(version.content, root)
    else
      false -> {:error, :typed_asset_loader_mismatch}
      error -> error
    end
  end

  defp write_tree(version, root) do
    with :ok <- File.chmod(root, 0o700),
         :ok <-
           Enum.reduce_while(version.content["files"], :ok, &write_file(&1, &2, root)),
         do: load(version.content, root)
  end

  defp write_file({path, bytes}, :ok, root) do
    target = Path.join(root, path)

    result =
      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(target, bytes, [:exclusive]),
           do: File.chmod(target, 0o600)

    if result == :ok, do: {:cont, :ok}, else: {:halt, result}
  end

  defp regular_files(actual),
    do:
      actual
      |> Enum.reject(fn {_path, info} -> info["type"] == "directory" end)
      |> Map.new(fn {path, info} -> {path, info["sha256"]} end)

  defp hashes(files), do: Map.new(files, fn {path, bytes} -> {path, Contract.sha256(bytes)} end)

  defp load(%{"kind" => "skill", "payload" => %{"name" => name}, "triggers" => triggers}, root) do
    with {:ok, skill} <- Skill.read(Path.join(root, "SKILL.md"), source: :learning),
         true <- skill.name == name and skill.model_invocable? and skill.diagnostics == [],
         true <-
           Enum.all?(
             triggers,
             &String.contains?(String.downcase(skill.description), String.downcase(&1))
           ) do
      {:ok, skill}
    else
      false -> {:error, :typed_asset_loader_mismatch}
      error -> error
    end
  end

  defp load(_content, _root), do: {:ok, nil}

  defp validate(attrs, context) when is_map(attrs) and is_map(context) do
    with true <- Enum.sort(Map.keys(attrs)) == Enum.sort(@fields),
         true <- attrs["kind"] in Map.keys(@kinds),
         true <-
           is_map(context.scope) and is_binary(context.scope["id"]) and
             byte_size(Contract.encode!(context.scope)) <= 4096 and
             binding?(context.binding) and context.trust in ~w(personal repository),
         true <-
           strings?(attrs["requires_tools"], 16, 64) and
             Enum.all?(attrs["requires_tools"], &(&1 in context.tools)),
         true <- strings?(attrs["triggers"], 8, 128),
         true <- files?(attrs["files"]),
         true <- byte_size(Contract.encode!(attrs)) <= 65_536,
         true <- kind?(attrs, context) do
      :ok
    else
      _invalid -> {:error, :invalid_typed_asset}
    end
  rescue
    _invalid -> {:error, :invalid_typed_asset}
  end

  defp validate(_attrs, _context), do: {:error, :invalid_typed_asset}

  defp binding?(%{"runtime_sha256" => runtime} = binding) do
    digest?(runtime) and Enum.all?(binding, &binding_entry?/1)
  end

  defp binding?(_unbound), do: false

  defp binding_entry?({key, value})
       when key in ~w(runtime_sha256 tools_sha256 environment_sha256),
       do: digest?(value)

  defp binding_entry?({key, value}) when key in ~w(model effort repository),
    do: is_binary(value) and byte_size(value) in 1..256

  defp binding_entry?(_authority_or_unknown), do: false
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)

  defp kind?(
         %{"kind" => "skill", "payload" => payload, "files" => files, "triggers" => triggers},
         _context
       ) do
    Enum.sort(Map.keys(payload)) == ["name"] and is_binary(payload["name"]) and
      Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, payload["name"]) and
      triggers != [] and Map.has_key?(files, "SKILL.md") and closure?(files)
  end

  defp kind?(
         %{
           "kind" => "tool_description",
           "payload" => payload,
           "files" => files,
           "triggers" => []
         },
         context
       ) do
    context.trust == "personal" and files == %{} and is_map(payload) and map_size(payload) in 1..4 and
      Enum.all?(payload, fn {name, text} ->
        name in context.tools and
          name in context.description_tools and is_binary(text) and byte_size(text) in 1..1024
      end) and
      byte_size(Contract.encode!(payload)) <= 2048
  end

  defp kind?(
         %{
           "kind" => "configuration",
           "payload" => %{"extension" => "search", "glob_after_requests" => n} = payload,
           "files" => files,
           "triggers" => []
         },
         context
       ) do
    map_size(payload) == 2 and files == %{} and n in 0..1000 and
      "search.glob_after_requests" in context.settings_allowlist
  end

  defp kind?(_attrs, _context), do: false

  defp files?(files) when is_map(files) and map_size(files) <= 32 do
    Enum.all?(files, &file?/1)
  end

  defp files?(_files), do: false

  defp file?({path, bytes}) do
    is_binary(path) and Path.type(path) == :relative and Path.join(Path.split(path)) == path and
      Enum.all?(Path.split(path), &path_component?/1) and
      Path.extname(path) in ~w(.md .txt .json) and is_binary(bytes) and String.valid?(bytes) and
      byte_size(bytes) <= 16_384
  end

  defp path_component?(part),
    do: part not in [".", "..", ""] and not String.starts_with?(part, ".")

  defp closure?(files) do
    Enum.all?(files, fn {path, bytes} ->
      Regex.scan(
        ~r/\[[^\]]*\]\(([^\s)]+)\)|`((?:references|helpers|scripts|templates)\/[^`]+)`/,
        bytes,
        capture: :all_but_first
      )
      |> List.flatten()
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.all?(&reference?(&1, path, files))
    end)
  end

  defp reference?(reference, path, files) do
    target =
      if Path.dirname(path) == ".", do: reference, else: Path.join(Path.dirname(path), reference)

    Map.has_key?(files, target)
  end

  defp strings?(values, maximum, bytes),
    do:
      is_list(values) and length(values) <= maximum and
        Enum.uniq(values) == values and
        Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..bytes))

  defp validator,
    do: %{
      "id" => "lemieux/typed-asset/v1",
      "code_sha256" => Contract.sha256(__MODULE__.module_info(:md5))
    }
end
