defmodule Lemieux.Providers.ReqLLMIdleConfigTest do
  # Application environment is global, so this cannot run beside the tests
  # whose streams would read it.
  use ExUnit.Case, async: false

  alias Lemieux.Providers.ReqLLM, as: ReqLLMProvider

  setup do
    previous = Application.fetch_env(:req_llm, :stream_idle_timeout)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:req_llm, :stream_idle_timeout, value)
        :error -> Application.delete_env(:req_llm, :stream_idle_timeout)
      end
    end)
  end

  # req_llm reads `:stream_idle_timeout` from its application environment
  # when no option names one; a default option would override a host's
  # `config :req_llm, stream_idle_timeout: ...`.
  test "a stream idle timeout configured for req_llm is not overridden" do
    Application.put_env(:req_llm, :stream_idle_timeout, 42_000)

    {_module, state} = ReqLLMProvider.new()

    assert state.options[:receive_timeout] == :infinity
    refute Keyword.has_key?(state.options, :stream_idle_timeout)
  end
end
