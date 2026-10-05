defmodule Lemieux.MCP.CredentialsTest do
  use ExUnit.Case, async: true

  alias Lemieux.MCP

  describe "expanding a configuration about to be used" do
    test "replaces a variable with what the environment says" do
      System.put_env("LEMIEUX_TEST_TOKEN", "sekrit")
      on_exit(fn -> System.delete_env("LEMIEUX_TEST_TOKEN") end)

      assert {:ok, %{"authorization" => "Bearer sekrit"}} =
               MCP.expand(%{"authorization" => "Bearer ${LEMIEUX_TEST_TOKEN}"})
    end

    test "reaches into lists and nested values" do
      System.put_env("LEMIEUX_TEST_ARG", "value")
      on_exit(fn -> System.delete_env("LEMIEUX_TEST_ARG") end)

      assert {:ok, ["--flag", "value"]} = MCP.expand(["--flag", "${LEMIEUX_TEST_ARG}"])
    end

    # Otherwise the request goes out with the literal text where a credential
    # should be, and the server answers 401 for reasons nobody can see.
    test "a variable that is not set is an error naming it" do
      assert {:error, message} = MCP.expand(%{"authorization" => "${LEMIEUX_NOT_SET_ANYWHERE}"})
      assert message =~ "LEMIEUX_NOT_SET_ANYWHERE"
    end

    test "leaves anything without a variable alone" do
      assert {:ok, "plain"} = MCP.expand("plain")
      assert {:ok, 42} = MCP.expand(42)
    end
  end

  describe "what is written down" do
    # The transcript keeps the reference, never the secret: a token expanded
    # before recording would be a credential on disk, in a file kept to be
    # read later.
    test "a configuration records the variable, not its value" do
      System.put_env("LEMIEUX_TEST_TOKEN", "sekrit")
      on_exit(fn -> System.delete_env("LEMIEUX_TEST_TOKEN") end)

      config =
        MCP.config(%{
          "name" => "x",
          "headers" => %{"authorization" => "Bearer ${LEMIEUX_TEST_TOKEN}"}
        })

      assert config["headers"]["authorization"] == "Bearer ${LEMIEUX_TEST_TOKEN}"
      refute inspect(config) =~ "sekrit"
    end
  end
end
