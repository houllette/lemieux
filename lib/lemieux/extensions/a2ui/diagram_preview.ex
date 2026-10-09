defmodule Lemieux.Extensions.A2UI.DiagramPreview do
  @moduledoc """
  A read-only syntax and fit check for the same diagrams the TUI renders.

  No terminal, filesystem, browser or model request is involved. Width is the
  caller's target content width, not a claim about an attached terminal. The
  result describes renderability, never proof that an illustrated action ran.
  """
  @behaviour Lemieux.Tool
  alias Lemieux.Extensions.A2UI.{Diagram, DiagramSchema}
  alias Lemieux.Tool.Result

  @impl true
  def name, do: "diagram_preview"
  @impl true
  def description,
    do:
      "Optional local diagram syntax/fit check. Prefer Mermaid source; native diagram components are accepted. Request componentSchema for the exact native record format, without rendering. Preview returns plaintext at width (default 80). Checks an illustration, not whether its actions happened."

  @impl true
  def read_only?, do: true
  @impl true
  def parallel_safe?, do: true
  @impl true
  def metadata, do: %{effects: %{class: "read", resource_types: []}, policy: %{approval: "never"}}
  @impl true
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "oneOf" => [
        %{"required" => ["source"]},
        %{"required" => ["diagram"]},
        %{"required" => ["componentSchema"], "not" => %{"required" => ["width"]}}
      ],
      "properties" => %{
        "source" => %{
          "type" => "string",
          "maxLength" => 8192,
          "description" => "Mermaid source, including its family header."
        },
        "diagram" => %{
          "type" => "object",
          "maxProperties" => 16,
          "required" => ["component"],
          "properties" => %{"component" => %{"enum" => Diagram.types()}},
          "description" =>
            "Native component; request componentSchema for its exact fields if needed."
        },
        "componentSchema" => %{
          "enum" => Diagram.types(),
          "description" => "Return this native component's JSON Schema only."
        },
        "width" => %{"type" => "integer", "minimum" => 1, "maximum" => 200}
      }
    }
  end

  @impl true
  def run(%{"componentSchema" => type} = args, _context) when map_size(args) == 1 do
    case Map.fetch(DiagramSchema.schemas(), type) do
      {:ok, schema} ->
        {:ok, Result.new(JSON.encode!(schema), structured_content: %{"schema" => schema})}

      :error ->
        {:error, "Unknown diagram componentSchema."}
    end
  end

  def run(%{"source" => source} = args, context) when not is_map_key(args, "diagram"),
    do:
      run(
        Map.put(Map.delete(args, "source"), "diagram", %{
          "component" => "MermaidDiagram",
          "source" => source
        }),
        context
      )

  def run(%{"diagram" => node} = args, _context) when not is_map_key(args, "source") do
    width = Map.get(args, "width", 80)

    if is_integer(width) and width in 1..200 and Map.keys(args) -- ~w(diagram width) == [],
      do: preview(node, width),
      else: {:error, "width must be 1..200 terminal cells; unknown arguments are not supported"}
  end

  def run(_args, _context),
    do: {:error, "provide exactly one of source, diagram or componentSchema"}

  defp preview(node, width) do
    case Diagram.prepare(node) do
      {:ok, prepared} ->
        variant = Diagram.select(prepared, width)
        dimensions = Enum.map(prepared.variants, &%{"width" => &1.cols, "height" => &1.rows})

        data = %{
          "valid" => true,
          "family" => prepared.family,
          "fits" => variant != nil,
          "targetWidth" => width,
          "variants" => dimensions,
          "summary" => prepared.summary,
          "preview" => if(variant, do: variant.frame.text, else: nil)
        }

        status =
          if variant,
            do: "Complete diagram fits: #{variant.cols}x#{variant.rows} cells.",
            else:
              "A complete diagram does not fit #{width} cells; the TUI will show the relationships as text."

        {:ok,
         Result.new(
           status <>
             "\n" <> prepared.summary <> if(variant, do: "\n\n" <> variant.frame.text, else: ""),
           structured_content: data
         )}

      {:error, reason} ->
        {:error, reason}

      :error ->
        {:error, "This host has no native diagram support; add the optional :ascii dependency."}
    end
  end
end
