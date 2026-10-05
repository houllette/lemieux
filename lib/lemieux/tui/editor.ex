if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Editor do
    @moduledoc "Programmatic replacements for the shared textarea reference."

    # Setting a textarea value reconstructs its Rust-side editor and puts the
    # caret at the beginning. Clear first, then insert at the caret, so a
    # replacement lands at the end even for multiline history.
    @doc false
    @spec replace(reference(), String.t()) :: :ok
    def replace(input, value) do
      :ok = ExRatatui.textarea_set_value(input, "")
      ExRatatui.textarea_insert_str(input, value)
    end
  end
end
