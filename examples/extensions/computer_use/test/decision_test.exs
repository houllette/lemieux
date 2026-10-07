defmodule LemieuxComputerUse.DecisionTest do
  use ExUnit.Case, async: true
  alias LemieuxComputerUse.Decision

  test "operation and compatible target questions share one observed state" do
    page = %{
      "url" => "https://example.com",
      "text" => "Search",
      "actions" => [
        %{"id" => "1", "operation" => "CLICK", "label" => "Search", "role" => "button"},
        %{"id" => "2", "operation" => "CLICK", "label" => "Help", "checked" => nil},
        %{"id" => "3", "operation" => "TYPE_TEXT", "label" => "Destination", "value" => ""}
      ]
    }

    request = Decision.request(page, "Find Lisbon", [], [])

    assert Map.keys(request["questions"]) |> Enum.sort() == ["click_target", "operation"]

    assert Map.keys(request["questions"]["operation"]["criteria"]) |> Enum.sort() ==
             ~w(BLOCKED CLICK DONE TYPE_TEXT WAIT)

    # Descriptions are strings in key order, without the attributes a page
    # left null.
    assert request["questions"]["click_target"]["criteria"] == %{
             "1" => ~s({"label":"Search","role":"button"}),
             "2" => ~s({"label":"Help"})
           }

    assert length(request["state"]["elements"]) == 3

    response = %{
      "answers" => %{
        "operation" => choice(request["questions"]["operation"]["criteria"], "CLICK"),
        "click_target" => choice(request["questions"]["click_target"]["criteria"], "2")
      }
    }

    assert {:ok, %{"id" => "2"}, %{"target_confidence" => 1.0}} =
             Decision.decode(request, response, page)
  end

  test "an operation with one target is not asked about, and selecting it selects the target" do
    page = %{
      "actions" => [
        %{"id" => "1", "operation" => "CLICK", "label" => "Go"},
        %{"id" => "down", "operation" => "SCROLL_DOWN", "label" => "Scroll down"}
      ]
    }

    request = Decision.request(page, "Go", [], [])
    assert Map.keys(request["questions"]) == ["operation"]

    for {operation, id} <- [{"CLICK", "1"}, {"SCROLL_DOWN", "down"}] do
      operation_answer = choice(request["questions"]["operation"]["criteria"], operation)

      # An answer to a question nobody asked cannot redirect the forced choice.
      answers = %{
        "operation" => operation_answer,
        "click_target" => choice(%{"evil" => nil}, "evil")
      }

      assert {:ok, %{"id" => ^id, "operation" => ^operation},
              %{"operation_confidence" => 1.0, "target_confidence" => nil}} =
               Decision.decode(request, %{"answers" => answers}, page, 0.5)
    end

    # A page that no longer matches the request, with two targets where it
    # offered one, has no single target to take.
    two = %{page | "actions" => [hd(page["actions"]) | page["actions"]]}

    assert {:error, :invalid_choice} =
             Decision.decode(
               request,
               %{
                 "answers" => %{
                   "operation" => choice(request["questions"]["operation"]["criteria"], "CLICK")
                 }
               },
               two
             )
  end

  test "more than 26 targets are asked in groups, and the pair of answers selects one" do
    actions =
      for n <- 1..60,
          do: %{"id" => Integer.to_string(n), "operation" => "CLICK", "label" => "Link #{n}"}

    page = %{"actions" => actions}
    request = Decision.request(page, "Open Link 30", [], [])
    questions = request["questions"]

    assert Map.keys(questions) |> Enum.sort() ==
             ~w(click_target_1 click_target_2 click_target_3 click_target_group operation)

    assert Enum.map(1..3, &map_size(questions["click_target_#{&1}"]["criteria"])) == [20, 20, 20]
    assert Map.has_key?(questions["click_target_2"]["criteria"], "30")
    assert JSON.decode!(questions["click_target_group"]["criteria"]["2"]) |> hd() == "Link 21"

    answers = %{
      "operation" => choice(questions["operation"]["criteria"], "CLICK"),
      "click_target_group" => %{
        choice(questions["click_target_group"]["criteria"], "2")
        | "confidence" => 0.8
      },
      "click_target_2" => %{
        choice(questions["click_target_2"]["criteria"], "30")
        | "confidence" => 0.5
      }
    }

    assert {:ok, %{"id" => "30"}, %{"target_confidence" => 0.4}} =
             Decision.decode(request, %{"answers" => answers}, page)

    assert {:error, :low_confidence} =
             Decision.decode(request, %{"answers" => answers}, page, 0.45)

    # A target from another group is not in the chosen group's question.
    wrong =
      put_in(answers, ["click_target_2"], choice(questions["click_target_1"]["criteria"], "3"))

    assert {:error, :invalid_choice} = Decision.decode(request, %{"answers" => wrong}, page)
  end

  test "every question offers 2 to 26 options described by strings, whatever the page" do
    for count <- [1, 2, 26, 27, 53, 150, 700] do
      actions =
        for n <- 1..count,
            do: %{
              "id" => "t#{n}",
              "operation" => "CLICK",
              "label" => "Target #{n}",
              "checked" => false
            }

      request = Decision.request(%{"actions" => actions}, "Goal", [], [])

      for {key, %{"type" => "choice", "criteria" => criteria}} <- request["questions"] do
        assert map_size(criteria) in 2..26, "#{count} targets: #{key} has #{map_size(criteria)}"
        assert Enum.all?(Map.values(criteria), &is_binary/1), "#{count} targets: #{key}"
      end

      offered =
        for {"click_target" <> _, %{"criteria" => criteria}} <- request["questions"],
            id <- Map.keys(criteria),
            String.starts_with?(id, "t"),
            do: id

      assert length(offered) == if(count == 1, do: 0, else: min(count, 676))
    end
  end

  test "invented targets, malformed probabilities and low confidence never execute" do
    page = %{
      "actions" => [
        %{"id" => "1", "operation" => "CLICK", "label" => "Go"},
        %{"id" => "2", "operation" => "CLICK", "label" => "Back"}
      ]
    }

    request = Decision.request(page, "Go", [], [])
    operation = choice(request["questions"]["operation"]["criteria"], "CLICK")

    for target <- [
          choice(%{"evil" => nil}, "evil"),
          %{"choice" => "1", "confidence" => 1, "probabilities" => %{"1" => -1, "2" => 2}},
          nil
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
