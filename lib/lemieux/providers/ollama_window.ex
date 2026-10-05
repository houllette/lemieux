defmodule Lemieux.Providers.OllamaWindow do
  @moduledoc """
  The context window a local Ollama daemon actually gives a model.

  This is window discovery, not a provider adapter: model requests still go
  through `req_llm`'s Ollama provider and its OpenAI-compatible `/v1`
  endpoint. What this module reads is the daemon's own native API, and only
  the two endpoints that describe a model without loading it — `/api/ps` and
  `/api/show`. It never sends a prompt and never asks for a model to be
  loaded.

  ## Why the window has to be asked for

  The window a local model gets is a server setting, not a model fact.
  Ollama sizes it when it loads the model — from `OLLAMA_CONTEXT_LENGTH`, the
  app's *Context length* setting or a Modelfile's `num_ctx`, and otherwise
  from GPU memory: 4,096 tokens below about 23 GiB, 32,768 below about
  47 GiB, 262,144 above that. The `/v1` endpoint lmx uses has no way to ask
  for another size (Ollama ignores a per-request `num_ctx` there), and a
  conversation that outgrows the window is not refused: the daemon drops its
  oldest part without an error. Measured on a simulated 4,096-token machine,
  the person's task and the file the model had just read were gone from the
  third request, and the session ended with an empty answer and exit 0. No
  overflow ever arrives to correct a guess, so a guess is all a session has
  unless somebody asks the daemon.

  ## What each endpoint can say

    * `/api/ps` lists the models in memory with the `context_length` each was
      loaded with. Once a session's own request has loaded the model, that is
      exactly the window every later request gets (`loaded/3`). Before then
      it may describe a load another client made with its own `num_ctx`; a
      `/v1` request with no options reloads the model at the server default
      in that case, which is why a session keeps asking after its requests
      rather than trusting what it heard at startup.
    * `/api/show` reports a Modelfile's `num_ctx`, which a `/v1` request
      always gets, and the length the model was trained on, which the daemon
      never exceeds (`configured/3`). Without a `num_ctx` it cannot say what
      the server default will be.

  Every lookup is best effort and quick: a daemon that is not running, is
  not Ollama, or answers something else yields `nil`, and the caller plans
  as it would have without asking.
  """

  @connect_timeout 250
  @receive_timeout 1_000

  @doc """
  The window `model` will be served with: what it is loaded with now, or
  else what its Modelfile asks for, or `nil`.
  """
  @spec window(base_url :: String.t(), model :: String.t()) :: pos_integer() | nil
  def window(base_url, model), do: loaded(base_url, model) || configured(base_url, model)

  @doc """
  The `context_length` `/api/ps` reports for `model`, or `nil` when it is not
  loaded or the daemon cannot be asked.

  `base_url` is the OpenAI-compatible base a request is sent to, `/v1` and
  all; a model named without a tag is the daemon's `:latest`.
  """
  @spec loaded(base_url :: String.t(), model :: String.t()) :: pos_integer() | nil
  def loaded(base_url, model) when is_binary(base_url) and is_binary(model) do
    wanted = tagged(model)

    with {:ok, %Req.Response{status: 200, body: %{"models" => models}}} when is_list(models) <-
           Req.get(native_base(base_url) <> "/api/ps", request_options()),
         %{"context_length" => window} when is_integer(window) and window > 0 <-
           Enum.find(models, &(wanted in names(&1))) do
      window
    else
      _unknown -> nil
    end
  catch
    # `Req` returns most failures, a body that does not decode among them,
    # but raises on a base URL with no usable scheme and exits on a port out
    # of range. A lookup that cannot say must not fail the session asking,
    # nor the request it follows.
    _kind, _reason -> nil
  end

  @doc """
  The window `/api/show` says `model` will load with — its Modelfile's
  `num_ctx`, never more than the length it was trained on — or `nil` when
  the Modelfile sets none.
  """
  @spec configured(base_url :: String.t(), model :: String.t()) :: pos_integer() | nil
  def configured(base_url, model) when is_binary(base_url) and is_binary(model) do
    case Req.post(
           native_base(base_url) <> "/api/show",
           [json: %{model: model}] ++ request_options()
         ) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        body |> Map.get("parameters") |> num_ctx() |> within(trained(body["model_info"]))

      _unknown ->
        nil
    end
  catch
    _kind, _reason -> nil
  end

  @doc """
  The daemon's own address, given the OpenAI-compatible base URL a request
  goes to: the same URL without its trailing `/v1`.
  """
  @spec native_base(base_url :: String.t()) :: String.t()
  def native_base(base_url) when is_binary(base_url) do
    uri = URI.parse(base_url)

    path =
      uri.path
      |> to_string()
      |> String.trim_trailing("/")
      |> String.replace_suffix("/v1", "")

    URI.to_string(%{uri | path: path, query: nil, fragment: nil})
  end

  defp request_options do
    [
      retry: false,
      receive_timeout: @receive_timeout,
      connect_options: [timeout: @connect_timeout]
    ]
  end

  defp names(model) when is_map(model) do
    ["name", "model"]
    |> Enum.map(&Map.get(model, &1))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&tagged/1)
  end

  defp names(_other), do: []

  # `llama3` and `llama3:latest` are one model to the daemon, and `/api/ps`
  # always names it the second way.
  defp tagged(name) do
    if name |> Path.basename() |> String.contains?(":"), do: name, else: name <> ":latest"
  end

  # `parameters` is the Modelfile's PARAMETER lines as text, one per line:
  # `num_ctx                        32768`.
  defp num_ctx(parameters) when is_binary(parameters) do
    Enum.find_value(String.split(parameters, "\n"), fn line ->
      case String.split(line) do
        ["num_ctx", value] -> positive(value)
        _other -> nil
      end
    end)
  end

  defp num_ctx(_parameters), do: nil

  defp trained(info) when is_map(info) do
    Enum.find_value(info, fn
      {key, value} when is_binary(key) and is_integer(value) and value > 0 ->
        if String.ends_with?(key, ".context_length"), do: value

      _other ->
        nil
    end)
  end

  defp trained(_info), do: nil

  defp within(nil, _trained), do: nil
  defp within(window, nil), do: window
  defp within(window, trained), do: min(window, trained)

  defp positive(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _other -> nil
    end
  end
end
