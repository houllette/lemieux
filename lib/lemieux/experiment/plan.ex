defmodule Lemieux.Experiment.Plan do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A versioned preregistration for one bounded control/variant comparison.

  Plans are immutable once attempts begin. Requiring one declared change,
  paired case ids, a primary metric, a minimum effect and a stopping rule
  prevents an optimizer from changing the question after seeing results.

  ## Stopping rules

  Two rule shapes are accepted, and the choice is frozen with the rest of the
  plan:

    * `%{"minimum_pairs" => n, "confidence" => c}` — the fixed-n rule. The
      decision reads a normal-approximation interval once `n` paired holdout
      outcomes exist. This is the default path; its wire shape is pinned by
      the golden fixtures and does not change.
    * `%{"kind" => "e_process", "alpha" => a, "minimum_pairs" => n,
      "range" => [lo, hi]}` with an optional `"lambda"` — an anytime-valid
      rule. The decision runs paired Hoeffding test supermartingales over the
      holdout differences and may stop the moment either reaches `1 / a`, or
      keep sampling, without inflating the false-commit rate.

  The second shape exists because "keep it if it scored higher" on a small
  validation set is uncontrolled adaptive multiple testing: every peek is
  another chance to commit noise, and PACE (arXiv 2606.08106) measured greedy
  acceptance committing 13–21 spurious edits per run. A fixed-n interval is
  honest only if nobody looks early; an e-process is honest under optional
  stopping, which is how a confirmation lane actually gets used.

  `range` is declared by the author rather than inferred so continuous metrics
  are bounded honestly: the supermartingale is only valid for differences
  inside `[lo, hi]`, and `Lemieux.Experiment.Decision` refuses evidence that
  falls outside it. A binary metric produces differences in `[-1, 1]`, so an
  `e_process` rule on a binary metric must declare exactly that range; a
  narrower one would void the guarantee and a wider one would waste it.
  `lambda`, when given, must satisfy `lambda * (hi - lo) <= 1` so the bet can
  never exceed the range it is placed on.
  """

  alias Lemieux.Contract
  alias Lemieux.ID

  @version 1
  @required ~w(hypothesis variant control metric sample stopping_rule budget)

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          sha256: String.t(),
          created_at: DateTime.t(),
          hypothesis: String.t(),
          variant: map(),
          control: map(),
          metric: map(),
          sample: map(),
          stopping_rule: map(),
          budget: map(),
          provenance: map()
        }

  @enforce_keys [
    :id,
    :sha256,
    :created_at,
    :hypothesis,
    :variant,
    :control,
    :metric,
    :sample,
    :stopping_rule,
    :budget,
    :provenance
  ]
  defstruct schema_version: @version,
            id: nil,
            sha256: nil,
            created_at: nil,
            hypothesis: nil,
            variant: nil,
            control: nil,
            metric: nil,
            sample: nil,
            stopping_rule: nil,
            budget: nil,
            provenance: %{}

  @doc "Validates and freezes an experiment plan."
  @spec new(attrs :: map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- required(attrs),
         :ok <- hypothesis(attrs["hypothesis"]),
         :ok <- variant(attrs["variant"]),
         :ok <- control(attrs["control"], attrs["variant"]),
         :ok <- metric(attrs["metric"]),
         :ok <- sample(attrs["sample"]),
         :ok <- stopping_rule(attrs["stopping_rule"], attrs["metric"]),
         :ok <- budget(attrs["budget"]),
         :ok <- provenance(Map.get(attrs, "provenance", %{})),
         {:ok, created_at} <- parse_time(Map.get(attrs, "created_at")) do
      plan =
        %__MODULE__{
          id: Map.get(attrs, "id", "experiment_" <> ID.generate()),
          sha256: "",
          created_at: created_at,
          hypothesis: attrs["hypothesis"],
          variant: attrs["variant"],
          control: attrs["control"],
          metric: attrs["metric"],
          sample: attrs["sample"],
          stopping_rule: attrs["stopping_rule"],
          budget: attrs["budget"],
          provenance: Map.get(attrs, "provenance", %{})
        }

      sha256 = plan |> to_map() |> Map.delete("sha256") |> Contract.digest()

      if Map.get(attrs, "sha256", sha256) == sha256,
        do: {:ok, %{plan | sha256: sha256}},
        else: {:error, :digest_mismatch}
    end
  end

  def new(_attrs), do: {:error, :invalid_plan}

  @doc "Encodes a plan for durable preregistration."
  @spec encode!(plan :: t()) :: String.t()
  def encode!(%__MODULE__{} = plan), do: plan |> to_map() |> JSON.encode!()

  @doc "Decodes and revalidates a preregistered plan."
  @spec decode!(json :: String.t()) :: t()
  def decode!(json) when is_binary(json) do
    case JSON.decode!(json) do
      %{"schema_version" => @version} = map ->
        case new(Map.delete(map, "schema_version")) do
          {:ok, plan} -> plan
          {:error, reason} -> raise ArgumentError, "invalid experiment plan: #{inspect(reason)}"
        end

      %{"schema_version" => version} ->
        raise ArgumentError, "unsupported experiment plan version #{inspect(version)}"

      _map ->
        raise ArgumentError, "experiment plan is missing its schema version"
    end
  end

  @doc "Decodes and verifies a preregistered plan without raising."
  @spec decode(json :: String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- Contract.decode(json),
         :ok <- Contract.verify_version(map, "schema_version", @version),
         :ok <- verify(map) do
      new(Map.delete(map, "schema_version"))
    end
  end

  @doc "Verifies the current schema and immutable plan digest."
  @spec verify(plan_or_map :: t() | map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = plan), do: plan |> to_map() |> verify()

  def verify(map) when is_map(map) do
    with :ok <- Contract.verify_version(map, "schema_version", @version) do
      Contract.verify_digest(map, "sha256")
    end
  end

  def verify(_other), do: {:error, :invalid_plan}

  @doc "Returns the JSON-shaped plan."
  @spec to_map(plan :: t()) :: map()
  def to_map(%__MODULE__{} = plan) do
    %{
      "schema_version" => plan.schema_version,
      "id" => plan.id,
      "sha256" => plan.sha256,
      "created_at" => DateTime.to_iso8601(plan.created_at),
      "hypothesis" => plan.hypothesis,
      "variant" => plan.variant,
      "control" => plan.control,
      "metric" => plan.metric,
      "sample" => plan.sample,
      "stopping_rule" => plan.stopping_rule,
      "budget" => plan.budget,
      "provenance" => plan.provenance
    }
  end

  defp required(attrs) do
    case Enum.find(@required, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:missing_field, field}}
    end
  end

  defp hypothesis(value) when is_binary(value) and value != "", do: :ok
  defp hypothesis(_value), do: {:error, :invalid_hypothesis}

  defp variant(%{"digest" => digest, "changes" => [_change]})
       when is_binary(digest) and digest != "",
       do: :ok

  defp variant(%{"changes" => changes}) when is_list(changes) and length(changes) > 1,
    do: {:error, :multi_factor_variant}

  defp variant(_variant), do: {:error, :invalid_variant}

  defp control(%{"digest" => digest}, %{"digest" => variant_digest})
       when is_binary(digest) and digest != "" and digest != variant_digest,
       do: :ok

  defp control(_control, _variant), do: {:error, :invalid_control}

  defp metric(%{"kind" => kind, "minimum_effect" => effect})
       when kind in ["binary", "continuous"] and is_number(effect),
       do: :ok

  defp metric(_metric), do: {:error, :invalid_metric}

  defp sample(%{
         "development_case_ids" => development,
         "holdout_case_ids" => holdout
       })
       when is_list(development) and development != [] and is_list(holdout) and holdout != [] do
    cond do
      not Enum.all?(development ++ holdout, &(is_binary(&1) and &1 != "")) ->
        {:error, :invalid_sample_case_ids}

      not MapSet.disjoint?(MapSet.new(development), MapSet.new(holdout)) ->
        {:error, :overlapping_corpus_splits}

      true ->
        :ok
    end
  end

  defp sample(_sample), do: {:error, :invalid_sample}

  # Dispatch on "kind" first: an e_process rule that also happens to carry a
  # "confidence" key must be validated as an e_process rule, not accepted as
  # the fixed-n shape and then crash the decision when it looks for "alpha".
  defp stopping_rule(%{"kind" => "e_process"} = rule, metric) do
    with :ok <- alpha(rule["alpha"]),
         :ok <- minimum_pairs(rule["minimum_pairs"]),
         {:ok, width} <- range(rule["range"], metric) do
      lambda(Map.get(rule, "lambda"), width)
    end
  end

  defp stopping_rule(%{"kind" => _kind}, _metric), do: {:error, {:invalid_stopping_rule, :kind}}

  defp stopping_rule(%{"minimum_pairs" => pairs, "confidence" => confidence}, _metric)
       when is_integer(pairs) and pairs > 0 and is_number(confidence) and confidence > 0 and
              confidence < 1,
       do: :ok

  defp stopping_rule(_rule, _metric), do: {:error, :invalid_stopping_rule}

  defp alpha(value) when is_number(value) and value > 0 and value < 1, do: :ok
  defp alpha(_value), do: {:error, {:invalid_stopping_rule, :alpha}}

  defp minimum_pairs(value) when is_integer(value) and value > 0, do: :ok
  defp minimum_pairs(_value), do: {:error, {:invalid_stopping_rule, :minimum_pairs}}

  defp range([low, high], %{"kind" => "binary"})
       when is_number(low) and is_number(high) and low < high do
    if low == -1 and high == 1,
      do: {:ok, high - low},
      else: {:error, {:invalid_stopping_rule, :binary_range}}
  end

  defp range([low, high], _metric) when is_number(low) and is_number(high) and low < high,
    do: {:ok, high - low}

  defp range(_value, _metric), do: {:error, {:invalid_stopping_rule, :range}}

  defp lambda(nil, _width), do: :ok
  defp lambda(value, width) when is_number(value) and value > 0 and value * width <= 1, do: :ok
  defp lambda(_value, _width), do: {:error, {:invalid_stopping_rule, :lambda}}

  defp budget(%{"usage_mode" => "quota", "maximum_requests" => maximum} = budget)
       when is_integer(maximum) and maximum > 0 do
    if budget["maximum_cost_usd"] == nil, do: :ok, else: {:error, :invalid_budget}
  end

  defp budget(%{"usage_mode" => "quota"}), do: {:error, :invalid_budget}

  defp budget(%{"maximum_cost_usd" => maximum}) when is_number(maximum) and maximum >= 0,
    do: :ok

  defp budget(_budget), do: {:error, :invalid_budget}

  defp provenance(value) when is_map(value), do: :ok
  defp provenance(_value), do: {:error, :invalid_provenance}

  defp parse_time(nil), do: {:ok, DateTime.utc_now()}

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> {:ok, time}
      _invalid -> {:error, :invalid_created_at}
    end
  end

  defp parse_time(_value), do: {:error, :invalid_created_at}
end
