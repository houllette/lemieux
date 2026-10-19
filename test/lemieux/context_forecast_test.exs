defmodule Lemieux.ContextForecastTest do
  use ExUnit.Case, async: true

  alias Lemieux.Context.Forecast
  alias Lemieux.{Entry, Request}

  test "auxiliary title and guidance requests cannot calibrate conversation input" do
    request = %Request{model: "test:model", system: String.duplicate("x", 100_000)}
    bytes = Request.input_bytes(request)

    entries = [
      Entry.new(:request, %{"id" => "turn", "input_bytes" => bytes}),
      Entry.new(:assistant, %{}, usage: %{"request_id" => "turn", "input_tokens" => 20_000})
    ]

    assert %{input_tokens: expected, source: :measured_delta} = Forecast.input(request, entries)

    for type <- [:extension_state, :guidance] do
      auxiliary = [
        Entry.new(:request, %{"id" => "title", "input_bytes" => 3600}),
        %{
          Entry.new(:extension_state, %{})
          | type: type,
            usage: %{"request_id" => "title", "input_tokens" => 800}
        }
      ]

      assert Forecast.input(request, entries ++ auxiliary) == %{
               input_tokens: expected,
               source: :measured_delta
             }
    end
  end
end
