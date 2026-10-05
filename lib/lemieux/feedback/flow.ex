defmodule Lemieux.Feedback.Flow do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  The deliberately manual first feedback-to-asset proof.

  This coordinator performs no model call and runs no automatic experiment. It
  freezes an eligible case and creates an immutable, unapproved asset proposal;
  `approve/3` records a human actor before moving a pure activation pointer.
  Keeping these steps explicit is what lets a later durable host replace the
  in-memory projection without creating a privileged shortcut around review.
  """

  alias Lemieux.Asset.Proposal
  alias Lemieux.Asset.Registry
  alias Lemieux.Asset.Version
  alias Lemieux.Feedback
  alias Lemieux.Feedback.CaseDraft

  @type t :: %__MODULE__{
          feedback: Feedback.t(),
          case_draft: CaseDraft.t(),
          proposal: Proposal.t()
        }

  @enforce_keys [:feedback, :case_draft, :proposal]
  defstruct [:feedback, :case_draft, :proposal]

  @doc "Freezes a case and creates an unapproved asset proposal."
  @spec prepare(feedback :: Feedback.t(), case_opts :: keyword(), asset_attrs :: map()) ::
          {:ok, t()} | {:error, term()}
  def prepare(%Feedback{} = feedback, case_opts, asset_attrs)
      when is_list(case_opts) and is_map(asset_attrs) do
    attrs =
      Map.update(
        asset_attrs,
        :motivating_feedback_ids,
        [feedback.id],
        &Enum.uniq([feedback.id | &1])
      )

    with {:ok, source_dir} <- required(case_opts, :source_dir),
         {:ok, output_dir} <- required(case_opts, :output_dir),
         {:ok, draft} <- CaseDraft.create(feedback, source_dir, output_dir, case_opts),
         {:ok, version} <- Version.new(attrs) do
      {:ok,
       %__MODULE__{
         feedback: feedback,
         case_draft: draft,
         proposal: Proposal.new(version)
       }}
    end
  end

  @doc "Records human approval and activates the proposed immutable version."
  @spec approve(flow :: t(), actor :: map(), registry :: Registry.t()) ::
          {:ok, t(), Registry.t(), Registry.activation()} | {:error, term()}
  def approve(%__MODULE__{} = flow, actor, %Registry{} = registry) when is_map(actor) do
    with {:ok, proposal} <- Proposal.approve(flow.proposal, actor),
         {:ok, registry, activation} <- Registry.activate(registry, proposal) do
      {:ok, %{flow | proposal: proposal}, registry, activation}
    end
  end

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _invalid -> {:error, {:missing_flow_option, key}}
    end
  end
end
