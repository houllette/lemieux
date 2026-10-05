defmodule Lemieux.Learning.Overlay do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  The learned harness layer a host applies by default, with its provenance.

  Discovery produces candidates and confirmation produces verdicts, and until
  this module existed neither reached the harness a person actually runs:
  `lmx` read persona, instructions, memory and skills from files and nothing
  else. An overlay is that missing file. It carries only what a candidate
  can change — a system-prompt suffix and per-tool descriptions — plus the
  provenance that says which campaign, which candidate, which digest and
  which confirmation verdict it came from.

  Activation is a file in version control, on purpose. The architecture
  keeps "project-owned changes use ordinary Git review", and a personal
  overlay under `~/.lmx` is the same idea for one person: rollback is
  `git revert` or deleting the file, there is no second mutable memory
  plane, and the harness snapshot records the overlay's digest on every
  request so evidence says which learned layer was in force. `export/3`
  refuses to write an unconfirmed candidate unless the caller says so, and
  then labels it, because a frontier member is a development result.

  ## Whose overlay may do what

  The digest a file carries is computed by whoever wrote the file, so it
  proves the file is intact and nothing about who wrote it. A repository's
  overlay is therefore read as what it is — text a checkout supplies — and
  `lmx` applies only its system-prompt suffix, naming it on every start;
  tool descriptions come only from a person's own overlay
  (`Lemieux.Extensions.Workspace.Discovery` holds that rule, and
  `without_tool_descriptions/1` is how it is applied).
  """

  alias Lemieux.Contract
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Tool
  alias Lemieux.Tool.Override

  @version 1
  @filename "harness.json"

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          sha256: String.t(),
          system_suffix: String.t() | nil,
          tool_descriptions: %{String.t() => String.t()},
          provenance: map(),
          qualification: String.t()
        }

  defstruct path: nil,
            sha256: "",
            system_suffix: nil,
            tool_descriptions: %{},
            provenance: %{},
            qualification: "unconfirmed"

  @doc "The file name a host looks for under a project's `.lmx/` or a personal `~/.lmx/`."
  @spec filename() :: String.t()
  def filename, do: @filename

  @doc "Reads and validates an overlay file; a missing file is `{:ok, nil}`."
  @spec read(path :: Path.t()) :: {:ok, t() | nil} | {:error, term()}
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, map} <- Contract.decode(bytes),
             {:ok, overlay} <- from_map(map) do
          {:ok, %{overlay | path: path}}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Builds and verifies an overlay from its JSON shape.

  `"qualification"` is `"confirmed"` or `"unconfirmed"` (the default), the
  two values `from_archive/2` writes; anything else is
  `{:error, :invalid_qualification}`. A host names the qualification of a
  repository's overlay in a startup notice, so a free-form value was a
  repository writing its own words into what `lmx` says — "confirmed by the
  lmx maintainers" — and a non-string one crashed discovery in that
  repository.
  """
  @spec from_map(map :: map()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) do
    with :ok <- Contract.verify_version(map, "schema_version", @version),
         :ok <- Contract.verify_digest(map, "sha256"),
         :ok <- suffix(map["system_suffix"]),
         :ok <- descriptions(map["tool_descriptions"]),
         {:ok, qualification} <- qualification_field(map["qualification"]) do
      {:ok,
       %__MODULE__{
         sha256: map["sha256"],
         system_suffix: map["system_suffix"],
         tool_descriptions: map["tool_descriptions"] || %{},
         provenance: map["provenance"] || %{},
         qualification: qualification
       }}
    end
  end

  defp qualification_field(nil), do: {:ok, "unconfirmed"}

  defp qualification_field(qualification) when qualification in ["confirmed", "unconfirmed"],
    do: {:ok, qualification}

  defp qualification_field(_other), do: {:error, :invalid_qualification}

  @doc "The canonical JSON shape, digest included."
  @spec to_map(overlay :: t()) :: map()
  def to_map(%__MODULE__{} = overlay) do
    base = %{
      "schema_version" => @version,
      "system_suffix" => overlay.system_suffix,
      "tool_descriptions" => overlay.tool_descriptions,
      "provenance" => overlay.provenance,
      "qualification" => overlay.qualification
    }

    Map.put(base, "sha256", Contract.digest(base))
  end

  @doc "Encodes an overlay for a file."
  @spec encode!(overlay :: t()) :: String.t()
  def encode!(%__MODULE__{} = overlay), do: overlay |> to_map() |> Contract.encode!()

  @doc """
  Derives an overlay from a campaign archive candidate.

  Requires the archive's `plan.json`, the candidate, its content and the seed
  content. The system suffix is the part of the candidate's system prompt
  that follows the seed's; a candidate whose prompt does not extend the
  seed's is recorded as a full replacement. A confirmation result under
  `confirmations/<candidate>/result.json` is folded into the provenance and
  sets the qualification; without one the qualification stays
  `"unconfirmed"` and `export/3` needs `unconfirmed: true`.
  """
  @spec from_archive(archive_dir :: Path.t(), candidate_id :: String.t()) ::
          {:ok, t()} | {:error, term()}
  def from_archive(archive_dir, candidate_id)
      when is_binary(archive_dir) and is_binary(candidate_id) do
    with {:ok, plan} <- read_plan(archive_dir),
         {:ok, candidate} <- read_candidate(archive_dir, plan, candidate_id),
         {:ok, content} <- artifact(archive_dir, Candidate.content_sha256(candidate)),
         {:ok, seed} <- File.read(Path.join(archive_dir, "seed/profile.json")),
         {:ok, profile} <- decode(content),
         {:ok, seed_profile} <- decode(seed) do
      confirmation = read_confirmation(archive_dir, candidate_id)

      {suffix, mode} =
        suffix_from(seed_profile["options"]["system"], profile["options"]["system"])

      overlay = %__MODULE__{
        system_suffix: suffix,
        tool_descriptions: profile["options"]["tool_descriptions"] || %{},
        provenance: %{
          "campaign_id" => plan.id,
          "plan_sha256" => plan.sha256,
          "candidate_id" => candidate.id,
          "candidate_sha256" => candidate.sha256,
          "content_sha256" => Candidate.content_sha256(candidate),
          "mutation_kind" => candidate.mutation_kind,
          "changed_paths" => get_in(candidate.extensions, ["changed_paths"]) || [],
          "hypothesis" => get_in(candidate.extensions, ["hypothesis"]),
          "search_model" => profile["model"],
          "system_mode" => mode,
          "confirmation" => confirmation,
          "exported_at" => DateTime.to_iso8601(DateTime.utc_now())
        },
        qualification: qualification(confirmation)
      }

      {:ok, %{overlay | sha256: to_map(overlay)["sha256"]}}
    end
  end

  @doc """
  Writes an overlay file. Refuses an unconfirmed overlay unless
  `unconfirmed: true`, and refuses to overwrite unless `force: true`.
  """
  @spec export(overlay :: t(), path :: Path.t(), opts :: keyword()) :: :ok | {:error, term()}
  def export(%__MODULE__{} = overlay, path, opts \\ []) when is_binary(path) and is_list(opts) do
    cond do
      overlay.qualification != "confirmed" and not Keyword.get(opts, :unconfirmed, false) ->
        {:error, {:unconfirmed_overlay, overlay.qualification}}

      File.exists?(path) and not Keyword.get(opts, :force, false) ->
        {:error, {:overlay_exists, path}}

      true ->
        with :ok <- File.mkdir_p(Path.dirname(path)) do
          File.write(path, encode!(overlay))
        end
    end
  end

  @doc "Applies an overlay's suffix to a system prompt."
  @spec apply_system(overlay :: t() | nil, system :: String.t()) :: String.t()
  def apply_system(nil, system), do: system
  def apply_system(%__MODULE__{system_suffix: nil}, system), do: system
  def apply_system(%__MODULE__{system_suffix: ""}, system), do: system
  def apply_system(%__MODULE__{system_suffix: suffix}, system), do: system <> "\n\n" <> suffix

  @doc """
  Wraps tools whose names the overlay describes in `Lemieux.Tool.Override`.

  A description for a tool the catalog does not carry is skipped rather than
  an error, which is why the map is filtered before `Lemieux.Tool.decorate/2`
  sees it: an overlay is written against the full default set and applied to
  whatever a session was actually given, which a read-only A2A task or a
  narrowed profile may have cut down.
  """
  @spec apply_tools(overlay :: t() | nil, tools :: [Tool.t()]) :: [Tool.t()]
  def apply_tools(nil, tools), do: tools

  def apply_tools(%__MODULE__{tool_descriptions: descriptions}, tools) when is_list(tools) do
    present = MapSet.new(tools, &Tool.name/1)

    wrappers =
      for {name, description} <- descriptions, MapSet.member?(present, name), into: %{} do
        {name, &Override.new!(&1, description: description)}
      end

    Tool.decorate(tools, wrappers)
  end

  @doc "The resolved-asset record a host puts in `harness_context` for evidence."
  @spec asset(overlay :: t()) :: map()
  def asset(%__MODULE__{} = overlay) do
    %{
      "type" => "harness_overlay",
      "id" => overlay.path || "harness_overlay",
      "sha256" => overlay.sha256,
      "qualification" => overlay.qualification,
      "candidate_id" => overlay.provenance["candidate_id"],
      "campaign_id" => overlay.provenance["campaign_id"]
    }
  end

  @doc """
  The overlay without its tool descriptions, and the tool names it described.

  The digest is recomputed when anything was dropped, so the asset a session
  records describes the layer that was actually in force, not the file it
  was cut from.
  """
  @spec without_tool_descriptions(overlay :: t()) :: {t(), [String.t()]}
  def without_tool_descriptions(%__MODULE__{tool_descriptions: descriptions} = overlay)
      when map_size(descriptions) == 0,
      do: {overlay, []}

  def without_tool_descriptions(%__MODULE__{tool_descriptions: descriptions} = overlay) do
    stripped = %{overlay | tool_descriptions: %{}}
    {%{stripped | sha256: to_map(stripped)["sha256"]}, descriptions |> Map.keys() |> Enum.sort()}
  end

  @doc "Merges a personal overlay under a project overlay; project keys win."
  @spec merge(personal :: t() | nil, project :: t() | nil) :: t() | nil
  def merge(nil, project), do: project
  def merge(personal, nil), do: personal

  def merge(%__MODULE__{} = personal, %__MODULE__{} = project) do
    merged = %__MODULE__{
      path: project.path,
      system_suffix: join_suffix(personal.system_suffix, project.system_suffix),
      tool_descriptions: Map.merge(personal.tool_descriptions, project.tool_descriptions),
      provenance: %{"personal" => personal.provenance, "project" => project.provenance},
      qualification: weakest(personal.qualification, project.qualification)
    }

    %{merged | sha256: to_map(merged)["sha256"]}
  end

  defp join_suffix(nil, project), do: project
  defp join_suffix(personal, nil), do: personal
  defp join_suffix(personal, project), do: personal <> "\n\n" <> project

  defp weakest("confirmed", "confirmed"), do: "confirmed"
  defp weakest(_left, _right), do: "unconfirmed"

  defp suffix_from(seed, candidate) when is_binary(seed) and is_binary(candidate) do
    if String.starts_with?(candidate, seed) do
      {candidate
       |> binary_part(byte_size(seed), byte_size(candidate) - byte_size(seed))
       |> String.trim(), "suffix"}
    else
      {candidate, "replacement"}
    end
  end

  defp suffix_from(_seed, candidate), do: {candidate, "replacement"}

  defp qualification(%{"verdict" => "pass"}), do: "confirmed"
  defp qualification(_confirmation), do: "unconfirmed"

  defp read_confirmation(dir, candidate_id) do
    path = Path.join([dir, "confirmations", safe(candidate_id), "result.json"])

    case File.read(path) do
      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, result} ->
            Map.take(result, [
              "verdict",
              "reason",
              "arms",
              "pairs",
              "experiment_id",
              "experiment_sha256"
            ])

          _invalid ->
            nil
        end

      {:error, _} ->
        nil
    end
  end

  defp read_plan(dir) do
    with {:ok, bytes} <- File.read(Path.join(dir, "plan.json")), do: Plan.decode(bytes)
  end

  defp read_candidate(dir, plan, id) do
    path = Path.join([dir, "candidates", safe(id) <> ".json"])

    case File.read(path) do
      {:ok, bytes} -> Candidate.decode(plan, bytes)
      {:error, :enoent} -> {:error, {:unknown_candidate, id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp artifact(dir, sha256) do
    case File.read(Path.join([dir, "artifacts", sha256])) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:error, {:candidate_content_missing, sha256}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(bytes) do
    case JSON.decode(bytes) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _invalid -> {:error, :profile_not_json}
    end
  end

  defp suffix(nil), do: :ok
  defp suffix(value) when is_binary(value), do: :ok
  defp suffix(_value), do: {:error, :invalid_system_suffix}

  defp descriptions(nil), do: :ok

  defp descriptions(map) when is_map(map) do
    if Enum.all?(map, fn {name, text} -> is_binary(name) and is_binary(text) and text != "" end),
      do: :ok,
      else: {:error, :invalid_tool_descriptions}
  end

  defp descriptions(_value), do: {:error, :invalid_tool_descriptions}

  defp safe(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")
end
