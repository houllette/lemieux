defmodule Lemieux.Ingress do
  @moduledoc """
  A runtime host attestor for input and approval ingress.

  A claim is untrusted client data. Only the attestor installed by the host
  at session start can classify it; the caller PID and operation context come
  from the session. An implementation verifies its own authentication and
  channel contract, returning bounded opaque actor/channel references. Neither
  a user-role entry nor clicking a control establishes a human identity.

  The callback must be bounded and local: authenticate remote traffic before
  it enters the session, then verify the resulting evidence here. Return only
  safe references, never credentials, signatures, prompts or raw identities.
  This is a trusted-code seam, not a security boundary against arbitrary code
  running inside the same BEAM. It is never restored from a transcript.
  """

  @derive {Inspect, only: [:module]}
  defstruct [:module, :state]

  @type t :: {module(), term()} | %__MODULE__{} | nil
  @type source :: :unknown | :direct_interactive | :host_rpc | :extension_injected
  @type attestation :: %{
          optional(:actor) => String.t(),
          optional(:channel) => String.t(),
          source: source()
        }
  @callback attest(
              state :: term(),
              caller :: pid(),
              operation :: :input | :approval,
              claim :: term(),
              context :: map()
            ) :: {:ok, attestation()} | {:error, term()}

  @doc false
  @spec option(value :: term()) :: t()
  def option(nil), do: nil

  def option({module, _state} = value) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :attest, 5),
      do: %__MODULE__{module: module, state: elem(value, 1)},
      else: raise(ArgumentError, ":ingress requires a host attest/5 implementation")
  end

  def option(_invalid), do: raise(ArgumentError, ":ingress requires {module, state}")

  @doc false
  @spec unknown() :: map()
  def unknown,
    do: %{version: 1, source: :unknown, attested?: false, ingress: nil, actor: nil, channel: nil}

  @doc false
  @spec attest(
          attestor :: t(),
          caller :: pid(),
          operation :: atom(),
          claim :: term(),
          context :: map()
        ) ::
          {:ok, map()} | {:error, :unattested}
  def attest(_attestor, _caller, _operation, nil, _context), do: {:ok, unknown()}
  def attest(nil, _caller, _operation, _claim, _context), do: {:error, :unattested}

  def attest(%__MODULE__{module: module, state: state}, caller, operation, claim, context) do
    if :erlang.external_size(claim) <= 4_096 do
      case module.attest(state, caller, operation, claim, context) do
        {:ok, %{source: source} = metadata}
        when source in [:unknown, :direct_interactive, :host_rpc, :extension_injected] ->
          safe_metadata(module, source, metadata)

        _unattested ->
          {:error, :unattested}
      end
    else
      {:error, :unattested}
    end
  end

  @doc false
  @spec audit(metadata :: map()) :: map()
  def audit(metadata),
    do: %{
      "version" => 1,
      "source" => Atom.to_string(metadata.source),
      "attested" => metadata.attested?,
      "ingress" => metadata.ingress,
      "actor" => metadata.actor,
      "channel" => metadata.channel
    }

  defp safe_metadata(module, source, metadata) do
    actor = Map.get(metadata, :actor)
    channel = Map.get(metadata, :channel)

    if safe_reference?(actor) and safe_reference?(channel),
      do:
        {:ok,
         %{
           version: 1,
           source: source,
           attested?: true,
           ingress: Atom.to_string(module),
           actor: actor,
           channel: channel
         }},
      else: {:error, :unattested}
  end

  defp safe_reference?(nil), do: true

  defp safe_reference?(value),
    do: is_binary(value) and byte_size(value) <= 128 and String.valid?(value)
end
