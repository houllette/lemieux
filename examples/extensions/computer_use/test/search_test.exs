defmodule LemieuxComputerUse.SearchTest do
  use ExUnit.Case, async: true
  alias LemieuxComputerUse.Search

  test "Exa results become bounded provider-neutral rows" do
    rows =
      Enum.map(
        1..10,
        &%{"url" => "https://example.com/#{&1}", "text" => String.duplicate("x", 2000)}
      )

    assert {:ok, results, %{"cost_usd" => nil}} =
             Search.parse(JSON.encode!(%{"results" => rows}), nil)

    assert length(results) == 5
    assert hd(results).title == "https://example.com/1"
    assert String.length(hd(results).snippet) == 1500
    assert {:error, _} = Search.parse("unexpected prose", nil)
  end
end
