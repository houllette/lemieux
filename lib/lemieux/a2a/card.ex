defmodule Lemieux.A2A.Card do
  @moduledoc """
  A2A 1.0 Agent Cards. Public cards omit filesystem paths, model routes and
  credentials. HTTP interfaces use supportedInterfaces and protocolVersion;
  distribution uses a custom binding URI and requires a trusted BEAM domain.
  """

  alias Lemieux.A2A.Message
  alias Lemieux.A2A.Skill

  @bindings %{"urn:lemieux:a2a:distribution" => :distribution, "JSONRPC" => :jsonrpc}

  @typedoc """
  How to reach an agent: the binding, and the address under it.

  `{:distribution, :"myapp@host"}` is a node. An HTTP binding would be
  `{:jsonrpc, "https://..."}`.
  """
  @type interface :: {atom(), term()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          version: String.t(),
          skills: [Skill.t()],
          interfaces: [interface()],
          capabilities: %{optional(atom()) => boolean()},
          metadata: map(),
          security_schemes: map(),
          security_requirements: [map()],
          input_modes: [String.t()],
          output_modes: [String.t()]
        }

  defstruct [
    :id,
    :name,
    :description,
    version: "1.0",
    skills: [],
    interfaces: [],
    capabilities: %{streaming: true, push_notifications: false},
    metadata: %{},
    security_schemes: %{},
    security_requirements: [],
    input_modes: ["text/plain", "application/json"],
    output_modes: ["text/plain"]
  ]

  @doc """
  The card for a running session, describing what it will answer.

  Built from the session rather than configured, so that a card cannot
  advertise a skill the session would refuse — the list is derived from the
  same tools the answer will actually be given.
  """
  @spec for_session(snapshot :: map(), opts :: keyword()) :: t()
  def for_session(snapshot, opts \\ []) do
    %__MODULE__{
      id: snapshot.id,
      name: Keyword.get(opts, :name) || "lmx #{snapshot.id}",
      description: Keyword.get(opts, :description) || "Read-only repository questions",
      skills: Keyword.get_lazy(opts, :skills, fn -> Skill.from_tools(snapshot) end),
      interfaces: Keyword.get(opts, :interfaces, [{:distribution, node()}]),
      metadata: %{},
      security_schemes: Keyword.get(opts, :security_schemes, %{}),
      security_requirements: Keyword.get(opts, :security_requirements, [])
    }
  end

  @doc """
  The card as JSON, in the protocol's shape.

  `interfaces` becomes a list of objects rather than the tuples used inside,
  because a tuple is an Erlang idea and the wire has never heard of one.
  """
  @spec to_json(card :: t()) :: map()
  def to_json(%__MODULE__{} = card) do
    %{
      "name" => card.name,
      "description" => card.description || "Read-only repository questions",
      "defaultInputModes" => card.input_modes,
      "defaultOutputModes" => card.output_modes,
      "version" => card.version,
      "capabilities" => Map.new(card.capabilities, fn {key, value} -> {camel(key), value} end),
      "skills" => Enum.map(card.skills, &Skill.to_json/1),
      "supportedInterfaces" =>
        Enum.map(card.interfaces, fn {binding, address} ->
          %{
            "protocolBinding" => binding_name(binding),
            "protocolVersion" => "1.0",
            "url" => to_string(address)
          }
        end),
      "securitySchemes" => card.security_schemes,
      "securityRequirements" => card.security_requirements
    }
  end

  @doc """
  A card a peer published.
  """
  @spec from_json(json :: map()) :: {:ok, t()} | {:error, String.t()}
  def from_json(%{"name" => name} = json) when is_binary(name) do
    with true <- valid_fields?(json),
         {:ok, interfaces} <- interfaces(Map.get(json, "supportedInterfaces", [])),
         {:ok, capabilities} <- capabilities(Map.get(json, "capabilities", %{})) do
      {:ok,
       %__MODULE__{
         id: json["id"],
         name: name,
         description: json["description"],
         version: Map.get(json, "version", "1.0"),
         skills: json |> Map.get("skills", []) |> Enum.map(&Skill.from_json/1),
         interfaces: interfaces,
         capabilities: capabilities,
         metadata: Map.get(json, "metadata", %{}),
         security_schemes: Map.get(json, "securitySchemes", %{}),
         security_requirements: Map.get(json, "securityRequirements", []),
         input_modes: json["defaultInputModes"],
         output_modes: json["defaultOutputModes"]
       }}
    else
      false -> {:error, "invalid agent card fields"}
      {:error, reason} -> {:error, reason}
    end
  end

  def from_json(_json), do: {:error, "the peer sent something that is not an agent card"}

  defp interfaces(interfaces) when is_list(interfaces) do
    interfaces
    |> Enum.reduce_while({:ok, []}, fn interface, {:ok, parsed} ->
      case interface(interface) do
        {:ok, value} -> {:cont, {:ok, [value | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp interfaces(_interfaces),
    do: {:error, "the peer sent an agent card with invalid interfaces"}

  defp interface(%{
         "protocolBinding" => transport,
         "protocolVersion" => version,
         "url" => address
       })
       when is_binary(transport) and is_binary(version) and is_binary(address) do
    # Transport names cross an untrusted JSON boundary. Converting an unknown
    # name with String.to_atom/1 would permanently consume one VM atom per
    # novel value, so only bindings this build can actually use become atoms.
    case {version, Map.fetch(@bindings, transport)} do
      {"1.0", {:ok, binding}} -> {:ok, {binding, address}}
      _ -> {:ok, {:unsupported, address}}
    end
  end

  defp interface(_interface),
    do: {:error, "the peer sent an agent-card interface without a transport and URL"}

  defp capabilities(capabilities) when is_map(capabilities) do
    streaming = Map.get(capabilities, "streaming", false)
    push_notifications = Map.get(capabilities, "pushNotifications", false)

    if is_boolean(streaming) and is_boolean(push_notifications) do
      {:ok, %{streaming: streaming, push_notifications: push_notifications}}
    else
      {:error, "the peer sent invalid agent-card capabilities"}
    end
  end

  defp capabilities(_capabilities),
    do: {:error, "the peer sent invalid agent-card capabilities"}

  defp valid_fields?(json) do
    required = [
      {"description", &is_binary/1},
      {"version", &is_binary/1},
      {"skills", &skills?/1},
      {"supportedInterfaces", &nonempty_list?/1},
      {"defaultInputModes", &Message.strings?/1},
      {"defaultOutputModes", &Message.strings?/1}
    ]

    Enum.all?(required, fn {key, predicate} ->
      Map.has_key?(json, key) and predicate.(json[key])
    end) and
      Message.fields?(json, [
        {"metadata", &is_map/1},
        {"securitySchemes", &is_map/1},
        {"securityRequirements", &maps?/1}
      ])
  end

  defp skills?(skills) when is_list(skills), do: Enum.all?(skills, &skill?/1)
  defp skills?(_skills), do: false

  defp skill?(%{"id" => id, "name" => name, "description" => desc, "tags" => tags}),
    do: is_binary(id) and is_binary(name) and is_binary(desc) and Message.strings?(tags)

  defp skill?(_skill), do: false
  defp maps?(values) when is_list(values), do: Enum.all?(values, &is_map/1)
  defp maps?(_values), do: false
  defp nonempty_list?(value), do: is_list(value) and value != []

  defp binding_name(:jsonrpc), do: "JSONRPC"
  defp binding_name(:distribution), do: "urn:lemieux:a2a:distribution"
  defp binding_name(binding), do: to_string(binding)

  defp camel(:push_notifications), do: "pushNotifications"
  defp camel(key), do: Atom.to_string(key)

  @doc """
  Whether this agent offers `binding`, and at what address.
  """
  @spec reachable(card :: t(), binding :: atom()) :: {:ok, term()} | :error
  def reachable(%__MODULE__{interfaces: interfaces}, binding) do
    case List.keyfind(interfaces, binding, 0) do
      {^binding, address} -> {:ok, address}
      nil -> :error
    end
  end
end
