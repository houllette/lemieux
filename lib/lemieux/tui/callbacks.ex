defmodule Lemieux.TUI.Callbacks do
  @moduledoc """
  Stable defaults held in TUI state. Keep these outside the screen module:
  replacing render/event code must not invalidate a stored local function.
  OTP soft purge ignores indirect fun references. Clipboard captures transport
  here; changing this module requires restart while that callback is retained.
  """

  alias Lemieux.TUI.ExternalEditor
  alias Lemieux.TUI.ImagePaste

  @doc false
  @spec clock() :: integer()
  def clock, do: System.monotonic_time(:millisecond)

  @doc false
  @spec title(text :: String.t()) :: :ok
  def title(_text), do: :ok

  # ExRatatui's `test_mode` draws on a headless terminal nobody is looking
  # at. A notification or clipboard write from there lands on whatever
  # terminal is running the tests (the OSC 9 escapes a TUI test run used to
  # print), and a native clipboard tool would overwrite the developer's own
  # clipboard. A headless screen gets this default instead; a test that
  # wants the real effect passes its own callback.
  @doc false
  @spec inert(text :: String.t()) :: :ok
  def inert(_text), do: :ok

  @doc false
  @spec clipboard(transport :: term()) :: (String.t() -> term())
  def clipboard(transport), do: fn text -> Lemieux.Clipboard.copy(text, transport) end

  @doc false
  @spec notify(transport :: term()) :: (String.t() -> term())
  def notify(transport), do: fn text -> Lemieux.Terminal.notify(text, transport) end

  # Only the local transport has a terminal this process can hand to an
  # editor: a session transport draws on somebody else's screen, where
  # `/dev/tty` is not theirs. `nil` makes the key say so rather than open an
  # editor on the wrong machine.
  @doc false
  @spec editor(transport :: term(), opts :: keyword()) ::
          (String.t() -> {:ok, String.t()} | {:error, term()}) | nil
  def editor(:local, opts) do
    mouse? = Keyword.get(opts, :mouse_capture, true) != false
    fn text -> ExternalEditor.edit(text, mouse?: mouse?) end
  end

  def editor(_transport, _opts), do: nil

  # The clipboard read is the local machine's for the same reason.
  @doc false
  @spec paste_image(transport :: term()) :: (-> {:ok, binary()} | {:error, term()}) | nil
  def paste_image(:local), do: &ImagePaste.capture/0
  def paste_image(_transport), do: nil
end
