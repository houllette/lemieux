defmodule LemieuxJevCompaction.TrialTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias LemieuxJevCompaction.Trial
  alias SystemOneSDK.Test

  test "paired trials grade answers and retain only bounded score and usage evidence" do
    client = Test.client()
    Test.stub(client, %{"keep_1" => {:noul, 0.02}}, usage: %{input_tokens: 30, output_tokens: 1})

    case_data = sample_case()

    provider_factory = fn _case, _arm, _repetition ->
      Scripted.new([
        Scripted.complete("OK",
          usage: %{"input_tokens" => 200, "output_tokens" => 2, "cost_usd" => 0.001}
        )
      ])
    end

    assert {:ok, report} =
             Trial.run([case_data],
               model: "test:model",
               arms: [:baseline, :shadow],
               provider_factory: provider_factory,
               sdk_client: client,
               sdk_rates: %{"input_per_million" => 0.042, "output_per_million" => 0.0},
               cost_cap_usd: 0.10,
               reservation_per_run_usd: 0.02,
               hook_opts: [min_saved_tokens: 1]
             )

    assert %{"runs" => [baseline, shadow]} = report
    assert baseline["arm"] == "baseline"
    assert shadow["arm"] == "shadow"

    assert [%{"correct" => true, "status" => "stop", "usage" => [usage]}] =
             baseline["followups"]

    assert usage["input_tokens"] == 200
    assert usage["output_tokens"] == 2
    assert usage["cost_usd"] == 0.001

    assert [%{"candidates" => [%{"must_keep" => false, "keep_probability" => 0.02}]}] =
             shadow["evaluations"]

    refute inspect(report) =~ "RELEASE_CODE"
    refute inspect(report) =~ "Ignore the file"
    assert report["cost_usd"] > 0.002
    Test.verify!(client)
    Test.close(client)
  end

  test "Jev arm assembles the standalone extension before a resumed model turn" do
    client = Test.client()
    Test.stub(client, %{"keep_1" => {:noul, 0.01}})
    parent = self()

    factory = fn _, _, _ ->
      provider =
        Scripted.new([
          Scripted.complete("OK",
            usage: %{"input_tokens" => 200, "output_tokens" => 2, "cost_usd" => 0.001}
          )
        ])

      send(parent, {:continuation_provider, provider})
      provider
    end

    assert {:ok, %{"runs" => [run]}} =
             Trial.run([sample_case()],
               model: "test:model",
               arms: [:jev],
               provider_factory: factory,
               sdk_client: client,
               sdk_rates: %{"input_per_million" => 0.042, "output_per_million" => 0.0},
               cost_cap_usd: 0.1,
               reservation_per_run_usd: 0.02
             )

    assert run["jev_extension_attached"] == true
    assert run["transcript_preserved"] == true
    assert [%{"applied" => true}] = run["evaluations"]
    assert [%{"correct" => true}] = run["followups"]
    assert_receive {:continuation_provider, provider}
    assert [request] = Scripted.requests(provider)

    assert Enum.any?(request.entries, fn entry ->
             entry.type == :tool_result and
               String.contains?(entry.payload["output"], "rerun the tool")
           end)

    refute Code.ensure_loaded?(LemieuxComputerUse)
    Test.verify!(client)
    Test.close(client)
  end

  test "production defaults leave a recent required read untouched without calling Jev" do
    client = Test.client()

    assert {:ok, %{"runs" => [run]}} =
             Trial.run([sample_case()],
               model: "test:model",
               arms: [:jev],
               production_defaults: true,
               provider_factory: fn _, _, _ ->
                 Scripted.new([
                   Scripted.complete("OK",
                     usage: %{"input_tokens" => 200, "output_tokens" => 2, "cost_usd" => 0.001}
                   )
                 ])
               end,
               sdk_client: client,
               sdk_rates: %{"input_per_million" => 0.042, "output_per_million" => 0.0},
               cost_cap_usd: 0.1,
               reservation_per_run_usd: 0.02
             )

    assert run["jev_extension_attached"] == true
    assert run["transcript_preserved"] == true
    assert run["evaluations"] == []
    assert [%{"correct" => true}] = run["followups"]
    assert Test.requests(client) == []
    Test.close(client)
  end

  test "budget admission rejects the whole batch before any provider work" do
    assert {:error, :cost_cap_exceeded} =
             Trial.run([%{"id" => "sample"}],
               model: "test:model",
               arms: [:baseline, :shadow],
               repetitions: 3,
               provider_factory: fn _, _, _ -> flunk("provider was called") end,
               cost_cap_usd: 0.05,
               reservation_per_run_usd: 0.01
             )
  end

  test "missing provider usage stops the trial rather than producing a free run" do
    assert {:error, :incomplete_paid_usage, %{"runs" => []}} =
             Trial.run([sample_case()],
               model: "test:model",
               arms: [:baseline],
               provider_factory: fn _, _, _ -> Scripted.new([Scripted.complete("OK")]) end,
               sdk_rates: %{"input_per_million" => 0.042, "output_per_million" => 0.0},
               cost_cap_usd: 0.1,
               reservation_per_run_usd: 0.02
             )
  end

  test "a failed Jev call leaves its spending unknown and stops the trial" do
    client = Test.client()
    Test.stub_transport_error(client, :closed)

    assert {:error, :incomplete_paid_usage, %{"runs" => []}} =
             Trial.run([sample_case()],
               model: "test:model",
               arms: [:jev],
               provider_factory: fn _, _, _ ->
                 Scripted.new([
                   Scripted.complete("OK",
                     usage: %{"input_tokens" => 200, "output_tokens" => 2, "cost_usd" => 0.001}
                   )
                 ])
               end,
               sdk_client: client,
               sdk_rates: %{"input_per_million" => 0.042, "output_per_million" => 0.0},
               cost_cap_usd: 0.1,
               reservation_per_run_usd: 0.02,
               hook_opts: [min_saved_tokens: 1]
             )

    Test.verify!(client)
    Test.close(client)
  end

  test "a continuation may reread a changed file before answering" do
    case_data =
      sample_case()
      |> Map.put("mutations", %{"archive.ex" => "Current status: APPROVED."})
      |> Map.put("followups", [
        %{"prompt" => "Read archive.ex again and give its status.", "expected" => "APPROVED"}
      ])

    parent = self()

    factory = fn _, _, _ ->
      provider =
        Scripted.new([
          [
            {:tool_call, %{id: "reread-1", name: "read", arguments: %{"path" => "archive.ex"}}},
            {:usage, %{"input_tokens" => 200, "output_tokens" => 2, "cost_usd" => 0.001}},
            {:done, :tool_calls}
          ],
          Scripted.complete("APPROVED",
            usage: %{"input_tokens" => 220, "output_tokens" => 2, "cost_usd" => 0.001}
          )
        ])

      send(parent, {:continuation_provider, provider})
      provider
    end

    assert {:ok, %{"runs" => [%{"followups" => [%{"correct" => true, "usage" => usages}]}]}} =
             Trial.run([case_data],
               model: "test:model",
               arms: [:baseline],
               provider_factory: factory,
               sdk_rates: %{"input_per_million" => 0.042, "output_per_million" => 0.0},
               cost_cap_usd: 0.1,
               reservation_per_run_usd: 0.02
             )

    assert length(usages) == 2
    assert_receive {:continuation_provider, provider}
    assert [first, second] = Scripted.requests(provider)
    assert first.params[:max_tokens] == 256

    assert Enum.any?(second.entries, fn entry ->
             entry.type == :tool_result and entry.payload["output"] =~ "APPROVED"
           end)
  end

  defp sample_case do
    %{
      "id" => "obsolete_read",
      "category" => "goal_switch",
      "files" => [
        %{
          "path" => "archive.ex",
          "line_count" => 300,
          "target_line" => 250,
          "target_text" => "RELEASE_CODE=EMBER42"
        }
      ],
      "seed_reads" => ["archive.ex"],
      "must_keep_by_path" => %{"archive.ex" => false},
      "followups" => [%{"prompt" => "Ignore the file. Reply OK.", "expected" => "OK"}]
    }
  end
end
