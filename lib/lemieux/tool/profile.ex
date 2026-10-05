defmodule Lemieux.Tool.Profile do
  @moduledoc """
  Host authorization narrowed to one session-local tool catalog.

  Lemieux has no tenant database and does not invent one. An embedding host
  resolves tenant policy and passes a JSON-shaped profile containing the
  allowed tool identities plus audit evidence about who enabled it. The
  profile is snapshotted in every request, but it is not restored as authority:
  a resumed session must be authorized again by its current host.

  Shared profiles treat tools declaring `default_off_shared` as denied unless
  the allowlist names them explicitly. That makes `elixir` default-off in a
  multi-tenant deployment without changing the explicit standalone profile.
  """

  alias Lemieux.Tool

  @typedoc "A normalized host profile."
  @type t :: %__MODULE__{
          id: String.t(),
          allow: :all | MapSet.t(String.t()),
          shared?: boolean(),
          human_channel?: boolean(),
          enabled_by: map() | nil
        }

  defstruct id: "legacy",
            allow: :all,
            shared?: false,
            human_channel?: true,
            enabled_by: nil

  @doc "Normalizes a JSON map, keyword list or omitted legacy profile."
  @spec new(profile :: nil | map() | keyword() | t()) :: t()
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = profile), do: profile

  def new(profile) when is_map(profile) or is_list(profile) do
    profile = normalize(profile)
    shared? = Map.get(profile, "shared", false)

    %__MODULE__{
      id: Map.get(profile, "id", if(shared?, do: "shared", else: "host")),
      allow: allow(Map.get(profile, "allow", "all")),
      shared?: shared?,
      human_channel?: Map.get(profile, "human_channel", not shared?),
      enabled_by: Map.get(profile, "enabled_by")
    }
    |> validate!()
  end

  @typedoc "Why a profile refused a tool."
  @type denial :: :not_allowlisted | :default_off_shared | :no_human_channel

  @doc """
  Whether this host profile authorizes `tool`, and if not, why.

  A boolean is enough to filter a catalog and not enough to tell anybody what
  happened. The three refusals mean different things to whoever has to act on
  them: an allowlist that omits the tool is a host decision about that tool,
  `default_off_shared` is a host decision about sharing which the allowlist
  can override, and a missing human channel is a property of where the session
  runs rather than a policy at all. Reported as one boolean, all three arrive
  as "not authorized" and the reader has to guess which.
  """
  @spec decision(profile :: t(), tool :: Tool.t()) :: :allow | {:deny, denial()}
  def decision(%__MODULE__{} = profile, tool) do
    descriptor = Tool.descriptor(tool)
    name = descriptor.identity["name"]
    canonical = descriptor.identity["canonical_name"]

    cond do
      not allowlisted?(profile, name, canonical) -> {:deny, :not_allowlisted}
      shared_default?(profile, descriptor, name, canonical) -> {:deny, :default_off_shared}
      missing_human?(profile, descriptor) -> {:deny, :no_human_channel}
      true -> :allow
    end
  end

  defp allowlisted?(%__MODULE__{allow: :all}, _name, _canonical), do: true

  defp allowlisted?(%__MODULE__{allow: allow}, name, canonical),
    do: MapSet.member?(allow, name) or MapSet.member?(allow, canonical)

  defp shared_default?(profile, descriptor, name, canonical) do
    profile.shared? and descriptor.policy["default_off_shared"] == true and
      not explicitly_allowed?(profile, name, canonical)
  end

  defp missing_human?(profile, descriptor),
    do: descriptor.policy["requires_human_channel"] == true and not profile.human_channel?

  @doc "Whether this host profile authorizes `tool` for the session catalog."
  @spec allowed?(profile :: t(), tool :: Tool.t()) :: boolean()
  def allowed?(%__MODULE__{} = profile, tool), do: decision(profile, tool) == :allow

  @doc "Filters a catalog without changing tool order."
  @spec filter(profile :: t(), tools :: [Tool.t()]) :: [Tool.t()]
  def filter(%__MODULE__{} = profile, tools) when is_list(tools),
    do: Enum.filter(tools, &allowed?(profile, &1))

  @doc "Returns the JSON evidence stored with each request."
  @spec snapshot(profile :: t()) :: map()
  def snapshot(%__MODULE__{} = profile) do
    %{
      "id" => profile.id,
      "allow" => encoded_allow(profile.allow),
      "shared" => profile.shared?,
      "human_channel" => profile.human_channel?,
      "enabled_by" => profile.enabled_by
    }
  end

  defp explicitly_allowed?(%__MODULE__{allow: :all}, _name, _canonical), do: false

  defp explicitly_allowed?(%__MODULE__{allow: allow}, name, canonical),
    do: MapSet.member?(allow, name) or MapSet.member?(allow, canonical)

  defp allow("all"), do: :all
  defp allow(:all), do: :all
  defp allow(names) when is_list(names), do: MapSet.new(names, &to_string/1)

  defp allow(invalid),
    do:
      raise(
        ArgumentError,
        "tool profile allow must be \"all\" or a list, got: #{inspect(invalid)}"
      )

  defp validate!(%__MODULE__{} = profile) do
    valid_actor? = is_nil(profile.enabled_by) or json_safe?(profile.enabled_by)

    if is_binary(profile.id) and profile.id != "" and is_boolean(profile.shared?) and
         is_boolean(profile.human_channel?) and valid_actor? do
      profile
    else
      raise ArgumentError, "tool profile must have a non-empty id and JSON enabled_by evidence"
    end
  end

  defp encoded_allow(:all), do: "all"
  defp encoded_allow(allow), do: allow |> MapSet.to_list() |> Enum.sort()

  defp normalize(value) when is_list(value) do
    if Keyword.keyword?(value),
      do: value |> Map.new() |> normalize(),
      else: Enum.map(value, &normalize/1)
  end

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize(nested)} end)
  end

  defp normalize(value) when is_boolean(value) or is_nil(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value

  defp json_safe?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)

  defp json_safe?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_safe?(nested) end)
  end

  defp json_safe?(_value), do: false
end
