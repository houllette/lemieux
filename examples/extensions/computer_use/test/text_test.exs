defmodule LemieuxComputerUse.TextTest do
  use ExUnit.Case, async: true

  defmodule Adapter do
    def run(request) do
      send(self(), {:text_request, request})

      {request,
       Req.Response.new(
         status: 200,
         body: %{
           "id" => "fixture-response",
           "model" => "gpt-4o-mini",
           "object" => "response",
           "status" => "completed",
           "output" => [
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [
                 %{"type" => "output_text", "text" => ~s({"text":"Lisbon"}), "annotations" => []}
               ]
             }
           ],
           "usage" => %{"input_tokens" => 20, "output_tokens" => 5, "total_tokens" => 25}
         }
       )}
    end
  end

  test "field text uses ReqLLM structured output and preserves usage without credentials" do
    assert {:ok, "Lisbon", evidence} =
             LemieuxComputerUse.Text.generate("Find Lisbon", %{"label" => "Destination"}, %{},
               text_model: "openai:gpt-4o-mini",
               text_options: [api_key: "fixture-secret", req_http_options: [adapter: Adapter]]
             )

    assert_receive {:text_request, request}
    assert JSON.decode!(request.body)["text"]["format"]["type"] == "json_schema"
    assert evidence["usage"]["input_tokens"] == 20
    refute JSON.encode!(evidence) =~ "fixture-secret"
  end

  test "typing without an explicitly selected text model fails closed" do
    assert {:error, "TYPE_TEXT requires a configured text_model through ReqLLM"} =
             LemieuxComputerUse.Text.generate("Find Lisbon", %{}, %{}, [])
  end
end
