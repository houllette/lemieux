defmodule Lemieux.Subagent.ErrorTest do
  use ExUnit.Case, async: true

  alias Lemieux.Subagent.Error
  alias Lemieux.Tool.Result

  test "readable amounts retain exact evidence and survive JSON replay" do
    reason = %{
      reason: :tree_budget,
      spent: 0.337745,
      reserved: 0.0,
      requested: 9.0,
      cap: 9.0,
      micros: %{spent: 337_745, reserved: 0, requested: 9_000_000, cap: 9_000_000}
    }

    result = Error.result(reason)
    assert result.model_text =~ "requested $9.00, available $8.66"
    assert result.model_text =~ "spent $0.34, reserved $0.00"
    assert result.model_text =~ "not the provider account balance"
    evidence = result |> Result.to_map() |> JSON.encode!() |> JSON.decode!()
    diagnostic = evidence["structured_content"]["subagent_error"]
    assert diagnostic["micros"]["spent"] == 337_745
    assert evidence["structured_content"]["original"] =~ "337745"
    assert Error.message(diagnostic) == result.model_text
  end

  test "reservations, exhaustion and unknown amounts are honest" do
    assert Error.message(%{
             "reason" => "tree_budget",
             "micros" => %{
               "cap" => 9_000_000,
               "spent" => 337_745,
               "reserved" => 1_000_000
             }
           }) =~ "available $7.66"

    assert Error.message(%{
             "reason" => "tree_budget",
             "micros" => %{
               "cap" => 1,
               "spent" => 2,
               "reserved" => 0
             }
           }) =~ "available $0.00"

    assert Error.message(%{"reason" => "tree_budget"}) =~ "available unknown"
    assert Error.result({:new_failure, %{code: 42}}).model_text =~ "saved tool result"
    assert Error.result({:root_limit, 3}).model_text =~ "limit of 3"
  end
end
