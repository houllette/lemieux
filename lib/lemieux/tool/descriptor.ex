defmodule Lemieux.Tool.Descriptor do
  @moduledoc """
  The versioned contract separated from a tool's executor.

  A descriptor is immutable and session-local. It carries stable identity,
  provenance, interface, effect, policy, runtime and lifecycle metadata while
  `executor` remains the module or configured struct that actually runs. The
  executor is deliberately omitted from `to_map/1`: it may contain functions,
  pids or credentials and is host-owned executable state, not transcript data.

  Existing `Lemieux.Tool` modules are wrapped automatically with conservative
  defaults. Hosts that need a governed capability construct a descriptor and
  override only the facts they can substantiate:

      Descriptor.new(MyApp.Tickets,
        identity: %{"namespace" => "acme", "contract_version" => "1"},
        origin: %{"type" => "hex", "package" => "acme_tickets", "version" => "2.1.0"},
        effects: %{"class" => "read", "resource_types" => ["ticket"]},
        runtime: %{
          "timeout_ms" => 5_000,
          "concurrency" => %{"class" => "resource", "resource_key" => "tickets"}
        }
      )

  The descriptor is internal request/audit truth. The model-facing wire stays
  the familiar name, description and input schema.

  ## A deadline only when one is declared

  `runtime.timeout_ms` is present only when the tool (or the host describing
  it) declares one; `timeout_ms/2` otherwise answers the host's session-wide
  maximum. It used to default to two minutes, which the host's maximum could
  lower but never raise — so a `write` parked behind a person's approval, or
  an MCP call that honestly needed five minutes, was cut off at two however
  long the host had said tools may take. A tool that knows its own bound
  (`bash`, `ask_user`) still declares it.
  """

  alias Lemieux.MCP.RemoteTool
  alias Lemieux.Tool

  @version 1
  @default_output_bytes 30_000

  @typedoc "A version-one descriptor plus its non-serializable executor."
  @type t :: %__MODULE__{
          executor: Tool.t(),
          identity: map(),
          origin: map(),
          interface: map(),
          effects: map(),
          policy: map(),
          runtime: map(),
          lifecycle: map(),
          digest: String.t()
        }

  @enforce_keys [
    :executor,
    :identity,
    :origin,
    :interface,
    :effects,
    :policy,
    :runtime,
    :lifecycle,
    :digest
  ]
  defstruct @enforce_keys

  @doc "Wraps an executor in descriptor v1, applying declared host metadata."
  @spec new(executor :: Tool.t(), opts :: keyword() | map()) :: t()
  def new(executor, opts \\ [])
  def new(%__MODULE__{} = descriptor, opts) when opts == [] or opts == %{}, do: descriptor

  def new(%__MODULE__{} = descriptor, opts) when is_list(opts) or is_map(opts) do
    metadata =
      descriptor
      |> to_map()
      |> Map.take(~w(identity origin interface effects policy runtime lifecycle))

    new(descriptor.executor, deep_merge(metadata, normalize(opts)))
  end

  def new(executor, opts) when is_list(opts) or is_map(opts) do
    name = Tool.name(executor)
    metadata = executor |> Tool.metadata() |> normalize()
    overrides = normalize(opts)
    origin = default_origin(executor)
    namespace = default_namespace(origin)

    base = %{
      "identity" => %{
        "name" => name,
        "namespace" => namespace,
        "canonical_name" => canonical(namespace, name),
        "contract_version" => "1",
        "implementation_digest" => implementation_digest(executor),
        "aliases" => []
      },
      "origin" => origin,
      "interface" => %{
        "description" => Tool.description(executor),
        "input_schema" => Tool.schema(executor),
        "output_schema" => nil,
        "content_types" => ["text/plain"]
      },
      "effects" => %{
        "class" => if(Tool.read_only?(executor), do: "read", else: "unknown"),
        "resource_types" => [],
        "resource_scopes" => [],
        "external_cost" => "unknown",
        "idempotent" => false,
        "retryable" => false,
        "dry_run" => false,
        "undo" => false
      },
      "policy" => %{
        "availability" => "host",
        "approval" => "policy",
        "requires_human_channel" => false,
        "default_off_shared" => false
      },
      "runtime" => %{
        "max_output_bytes" => @default_output_bytes,
        "concurrency" => default_concurrency(executor),
        "cancellation" => "kill_task"
      },
      "lifecycle" => %{
        "compatibility" => "descriptor-v1",
        "resume" => "host_rebind",
        "deprecated" => false
      }
    }

    fields = base |> deep_merge(metadata) |> deep_merge(overrides) |> canonicalize_identity(name)
    digest = fields |> Map.put("descriptor_version", @version) |> JSON.encode!() |> digest()

    descriptor = %__MODULE__{
      executor: executor,
      identity: fields["identity"],
      origin: fields["origin"],
      interface: fields["interface"],
      effects: fields["effects"],
      policy: fields["policy"],
      runtime: fields["runtime"],
      lifecycle: fields["lifecycle"],
      digest: digest
    }

    case validate(descriptor) do
      :ok -> descriptor
      {:error, reason} -> raise ArgumentError, "invalid tool descriptor: #{inspect(reason)}"
    end
  end

  @doc "Validates a descriptor independently of its executor callback shape."
  @spec validate(descriptor :: t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = descriptor) do
    snapshot = to_map(descriptor)

    with %{"name" => name, "namespace" => namespace, "canonical_name" => canonical_name} <-
           descriptor.identity,
         true <- nonempty?(name) and nonempty?(namespace),
         true <- canonical_name == canonical(namespace, name),
         %{"description" => description, "input_schema" => %{"type" => "object"}} <-
           descriptor.interface,
         true <- nonempty?(description),
         true <- json_safe?(snapshot),
         true <- valid_runtime?(descriptor.runtime) do
      :ok
    else
      _invalid -> {:error, :invalid_metadata}
    end
  end

  @doc "Returns the complete JSON descriptor, excluding executable state."
  @spec to_map(descriptor :: t()) :: map()
  def to_map(%__MODULE__{} = descriptor) do
    %{
      "descriptor_version" => @version,
      "identity" => descriptor.identity,
      "origin" => descriptor.origin,
      "interface" => descriptor.interface,
      "effects" => descriptor.effects,
      "policy" => descriptor.policy,
      "runtime" => descriptor.runtime,
      "lifecycle" => descriptor.lifecycle,
      "digest" => descriptor.digest
    }
  end

  @doc """
  Applies the descriptor deadline under the host's session-wide maximum.

  A descriptor that declares no deadline gets the host's maximum.
  """
  @spec timeout_ms(descriptor :: t(), host_max :: pos_integer()) :: pos_integer()
  def timeout_ms(%__MODULE__{runtime: runtime}, host_max)
      when is_integer(host_max) and host_max > 0 do
    case Map.get(runtime, "timeout_ms") do
      nil -> host_max
      declared -> min(declared, host_max)
    end
  end

  @doc """
  What the descriptor declares about asking a person before the tool runs.

  `policy.approval` `"never"` is `:never`, `"always"` is `:always`, and
  anything else — the default `"policy"` included — is `:policy`: the host's
  permission layer decides. Nothing in the library enforces it.
  """
  @spec approval(descriptor :: t()) :: :never | :always | :policy
  def approval(%__MODULE__{policy: %{"approval" => "never"}}), do: :never
  def approval(%__MODULE__{policy: %{"approval" => "always"}}), do: :always
  def approval(%__MODULE__{}), do: :policy

  @doc "Applies the descriptor output budget under the host's session-wide maximum."
  @spec output_limit(descriptor :: t(), host_max :: pos_integer()) :: pos_integer()
  def output_limit(%__MODULE__{} = descriptor, host_max)
      when is_integer(host_max) and host_max > 0 do
    min(descriptor.runtime["max_output_bytes"], host_max)
  end

  @doc "Returns a declared maximum external charge, zero, or nil when it is unknown."
  @spec external_cost_max_usd(descriptor :: t()) :: number() | nil
  def external_cost_max_usd(%__MODULE__{effects: effects}) do
    case effects do
      %{"external_cost" => %{"maximum_usd" => cost}}
      when is_number(cost) and cost >= 0 ->
        cost

      %{"class" => "external"} ->
        nil

      _not_externally_billed ->
        0.0
    end
  end

  @doc """
  Whether a lost result must be reported as an unknown outcome.

  A tool answers yes when its effects live somewhere the harness cannot
  look: a declared `"class" => "external"`, an explicit
  `"receipt" => true`, or an MCP origin — a server's tool is remote by
  definition, and its `readOnlyHint` is a claim that costs nothing to make,
  so it is not believed in the direction that would have a model repeat a
  side effect. `"idempotent" => true` or `"receipt" => false` answers no
  either way: a host that knows its tool is safe to repeat says so here.
  `Lemieux.Tool.Receipt` is what the answer changes.
  """
  @spec receipt?(descriptor :: t()) :: boolean()
  def receipt?(%__MODULE__{effects: effects, origin: origin}) do
    cond do
      effects["idempotent"] == true -> false
      effects["receipt"] == false -> false
      effects["receipt"] == true -> true
      effects["class"] == "external" -> true
      origin["type"] == "mcp" -> true
      true -> false
    end
  end

  @doc "Returns the scheduler contract for this tool."
  @spec concurrency(descriptor :: t()) :: :parallel | :exclusive | {:resource, String.t()}
  def concurrency(%__MODULE__{runtime: %{"concurrency" => %{"class" => "parallel"}}}),
    do: :parallel

  def concurrency(%__MODULE__{
        runtime: %{
          "concurrency" => %{"class" => "resource", "resource_key" => resource_key}
        }
      })
      when is_binary(resource_key) and resource_key != "",
      do: {:resource, resource_key}

  def concurrency(%__MODULE__{}), do: :exclusive

  defp canonicalize_identity(fields, name) do
    identity = fields["identity"]
    namespace = identity["namespace"]

    identity =
      identity
      |> Map.put("name", name)
      |> Map.put("canonical_name", canonical(namespace, name))

    Map.put(fields, "identity", identity)
  end

  defp default_origin(%RemoteTool{} = tool) do
    %{}
    |> Map.put("type", "mcp")
    |> Map.put("server", tool.server)
    |> put_present("protocol_version", Map.get(tool, :protocol_version))
    |> put_present("server_info", Map.get(tool, :server_info))
  end

  defp default_origin(%module{}) do
    %{"type" => "configured_instance", "module" => Atom.to_string(module)}
  end

  defp default_origin(module) when is_atom(module) do
    type = if built_in?(module), do: "built_in", else: "host_module"
    %{"type" => type, "module" => Atom.to_string(module)}
  end

  defp default_namespace(%{"type" => "built_in"}), do: "lemieux"
  defp default_namespace(%{"type" => "mcp", "server" => server}), do: "mcp.#{server}"
  defp default_namespace(_origin), do: "host"

  # Only a bare module reaches here: a configured struct is a
  # `configured_instance` whatever module defines it, which is why no
  # struct-backed tool needs naming as an exception.
  defp built_in?(module), do: String.starts_with?(Atom.to_string(module), "Elixir.Lemieux.Tools.")

  defp default_concurrency(executor) do
    if Tool.parallel_safe?(executor),
      do: %{"class" => "parallel"},
      else: %{"class" => "exclusive"}
  end

  defp implementation_digest(%RemoteTool{} = tool) do
    %{
      "server" => tool.server,
      "name" => tool.name,
      "description" => tool.description,
      "schema" => tool.schema,
      "output_schema" => Map.get(tool, :output_schema),
      "annotations" => Map.get(tool, :annotations),
      "meta" => Map.get(tool, :meta)
    }
    |> JSON.encode!()
    |> digest()
  end

  defp implementation_digest(%module{}), do: module_digest(module)
  defp implementation_digest(module) when is_atom(module), do: module_digest(module)

  defp module_digest(module) do
    if Code.ensure_loaded?(module) do
      digest(module.module_info(:md5))
    else
      digest(Atom.to_string(module))
    end
  end

  defp valid_runtime?(%{"max_output_bytes" => output, "concurrency" => concurrency} = runtime) do
    valid_timeout?(Map.get(runtime, "timeout_ms")) and is_integer(output) and output > 0 and
      valid_concurrency?(concurrency)
  end

  defp valid_runtime?(_runtime), do: false

  defp valid_timeout?(nil), do: true
  defp valid_timeout?(timeout), do: is_integer(timeout) and timeout > 0

  defp valid_concurrency?(%{"class" => class}) when class in ["parallel", "exclusive"],
    do: true

  defp valid_concurrency?(%{"class" => "resource", "resource_key" => key}),
    do: nonempty?(key)

  defp valid_concurrency?(_concurrency), do: false

  defp canonical(namespace, name), do: namespace <> "/" <> name

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

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value),
        do: deep_merge(left_value, right_value),
        else: right_value
    end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp nonempty?(value), do: is_binary(value) and value != ""

  defp json_safe?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)

  defp json_safe?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_safe?(nested) end)
  end

  defp json_safe?(_value), do: false

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
