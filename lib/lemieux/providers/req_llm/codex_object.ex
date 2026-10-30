defmodule Lemieux.Providers.ReqLLM.CodexObject do
  @moduledoc false

  alias ReqLLM.Output
  alias ReqLLM.Output.Validation
  alias ReqLLM.Provider.Options
  alias ReqLLM.Providers.OpenAICodex

  # ReqLLM 1.29's stream_object/4 copies every prepared Req option into
  # generation options. Codex's private :openai_codex_model then fails public
  # option validation before HTTP starts (#113). Keep ReqLLM's own schema
  # preparation, transport, decoder and output validation; remove only that
  # copied private option at the preparation/streaming boundary. Caller options
  # still pass through prepare_request/4 first, so unknown input is rejected.
  # Remove this bridge when the minimum ReqLLM version fixes that boundary.
  @spec stream(
          model :: LLMDB.Model.t(),
          context :: ReqLLM.Context.t(),
          schema :: term(),
          options :: keyword()
        ) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, term()}
  def stream(model, context, schema, options) do
    descriptor = Output.object(schema)
    options = Keyword.delete(options, :output)

    with {:ok, config, options} <- Validation.take_runtime_options(options),
         {:ok, options} <-
           Options.normalize_namespaced_provider_options(OpenAICodex, :object, model, options),
         :ok <- ReqLLM.ProviderFileReference.validate_context(context, model.provider),
         {:ok, compiled} <- ReqLLM.Schema.compile(schema),
         {:ok, prepared} <-
           OpenAICodex.prepare_request(
             :object,
             model,
             context,
             Keyword.put(options, :compiled_schema, compiled)
           ) do
      stream_options =
        options
        |> Keyword.merge(prepared.options |> Map.to_list() |> Keyword.delete(:openai_codex_model))
        |> Keyword.put(:stream, true)
        |> Keyword.put_new(:operation, :object)
        |> Keyword.put(:compiled_schema, compiled)

      contract = Validation.validation_contract(descriptor, compiled)

      OpenAICodex
      |> ReqLLM.Streaming.start_stream(
        model,
        prepared.options[:context] || context,
        stream_options
      )
      |> Validation.attach_stream_result(contract, config)
    end
  end
end
