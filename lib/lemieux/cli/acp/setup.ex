defmodule Lemieux.CLI.ACP.Setup do
  @moduledoc """
  Bounded terminal setup for an editor-launched agent.

  Authentication opens a separate terminal invocation, never a prompt on the
  JSON-RPC stream. Saving through the existing private configuration writer
  keeps key storage and file validation identical to the terminal host. No
  model request is made: setup establishes configuration, not entitlement.
  """

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Models
  alias Lemieux.CLI.Options
  alias Lemieux.ModelSpec

  @spec main(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, integer()}
  def main(argv, opts) do
    with {:ok, options} <- Options.parse(argv, command: :acp),
         true <- options.argv == [],
         path when is_binary(path) <- Config.path(options.config),
         {:ok, model} <- input(opts, "Model (provider:model) [#{options.model}]: "),
         model = if(model == "", do: options.model, else: model),
         {:ok, {provider, _id}} <- model(model),
         {:ok, key} <- key(provider, options.config, opts),
         :ok <- save(path, model, provider, key) do
      IO.puts("Saved Lemieux setup. Return to the editor and start a thread.")
      :ok
    else
      nil -> error("Setup needs a configuration file; remove --config none.")
      false -> error("acp setup takes no positional arguments")
      {:error, reason} -> error(reason)
    end
  end

  defp input(opts, prompt) do
    opts |> Keyword.get(:setup_input, &IO.gets/1) |> then(& &1.(prompt)) |> text()
  end

  defp model(model) do
    case ModelSpec.split(model) do
      {:ok, parts} -> {:ok, parts}
      :error -> {:error, "Enter a model as provider:model."}
    end
  end

  defp key(provider, config, opts) do
    if Models.credential(provider, config, opts) == :missing do
      prompt = ~c"Provider API key (hidden; Ctrl-D cancels): "
      read = Keyword.get(opts, :setup_password, &:io.get_password/1)

      with {:ok, key} <- text(read.(prompt)),
           false <- key == "" do
        {:ok, key}
      else
        true -> {:error, "No key supplied; setup was not saved."}
        error -> error
      end
    else
      {:ok, nil}
    end
  end

  defp text(value) when is_binary(value), do: {:ok, String.trim(value)}
  defp text(value) when is_list(value), do: {:ok, value |> List.to_string() |> String.trim()}
  defp text(_cancelled), do: {:error, "Setup cancelled."}

  defp save(path, model, provider, key) do
    Config.update(path, fn settings ->
      settings = Map.put(settings, "model", model)

      if key do
        providers = Map.get(settings, "providers", %{})
        section = providers |> Map.get(provider, %{}) |> Map.put("api_key", key)
        Map.put(settings, "providers", Map.put(providers, provider, section))
      else
        settings
      end
    end)
  end

  @spec methods(version :: 1 | 2, argv :: [String.t()], capabilities :: map()) :: [map()]
  def methods(version, argv, capabilities) do
    if match?(%{"auth" => %{"terminal" => true}}, capabilities) do
      id = if version == 1, do: "id", else: "methodId"

      [
        %{
          "type" => "terminal",
          id => "setup",
          "name" => "Configure Lemieux",
          "description" => "Choose a model and configure provider credentials in a terminal.",
          "args" => ["acp", "setup" | argv]
        }
      ]
    else
      []
    end
  end

  defp error(reason) do
    IO.puts(:stderr, "lmx: #{reason}")
    {:error, 1}
  end
end
