defmodule Lemieux.Learning.Discovery.Plan do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A frozen, proposer-visible contract for bounded exploratory search.

  Development and validation cases are explicit and disjoint. There is no
  holdout field: hidden confirmation belongs to `Lemieux.Experiment.Plan`
  after one candidate is selected and frozen by the host.
  """

  alias Lemieux.Contract

  @version 1
  @budget_fields ~w(maximum_candidates maximum_tokens maximum_cost_usd maximum_time_ms)
  @directions ~w(maximize minimize)

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          sha256: String.t(),
          created_at: DateTime.t(),
          scope: map(),
          target_interface: map(),
          mutation_surface: [map()],
          seeds: [map()],
          proposer: map(),
          base_model: map(),
          development_case_ids: [String.t()],
          validation_case_ids: [String.t()],
          objectives: [map()],
          hard_constraints: [map()],
          interface_validator: map(),
          budget: map(),
          extensions: map()
        }

  @enforce_keys [
    :id,
    :sha256,
    :created_at,
    :scope,
    :target_interface,
    :mutation_surface,
    :seeds,
    :proposer,
    :base_model,
    :development_case_ids,
    :validation_case_ids,
    :objectives,
    :hard_constraints,
    :interface_validator,
    :budget,
    :extensions
  ]
  defstruct schema_version: @version,
            id: nil,
            sha256: nil,
            created_at: nil,
            scope: %{},
            target_interface: %{},
            mutation_surface: [],
            seeds: [],
            proposer: %{},
            base_model: %{},
            development_case_ids: [],
            validation_case_ids: [],
            objectives: [],
            hard_constraints: [],
            interface_validator: %{},
            budget: %{},
            extensions: %{}

  @doc "Validates and freezes a bounded discovery plan."
  @spec new(attrs :: map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs = Contract.json(attrs)

    with :ok <- no_holdout(attrs),
         :ok <- nonempty(attrs["id"], "id"),
         :ok <- scope(attrs["scope"]),
         :ok <- nonempty_map(attrs["target_interface"], "target_interface"),
         :ok <- nonempty_list(attrs["mutation_surface"], "mutation_surface"),
         :ok <- seeds(attrs["seeds"]),
         :ok <- immutable_config(attrs["proposer"], "proposer"),
         :ok <- immutable_config(attrs["base_model"], "base_model"),
         :ok <- case_splits(attrs["development_case_ids"], attrs["validation_case_ids"]),
         :ok <- objectives(attrs["objectives"]),
         :ok <- constraints(attrs["hard_constraints"]),
         :ok <- immutable_config(attrs["interface_validator"], "interface_validator"),
         :ok <- budget(attrs["budget"]),
         {:ok, created_at} <- parse_time(Map.get(attrs, "created_at", now())) do
      base = %{
        "schema_version" => @version,
        "id" => attrs["id"],
        "created_at" => DateTime.to_iso8601(created_at),
        "scope" => attrs["scope"],
        "target_interface" => attrs["target_interface"],
        "mutation_surface" => attrs["mutation_surface"],
        "seeds" => attrs["seeds"],
        "proposer" => attrs["proposer"],
        "base_model" => attrs["base_model"],
        "development_case_ids" => normalize_ids(attrs["development_case_ids"]),
        "validation_case_ids" => normalize_ids(attrs["validation_case_ids"]),
        "objectives" => attrs["objectives"],
        "hard_constraints" => attrs["hard_constraints"],
        "interface_validator" => attrs["interface_validator"],
        "budget" => attrs["budget"],
        "extensions" => Map.get(attrs, "extensions", %{})
      }

      sha256 = Contract.digest(base)

      if Map.get(attrs, "sha256", sha256) == sha256 do
        {:ok, from_verified_map(Map.put(base, "sha256", sha256), created_at)}
      else
        {:error, :digest_mismatch}
      end
    end
  end

  def new(_attrs), do: {:error, :invalid_discovery_plan}

  @doc "Returns the proposer-visible JSON shape; it has no holdout key."
  @spec to_map(plan :: t()) :: map()
  def to_map(%__MODULE__{} = plan) do
    %{
      "schema_version" => plan.schema_version,
      "id" => plan.id,
      "sha256" => plan.sha256,
      "created_at" => DateTime.to_iso8601(plan.created_at),
      "scope" => plan.scope,
      "target_interface" => plan.target_interface,
      "mutation_surface" => plan.mutation_surface,
      "seeds" => plan.seeds,
      "proposer" => plan.proposer,
      "base_model" => plan.base_model,
      "development_case_ids" => plan.development_case_ids,
      "validation_case_ids" => plan.validation_case_ids,
      "objectives" => plan.objectives,
      "hard_constraints" => plan.hard_constraints,
      "interface_validator" => plan.interface_validator,
      "budget" => plan.budget,
      "extensions" => plan.extensions
    }
  end

  @doc "Encodes a canonical discovery plan."
  @spec encode!(plan :: t()) :: String.t()
  def encode!(%__MODULE__{} = plan), do: plan |> to_map() |> Contract.encode!()

  @doc "Decodes and verifies a discovery plan."
  @spec decode(json :: String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- Contract.decode(json),
         :ok <- Contract.verify_version(map, "schema_version", @version),
         :ok <- verify(map) do
      new(map)
    end
  end

  @doc "Verifies version and digest."
  @spec verify(plan_or_map :: t() | map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = plan), do: plan |> to_map() |> verify()

  def verify(map) when is_map(map) do
    with :ok <- Contract.verify_version(map, "schema_version", @version) do
      Contract.verify_digest(map, "sha256")
    end
  end

  def verify(_other), do: {:error, :invalid_discovery_plan}

  defp no_holdout(value) do
    if contains_holdout?(value), do: {:error, :holdout_not_proposer_visible}, else: :ok
  end

  defp contains_holdout?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      String.contains?(String.downcase(key), "holdout") or contains_holdout?(item)
    end)
  end

  defp contains_holdout?(value) when is_list(value), do: Enum.any?(value, &contains_holdout?/1)
  defp contains_holdout?(_value), do: false

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(_value, field), do: {:error, {:invalid_plan_field, field}}

  defp scope(%{"id" => id}) when is_binary(id) and id != "", do: :ok
  defp scope(_scope), do: {:error, :invalid_plan_scope}

  defp nonempty_map(value, _field) when is_map(value) and map_size(value) > 0, do: :ok
  defp nonempty_map(_value, field), do: {:error, {:invalid_plan_field, field}}

  defp nonempty_list(value, _field) when is_list(value) and value != [], do: :ok
  defp nonempty_list(_value, field), do: {:error, {:invalid_plan_field, field}}

  defp seeds(value) when is_list(value) and value != [] do
    ids = Enum.map(value, &Map.get(&1, "id"))

    if Enum.all?(value, &immutable_seed?/1) and length(ids) == MapSet.size(MapSet.new(ids)),
      do: :ok,
      else: {:error, :invalid_plan_seeds}
  end

  defp seeds(_value), do: {:error, :invalid_plan_seeds}

  defp immutable_seed?(%{"id" => id} = seed) when is_binary(id) and id != "" do
    digest = seed["content_sha256"] || seed["sha256"]
    is_binary(digest) and byte_size(digest) == 64
  end

  defp immutable_seed?(_seed), do: false

  defp immutable_config(%{"id" => id, "sha256" => sha256}, _field)
       when is_binary(id) and id != "" and is_binary(sha256) and byte_size(sha256) == 64,
       do: :ok

  defp immutable_config(_value, field), do: {:error, {:mutable_or_missing_configuration, field}}

  defp case_splits(development, validation) do
    with :ok <- ids(development),
         :ok <- ids(validation),
         true <- MapSet.disjoint?(MapSet.new(development), MapSet.new(validation)) do
      :ok
    else
      false -> {:error, :overlapping_development_validation_cases}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ids(value) when is_list(value) and value != [] do
    if Enum.all?(value, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :invalid_case_ids}
  end

  defp ids(_value), do: {:error, :missing_case_ids}

  defp normalize_ids(ids), do: ids |> Enum.uniq() |> Enum.sort()

  defp objectives(value) when is_list(value) and value != [] do
    if Enum.all?(value, fn
         %{"name" => name, "direction" => direction}
         when is_binary(name) and name != "" and direction in @directions ->
           true

         _invalid ->
           false
       end),
       do: :ok,
       else: {:error, :invalid_objectives}
  end

  defp objectives(_value), do: {:error, :invalid_objectives}

  defp constraints(value) when is_list(value) and value != [], do: :ok
  defp constraints(_value), do: {:error, :missing_hard_constraints}

  defp budget(value) when is_map(value) do
    with [] <- Enum.reject(@budget_fields, &Map.has_key?(value, &1)),
         true <- positive_integer?(value["maximum_candidates"]),
         true <- positive_integer?(value["maximum_tokens"]),
         true <- nonnegative_number?(value["maximum_cost_usd"]),
         true <- positive_integer?(value["maximum_time_ms"]),
         true <- Map.get(value, "unknown_cost", "reject") in ["allow", "reject"] do
      :ok
    else
      [_ | _] = missing -> {:error, {:missing_budget_fields, missing}}
      false -> {:error, :invalid_discovery_budget}
    end
  end

  defp budget(_value), do: {:error, :missing_discovery_budget}

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonnegative_number?(value), do: is_number(value) and value >= 0

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> {:ok, time}
      _invalid -> {:error, :invalid_created_at}
    end
  end

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp from_verified_map(map, created_at) do
    %__MODULE__{
      id: map["id"],
      sha256: map["sha256"],
      created_at: created_at,
      scope: map["scope"],
      target_interface: map["target_interface"],
      mutation_surface: map["mutation_surface"],
      seeds: map["seeds"],
      proposer: map["proposer"],
      base_model: map["base_model"],
      development_case_ids: map["development_case_ids"],
      validation_case_ids: map["validation_case_ids"],
      objectives: map["objectives"],
      hard_constraints: map["hard_constraints"],
      interface_validator: map["interface_validator"],
      budget: map["budget"],
      extensions: map["extensions"]
    }
  end
end
