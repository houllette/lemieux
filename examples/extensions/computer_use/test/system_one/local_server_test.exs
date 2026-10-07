defmodule LemieuxComputerUse.SystemOne.LocalServerTest do
  # Chooses browser actions through a System One server you started
  # yourself, over the real wire: the check that a model on your own machine
  # classifies like any other provider, and that the questions Decision
  # builds are ones such a server accepts. It runs only when
  # `LOCAL_SYSTEM_ONE_URL` names the server (test/test_helper.exs excludes it
  # otherwise), with `LOCAL_SYSTEM_ONE_MODEL` naming the model to ask and, if
  # the server wants one, `LOCAL_SYSTEM_ONE_KEY` the bearer token. Run
  # against Ollama 0.35 with clef-flash and nimble (2026-10):
  #
  #     ollama pull clef-flash        # Ollama 0.35+ serves /v1/systemone
  #     LOCAL_SYSTEM_ONE_URL=http://127.0.0.1:11434 LOCAL_SYSTEM_ONE_MODEL=clef-flash \
  #       mix test test/system_one/local_server_test.exs
  #
  # A model's choice on the fixture is its own, so the tests assert that the
  # answer decodes to an action the page offered and print the choice rather
  # than asserting it.
  use ExUnit.Case, async: false

  alias LemieuxComputerUse.{Decision, SystemOne}

  @moduletag :local_system_one

  test "a locally served model chooses an offered action, a lone target included" do
    # Five CLICK targets, one TYPE_TEXT and one SCROLL_DOWN: the last two
    # are the one-target operations no question is asked about.
    page = %{
      "url" => "https://hotels.example/",
      "title" => "Find a hotel",
      "text" =>
        "Find a hotel. Destination: (empty). Style: Any, Design, Classic. " <>
          "Free cancellation. Search. Help. Sign in.",
      "omitted_actions" => 0,
      "actions" => [
        target("1", "TYPE_TEXT", "Destination", "input", value: ""),
        target("2", "CLICK", "Destination", "input", value: ""),
        target("3", "CLICK", "Search", "button"),
        target("4", "CLICK", "Design", "checkbox", checked: false),
        target("5", "CLICK", "Free cancellation", "checkbox", checked: false),
        target("6", "CLICK", "Help", "a"),
        %{"id" => "down", "operation" => "SCROLL_DOWN", "label" => "Scroll down"}
      ]
    }

    request =
      Decision.request(page, "Search for design hotels in Lisbon with free cancellation", [], [])

    assert Map.keys(request["questions"]) |> Enum.sort() == ["click_target", "operation"]
    choose(page, request)
  end

  test "a locally served model chooses among more targets than one question may offer" do
    links = ~w(Home Products Solutions Customers Partners Careers Blog Events Webinars Docs API
               Status Changelog Community Forum Support Contact Security Privacy Terms Cookies
               Legal Press Investors About Team Mission Values Locations Pricing Enterprise
               Startups Education Nonprofits)

    page = %{
      "url" => "https://vendor.example/",
      "title" => "Vendor",
      "text" => "Welcome to Vendor. " <> Enum.join(links, ". "),
      "omitted_actions" => 0,
      "actions" =>
        links
        |> Enum.with_index(1)
        |> Enum.map(fn {label, n} -> target(Integer.to_string(n), "CLICK", label, "a") end)
    }

    request = Decision.request(page, "Open the pricing page", [], [])
    assert Map.has_key?(request["questions"], "click_target_group")
    choose(page, request)
  end

  defp choose(page, request) do
    url = System.fetch_env!("LOCAL_SYSTEM_ONE_URL")
    model = System.fetch_env!("LOCAL_SYSTEM_ONE_MODEL")

    provider = %{
      name: "local",
      type: :endpoint,
      base_url: url,
      api_key: System.get_env("LOCAL_SYSTEM_ONE_KEY"),
      api_key_header: nil,
      headers: %{},
      model: model
    }

    {micros, result} =
      :timer.tc(fn -> SystemOne.evaluate(request, provider: provider, timeout_ms: 120_000) end)

    assert {:ok, response} = result
    assert response["model"] == model

    assert {:ok, action, confidence} = Decision.decode(request, response, page)
    assert action["operation"] in Map.keys(request["questions"]["operation"]["criteria"])

    if action["id"], do: assert(action in page["actions"])

    assert is_number(confidence["operation_confidence"])
    target_confidence = confidence["target_confidence"]
    assert is_nil(target_confidence) or (target_confidence >= 0 and target_confidence <= 1)

    IO.puts(
      "\n#{model} at #{url}: #{action["operation"]} #{action["label"] || "-"}" <>
        "#{if action["id"], do: " (#{action["id"]})"}, operation confidence " <>
        "#{round3(confidence["operation_confidence"])}, target confidence " <>
        "#{round3(target_confidence)}, #{length(Map.keys(request["questions"]))} questions " <>
        "in #{div(micros, 1000)} ms, usage #{inspect(response["usage"])}"
    )
  end

  defp target(id, operation, label, role, attributes \\ []) do
    Map.merge(
      %{"id" => id, "operation" => operation, "label" => label, "role" => role},
      Map.new(attributes, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  defp round3(nil), do: "nil"
  defp round3(value), do: Float.round(value / 1, 3)
end
