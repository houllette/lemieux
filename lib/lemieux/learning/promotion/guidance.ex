defmodule Lemieux.Learning.Promotion.Guidance do
  @moduledoc false
  alias Lemieux.Contract
  alias Lemieux.Extension.Profile
  alias Lemieux.Harness
  alias Lemieux.Learning.Discovery.Surface
  alias Lemieux.Learning.Overlay
  alias Lemieux.Learning.Promotion.Policy
  alias Lemieux.Learning.Refinement
  alias Lemieux.Learning.Refinement.Evidence
  alias Lemieux.Learning.Refinement.Support
  alias Lemieux.Tool
  alias Lemieux.Tools

  @spec authorized?(grant :: map(), context :: map()) :: boolean()
  def authorized?(%{"description_tools" => []}, _context), do: true

  def authorized?(%{"description_tools" => names}, context) when is_list(names) do
    allowed = context[:description_tools] || []

    context.policy["trust"] == "personal" and is_list(allowed) and
      Enum.all?(names, &(&1 in allowed))
  end

  def authorized?(_grant, _context), do: false

  @spec prepare(request :: map(), context :: map(), base :: Harness.t()) ::
          {:ok, Overlay.t(), map() | nil} | {:error, term()}
  def prepare(request, context, base) do
    receipt = request.refinement
    profile = receipt["selected_profile"]

    with :ok <- Refinement.verify(receipt),
         true <- receipt["sha256"] in context.refinements,
         true <- receipt["decision"] == "proposed",
         true <- receipt["bindings"] == context.bindings,
         true <- receipt["source_runtime"]["sha256"] == context.runtime_sha256,
         :ok <- Profile.validate(request.baseline),
         :ok <- Profile.validate(profile),
         true <- Contract.digest(request.baseline) == receipt["original_profile_sha256"],
         true <- Contract.digest(profile) == receipt["selected_sha256"],
         true <- supported?(request, context),
         {:ok, suffix, descriptions} <- delta(request.baseline, profile),
         :ok <- trust(descriptions, context, base),
         {:ok, confirmation} <- confirmation(request, context),
         {:ok, overlay} <- overlay(suffix, descriptions, receipt, confirmation),
         true <- byte_size(Overlay.encode!(overlay)) <= context.policy["maximum_bytes"] do
      {:ok, overlay, confirmation}
    else
      _refused -> {:error, :guidance_not_eligible}
    end
  rescue
    _invalid -> {:error, :guidance_not_eligible}
  end

  defp supported?(
         %{
           mode: :task_local,
           refinement: %{"qualification" => "experimental_task_local"} = receipt
         },
         context
       ) do
    policy = receipt["support_policy"]

    Policy.authorize(context, "experimental_task_local") == :ok and
      Support.experimental?(policy) and
      Support.supported?(receipt["control"] || [], receipt["composition"] || [], true, policy)
  end

  defp supported?(%{refinement: receipt}, _context) do
    control = receipt["control"] || []
    composed = receipt["composition"] || []

    receipt["qualification"] in ~w(behavioral_unconfirmed task_local_verified) and
      Map.get(receipt, "support_policy", Support.strict()) == Support.strict() and
      length(control) >= 2 and
      Evidence.supported?(control, composed, receipt["qualification"] == "task_local_verified")
  end

  defp delta(baseline, profile) do
    paths = Surface.changed_paths(baseline, profile)
    original = baseline["options"]["system"]
    changed = profile["options"]["system"]

    with true <- paths != [] and Enum.all?(paths, &allowed?/1),
         true <-
           is_binary(original) and is_binary(changed) and String.starts_with?(changed, original) do
      suffix = binary_part(changed, byte_size(original), byte_size(changed) - byte_size(original))
      descriptions = profile["options"]["tool_descriptions"] || %{}
      prior = baseline["options"]["tool_descriptions"] || %{}
      # Removing a personal override would expose a different trusted description.
      true = Enum.all?(Map.keys(prior), &Map.has_key?(descriptions, &1))
      {:ok, suffix, Map.reject(descriptions, fn {name, text} -> prior[name] == text end)}
    else
      _refused -> {:error, :review_required}
    end
  end

  defp allowed?("options.system"), do: true
  defp allowed?("options.tool_descriptions"), do: true
  defp allowed?(path), do: String.starts_with?(path, "options.tool_descriptions.")

  defp trust(descriptions, context, base) do
    enabled =
      Harness.explain(base)["tools"] |> Enum.filter(& &1["enabled"]) |> MapSet.new(& &1["name"])

    local = MapSet.new(base.tools || Tools.default(), &Tool.name/1)
    allowed = MapSet.new(context[:description_tools] || [])

    if map_size(descriptions) == 0 or
         (context.policy["trust"] == "personal" and
            Enum.all?(
              Map.keys(descriptions),
              &(MapSet.member?(enabled, &1) and MapSet.member?(local, &1) and
                  MapSet.member?(allowed, &1))
            )), do: :ok, else: {:error, :trusted_description_required}
  end

  defp confirmation(%{mode: :task_local}, _context), do: {:ok, nil}

  defp confirmation(%{mode: :canary, confirmation: confirmation} = request, context) do
    with :ok <- Contract.verify_digest(confirmation, "sha256"),
         true <- confirmation["sha256"] in context.confirmations,
         true <-
           confirmation["kind"] == "independent_confirmation" and
             confirmation["verdict"] == "pass",
         true <- confirmation["content_sha256"] == request.refinement["selected_sha256"],
         true <-
           confirmation["scope"] == context.scope and
             confirmation["runtime_sha256"] == context.runtime_sha256,
         digest when is_binary(digest) and byte_size(digest) == 64 <-
           confirmation["evidence_sha256"],
         {:ok, issued, 0} <- DateTime.from_iso8601(confirmation["issued_at"]),
         {:ok, expires, 0} <- DateTime.from_iso8601(confirmation["expires_at"]),
         true <-
           DateTime.compare(issued, context.now) != :gt and
             DateTime.compare(context.now, expires) == :lt do
      {:ok, confirmation}
    else
      _refused -> {:error, :independent_confirmation_required}
    end
  end

  defp confirmation(_request, _context), do: {:error, :independent_confirmation_required}

  defp overlay(suffix, descriptions, receipt, confirmation) do
    base = %{
      "schema_version" => 1,
      "system_suffix" => suffix,
      "tool_descriptions" => descriptions,
      "provenance" => %{
        "refinement_sha256" => receipt["sha256"],
        "content_sha256" => receipt["selected_sha256"],
        "confirmation" => confirmation
      },
      "qualification" => if(confirmation, do: "confirmed", else: "unconfirmed")
    }

    Overlay.from_map(Map.put(base, "sha256", Contract.digest(base)))
  end

  @spec apply(base :: Harness.t(), overlay :: Overlay.t()) :: Harness.t()
  def apply(base, overlay) do
    harness =
      if overlay.system_suffix in [nil, ""],
        do: base,
        else: Harness.update_system(base, &Overlay.apply_system(overlay, &1 || ""))

    if overlay.tool_descriptions == %{},
      do: harness,
      else: Harness.update_tools(harness, &Overlay.apply_tools(overlay, &1))
  end
end
