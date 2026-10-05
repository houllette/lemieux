# Customizing the terminal UI

How `lmx`'s full-screen interface is built and how a host changes it: what
the screen does, the seams a host replaces (status line, panes, follow-up
hint, themes, keys, tool receipts, slash commands, approvals), how a host
starts it, and testing it without a terminal. For using the interface, start
with [Everyday use](everyday.md) and the [CLI reference](cli.md#terminal-ui).
Native packaging is in [Installing and updating lmx](releases.md). The
[glossary](index.md#words-you-will-meet) defines host, harness, extension,
receipt and the other terms used here.

Settings you can change without Elixir: [themes](#adding-a-theme) and
[keys](#rebinding-keys). For an extension or an embedding host: the [status
line](#replacing-the-status-line), the [layout](#rearranging-the-panes), [tool
receipts](#replacing-a-tool-receipt), [slash commands](#adding-a-slash-command)
and the [start options](#starting-the-screen-from-a-host). [Testing it without
a terminal](#testing-it-without-a-terminal) covers how to check those changes.

## What it is

The screen is built on [`ex_ratatui`](https://hexdocs.pm/ex_ratatui): Elixir
bindings to [ratatui](https://ratatui.rs), the Rust terminal-UI library, over
a Rustler NIF. `ex_ratatui` is not a line editor or a curses wrapper: it is
an immediate-mode widget toolkit. You hand it a list of `{widget, rect}` on
every frame and it diffs and paints.

Two runtimes sit on top of the raw drawing API:

- **Callback** (`use ExRatatui.App`): `mount/1`, `render/2`, `handle_event/2`,
  `handle_info/2`, `terminate/2`. LiveView's shape, and OTP-supervised.
- **Reducer** (`use ExRatatui.App, runtime: :reducer`): `init/1`, `update/2`,
  `subscriptions/1`. Elm's shape.

Lemieux uses the **callback** runtime because of `handle_info/2`. A session is
a `GenServer` that broadcasts `{:lemieux, id, event}` to its subscribers, and
the callback runtime's `handle_info/2` receives exactly that with no adapter
in between.

The screen must be one subscriber, not the only one. An embedding host can
watch the same session by capturing its observer pid in the arity-zero start
callback:

```elixir
observer = self()

Lemieux.TUI.start_link(
  start: fn ->
    Lemieux.start_session(subscriber: [self(), observer], ...)
  end
)
```

Inside the callback, `self()` is the screen's process. A restarted observer
can call `Lemieux.Session.subscribe/2` after reading the transcript for the
entries it missed.

## Interaction model

The screen opens with a short full-screen animation (Go Habs Go) while
workspace discovery, Ixway discovery and the recent-session list run in
supervised tasks. The animation gives way to the conversation as soon as the
session and its skills, commands and status settings are ready; a selected
Ixway model still needs its key-scoped catalogue first. The screen never
waits on MCP servers: they connect in the background, and the session's
`{:mcp_server, …}` and `{:ready, …}` events drive a `connecting NAME…` status
and one line in the notice box when they settle (a failed server, or one that
needs sign-in, gets its own). Keys and paste edit the input while it loads,
and Enter queues the draft until the session is ready.

What the screen says about its own setup goes to a notice box at the top
rather than into the transcript: the permission banner, a line saying that
`/undo` covers file-tool edits only where what commands change cannot be
recorded, workspace and configuration notices, which MCP servers connected
or could not, and update and version news, including a line after an update
with a link to that release's changelog. The box closes ten seconds after
its newest line, or at once on Esc, and stays open while a panel is open. A
click on a line with a link opens it. What answers something you did stays
in the transcript, where it can be found later: a start that failed, a
session that stopped, a command's result. `Lemieux.TUI.Notices` has the
rules.

A startup error is described in the transcript, where it can be read before
quitting; `/model` and `/provider` start the session again on a new choice,
and `/quit` always works. When the host passes a `:first_run` description (no
usable key), a panel asks for a provider and its key first. `lmx`'s panel
preselects a provider only when you named a model or resumed a session whose
provider has no key, offers a local Ollama model that can call tools when one
is running, and marks providers whose key is already set. Esc closes it,
says that no key was saved, and names the `/provider` switches that work
without one. When the host passes `:mcp_trust` for an untrusted repository
`.mcp.json`, a panel lists each server's command or URL and the variable names
it reads, and asks. The screen monitors the session process: a crash becomes a
notice row, and Enter on an empty line resumes the session. The installed
binary's update check and local Ollama discovery run after the screen opens.

The header reads `lemieux (vX) · DIR · NAME · PROVIDER · MODEL · effort E`.
DIR is the session's working directory, with your home shown as `~`; past 32
columns every directory but the last is cut to its first letter
(`~/Documents/work/lemieux` becomes `~/D/w/lemieux`), and a path longer still
becomes `…/lemieux`. NAME is the session's name, such as `wayne-gretzky`
([session names](cli.md#session-is-an-id-or-a-name)), never its opaque id;
the name is what `--resume`, `/resume SESSION` and `lmx log` accept. The same
name and directory go into the terminal's window and tab title as
`lmx | NAME | DIR`, through OSC 0, so a row of tabs says which session each
holds. Control characters and invalid UTF-8 in a directory name are shown as
`?` in both. The title is cleared on the way out. It is written by the host
rather than the screen: `Lemieux.CLI.TUI` supplies the writer, and an
embedder that does not gets no escape sequences written to a stream it owns.

`/name TEXT` overrides that label, in the header and in the tab, until you
quit. It is a caption, not a handle: nothing is stored, `--resume`
still takes the id or the derived name, and resuming another session drops
it.

Typing `@` re-reads the files this conversation attached and re-attaches any
that changed on disk, at most once every ten seconds, and is silent unless
something moved. The `@` picker also offers the resources connected MCP
servers publish, as `@server:uri`, beside files once something is typed after
the `@`; a colon in the query puts them first. They are listed in a task (on
the first `@` query, when the session reports it is ready, and when a server
says its resources changed), so a slow server never holds a key press
(`Lemieux.TUI.ResourceIndex`). A re-read on `@` re-reads an attached resource
from its server the same way it re-reads a file.

The transcript's horizontal rails are cyan in the normal coding profile and
magenta in Elixir mode, and `/color COLOUR` overrides both until you quit,
taking any of the terminal's named colours or a `#rrggbb` value; it also
recolours the highlighted completion. There are deliberately no side borders
beside transcript text, so text copied with the terminal's own selection comes
out clean. `/elixir` switches the live session between the host's standard
tools and the Elixir evaluator without starting a new session.

`/mcp` opens a compact panel showing configured servers, their transport,
tool counts and state: connecting, connected, needs sign-in, or failed with
its error. Up and Down select a server, `r` reconnects it (which opens the
browser for a server that needs sign-in), `o` turns it on or off for this
session, `a` adds a server through a tabbed questionnaire, and `d` twice
removes it from this session. Shift-D twice deletes the selected server from
its config file and this session. The questionnaire uses the same question
and review tabs as `ask_user`: choose HTTP or stdio, paste the URL or command
and any optional fields, and choose where to save it, your own
`"mcp_servers"` (the default) or the repository's `.mcp.json`. A header or
environment value that looks secret is saved as a `${NAME}` reference and
exported for this process, never written as typed. Results stay in the panel;
Esc returns to the conversation.

The status line below the input box reports the context position, the
session's usage and its cost as each becomes known, the permission mode when
permissions are on, and `req N/M` when the host set a request cap. It is
drawn in the theme's text colour. A compaction adds a row to the transcript,
such as `· summarised the earlier conversation (24 entries) · last request
128.4k tok`, and the status line shows `context ?` until the next provider
response measures the new request. Automatic compaction starts at 80% of the
context window by default, measured against at most 200,000 tokens of it for
very large windows (the session's `compaction_window_cap`). Within ten
percentage points of that mark, the row shows the remaining distance.
`"auto_compaction": false` in `~/.lmx/config.json` turns automatic compaction
and its warning off.

For an Ixway subscription route, a later receipt may update the **estimated
cost** in the status line. `/context` shows its reference provider, source,
exclusions, or unknown reason. This API equivalent is illustrative at current
catalog rates; measured API cost and budget accounting stay separate. See
[Ixway accounting](ixway.md#accounting-boundary).

Delegated children's usage joins both totals as the children report it,
request by request, so a fan-out's cost is visible while it runs and survives
a cancellation. It never changes the parent's context position: a child has
its own transcript, and nothing it read is in the parent's next request.

Closing the terminal ends the screen and stops any command the agent was
running, with the turn recorded as cancelled; see [Signals and closed
terminals](cli.md#signals-and-closed-terminals).

### The live row

While a request or a batch of tool calls is running, the last row of the
transcript is a turning spinner and a label with the elapsed time, and beside
it what the session is doing right now and for how long: `waiting for the
model (6s)`, `thinking (40s)`, `answering`, `composing write tmp/analysis.md
(18.2 KB)` while the model is still writing a tool call, `running bash (2m)`,
`3 read-only investigations running (4m)`, and after a fan-out closes,
`reading 3 read-only investigations (30.1 KB) · waiting for the model`. A
provider failure the session is retrying on its own reads `provider error,
retrying in 8s (3/6)`, and says when the partial answer already streamed was
kept (drawn dimmed, labelled interrupted, and never sent to the model again).
A prompt waiting for MCP servers that are still connecting says so. A long
write and a hung session look the same without the phase; the phase is what
tells them apart.

It is a row of the transcript rather than of the status line. The status line
is always visible, so it carries what is always true (the context position,
the spend); `thinking (40s)` is one moment of one turn and belongs beside the
tool calls it describes. When the turn ends it is replaced by the turn's
summary rule. It is drawn under the scrollback window rather than appended to
the transcript, so it never becomes scrollback and never moves the transcript
under a reader, and it wraps to at most two rows.

The label is one word per turn rather than `Processing` forever (`Working`,
`Percolating`, `Untangling`, `Forechecking`), drawn from
`Lemieux.TUI.Processing`'s list when the turn starts, so the moment a new turn
begins is visible without reading a timer. `"processing"` in
`~/.lmx/config.json` replaces the list; a list of one keeps a single word.
`Lemieux.TUI.Activity` owns the wording, so a host's status line and the
transcript cannot describe the same wait differently.

## Themes and colour

### Light and dark backgrounds

The default palette, `dark`, is drawn for a dark background. With no theme
chosen and `NO_COLOR` unset, a local screen asks the terminal for its
background before it takes the screen over, in this order:

1. The terminal itself, with xterm's background-colour query (OSC 11)
   followed by a device-attributes request. xterm, GNOME Terminal and other
   VTE terminals, iTerm2, kitty, WezTerm, Alacritty, Konsole, VS Code and tmux
   answer. The wait is at most 500 ms, or 1 s over SSH. It is skipped when
   `TERM` is unset or `dumb`, and on native Windows.
2. `COLORFGBG`, which some terminals set: a background index of 7 or 9 to 15
   means light.
3. The macOS appearance setting, for Terminal.app before macOS 26 only.

A light answer starts the screen in the `light` theme; anything else keeps
`dark`. A theme someone chose always wins: `"theme"` in `~/.lmx/config.json`,
`/theme`, or a host's `:theme`. A screen that opens with a chosen theme is
drawn in it from the first frame and asks the terminal nothing. `NO_COLOR`
starts in `mono` unless a theme was chosen by name.

The light palette takes its colours from the fixed 256-colour cube rather than
the terminal's named colours, which light profiles rarely pick for reading
text. Text you read is at least 4.5:1 against white (WCAG AA), and glyphs such
as gutters and rules at least 3:1. Plain text and your own input use the
terminal's own foreground colour, and dimmed text is drawn in the muted grey,
because dim text cannot reach 4.5:1 on white. `Lemieux.TUI.Theme.light/0` lists
each colour and its measured contrast.

### Colour depth

Every RGB colour on the screen (code and diff tints, syntax highlighting, a
`/color #rrggbb`, a host's own widgets) is drawn as its nearest xterm-256
colour unless the terminal says it draws 24-bit colour: `COLORTERM=truecolor`
or `24bit`, or a `TERM` ending in `-direct`. Terminal.app before macOS 26 and
GNU screen 4 misread 24-bit colour and drew code dim on yellow; with 256
colours they draw it right. Inside GNU screen (`STY` set) the screen always
uses 256 colours unless `TERM` ends in `-direct`, because screen passes on the
outer terminal's `COLORTERM`. A terminal that draws 24-bit colour without
saying so gets it with `export COLORTERM=truecolor`. A host pins the depth with
the `colours:` [start option](#starting-the-screen-from-a-host).

### Adding a theme

A palette is the one opinion here that a person changes without wanting to
write Elixir, so a theme is data, with a struct form and a map form, rather
than a module. Pass `themes:` to `Lemieux.TUI.start_link/1` with a map of name
to theme, a `%Lemieux.TUI.Theme{}` or the plain map below, and it is merged
over the shipped `dark`, `light` and `mono`: `/theme sepia` finds it, Tab
offers it, and `theme: "sepia"` starts the screen in it. A key that matches a
shipped name replaces that palette. The registry is a value in the screen's
state, not a global, so two screens in one VM can disagree about what `sepia`
means.

The map is the JSON shape the config file carries: string keys, the name and
two accents at the top, then one map per group of slots with every slot
present. A colour is one of the names `ExRatatui.Style` takes, `#rrggbb`, an
integer palette index, or `null` for the terminal's own; `code_theme` is a
highlighter theme name or `null`.

```json
{
  "name": "sepia",
  "accent": "#c08040",
  "elixir_accent": "magenta",
  "voices": {"you": "yellow", "you_text": "white", "remark": "gray", "alert": "red",
             "notice": "yellow", "activity": "magenta", "question": "yellow"},
  "text": {"plain": "white", "muted": "gray", "gutter": "dark_gray", "error": "light_red"},
  "tools": {"explore": "light_blue", "search": "light_cyan", "run": "light_yellow",
            "edit": "light_green", "write": "light_green", "eval": "light_magenta"},
  "children": {"name": "yellow", "ok": "green", "warn": "yellow", "fail": "red"},
  "blocks": {"heading": "light_cyan", "quote": "cyan", "code": "cyan", "code_bg": "#2b303b",
             "rule": "dark_gray", "add": "light_green", "delete": "light_red",
             "add_bg": "#123020", "delete_bg": "#371a20", "code_theme": "base16_ocean_dark"},
  "context": {"system": "green", "tools": "red", "conversation": "blue",
              "output": "magenta", "free": "dark_gray"}
}
```

No slot is only for an `ask_user` answer or for the *deprecated* badge in
`/model`'s menu: answers and their notes are drawn in `children.ok`, or in
`voices.question` where the accent is the same colour as `children.ok`, and
the badge in `voices.alert`.

`Lemieux.TUI.Theme.from_map/1` reads that and names every slot it cannot read
at once (a misspelt colour, a slot the renderer never reads, a missing group),
and `to_map/1` writes a theme back out. The shipped three round-trip through
the map form exactly, and `mono`'s `null` slots survive the trip, so the
quickest way to a palette of your own is
`Lemieux.TUI.Theme.to_map(Lemieux.TUI.Theme.dark())` and an editor. `lmx`
reads that map from the `"themes"` key of `~/.lmx/config.json`:
`Lemieux.CLI.Config` validates it at startup and names every unreadable
`group.slot`, `Lemieux.CLI.Runtime` puts it on `harness.themes`,
`Lemieux.CLI.TUI` forwards that harness and `Lemieux.TUI.start_link/1` reads
`themes` from it, and `"theme"` may name one of them; see
[Configuration](configuration.md).

### Blocks, and the theme

Model answers are drawn as the blocks they contain (fenced code with
highlighting, `diff` fences as diffs, pipe tables, block quotes, headings,
list items and rules), and the constraint that shaped how is the same one
that shapes everything else in the pane: every row must have an exact height.
`Lemieux.TUI.Window` pins the viewport by counting rows, and
`Lemieux.TUI.Selection` names a row by its distance from the newest, so a
widget that reflows itself (`ExRatatui.Widgets.Markdown`) cannot be used for a
streaming answer. Instead `Lemieux.TUI.Blocks` classifies each line the moment
the next one begins, and `Lemieux.TUI.RichText` lays each block row out into a
known number of screen rows. A closing fence re-highlights the whole block as
one source, so a heredoc is coloured as a heredoc; a table is one stored row
laid out into exactly its rows, columns squeezed from the widest down when the
pane is narrow. Wide text (CJK, full-width forms, emoji) is wrapped by its
display width everywhere: the transcript, tables, code, tool output and the
input box. The same walk over a finished answer is what a resumed transcript
draws. Code rows start in the first column and are tinted rather than
gutter-marked, so a block copied out of the transcript is the block.

Colours are a `Lemieux.TUI.Theme`: one slot per *meaning*, grouped by what it
colours, rather than one accent, so a question, an edit and an error keep
their own colours under every palette. `dark` is the default; `light` re-picks
every slot for a pale background; `mono` empties every slot for a terminal
without a palette or a reader who cannot tell the colours apart, leaving the
weight and the glyphs. `/theme` switches until you quit, `"theme"` in the
config file chooses the start, and `/color` still overrides the one accent on
top. The input cursor is drawn white on a dark accent and black on a light
one. A fenced block is highlighted once, when it closes, in the theme showing
then; switching afterwards recolours every row the renderer draws and leaves
that highlighting as it was.

## Keys and input

### Rebinding keys

The key table in the [CLI reference](cli.md#keys) is the default, and like a
theme it is data: `"keys"` in `~/.lmx/config.json` rebinds it, and a host
passes the same map, or a module, as `keys:` to `Lemieux.TUI.start_link/1` or
on `harness.keys`. Each entry maps a key description to an action name and is
merged over the shipped table key by key, so a key the map does not mention
keeps its default.

```json
{
  "keys": {
    "ctrl-j": "submit",
    "enter": "forward",
    "shift-up": "page_up",
    "shift-down": "page_down"
  }
}
```

A key is its `ex_ratatui` code with the modifiers in front, joined by `-`: one
of the named keys (`enter`, `esc`, `tab`, `back_tab`, `backspace`, `delete`,
`insert`, `up`, `down`, `left`, `right`, `home`, `end`, `page_up`,
`page_down`, `f1` to `f12`) or a single character. `space` is the space bar,
and a trailing `-` is the hyphen key, so `ctrl--` is ctrl and hyphen. The
modifiers are `ctrl`, `alt` and `shift`, in any order and any case:
`ctrl-shift-up` and `Shift-Ctrl-Up` are one binding, written back as
`ctrl-shift-up`. A binding names its modifier set exactly (`enter` is not
`shift-enter`), which is what lets `shift-up` mean something other than `up`.
On macOS, `alt-` keys arrive only when the terminal lets Option send Alt; see
[Keys](cli.md#keys).

The actions are `Lemieux.TUI.Keys.actions/0`, named for what each does to the
screen: `interrupt` (cancel the turn, or arm exit), `submit`, `previous` and
`next` (the completion menu when it is open, otherwise input history),
`scroll_up` and `scroll_down`, `page_up` and `page_down`, `complete` (the
highlighted completion, the follow-up hint, or a queued message while busy),
`select_queued`, `revise_queued`, `unstage_queued`, `revoke_steer` (Alt-Z:
take back the waiting steer, as `/unsteer` does), `dismiss`, `newline`,
`pager` (Ctrl-O), `history_search` (Ctrl-R), `external_editor` (Ctrl-G),
`paste_image` (Ctrl-V), `cycle_mode` (Shift-Tab: the permission mode) and
`toggle_notifications` (Alt-N). `forward` is the one other word a map may
use: it releases a key to the input box, which is what every key the table
does not claim already gets, so the editing vocabulary (cursor, word motion,
kill and yank, selection with Shift) stays the editor's and is never listed
here. `"alt-z": "forward"` frees Alt-Z, and `"alt-r": "revoke_steer"` binds
the action to Alt-R as well; set both to move it. `/help` lists the effective
bindings, named the way a person says them (`shift-tab`, `page up`), and ends
with links to the docs, issues and questions.

`Lemieux.TUI.Keys.from_map/1` reads the map and names every bad key and
unknown action at once, `Lemieux.CLI.Config` runs it at startup, and
`to_map/1` writes the effective table back;
`Lemieux.TUI.Keys.to_map(Lemieux.TUI.Keys.default())` is the quickest way to a
table of your own.

Two things a map may not do. A key cannot do two things: two spellings of one
key bound to different actions are refused rather than resolved by whichever
was read last. And `interrupt` must stay bound to something, because it is
the only way out of a running turn and the way out of the program, so a map
that takes `ctrl-c` for another action without giving `interrupt` another key
is refused. A module implementing `Lemieux.TUI.Keys` has one callback,
`action/1`, given the key event and returning an action or `:forward`; it is
trusted with both rules because it is code, and an answer outside the
vocabulary goes to the editor with a line in the transcript naming the
module. Cmd-Z, which no table can name, still revokes a steer in a terminal
that reports the Command key (the kitty keyboard protocol).

### The input box

The input box soft-wraps and grows to five visible rows; longer drafts scroll
inside it as the caret moves. Up and Down move through a multi-line draft,
then browse input history at its first or last line; Alt-Up and Alt-Down
browse history directly, and Down on the current draft moves the caret to the
end. Shift-Enter inserts a newline where the terminal reports the modifier;
Ctrl-J, or a trailing `\` before Enter, inserts one in any terminal. Pasted
text keeps its lines whatever line ending the terminal sends: a bare CR (VS
Code, GNOME Terminal, xterm, tmux) or CRLF (Windows clipboards). On Windows,
characters typed with AltGr (such as `@ { [ | ~` and `€` on German, French and
Polish layouts) are inserted, while Ctrl-Alt with an ASCII letter or digit
stays a shortcut. Ctrl-R searches the input history shared across sessions
(`~/.lmx/history.jsonl`, private and bounded).

**Ctrl-G** hands the draft to `$VISUAL`, else `$EDITOR`, else `vi`; arguments
work (`code --wait`). The screen gives the terminal back (it restores the
terminal's modes and leaves the alternate screen), runs the editor on the
terminal's device, waits, then reads the file back and repaints in full. The
draft is written to a fresh private directory (`0700`, the file `0600`) under
the temporary directory and deleted afterwards. It needs a POSIX `sh` on
`PATH`, and it does not work on native Windows yet (WSL2 behaves like Linux).
The editor is not the terminal's foreground job, so the terminal's signal keys
are switched off during the edit: Ctrl-C, Ctrl-Z and Ctrl-\ are ordinary keys
to a terminal editor, and while a window editor (`code --wait`) is open, keys
typed into the waiting terminal are read by the screen after the editor
closes, where a Ctrl-C arms quit or cancels a running turn. A resize during
the edit reaches a terminal editor only when it redraws.

**Steering and the queue.** While the agent is working, a drafted message
shows `Enter steer · Tab queue`. Enter sends it into the current turn as a
steer: the steer box, with a muted border, appears after any running tool's
result and reads `queued for next model request · /unsteer takes it back`.
Only one steer waits at a time (a second gets `one steer is already waiting ·
/unsteer takes it back`); `/unsteer` or Alt-Z takes it back until the next
model request starts. A turn that stops first marks the steer `turn stopped
before delivery`. Tab stages up to nine prompts or slash commands (for
example `/compact`), shown as numbered previews above the input and run in
order after successful turns. Alt-1 to Alt-9 choose one; Alt-E returns it to
the editor, where Enter or Tab saves the revision in its slot and Esc restores
the original; Alt-U discards it. A cancelled or failed turn leaves the queue
staged and marks an undelivered steer plainly.

### Mouse, links and copying

Mouse capture is on by default: drag to select and copy transcript text (the
status line briefly shows how many characters), and scroll with the wheel.
The selection is anchored to the transcript rather than the screen, so it
stays over its own text while you scroll or while the model streams below
it; dragging past the top or bottom edge scrolls and keeps selecting, and
releasing copies the whole range, including the part no longer visible. It is
linear, not rectangular. The one edit that clears it is a tool result
replacing the rows its own progress line held.

Clicking a styled Markdown link, an http(s) URL or an existing local file path
in the transcript opens it:

- an http(s) address opens in the browser;
- a local file whose type launches, installs or runs code (`.app`,
  `.command`, `.sh`, `.exe`, `.bat`, `.ps1`, `.jar`, `.desktop`, … — the full
  list is in `Lemieux.TUI.Links`) is not opened; the status row says `not
  opened · <.ext> files can run code, so lmx does not open them; open it
  yourself if you meant to`. The check ignores case and looks at every name in
  a chain of symlinks;
- a text file opens in a text editor: `open -t` on macOS, Notepad on Windows.
  On Linux it goes to `xdg-open`, except source a desktop may run (`.py`,
  `.rb`, `.js` and the like), web pages and `#!` scripts, which are shown in
  their folder instead;
- anything else is shown in its folder: Finder, Explorer, or the folder
  through `xdg-open`.

A rendered Markdown link shows its destination. When scrolled back, the
centred count on the lower transcript rail returns to the latest rows when
clicked; it uses the notice colour so it stands out from the rail. Submitting
a message keeps the current scroll position, and the lower rail disappears at
the bottom.

Copying uses the system clipboard tool (`pbcopy` on macOS, `wl-copy`, `xclip`
or `xsel` on Linux) when there is one, and the terminal's OSC 52 sequence
otherwise: over SSH, on Windows, or when no tool works, a machine with no
shell to start one included. OSC 52 is best effort, and nothing acknowledges
it. `--no-mouse` (or `"mouse": false`) leaves selection to the terminal and
costs the wheel, which terminals then turn into arrow keys.

### Terminal multiplexers

tmux is supported. It converts the colours it cannot pass on, and answers the
background query. Copying with OSC 52 through tmux needs
`set -s set-clipboard on` in its configuration.

GNU screen 4.x (macOS's `/usr/bin/screen`) is not supported for multi-line
paste: it passes no bracketed paste, so a pasted block arrives as typed lines,
and Enter sends the first as a prompt and the next ones as steers. Colours
inside screen are right, because the screen uses 256 colours when `STY` is
set. Prefer tmux.

## Replacing what the screen draws

### Replacing the status line

The row is the only permanently visible part of the screen, which makes it the
only part where what belongs on it is taste rather than correctness. So it is
handed over whole rather than configured: a host passes
`status_line: MyApp.Status` to `Lemieux.TUI.start_link/1`, implements
`Lemieux.TUI.Status`, and returns whatever `ExRatatui` can draw.

```elixir
defmodule MyApp.Status do
  @behaviour Lemieux.TUI.Status

  alias ExRatatui.Widgets.Gauge

  @impl Lemieux.TUI.Status
  def height, do: 2

  @impl Lemieux.TUI.Status
  def render(status, area) do
    [top, bottom] =
      ExRatatui.Layout.split(area, :vertical, [{:length, 1}, {:length, 1}])

    [
      {%Gauge{ratio: status.conversation.context.fraction || 0.0}, top},
      {stock_line(status), bottom}
    ]
  end
end
```

`status` is a `t:Lemieux.TUI.Status.t/0`: the turn's label and how long it has
been running, the phase and how long *that* has, the whole
`Lemieux.Conversation` (so the context position, the spend and the model are
all reachable), the theme and the accent. It is a struct built once per frame
from state the screen already holds, because `render/2` runs at frame rate and
must not call anything. The turn's half is there even though the shipped
layout no longer draws it: `Lemieux.TUI.Status.segments/1`, `screen/1`,
`activity/1` and `phase/1` are public, and `activity/1` is the whole of the
old row's left-hand side, spinner included, for a host that wants it back.

Two limits protect the rest of the screen. Returned rects are clamped to the
row, so the obvious mistake (placing a widget at `y: 0`, because that is where
it goes *within* the row) draws a smaller widget instead of erasing the
transcript. And `height/0` is clamped to a third of the frame.

The status line is a module rather than a name in the config file for the
same reason `Lemieux.Extension.Profile` never resolves one: JSON selects data,
and resolving a module name out of it would make a settings file a way to load
code. `"processing"` is a list of words, so it is data and lives there.

A turn that ends in a provider failure says so with `/retry to send the
request again`, and `/retry` does exactly that: the request is rebuilt from
the transcript as it stands, tool results included, with no new prompt. See
[Troubleshooting](troubleshooting.md#a-provider-request-failed).

### Rearranging the panes

The three panes (the transcript, the input box, the status band) are placed by
a `Lemieux.TUI.Layout`, and the shipped one is the arrangement described
above: the transcript on top taking whatever is left, the input box growing
from three to seven rows beneath it, and the status band at the bottom. Pass
`layout: MyApp.Layout` to `Lemieux.TUI.start_link/1`, or put it on
`harness.layout`, and implement the one callback, `panes/2`. It is given the
frame (`%{width: w, height: h}`) and what the panes need (`%{input: n, status:
n}`, the status band's height already asked of the status line and clamped,
once, so the layout and the status line cannot disagree by a row), and
returns one rect per pane in absolute cell coordinates:

```elixir
defmodule MyApp.Layout do
  @behaviour Lemieux.TUI.Layout

  alias ExRatatui.Layout.Rect

  # The input box on top, the transcript under it.
  @impl Lemieux.TUI.Layout
  def panes(%{width: width, height: height}, %{input: input, status: status}) do
    %{
      input: %Rect{x: 0, y: 0, width: width, height: input},
      status: %Rect{x: 0, y: input, width: width, height: status},
      transcript: %Rect{x: 0, y: input + status, width: width, height: height - input - status}
    }
  end
end
```

The callback returns rects rather than an order or a ratio, because a host
that wants the input on top, a status band beside the transcript, a
transcript of fixed height above a log of its own, or a margin on a wide
monitor can say each of those with three rects and none of them with a flag.
The screen computes the rects once per frame and every consumer reads the same
three: the draw, the completion menu (which opens over the transcript at the
edge nearest the input box), paging, and mouse selection, which is measured
from the transcript rect's own origin, so a click selects the row under the
pointer wherever the pane went.

Four invariants are checked on every frame: every rect inside the frame, no
two sharing a cell (touching is fine, and so is a gap), the input box at least
one row and one column, and no negative sizes. A layout that breaks one is not
drawn. The shipped arrangement is drawn instead, with the reason on the
transcript's lower rail (`layout: MyApp.Layout let the transcript and the
status overlap · drawn as shipped`) on every frame until it is fixed.
`Lemieux.TUI.Layout` carries the reasoning, and `check/2` is the rules as a
function.

### Replacing the follow-up hint

The grey text in the empty input box after a turn (`run the tests · tab`) is
the other thing the screen says on its own account, and it is replaced the
same way: pass `followups: MyApp.Followup` to `Lemieux.TUI.start_link/1`, and
implement `Lemieux.TUI.Followup`'s one callback, `suggest/1`. It is given the
turn's signals (how many files changed, commands ran, calls failed, files were
read, and which kind came last) and returns a string to offer or `nil` to
offer nothing; Tab puts the string in the box. The signals stay counters, so
no path or command reaches the box by accident. `Lemieux.TUI.Followup` says
why the guess is local rather than a model's, and the shipped rules are the
default when nothing is passed; a turn that only read files is offered no
"make the change" hint.

### Replacing a tool receipt

How a tool call appears in the transcript (`Ran mix test` with its output,
`Edited lib/x.ex (+3 -1)` with its diff, a line under `Explored`) is decided
per tool name by a `Lemieux.TUI.Renderer`. The built-ins draw the tools the
screen has a verb for, and a tool nobody registered gets the generic receipt:
`Ran NAME`, its first string argument, its output. Pass `renderers:` with a
map of tool name to module and it is merged over the built-ins, so the same
option replaces how `read` is drawn and gives an MCP tool named
`server__tool` a receipt of its own.

```elixir
defmodule MyApp.SearchReceipt do
  @behaviour Lemieux.TUI.Renderer

  alias Lemieux.TUI.ToolText

  @impl Lemieux.TUI.Renderer
  def call(call, _exploring?),
    do: [ToolText.heading(call.id, :search, "Asked the index for", call.arguments["query"])]

  @impl Lemieux.TUI.Renderer
  def result(call, result, _theme) do
    hits = get_in(result.payload, ["structured_content", "hits"]) || []
    {:replace, call(call, false) ++ Enum.map(hits, &{:tool_detail, call.id, :explore, &1["title"]})}
  end
end

Lemieux.TUI.start_link(renderers: %{"index__search" => MyApp.SearchReceipt})
```

`call/2` is given the call normalised (`%{id, name, arguments}`, the same
shape live and on resume) and whether the row above is already exploration.
`result/3` is given the output as text, the raw payload and the theme showing,
and returns `{:replace, rows}`, `{:output, text}`, `{:answer, text}` or
`:none`; it is optional, and a renderer that omits it gets the generic output.
A failed call is drawn as its output for every tool before any renderer is
asked, because an error is the one thing a person must never miss.
`Lemieux.TUI.ToolText` is the toolkit the built-ins are made of and is public
for reuse: `heading/4`, `detail/2`, `exploration/3`, `argument/3`,
`edit_rows/3` and `write_rows/3` for a tool that wants the diff `edit` gets.

The built-in `edit`, `write` and `apply_patch` receipts draw numbered unified
diffs (`Lemieux.TUI.Diff`, over `List.myers_difference/2`), with context
collapsed around each change. `edit` takes its line numbers from the numbered
snippet the tool returns; `write` over an existing file first says
`Overwrote PATH (N lines)` and then replaces that with a diff against the
checkpointed earlier contents, so it never shows a whole file as added;
`apply_patch` draws per-file headings and hunks with the tool's own parser.
Output is still cut to its head and tail in the transcript, and Ctrl-O opens
`Lemieux.TUI.Pager` over the full output of the last twenty calls.

The model's plan (the `todo` tool's `lemieux.plan` entries) is drawn by
`Lemieux.TUI.PlanPanel` above the input while a task is open, centred on the
step in progress, live and when a session is loaded. Messages from the check
after edits (`[lmx verify]`, from `Lemieux.Extensions.Verify`) are drawn as
their own row type rather than as something the person typed.

One invariant is enforced rather than trusted: every row a renderer returns
must be one of `ToolText`'s row shapes, and every row must carry the call's
id. The shapes give a row an exact height (`Lemieux.TUI.Window` pins the
viewport by counting rows, and `Lemieux.TUI.Selection` names a row by its
distance from the newest, so a row that cannot be measured would corrupt
both), and the id is how `announced?/2` keeps a re-delivered call from being
drawn twice and how a result finds the rows it replaces. `ToolText.call/4` and
`result/4` check both on everything a renderer returns; rows that fail are
replaced by the generic receipt plus one line naming the module and the
problem, and the window carries on. A kind the theme has no slot for
(`:deploy`, say) is drawn in the plain text colour; reusing `:edit` borrows
its green, and `:approval` (the kind the approval card below uses) the
question's yellow.

A renderer may also implement the optional `approval/1`, which draws the card
that asks whether a parked call may run. It is given the same normalised call
and returns rows under the same invariant, and a renderer that omits it gets
the shipped card.

### Approvals and elicitation

A `before_tool_call` hook that answers `:pending` (the bundled permissions
extension, a command hook answering `ask`, or a host's own) parks the call in
the session ([Hooks](hooks.md)), and the screen shows it as a card under the
call's own announcement:

```
• Ran bash rm -rf tmp
• Approve bash rm -rf tmp?
  └ y runs it · n [reason] refuses it · /approve · /deny [reason]
```

The input box's title becomes ` approve? `, its placeholder says which tool
is waiting, and the live row reads `waiting for your approval of bash` rather
than `running bash`, because this is the one wait that is on the person. A
short reply answers the oldest parked call: `y`, `yes` or `allow` run it;
`n`, `no` or `deny`, with anything after the word as the reason, refuse it
(`no, use rg instead` refuses with the reason `use rg instead`, which is what
the model reads as the call's result). Any other line is a steer, sent with a
reminder that the call is still waiting, since a steer lands at the next turn
boundary and there is no boundary until the call resolves. When more than one
call is parked, `/approve CALL_ID`, `/deny CALL_ID [REASON]` and `all` name
which; Tab completes the ids. An `ask_user` question opens its own panel above
the input and takes focus ahead of parked calls.

When the permissions extension parked the call, its payload carries a
`permission` map (the mode, why it asked, and numbered suggestions) and the
card draws them: `a` (or `aN` for the Nth) remembers the suggested rule, such
as `Bash(npm test:*)`, with `Permissions.remember/2`, or switches to the
suggested mode, and then runs the call. Shift-Tab cycles the mode through
`Permissions.cycle/1` (it never lands on full auto), and the status line shows
the mode's label. With permissions off, Shift-Tab and `/permissions` say so
and how to turn them on (`start lmx with --permission-mode ask to be asked
first`). `Lemieux.TUI.Policy` holds the card and the key handling.

The decision goes through `Lemieux.Session.resolve_tool/3`, and the card comes
down when the session records it, whether this screen answered, another host
on the same session did, or the session's approval timeout refused it. `lmx`
starts terminal UI sessions with `approval_timeout: :infinity`, and a parked
call's own tool deadline is paused while it waits, so a person who steps away
comes back to the card rather than to a refusal. With a finite timeout, the
tool result says what became of the call (`✗ bash denied: nobody approved this
call within 300000ms, so it was not run`) and the waiting state clears with
it. A screen that attaches while a call is parked draws the card from the
session's snapshot and can answer it.

An MCP server that asks for input mid-call (`Lemieux.MCP.Elicitation`) parks
a question under the same channel `ask_user` uses, with an id of `CALL:KEY`
and the server's prompt as the question (`? gh asks: how many? (count:
integer)`), and the answer entered in the panel resolves it. The text goes
back as typed; `Lemieux.MCP.Elicitation` casts it to the requested property's
type, or reads it as JSON when several were requested, and declines on its
behalf when neither fits. When the question payload carries a `title` and the
requested `fields`, the screen draws the title ahead of the question and one
line per field under it (`└ count · integer — how many to fetch`) before any
options.

### Adding a slash command

Every slash command is a `Lemieux.Conversation.Command`: one module that says
what it is called, how the rest of its line is read, what performing it does,
and what Tab offers after it. Pass `commands:` to `Lemieux.TUI.start_link/1`
(or as a `Lemieux.Harness` field) with a list of such modules and they go
ahead of the built-ins: in `/help`, in the completion menu, and at the prompt.

```elixir
defmodule MyApp.Commands.Ticket do
  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "ticket",
      description: "open a ticket for what the agent just did",
      accepts_arguments?: true,
      action: {:ticket, nil}
    }
  end

  @impl Lemieux.Conversation.Command
  def parse("", _conversation), do: {:error, "usage: /ticket TITLE"}
  def parse(title, _conversation), do: [{:ticket, String.trim(title)}]

  @impl Lemieux.Conversation.Command
  def perform(acc, host, {:ticket, title}) do
    {:ok, url} = MyApp.Tracker.open(title, session: host.id)
    Dispatch.say(acc, host, "opened #{url}")
  end

  @impl Lemieux.Conversation.Command
  def completions(_typed, _conversation), do: MyApp.Tracker.recent_titles()
end

Lemieux.TUI.start_link(commands: [MyApp.Commands.Ticket])
```

`parse/2` is pure and returns effects: a bare list, `{conversation, effects}`
to change the conversation, or `{:error, line}` to say the line and reprint
the prompt. It is where a command decides whether it may run mid-turn
(`Lemieux.Conversation.Command.wait/1` is the stock refusal). `perform/3` is
the shared half, with the shape of every per-effect function in
`Lemieux.Conversation.Dispatch`: it receives the front end's state and the
`Dispatch` host, and `Dispatch.say/3`, `fold/3`, `run/3` and `react/3` are how
it reaches the screen and the session. The `action` in the spec is what a
host's `command_policy` is shown, so a host command is refused by policy the
way a built-in is, and every command-shaped effect the parse can produce goes
in `actions` so the dispatcher can route it.

A host module whose name or alias is a built-in's replaces that built-in: pass
a module named `model` and `/model` becomes yours, in help, in completion and
at the prompt. Skills are merged after both, so a skill can never take a
command's name. `/refresh` and `/habs` are still there, hidden by a spec flag.
`Lemieux.Conversation.Command.Builtin` lists the shipped modules, `/unsteer`
and `/redo` among them, and is the place to read how each one is written.

### `/context` draws the window

`/context` is a picture rather than the footer restated. A bar tiles the pane
in proportion to what is in the window, and a legend names each band with its
token count:

```
Context window · 18.1k/200.0k tokens (9%)
█████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
█ system prompt 6.1k · █ tools & MCP 5.0k · █ conversation 6.5k
█ model output 512 · ░ free 181.9k
last request · 9.0k uncached in · 8.0k cache read · 600 cache write · 512 out
session · 18.1k tok · 90.6k delegated · 12 requests · $0.4120
```

Green is the system prompt, red the tool and MCP schemas, blue the
conversation, magenta the model's last answer, and the dimmest grey what is
still free. Free space also gets a lighter glyph, so the bar reads on a
terminal that lost its palette.

The band totals are the provider's measurement; the split across the three
*sent* bands is each one's share of the bytes Lemieux handed the provider,
read off the `:request` entry that recorded them. `Lemieux.Context` says why
that is an apportionment rather than a count: counting the parts would need a
tokenizer, and the alternative is saying nothing about a window that is mostly
tool schemas, which is the question people have when it fills up. A band
under one cell of the pane draws as nothing and is still named in the legend.
Right after compaction, or before the first answer, `/context` says the
window is unmeasured rather than claiming it is empty.

## Questions, tool rows and delegation

An `ask_user` call opens a panel joined to the input area. Questions can be
single choice, checkbox selection, ranking, free text, or a number. Choice and
ranking questions have two to six suggested answers. Choice questions add a
final **Other** slot for custom text; ranking contains only the items to
order. Text and number questions use the input area directly. An optional
diagram on a suggestion shows an example for that choice to the right of the
question when the terminal is wide enough, and a question-level diagram
provides shared context when the highlighted suggestion has none. Diagrams may
use up to five lines of 72 columns. The panel keeps the height its largest tab
needs, and the transcript viewport ends at its top so recent lines stay
visible.

Up and Down highlight a choice, Enter selects it, and Left and Right (or Tab
and Shift-Tab) cycle through questions and Review. For checkbox selection,
Space toggles suggestions and Enter continues. For ranking, highlight each
item and press its priority number (1–6); each item needs a unique number
before Enter continues. Press **n** on a single-choice suggestion to add a
note to that choice; for checkbox and ranking questions, **n** adds a note to
the whole question. Esc leaves note editing; Esc again cancels the
questionnaire. Review places each answer on a coloured line below its
question; move to a row and press Enter to edit it, or choose **Submit
answers** to send the whole set. Esc outside note editing, or Ctrl-C, closes
the panel and cancels the current turn. A draft in the input box returns after
submission or cancellation, and the panel is restored when a screen attaches
to a session that is already waiting.

Tool activity is drawn as a compact operation transcript rather than raw
JSON. Related reads are grouped under `Explored`; shell commands use `Ran`
with Bash syntax highlighting that tells programs, flags, quoted strings and
variable expansions apart. Command headings use the theme's code palette on
the normal terminal background, keep literal whitespace when wrapping, and
keep their output dimmed and indented; highlighting is computed once, when the
call arrives or a transcript is restored, and `mono` leaves commands
uncoloured. Edits and writes show file summaries and language-highlighted
red and green diff rows. Long command output keeps two rows from its beginning
and two from its end, so the command and its final status stay visible. The
full tool result stays in the transcript, and the middle row says when the
visible form was shortened.

An unmeasured cost stays labelled unmeasured. It may come from a
subscription-backed or otherwise unpriced credential, but the provider seam
does not supply session or weekly allowances, so the screen does not infer
them from missing price data.

Delegated work uses the same stream. Each child is one row, updated where it
sits:

```
├─ clive-desjardins · running · find the build, test and lint commands
│ └ read mix.exs ×2
├─ darlene-orr · running · map the module layout
│ └ bash grep -rn defmodule lib
├─ noelle-fiala · queued · summarise how the test suite is organised
── delegation ok · 3 read-only investigations ──
```

Name, then how it is going, then the brief it was sent with; what it is doing
right now goes underneath, because that changes several times a second while
the rest does not. A repeated call becomes a count rather than another line,
so a stuck scout is one row with a number instead of a screenful of identical
reads. The status is coloured by whether anybody has to do something about
it: green for `ok`, red for `failed` and `timeout`, yellow for a cancellation
or an exhausted budget, since the cap doing its job is not a failure. The
names are the same kind a parent session gets, derived from the child's own
transcript id, so three parallel scouts can be told apart; nothing is stored
to make that true.

**A resumed transcript draws the same rows.** The `:subagent_spawn` entry
carries the child id, the kind and the brief, and the `:subagent_result` that
follows updates the row rather than adding a second one, so a delegation read
back tomorrow is named, briefed and counted exactly as it was live. What
cannot be rebuilt is the activity line: a child's tool calls are in the
*child's* transcript, and the parent never saw them. The row does not open
that transcript; `lmx log CHILD_ID` prints it, and `lmx --resume CHILD_ID`
opens it.

## Starting the screen from a host

`Lemieux.TUI.start_link/1` starts the screen over the local terminal
(`:transport`, default `:local`), over `:ssh` or `:distributed`, or over a
transport the host owns, `{:session, session, writer_fn}`, which carries the
rendered bytes anywhere it chooses. Besides the seams above (`:status_line`,
`:layout`, `:followups`, `:theme`, `:themes`, `:keys`, `:renderers`,
`:commands`, or a `:harness` carrying them, where an option given explicitly
still wins), it takes:

- `mouse_capture:` — `true` by default, so link clicks and the wheel reach the
  screen and an unmodified drag selects; `false` leaves the mouse to the
  terminal, and mouse events then depend on the transport.
- `background:` — `:light`, `:dark` or `:unknown`. Answers the [background
  question](#light-and-dark-backgrounds) and skips the terminal query.
- `colours:` — `:truecolor` or `:ansi256`, overriding the [colour
  depth](#colour-depth) detection.
- `trap_signals: true` — the screen traps SIGTERM for as long as it runs, and
  leaves, restoring the terminal, before the VM stops. Off by default, because
  how the VM shuts down is the host's decision; ignored with `test_mode` and
  remote transports. SIGHUP is never trapped: a hangup means the terminal is
  gone and the screen cannot answer it, so the operating system's default
  (ending the process) stands.
- `command_policy:` — `fn parsed_action -> :allow | {:deny, message} end`. A
  denied command is left out of help and completion and checked again when it
  is dispatched; the action is an effect such as `{:mcp_add, path}`, never
  terminal text.
- `size:` — the terminal's size, so paging is right before the first resize
  event.
- `task_supervisor:` — the `Task.Supervisor` the screen runs its background
  work under: `/compact`, `/retry`, `/undo`, `/diff`, `/export`, `!COMMAND`
  and the like. `lmx` passes its runtime's. Without one, that work is linked
  to the screen, so a call that crashes against a live session (one that
  times out, say) takes the screen down with it.
- `discovered_models:` — model specifications the host already found, such
  as a local Ollama's tags, offered by `/model` and `/provider` beside the
  session's own. A `{:preferred, spec}` among them names the model the host
  would choose for that spec's provider, and goes first. Discovery that
  finishes after the screen opens is sent to it as
  `{:models_discovered, models}`, in the same shape; what it adds goes after
  what was found before, except a `{:preferred, spec}`, which still goes
  first. `/provider NAME`, on a session with no model of its own for
  `NAME`, switches to a configured or recently used model that was
  discovered, else to the first discovered one.

Without any of these, a local screen adapts on its own: a light background
gets the light theme, and RGB colours are drawn as 256 colours unless
`COLORTERM` says the terminal has 24-bit colour. All options are also passed
to `mount/1`.

`lmx` traps SIGTERM in its own host, `Lemieux.CLI.TUI`, so `kill PID` leaves
the terminal restored and stops the session cleanly; a host that traps
nothing and is stopped with SIGTERM can leave the terminal inside the
alternate screen. Before any command runs, `lmx` points `ERL_CRASH_DUMP` at
`~/.lmx/crash` (`crash/` under `LMX_HOME`), as the release launcher does
([Crash dumps](cli.md#crash-dumps)); `Lemieux.CLI.TUI.main/2` points it into
its state directory for a host that opens the screen without that setup,
unless it is already set. With `trap_signals: true`, the VM's signal server
holds a function defined in `Lemieux.TUI.Signals`, and `lmx`'s own trap
holds one defined in `Lemieux.CLI.TUI`, so a release that changes either
module must restart rather than hot-upgrade.

## Testing it without a terminal

`render/2` is a function from state to `[{widget, rect}]`, and
`handle_event/2` a function from event and state to state. Neither touches
the NIF. So the screen's behaviour is tested by calling them directly and
asserting on the widget structs that come back: no terminal, no NIF, no
platform assumption, and it runs in CI on a machine with no TTY.

That is the same split the rest of Lemieux uses (`Lemieux.Turn` is a pure
fold, `Lemieux.Session` is the process around it), and it is why
`Lemieux.Conversation` exists: the decisions a front end makes are in a pure
module both front ends call, and `Lemieux.TUI` is left holding the drawing.

For the parts that genuinely need the runtime, `ex_ratatui` supports headless
operation directly:

```elixir
{:ok, pid} = Demo.start_link(test_mode: {40, 10})
send(pid, {:say, "from another process"})
ExRatatui.Runtime.inject_event(pid, %ExRatatui.Event.Key{code: "x", kind: "press", modifiers: []})
ExRatatui.Runtime.snapshot(pid)
#=> %{mode: :callbacks, dimensions: {40, 10}, polling_enabled?: false, render_count: 3, ...}
```

`render_count: 3` is mount, then the message, then the key, so external
messages and injected input both reach the app with no terminal attached. The
snapshot does *not* give back the rendered cell buffer, so it proves the
wiring and cannot assert on the picture; asserting on the picture is what
calling `render/2` directly is for.

A screen started with `test_mode` has no person looking at it, so its local
effects default to inert: the desktop notification, the clipboard write, the
external editor and the clipboard image read do nothing unless the test passes
its own callback (`:notify`, `:clipboard`, `:editor`, `:paste_image`). Without
that, a test that reached an approval would print an OSC 9 notification into
the test run, and a copy would overwrite the developer's clipboard.

## Related question batches

`ask_user` also accepts `questions` instead of `question`: one to four objects
with `question`, optional stable `id`, optional `diagram`, and `type`
(`single_choice`, `multi_select`, `ranking`, `text`, or `number`). Choice and
ranking questions require `options` (two to six, each with `label`, optional
stable `id`, `description`, `preview`, and `diagram`); text and number
questions omit them. Omitting `type` keeps single-choice behaviour; the older
`multiple: true` batch field also selects `multi_select`. Missing ids are
assigned from position; duplicate explicit ids are rejected. The whole batch
is validated and parked as one call. The screen collects the answers locally
and sends them only after Review. `/decline` or `/cancel-question` ends the
batch.

Embedded hosts answer the emitted call id through `Session.answer/3` with
`%{"answers" => [%{"selected" => [option_id], "option_notes" => %{option_id => "note"}}, %{"ranked" => [option_id, next_id], "notes" => "overall priority"}, %{"text" => "custom"}, %{"number" => "2.5"}]}`
in question order, or `%{"status" => "declined" | "cancelled" | "unavailable"}`.
Tool results keep stable question ids and distinguish these outcomes from
`timed_out` and invalid answers. A timeout or an absent human channel never
selects a default. Single-choice calls without an explicit type keep their
original text-result interface; typed single questions return the same
structured result as batches.
