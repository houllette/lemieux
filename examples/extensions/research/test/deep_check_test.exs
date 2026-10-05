defmodule ResearchExtension.DeepCheckTest do
  use ExUnit.Case, async: true

  @script Path.expand("../bench/fixtures/workspace/deep_check.exs", __DIR__)

  @cases [
    {"beam-maintenance",
     "Elixir Task.yield_many/2 no longer waits indefinitely when :limit exceeds the task count. OTP beam_lib error filenames changed from atom to a list of characters.",
     "Elixir Task.yield_many/2 was fixed. OTP beam_lib still returns an atom filename."},
    {"postgres-logical-upgrade",
     "The output_plugin_libraries defaults are pgoutput and test_decoding. pg_upgrade --check fails if the new cluster has not allowed the old slot's custom plugin. 18.5 was skipped after a post-wrap regression.",
     "output_plugin_libraries includes pgoutput, but not the custom plugin; 18.5 was skipped after a regression."},
    {"kubernetes-136-upgrade",
     "UnknownVersionInteroperabilityProxy is beta and enabled by default. Service.spec.externalIPs is deprecated and Kubernetes warns when it is used in v1.36. kube-proxy opt-out is v1.40 at the earliest, with final removal in v1.43 at the earliest.",
     "UnknownVersionInteroperabilityProxy is beta and enabled by default. Service.spec.externalIPs is deprecated with warnings in 1.36 and removal in 1.40."},
    {"python-315-rc2",
     "Python 3.15.0rc2 was released 2026-09-01; PEP 790 schedules final for 2026-10-01. There will be no further ABI changes; wheels built against the RC will work with the final release. It is not recommended for production.",
     "Python 3.15.0rc2 was released 2026-09-01; final is scheduled for 2026-10-01. Wheels are available, but production is not recommended."}
  ]

  for {id, correct, incomplete} <- @cases do
    test "#{id} accepts the complete answer and rejects a near miss" do
      id = unquote(id)
      correct = unquote(correct)
      incomplete = unquote(incomplete)

      assert {"pass\n", 0} = run_grader(id, correct)
      assert {_message, 1} = run_grader(id, incomplete)
    end
  end

  test "accepts the iterative arm's JSON envelope" do
    answer =
      "Elixir Task.yield_many/2 no longer hangs. OTP beam_lib error filenames changed from atom to charlist."

    assert {"pass\n", 0} =
             run_grader(
               "beam-maintenance",
               JSON.encode!(%{"answer" => answer, "citations" => []})
             )
  end

  defp run_grader(id, answer) do
    System.cmd("elixir", [@script, id, answer],
      cd: Path.dirname(@script),
      stderr_to_stdout: true
    )
  end
end
