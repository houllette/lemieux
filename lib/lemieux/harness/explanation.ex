defmodule Lemieux.Harness.Explanation do
  @moduledoc false
  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tool.Override
  alias Lemieux.Tool.Profile
  alias Lemieux.Tools

  @limits ~w(max_turns max_requests max_cost_usd tool_timeout_ms tool_output_bytes approval_timeout compact_at reasoning_effort)a

  @spec build(harness :: Harness.t(), overrides :: keyword()) :: map()
  def build(harness, overrides) do
    settings =
      Map.merge(
        Map.from_struct(harness),
        Map.new(Keyword.take(overrides, Harness.session_fields()))
      )

    catalog = (settings.tools || Tools.default()) ++ (settings.host_tools || [])
    disabled = settings.disabled_tools || []
    profile = Profile.new(settings.tool_profile)

    tools =
      Enum.map(catalog, fn tool ->
        %{
          "name" => Tool.name(tool),
          "implementation" => implementation(tool),
          "enabled" => Tool.name(tool) not in disabled and Profile.allowed?(profile, tool)
        }
      end)

    %{
      "version" => 1,
      "scope" => "prepared_local_catalog",
      "tools" => tools,
      "disabled_tools" => disabled,
      "system" => prompt(settings.system),
      "settings" =>
        Map.new(@limits, &{Atom.to_string(&1), setting(&1, Map.fetch!(settings, &1))}),
      "hooks" =>
        Enum.map(settings.hooks || [], fn {event, _} -> Atom.to_string(event) end) |> Enum.uniq(),
      "strategies" =>
        Map.new(
          [:messages, :guard, :compaction, :environment],
          &{Atom.to_string(&1), strategy(Map.fetch!(settings, &1))}
        ),
      "host_overrides" =>
        overrides
        |> Keyword.keys()
        |> Enum.filter(&(&1 in Harness.session_fields()))
        |> Enum.map(&Atom.to_string/1)
        |> Enum.sort(),
      "extensions" => Enum.map(harness.applied, &Map.take(&1, ["module", "digest", "changes"])),
      "mcp_servers" => length(settings.mcp_servers || [])
    }
  end

  defp implementation(%Override{tool: inner}), do: [inspect(Override) | implementation(inner)]
  defp implementation(%module{}), do: [inspect(module)]
  defp implementation(module) when is_atom(module), do: [inspect(module)]

  defp prompt(:default), do: %{"source" => "shipped_default"}
  defp prompt(nil), do: %{"source" => "disabled"}

  defp prompt(text),
    do: %{
      "source" => "configured",
      "bytes" => byte_size(text),
      "sha256" => Lemieux.Contract.sha256(text)
    }

  defp setting(_key, :default), do: "session_default"
  defp setting(key, nil) when key in [:compact_at, :reasoning_effort], do: nil
  defp setting(_key, nil), do: "session_default"
  defp setting(_key, value) when is_number(value), do: value
  defp setting(:reasoning_effort, value) when is_binary(value), do: value
  defp setting(_key, _value), do: "invalid"

  defp strategy(nil), do: "session_default"
  defp strategy({module, _state}), do: inspect(module)
  defp strategy(module) when is_atom(module), do: inspect(module)
  defp strategy(_value), do: "configured"
end
