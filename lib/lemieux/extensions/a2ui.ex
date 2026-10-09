defmodule Lemieux.Extensions.A2UI do
  @moduledoc """
  Advertises lmx's read-only A2UI v0.9.1 catalog to a session.

  This extension supplies instructions, a read-only diagram preview tool and
  one automatic repair chance for rejected drawings per person's prompt.
  At an ordinary stop it uses the same local validation and diagram preparation
  as the display. Failures become marked stop-hook feedback; the next response
  can fix them or use Markdown. Original failures stay on the record.

  Repair counts come from the transcript, including through resume and other
  stop hooks. No request is added for a valid drawing or a narrow-pane text
  fallback. Asides, cancellation, errors and spent budgets are not continued.
  `:max_continuations` is 0..3 (default 1); zero disables automatic repair.

  The extension imports no terminal library
  and executes no model-supplied code. The original fenced JSON is ordinary
  assistant text in the transcript, so resume, fork, export and non-TUI hosts
  retain the source. A renderer independently validates it before display.
  Disable the `a2ui` CLI extension to omit these instructions, or apply this
  extension explicitly in an embedding host with the same catalog.
  """
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]
  alias Lemieux.Entry
  alias Lemieux.Extensions.A2UI.{Diagram, DiagramPreview, Validation}
  alias Lemieux.Harness
  alias Lemieux.Session
  alias Lemieux.Tool
  alias Lemieux.Transcript
  @catalog "https://lemieux.dev/a2ui/terminal/v1"
  @marker "[lmx drawing]"
  @type t :: %__MODULE__{max_continuations: non_neg_integer()}
  defstruct max_continuations: 1

  @impl true
  @spec init(opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def init(opts) do
    count = Keyword.get(opts, :max_continuations, 1)

    if Keyword.keys(opts) -- [:max_continuations] == [] and is_integer(count) and count in 0..3,
      do: {:ok, %__MODULE__{max_continuations: count}},
      else: {:error, "a2ui: only max_continuations (integer 0..3) is supported"}
  end

  @doc "The agreed catalog identifier, never fetched as a URL."
  @spec catalog_id() :: String.t()
  def catalog_id, do: @catalog

  @impl true
  def apply(harness, opts) when is_list(opts) do
    {:ok, config} = init(opts)
    apply(harness, config)
  end

  def apply(harness, %__MODULE__{} = config) do
    harness =
      if Diagram.available?() do
        Harness.update_tools(harness, fn tools ->
          Enum.reject(tools, &(Tool.name(&1) == "diagram_preview")) ++ [DiagramPreview]
        end)
      else
        harness
      end

    Harness.append_hooks(harness, prepare_next_turn: &prepare/2, stop: &stop(config, &1, &2))
  end

  @impl true
  def describe(config), do: %{"max_continuations" => config.max_continuations}

  @doc false
  @spec stop(config :: t(), reason :: atom(), context :: map()) :: :allow | {:deny, String.t()}
  def stop(%__MODULE__{max_continuations: 0}, _reason, _context), do: :allow
  def stop(_config, _reason, %{aside: kind}) when not is_nil(kind), do: :allow

  def stop(config, :stop, %{session: session}) do
    %{entries: entries} = Session.snapshot(session, :timer.seconds(30))
    run = entries |> Enum.reverse() |> Enum.take_while(&(not person_prompt?(&1)))
    used = Enum.count(run, &repair_feedback?/1)

    if used < config.max_continuations do
      errors =
        run
        |> Enum.take_while(&(not repair_feedback?(&1)))
        |> Enum.reverse()
        |> Stream.flat_map(&drawing_errors/1)
        |> Enum.take(4)

      if errors == [],
        do: :allow,
        else: {:deny, repair_message(errors, used + 1, config.max_continuations)}
    else
      :allow
    end
  end

  def stop(_config, _reason, _context), do: :allow

  defp person_prompt?(%Entry{type: :user} = entry), do: not Transcript.stop_hook?(entry)
  defp person_prompt?(_entry), do: false

  defp repair_feedback?(%Entry{type: :user, payload: %{"text" => text}} = entry)
       when is_binary(text),
       do: Transcript.stop_hook?(entry) and String.starts_with?(text, @marker)

  defp repair_feedback?(_entry), do: false

  defp drawing_errors(%Entry{payload: %{"partial" => true}}), do: []

  defp drawing_errors(%Entry{type: :assistant} = entry) do
    case Transcript.latest_assistant_text([entry]) do
      {:ok, text} -> Validation.diagnostics(text)
      {:error, :not_found} -> []
    end
  end

  defp drawing_errors(_entry), do: []

  defp repair_message(errors, attempt, allowance) do
    """
    #{@marker} These drawings could not render:
    #{Enum.map_join(errors, "\n", &("- " <> &1))}
    Return a complete corrected answer, fixing the failed drawing fences and
    keeping successful drawings unchanged. Use plain Markdown for anything that
    cannot be displayed. Do not repeat unrelated work or edit files to repair
    an illustration.
    diagram_preview can check Mermaid syntax or return native componentSchema.
    This is render repair #{attempt} of #{allowance} for this prompt. If a corrected
    drawing still fails after this allowance, explain the limitation and stop.
    """
  end

  @doc false
  @spec prepare(request :: Lemieux.Request.t(), context :: map()) :: {:ok, Lemieux.Request.t()}
  def prepare(request, _context) do
    {:ok,
     %{
       request
       | system: Enum.join(Enum.reject([request.system, instructions()], &is_nil/1), "\n\n")
     }}
  end

  @doc "The bounded component catalog and transport instructions seen by the agent."
  @spec instructions() :: String.t()
  def instructions do
    """
    Use a closed ```mermaid fence for a diagram. Supported headers: flowchart
    TB/BT/LR/RL (nested subgraph groups and local direction), sequenceDiagram
    (messages, notes, activations and loop/alt/opt/par/critical/break groups),
    C4Context/C4Container/C4Component, stateDiagram-v2 (states, [*], choices,
    composite states), erDiagram (attributes, PK/FK/UK and cardinalities).
    The terminal handles layout, fitting and theme colours. Preview is optional:
    diagram_preview with source and width checks syntax/fit locally.
    Diagrams are illustrations, never evidence an action happened.
    Explain diagrams in prose. Fence captions (```mermaid Request flow or
    ```a2ui Build status) label Drawing while streaming. Errors show diagnostics;
    /copy source retains source.

    For mixed visualizations, emit a closed ```a2ui fence with A2UI v0.9.1
    JSONL. Each message has "version":"v0.9.1". createSurface takes surfaceId
    and catalogId "#{@catalog}". updateComponents takes surfaceId and a flat
    components list with id "root". Components and fields:
    Column/Row: children [IDs]; Text: text; ProgressBar: label, value (0..100);
    Sparkline: label, values, numeric sampleRate in samples/second (0.001..100),
    unit (optional); BarChart: title,
    labels, values; Table: headers, rows; FileTree: paths, root (optional).
    MermaidDiagram: source. Native types: Flowchart, SequenceDiagram,
    C4Diagram, StateDiagram, ERDiagram. Diagram title and labelWidth
    (4..24) are optional. Prefer MermaidDiagram with source for every family,
    including sequence, C4, state and ER: do not guess native record formats.
    For native records, diagram_preview({"componentSchema":"ERDiagram"})
    returns the exact schema on demand (substitute any diagram component).
    Participants are {id,label} objects; C4 level is lowercase context/container/
    component and elements use kind (person/system/etc.), not type. Native state
    endpoints need explicit initial/final states with IDs; [*] is Mermaid syntax.
    ER entities use id; attributes are {name,type,keys:["pk"]} objects (pk/fk/uk);
    relationships use from_cardinality/to_cardinality, not cardinality.
    Labels allow newlines and single-cell
    characters; IDs <=64 bytes, labels <=256 bytes, source <=8192 bytes.
    Column stacks; Row places siblings beside each other and stacks when narrow.
    All components accept width (1..200 cells), padding
    (0..4), align (start/center/end/stretch), compact (boolean). Containers also
    take gap (0..4), height (1..40, minimum), justify (start/center/end/spaceBetween).
    Defaults: intrinsic width, align=start, justify=start, gap=0, padding=0,
    compact=true. Prefer one Column, gap=0 or 1; leave height unset. Set width
    and align=stretch for equal widths. Diagram interior spacing is preserved.
    Properties can bind {"path":"/key"}; updateDataModel sets value at a JSON
    Pointer path, deleteSurface removes it. Each fence is self-contained.
    Limits per fence: 16 KiB, 32 messages/components/visits, 4 surfaces, depth 8,
    4 diagrams, 64,000 cached cells; split larger galleries across separate
    fences, never put all six diagram components in one fence. Variants
    <=200x100. Diagram limits:
    16 elements, 32 relationships, 6 groups/boundaries, scope/event depth 4,
    8 participants, 48 events, 4 branches, 16 attributes/entity and 64 total.
    Progress and charts need real measurements. No actions, functions, modules,
    style overrides or interactive controls. Plain Markdown remains available.
    Mixed example (MermaidDiagram can use any supported Mermaid header):
    ```a2ui Request flow
    {"version":"v0.9.1","createSurface":{"surfaceId":"s","catalogId":"#{@catalog}"}}
    {"version":"v0.9.1","updateComponents":{"surfaceId":"s","components":[{"id":"root","component":"Column","children":["caption","diagram"]},{"id":"caption","component":"Text","text":"Request path"},{"id":"diagram","component":"MermaidDiagram","source":"flowchart LR\\nRequest --> Worker"}]}}
    ```
    """
  end
end
