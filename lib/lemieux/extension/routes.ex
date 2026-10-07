defmodule Lemieux.Extension.Routes do
  @moduledoc """
  Model routes an extension offers the host that loaded it.

  A `Lemieux.Extension` shapes the harness, and the harness deliberately
  holds no provider: where a session's requests go is host authority, which
  is why no `c:Lemieux.Extension.apply/2` can redirect them. A route is still
  code somebody else wrote — a gateway's catalogue and destination, as
  `Lemieux.Provider.Route` defines them — and before this behaviour the only
  way to run one in the installed `lmx` was to build another binary around
  it. This is the other door: a module the host loaded, through the same
  explicit, trusted mechanism it loads extensions with, *offers* named routes
  from `c:routes/1`, and the host decides whether to register them, wraps
  each in its own `Lemieux.Providers.ReqLLM` with its own timeouts, and
  dispatches a session's requests to one by the model's provider name
  (`Lemieux.CLI.Routes`, `Lemieux.CLI.ProviderMux`). The harness never sees
  them, an extension never constructs a provider, and inference still goes
  through `req_llm`: a route owns destination and catalogue, not encoding.

  A module may implement this behaviour beside `Lemieux.Extension` or on
  its own: `Lemieux.CLI.Extensions` loads a module that exports either
  `apply/2` or `routes/1`, and applies the first to the harness while
  registering the second.

  ## Writing one

      defmodule MyApp.Relay do
        @behaviour Lemieux.Extension.Routes

        @impl true
        def routes(config: config) do
          case {config["endpoint"], System.get_env("RELAY_API_KEY")} do
            {nil, _key} -> {:error, "relay needs an \"endpoint\" option"}
            {_endpoint, nil} -> {:error, "RELAY_API_KEY is not set"}
            {endpoint, key} -> {:ok, [%{name: "relay", route: {MyApp.Relay.Route, MyApp.Relay.Route.new(endpoint, key)}}]}
          end
        end
      end

  `c:routes/1` receives the loader's options — `[config: map]`, the
  manifest's `options` with the person's `"extension_options"` merged over
  it, string keys and all — and builds route state without I/O: discovery
  belongs in `c:Lemieux.Provider.Route.ready/1`, where the host runs it at
  the right moment and reports its failure in a sentence. The host readies
  only the route the start model is on, so a route must also list and check
  its models from an unreadied state (`c:Lemieux.Provider.Route.ready/1`
  says how). Start no process here; a route that needs one belongs in a
  host that supervises it. A refusal is the clause's own `{:error, reason}`,
  never a clause that does not match: the host calls `routes/1` as it is
  and renders what it returns.

  Read a credential from the environment or from the options and never
  return it from `c:Lemieux.Extension.describe/1`: the loader records the
  module and that it offers routes, and nothing of its state, in the
  transcript, and the adapter the host wraps a route in shows nothing of
  that state when inspected. A compiled bundle should still derive a quiet
  `Inspect` for its own state (`@derive {Inspect, only: []}`). A script
  compiled by the running host cannot, as the protocols are consolidated by
  then, so a script keeps a credential out of its state altogether and
  reads it when a request is sent — the shipped example keeps only the
  variable's name.

  ## Names

  A name is the provider prefix of every model the route serves —
  `relay:qwen3-32b` — and what `--router NAME`, `/provider NAME` and the
  config file's `providers.NAME` address. It is lowercase letters, digits
  and `_`, starting with a letter, the same shape the config file takes
  for a provider, and `validate/1` checks it. A host refuses a name that is
  one of `req_llm`'s providers or already registered: the first would
  shadow a direct provider the person configured, and both would make
  `openai:gpt-5` mean two different destinations. `ixway` belongs to
  `Lemieux.Ixway`.
  """

  alias Lemieux.Provider.Route

  @typedoc "One route offered under the name its models carry."
  @type registration :: %{name: String.t(), route: Route.t()}

  @name_pattern ~r/^[a-z][a-z0-9_]*$/

  # What `Lemieux.Provider.Route` requires of an implementation; the hooks
  # and the preparation callbacks are optional and checked at the call.
  @required_callbacks [
    available_models: 2,
    validate_model: 3,
    context_window: 2,
    reasoning_efforts: 2,
    target: 3
  ]

  @doc """
  The routes this module offers, built from the loader's options.

  `{:error, reason}` stops the start with the reason, so a missing
  credential or an unusable option is said once, in a sentence, rather than
  as a session that cannot reach its model.
  """
  @callback routes(opts :: keyword()) :: {:ok, [registration()]} | {:error, term()}

  @doc "Whether `name` may name a route: lowercase letters, digits and `_`, starting with a letter."
  @spec valid_name?(name :: term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_pattern, name)
  def valid_name?(_name), do: false

  @doc """
  Checks the shape of what `c:routes/1` returned: a list of registrations,
  each with a valid name and a `{module, state}` route whose module defines
  the required `Lemieux.Provider.Route` callbacks, and no name twice.

  Host policy — names a host reserves, routes it already holds — is the
  host's to check (`Lemieux.CLI.Routes`); this is only whether the value is
  a list of routes at all.
  """
  @spec validate(registrations :: term()) :: :ok | {:error, String.t()}
  def validate(registrations) when is_list(registrations) do
    with :ok <- each(registrations, &registration/1) do
      names = Enum.map(registrations, & &1.name)

      case names -- Enum.uniq(names) do
        [] -> :ok
        [name | _] -> {:error, "route #{inspect(name)} is offered twice"}
      end
    end
  end

  def validate(other), do: {:error, "routes/1 must return {:ok, [routes]}, got #{shape(other)}"}

  @doc """
  Names a value by its shape and never by its contents, for a refusal about
  a registration built wrong: the value may hold a credential, and a
  sentence on standard error must not.
  """
  @spec shape(value :: term()) :: String.t()
  def shape(%{__struct__: struct}), do: "a #{inspect(struct)} struct"
  def shape(value) when is_map(value), do: "a map with keys #{inspect(Map.keys(value))}"
  def shape(value) when is_atom(value), do: inspect(value)
  def shape(value) when is_tuple(value), do: "a #{tuple_size(value)}-tuple"
  def shape(value) when is_list(value), do: "a list of #{length(value)}"
  def shape(value) when is_binary(value), do: "a string"
  def shape(value) when is_number(value), do: "a number"
  def shape(value) when is_function(value), do: "a function"
  def shape(_value), do: "a value of another type"

  defp each(list, check) do
    Enum.reduce_while(list, :ok, fn item, :ok ->
      case check.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp registration(%{name: name, route: {module, _state}}) when is_atom(module) do
    cond do
      not valid_name?(name) ->
        {:error,
         "route name #{inspect(name)} must be lowercase letters, digits and _, " <>
           "starting with a letter"}

      not Code.ensure_loaded?(module) ->
        {:error, "route #{name} names #{inspect(module)}, which is not loaded"}

      missing =
          Enum.find(@required_callbacks, fn {f, a} -> not function_exported?(module, f, a) end) ->
        {function, arity} = missing

        {:error,
         "route #{name} names #{inspect(module)}, which does not define " <>
           "#{function}/#{arity}, so it is not a Lemieux.Provider.Route"}

      true ->
        :ok
    end
  end

  defp registration(other),
    do:
      {:error,
       "each route must be %{name: \"NAME\", route: {module, state}}, got #{shape(other)}"}
end
