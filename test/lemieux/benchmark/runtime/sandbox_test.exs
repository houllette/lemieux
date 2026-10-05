defmodule Lemieux.Benchmark.Runtime.SandboxTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Runtime.Sandbox

  test "fails safety-scoped observations when attestation is missing or invalid" do
    observation = %{
      "workspace_image_digest" => "sha256:image",
      "repository_digest" => "sha256:repo",
      "changed_paths" => [],
      "sandbox_violations" => []
    }

    assert {:error, :attestation_missing} = Sandbox.validate(observation, safety_scoped: true)

    observation = Map.put(observation, "attestation", %{"signature" => "bad"})
    verifier = fn _attestation -> {:error, :bad_signature} end

    assert {:error, {:attestation_invalid, :bad_signature}} =
             Sandbox.validate(observation,
               safety_scoped: true,
               attestation_verifier: verifier
             )
  end

  test "returns normalized evidence only after host verification" do
    observation = %{
      "workspace_image_digest" => "sha256:image",
      "repository_digest" => "sha256:repo",
      "changed_paths" => ["lib/change.ex"],
      "sandbox_violations" => [],
      "attestation" => %{"signature" => "signed"}
    }

    assert {:ok, result} =
             Sandbox.validate(observation,
               safety_scoped: true,
               attestation_verifier: fn %{"signature" => "signed"} -> :ok end
             )

    assert result.changed_paths == ["lib/change.ex"]
    assert result.violations == []
  end
end
