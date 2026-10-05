defmodule SecurityExample.PipelineTest do
  use ExUnit.Case, async: true

  test "policy is reusable without a model" do
    assert {:ok, []} = SecurityExample.Pipeline.assess_ports([])
    assert {:ok, [%{"port" => 23}]} = SecurityExample.Pipeline.assess_ports([443, 23, 23])
  end

  test "command preparation rejects shell fragments and unbounded targets" do
    for target <- ["127.0.0.1;echo injected", "--script=all", "192.0.2.0/24"] do
      assert {:error, _} = SecurityExample.Pipeline.nmap_command(target, [443])
    end

    assert {:error, _} = SecurityExample.Pipeline.nmap_command("192.0.2.1", ["80;echo injected"])
    assert {:ok, command} = SecurityExample.Pipeline.nmap_command("192.0.2.1", [443, 80, 443])
    assert command == "nmap -sT -n --host-timeout 20s -p 80,443 -oX - 192.0.2.1"
  end
end
