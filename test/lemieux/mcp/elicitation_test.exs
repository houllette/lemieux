defmodule Lemieux.MCP.ElicitationTest do
  use ExUnit.Case, async: true

  alias Lemieux.MCP.Elicitation

  defp request(params), do: %{"method" => "elicitation/create", "params" => params}

  defp form(properties, message \\ "who is asking?") do
    request(%{
      "mode" => "form",
      "message" => message,
      "requestedSchema" => %{"type" => "object", "properties" => properties}
    })
  end

  describe "what can be asked" do
    test "a form-mode request becomes a question naming the server" do
      assert {:ok, question} =
               Elicitation.question(form(%{"name" => %{"type" => "string"}}), "gh")

      assert question =~ "gh asks"
      assert question =~ "who is asking?"
      assert question =~ "name"
    end

    test "a request with no mode is form mode, per the specification" do
      assert {:ok, _question} =
               Elicitation.question(request(%{"message" => "hello"}), "gh")
    end

    # None of these were declared, so a conforming server never sends them.
    # Declining is the honest answer to one that does anyway.
    test "url mode is not supported, because opening a browser is not ours to do" do
      assert :unsupported =
               Elicitation.question(request(%{"mode" => "url", "url" => "https://e.x"}), "gh")
    end

    test "sampling is not supported" do
      assert :unsupported =
               Elicitation.question(
                 %{"method" => "sampling/createMessage", "params" => %{}},
                 "gh"
               )
    end
  end

  describe "what a host may show beside the question" do
    test "fields carry the name, the type and the server's description" do
      request =
        form(%{
          "count" => %{"type" => "integer", "description" => "How many to fetch"},
          "label" => %{}
        })

      assert Elicitation.fields(request) == [
               %{name: "count", type: "integer", description: "How many to fetch"},
               %{name: "label", type: "string", description: nil}
             ]
    end

    test "the title comes from the schema, then the params, and is nil when absent" do
      titled =
        request(%{
          "mode" => "form",
          "message" => "m",
          "requestedSchema" => %{"type" => "object", "title" => "Fetch", "properties" => %{}}
        })

      assert Elicitation.title(titled) == "Fetch"
      assert Elicitation.title(request(%{"mode" => "form", "title" => "Plain"})) == "Plain"
      assert Elicitation.title(form(%{})) == nil
      assert Elicitation.fields(%{"method" => "other"}) == []
      assert Elicitation.title(%{"method" => "other"}) == nil
    end
  end

  describe "turning an answer into a response" do
    test "a single string property takes the answer as it was typed" do
      response = Elicitation.response(form(%{"name" => %{"type" => "string"}}), {:ok, "octocat"})

      assert response == %{"action" => "accept", "content" => %{"name" => "octocat"}}
    end

    test "a number property is converted, so the server gets the type it asked for" do
      response = Elicitation.response(form(%{"age" => %{"type" => "number"}}), {:ok, " 30 "})

      assert response == %{"action" => "accept", "content" => %{"age" => 30}}
    end

    test "a boolean property accepts the words a person would type" do
      schema = form(%{"ok" => %{"type" => "boolean"}})

      assert %{"content" => %{"ok" => true}} = Elicitation.response(schema, {:ok, "yes"})
      assert %{"content" => %{"ok" => false}} = Elicitation.response(schema, {:ok, "No"})
    end

    test "an answer that is not the type asked for is declined, not coerced" do
      response = Elicitation.response(form(%{"age" => %{"type" => "number"}}), {:ok, "quite old"})

      assert response == %{"action" => "decline"}
    end

    test "several properties are read as JSON, since text cannot say which is which" do
      schema = form(%{"name" => %{"type" => "string"}, "email" => %{"type" => "string"}})

      response = Elicitation.response(schema, {:ok, ~s({"name": "a", "email": "b"})})

      assert response == %{"action" => "accept", "content" => %{"name" => "a", "email" => "b"}}
    end

    test "several properties answered with prose are declined rather than guessed at" do
      schema = form(%{"name" => %{"type" => "string"}, "email" => %{"type" => "string"}})

      assert %{"action" => "decline"} = Elicitation.response(schema, {:ok, "me, at my address"})
    end

    # Nobody answered — a timeout, or a session with no one attached. The
    # specification expects a client to be able to say so.
    test "no answer is a decline" do
      assert %{"action" => "decline"} =
               Elicitation.response(form(%{"name" => %{}}), {:error, :timeout})
    end

    test "a request for consent alone accepts with nothing attached" do
      assert %{"action" => "accept", "content" => %{}} =
               Elicitation.response(request(%{"message" => "may I?"}), {:ok, "yes"})
    end
  end
end
