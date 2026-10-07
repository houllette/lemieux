defmodule Lemieux.CLI.Routes do
  @moduledoc """
  The model routes one `lmx` invocation can send requests through, by name.

  A route (`Lemieux.Provider.Route`) owns a catalogue and a destination; this
  is the host's list of them. The shipped gateway, `Lemieux.Ixway`, is
  registered here as `ixway` when `--ixway`, `LMX_IXWAY_URL` or the config
  file's `ixway` section configures it, and every extension `lmx` loaded
  that offers routes (`Lemieux.Extension.Routes`) has them registered after
  it, in loading order. From here on the two are indistinguishable:
  `Lemieux.CLI.Runtime` wraps each in the adapter with this host's timeouts,
  `Lemieux.CLI.ProviderMux` dispatches a session's requests to one by the
  model's name, `Lemieux.Providers.ReqLLM.prepare/2` resolves `NAME:@default`
  and checks the start model on it, and the terminal UI's `/provider` and
  `/model` list its models beside the direct providers'. Before this module
  the CLI did each of those for Ixway by module name, and a second route
  would have meant a second copy of each.

  ## What stays the host's

  Where a session's requests go is this host's authority, not the
  harness's (`Lemieux.Harness` says why), so an extension *offers* a route
  and this module decides whether it is registered: a valid name that is not
  one of `req_llm`'s providers, not `ixway` and not already taken, and a
  module that implements the route behaviour. The adapter around it is built
  here, with the same `receive_timeout` and `stream_idle_timeout` the direct
  connection gets, so an extension cannot hand the host a provider of its
  own making and inference keeps going through `req_llm`. Credentials stay
  in the route's state: nothing here reads them, and the provenance a
  transcript records of a loaded extension names the module and nothing of
  its state (`Lemieux.CLI.Extensions`).

  ## Refusals

  Every problem here stops the start in a sentence naming the extension and
  the route — a `routes/1` that returned an error (a credential the route
  needs is not set), a route with a malformed name or a module that is not a
  route, a name that would shadow a direct provider or another route, and
  `--router NAME` naming a route nobody registered. A session that quietly
  went to the direct provider in any of these cases would be the silent
  fallback a route exists to rule out.
  """

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Extensions, as: LoadedExtensions
  alias Lemieux.CLI.Options
  alias Lemieux.Extension.Routes, as: Offered
  alias Lemieux.Ixway
  alias Lemieux.Providers.ReqLLM, as: Adapter

  @typedoc "Registered routes in order: each name with the routed connection that serves it."
  @type t :: [{String.t(), Lemieux.Provider.t()}]

  # One provider instance survives `/model` and `/provider` changes, so the
  # timeout policy goes on the connection rather than being chosen from the
  # startup model; the direct connection in `Lemieux.CLI.Runtime` says why
  # these two values.
  @adapter_options [receive_timeout: :infinity, stream_idle_timeout: :timer.minutes(5)]

  @reserved ["ixway"]

  @doc """
  The routes `lmx` ships: Ixway under `ixway`, when the options configure
  an instance; otherwise none.
  """
  @spec builtin(options :: Options.t()) :: t()
  def builtin(%Options{ixway: endpoint} = options) when is_binary(endpoint),
    do: [{"ixway", ixway(options)}]

  def builtin(%Options{}), do: []

  @doc """
  The Ixway connection the options describe, routed through this host's
  adapter: the instance from `--ixway`/`LMX_IXWAY_URL`/the file, the key from
  `IXWAY_API_KEY` or the file's `ixway.api_key`, and the file's routing
  headers.
  """
  @spec ixway(options :: Options.t()) :: Lemieux.Provider.t()
  def ixway(%Options{ixway: endpoint} = options) when is_binary(endpoint) do
    {:ok, _started} = Application.ensure_all_started(:req_llm)
    ixway = Config.get(options.config, "ixway", %{})

    Ixway.provider(
      [
        endpoint: endpoint,
        api_key: System.get_env("IXWAY_API_KEY") || ixway["api_key"],
        headers: ixway |> Map.get("headers", %{}) |> Map.to_list()
      ],
      @adapter_options
    )
  end

  @doc """
  Registers the shipped routes and then every route the loaded extensions
  offer, in order; the first problem stops the list with its sentence.
  """
  @spec register(options :: Options.t(), loaded :: [LoadedExtensions.loaded()]) ::
          {:ok, t()} | {:error, String.t()}
  def register(%Options{} = options, loaded) when is_list(loaded) do
    builtin = builtin(options)
    sources = Map.new(builtin, fn {name, _provider} -> {name, "Lemieux.Ixway"} end)

    loaded
    |> Enum.reduce_while({:ok, builtin, sources}, fn
      %{routes: nil}, acc ->
        {:cont, acc}

      %{routes: {module, opts}, provenance: provenance}, {:ok, routes, sources} ->
        source = "extension #{provenance["name"]} (#{inspect(module)})"

        case offered(module, opts, source) do
          {:ok, registrations} -> admit(registrations, source, routes, sources)
          {:error, _message} = error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, routes, _sources} -> {:ok, routes}
      {:error, _message} = error -> error
    end
  end

  @doc "The registered names, in order."
  @spec names(routes :: t()) :: [String.t()]
  def names(routes) when is_list(routes), do: Enum.map(routes, &elem(&1, 0))

  @doc "Whether a route named `name` is registered."
  @spec registered?(routes :: t(), name :: String.t() | nil) :: boolean()
  def registered?(routes, name) when is_list(routes) and is_binary(name),
    do: List.keymember?(routes, name, 0)

  def registered?(_routes, nil), do: false

  @doc "The connection registered under `name`."
  @spec fetch(routes :: t(), name :: String.t()) :: {:ok, Lemieux.Provider.t()} | :error
  def fetch(routes, name) when is_list(routes) and is_binary(name) do
    case List.keyfind(routes, name, 0) do
      {^name, provider} -> {:ok, provider}
      nil -> :error
    end
  end

  @doc """
  Checks that the route `--router`/`LMX_ROUTER` selected, when it named one
  rather than `direct` or `ixway`, is registered.
  """
  @spec selected(options :: Options.t(), routes :: t()) :: :ok | {:error, String.t()}
  def selected(%Options{host: %{route: nil}}, _routes), do: :ok

  def selected(%Options{host: %{route: name}}, routes) do
    if registered?(routes, name) do
      :ok
    else
      {:error,
       "no model route named #{name} is registered: --router/LMX_ROUTER takes direct, ixway " <>
         "or the name of a route an extension registers (one that exports routes/1, selected " <>
         "with --extension NAME, --extension-dir PATH or the config file's \"extensions\")" <>
         known(routes)}
    end
  end

  defp known([]), do: "; no loaded extension registers one"
  defp known(routes), do: "; registered: #{Enum.join(names(routes), ", ")}"

  defp offered(module, opts, source) do
    case module.routes(opts) do
      {:ok, registrations} ->
        case Offered.validate(registrations) do
          :ok -> {:ok, registrations}
          {:error, problem} -> {:error, "#{source} offers routes lmx cannot register: #{problem}"}
        end

      {:error, reason} ->
        {:error, "#{source} could not build its routes: #{describe(reason)}"}

      other ->
        {:error,
         "#{source}: routes/1 must return {:ok, [routes]} or {:error, reason}, got " <>
           inspect(other, limit: 5, printable_limit: 80)}
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{__exception__: true} = exception), do: Exception.message(exception)
  defp describe(reason), do: inspect(reason)

  defp admit([], _source, routes, sources), do: {:cont, {:ok, routes, sources}}

  defp admit([%{name: name, route: route} | rest], source, routes, sources) do
    cond do
      name in @reserved ->
        {:halt,
         {:error,
          "#{source} offers a route named #{name}, which belongs to Lemieux.Ixway; give the " <>
            "route a name of its own"}}

      Map.has_key?(sources, name) ->
        {:halt,
         {:error,
          "#{source} offers a route named #{name}, which #{sources[name]} already registered; " <>
            "every route needs its own name"}}

      direct_provider?(name) ->
        {:halt,
         {:error,
          "#{source} offers a route named #{name}, which would shadow req_llm's #{name} " <>
            "provider; a route needs a name of its own"}}

      true ->
        provider = Adapter.new([route: route] ++ @adapter_options)
        admit(rest, source, routes ++ [{name, provider}], Map.put(sources, name, source))
    end
  end

  defp direct_provider?(name) do
    {:ok, _started} = Application.ensure_all_started(:req_llm)
    Enum.any?(ReqLLM.Providers.list(), &(Atom.to_string(&1) == name))
  end
end
