defmodule LemieuxComputerUse.DecisionTest do
  use ExUnit.Case, async: true
  alias LemieuxComputerUse.Decision

  test "operation and compatible target questions share one observed state" do
    page = %{
      "url" => "https://example.com",
      "text" => "Search",
      "actions" => [
        %{"id" => "1", "operation" => "CLICK", "label" => "Search"},
        %{"id" => "2", "operation" => "TYPE_TEXT", "label" => "Destination"}
      ]
    }

    request = Decision.request(page, "Find Lisbon", [], [])

    assert Map.keys(request["questions"]) |> Enum.sort() == [
             "click_target",
             "operation",
             "type_text_target"
           ]

    assert Map.keys(request["questions"]["click_target"]["criteria"]) == ["1"]
    assert Map.keys(request["questions"]["type_text_target"]["criteria"]) == ["2"]

    response = %{
      "answers" => %{
        "operation" => choice(request["questions"]["operation"]["criteria"], "CLICK"),
        "click_target" => choice(%{"1" => nil}, "1")
      }
    }

    assert {:ok, %{"id" => "1"}, _} = Decision.decode(request, response, page)
  end

  test "invented targets, malformed probabilities and low confidence never execute" do
    page = %{"actions" => [%{"id" => "1", "operation" => "CLICK", "label" => "Go"}]}
    request = Decision.request(page, "Go", [], [])
    operation = choice(request["questions"]["operation"]["criteria"], "CLICK")

    for target <- [
          choice(%{"evil" => nil}, "evil"),
          %{"choice" => "1", "confidence" => 1, "probabilities" => %{"1" => -1}}
        ] do
      assert {:error, :invalid_choice} =
               Decision.decode(
                 request,
                 %{"answers" => %{"operation" => operation, "click_target" => target}},
                 page
               )
    end

    assert {:error, :low_confidence} =
             Decision.decode(
               request,
               %{"answers" => %{"operation" => %{operation | "confidence" => 0.1}}},
               page,
               0.5
             )
  end

  defp choice(criteria, selected),
    do: %{
      "type" => "choice",
      "choice" => selected,
      "confidence" => 1.0,
      "probabilities" =>
        Map.new(criteria, fn {key, _} -> {key, if(key == selected, do: 1.0, else: 0.0)} end)
    }
end
