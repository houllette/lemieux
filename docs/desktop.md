# Desktop launchers and Omarchy

On Linux, `lmx desktop install` adds `lmx` to your desktop's application
launcher, so it opens in a terminal like any other application. This page
covers that command, launching `lmx` from [Omarchy](https://omarchy.org)
keybindings and menus, and the commands a launcher or an agent selector
uses to start `lmx`.

Desktop integration is a separate step that you run yourself. Installing or
updating `lmx` ([Installing and updating lmx](releases.md)) never changes
your desktop.

## Add lmx to the application launcher

```sh
lmx desktop install
```

It writes two files, both in your own data directory (`$XDG_DATA_HOME`, or
`~/.local/share` when that is not set):

| File | What it is |
| --- | --- |
| `applications/lemieux.desktop` | The launcher entry, named `lmx` |
| `icons/hicolor/scalable/apps/lemieux.svg` | Its icon |

It does nothing else: it runs no `update-desktop-database`, reloads no
compositor, writes nothing under `/usr` or into Omarchy's own files, and
leaves `~/.lmx` alone. It ends by naming what the entry runs and where:

```text
Wrote /home/you/.local/share/applications/lemieux.desktop and its icon, /home/you/.local/share/icons/hicolor/scalable/apps/lemieux.svg.
It runs /home/you/.local/bin/lmx in /home/you, in the desktop's terminal.
If the launcher does not list it yet, log out and back in. lmx desktop uninstall removes it.
```

Most launchers watch the `applications` directory and show the entry at
once. If yours does not, log out and back in.

| Option | Effect |
| --- | --- |
| `--exec PATH` | The `lmx` the entry runs (see [which lmx](#which-lmx-the-entry-runs)) |
| `--directory DIR` | The directory it opens in (see [where it starts](#where-it-starts)); a relative `DIR` is taken from where you run the command |
| `--omarchy`, `--no-omarchy` | Open it through Omarchy's terminal launcher, or through the desktop's terminal, whatever was detected |
| `--force` | Replace a `lemieux.desktop` or an icon that `lmx` did not write, or install as root |

Run `lmx desktop install` again to change these; it replaces the entry it
wrote before.

`lmx desktop install` stops without writing anything when:

- a `lemieux.desktop` exists that `lmx` did not write (`--force` replaces
  it). An icon that is not `lmx`'s is kept the same way, and the entry is
  still written;
- it runs as root. A desktop entry belongs to the user whose launcher shows
  it, and under `sudo` the home directory can still be yours, so the entry
  would be a root-owned file in it. Run it as yourself. If root itself uses
  this desktop, pass `--force`;
- it finds no installed `lmx` (below), or `--exec` or `--directory` names
  something that does not exist.

On macOS and Windows every `lmx desktop` command says that desktop entries
are a Linux feature, writes nothing and exits with status 2.

### Which lmx the entry runs

The entry names `lmx` by its full path, because a desktop session's `PATH`
often lacks `~/.local/bin`: that directory is added by your shell's profile,
which the session never reads. The path is the first of:

1. `--exec PATH`;
2. the installer's launcher, `PREFIX/bin/lmx`. An installed `lmx` knows its
   prefix, and the launcher's path stays the same when updates replace the
   version behind it;
3. the `lmx` on your `PATH`.

From a source checkout, `mix lmx desktop install` uses an installed `lmx`
if it finds one. A checkout itself cannot be started from a desktop entry,
so with no installed `lmx` the command stops and says to install a release
or pass `--exec`.

### Where it starts

From a terminal, `lmx` works in the directory you start it in, and
`lmx -C DIR` in `DIR`. A launcher has no such directory: it starts programs
in its own working directory, usually your home directory and sometimes
`/`. So the entry passes `-C DIR` explicitly, and the agent never works in
whatever directory the launcher, or the installation, happens to be in:

- `--directory DIR` when you gave one;
- on Omarchy, `~/Work` when it exists, which is where Omarchy starts its
  own agents;
- otherwise your home directory.

Where you run `lmx desktop install` does not change this, and neither does
`-C`. The entry always opens that one directory. To work on a project, start
`lmx` from a terminal in it, or give the project a keybinding of its own
with its own `-C` ([below](#omarchy)). `lmx -c` resumes the newest session
that ran in a directory.

## Check and remove it

`lmx desktop status` shows the entry, whether `lmx` wrote it and which
version, its `Exec` line, the `lmx` it runs and the directory it starts in
(each marked present or missing), the icon, and whether Omarchy was
detected:

```text
Desktop entry: /home/you/.local/share/applications/lemieux.desktop (written by lmx 0.8.0)
  Exec: omarchy-launch-tui --app-id=org.omarchy.lemieux /home/you/.local/bin/lmx -C /home/you/Work
  runs: /home/you/.local/bin/lmx (present)
  starts in: /home/you/Work (present)
Icon: /home/you/.local/share/icons/hicolor/scalable/apps/lemieux.svg (lmx's)
Omarchy: detected (omarchy-launch-tui is on PATH)
```

`lmx desktop uninstall` removes only what `install` wrote: the entry when it
carries `lmx`'s marker (`X-Lemieux-Managed=true`), and the icon when it is
byte for byte the icon `lmx` ships. It reports each file it removed or kept.
Your settings, keys and sessions in `~/.lmx`, the installation itself, and
your Omarchy and Hyprland configuration are never touched.

Removing `lmx` ([Uninstall](releases.md#uninstall)) does not remove the
entry: run `lmx desktop uninstall` first.

Every `lmx desktop` command exits with 0 when it did what it was asked, 1
when it stopped (an entry it did not write, root, no `lmx` found, a file it
could not write), and 2 for a usage error or a system that is not Linux.

## Omarchy

When `omarchy-launch-tui` is on `PATH`, `lmx desktop install` writes an
entry that opens `lmx` through it, with its own window identity, the app id
`org.omarchy.lemieux`:

```text
Exec=omarchy-launch-tui --app-id=org.omarchy.lemieux /home/you/.local/bin/lmx -C /home/you/Work
Terminal=false
StartupWMClass=org.omarchy.lemieux
```

`omarchy-launch-tui` opens your configured terminal with Omarchy's styling.
Window rules can match `lmx` windows by the app id.

The examples below use that same command. They assume the default
installation prefix: `lmx desktop status` prints the path your entry runs
(`runs:`), and you can use `lmx` instead when it is on your session's
`PATH`.

### A keybinding

Current Omarchy releases keep your own keybindings in
`~/.config/hypr/bindings.lua`. Add one with `o.bind`, on a chord nothing
else uses; `omarchy menu keybindings --print` lists the ones taken:

```lua
-- lmx in ~/Work
o.bind("SUPER + SHIFT + CTRL + L", "lmx", "omarchy-launch-tui --app-id=org.omarchy.lemieux ~/.local/bin/lmx -C ~/Work")
```

Each project can have its own, with its own `-C` directory.

Older Omarchy releases (3.x) keep them in `~/.config/hypr/bindings.conf`,
in Hyprland's own format:

```text
bindd = SUPER SHIFT CTRL, L, lmx, exec, omarchy-launch-tui --app-id=org.omarchy.lemieux ~/.local/bin/lmx -C ~/Work
```

### Replacing Omarchy's agent shortcut

Omarchy's own agent shortcut, `SUPER + SHIFT + CTRL + A`, runs
`omarchy-agent --pick`. To have it open `lmx` instead, replace it in your
`bindings.lua`. `o.rebind` takes the same arguments as `o.bind`:

```lua
-- SUPER + SHIFT + CTRL + A opens lmx instead of Omarchy's agent picker
o.rebind("SUPER + SHIFT + CTRL + A", "Agent", "omarchy-launch-tui --app-id=org.omarchy.lemieux ~/.local/bin/lmx -C ~/Work")
```

`lmx` never makes this change for you. To undo it, delete the line: the
default binding is defined in Omarchy's own files, which this leaves as
they were, so it comes back. To give `lmx` windows the rules Omarchy gives
its agent windows, use `--app-id=org.omarchy.agent` instead.

### A menu entry

Your additions to the Omarchy menu go in
`~/.config/omarchy/extensions/omarchy-menu.jsonc`. An id without a dot puts
the row on the root menu:

```jsonc
{
  // lmx, the coding agent, on the root of the Omarchy menu
  "lmx": {"icon":"","label":"lmx","description":"Lemieux coding agent","action":"omarchy-launch-tui --app-id=org.omarchy.lemieux ~/.local/bin/lmx -C ~/Work"},
}
```

Comments must take whole lines. A comment after an entry on the same line
breaks the file, and the menu then shows none of your entries. Add the new
key inside your file's existing braces if you already have one.

### Omarchy's skills

On Omarchy, `lmx` discovers Omarchy's own agent skills automatically from
Omarchy's skills directory, so a session can follow the same Omarchy
instructions that other agents receive. `lmx skills` shows what was found
and where it came from, and `{"skills": {"omarchy": false}}` in
`~/.lmx/config.json` turns the discovery off. See
[Agent Skills](configuration.md#agent-skills-and-legacy-commands) and the
[CLI reference](cli.md).

## Starting lmx from a launcher or an agent selector

What a launcher, a keybinding or an agent selector such as Omarchy's
`omarchy-agent` needs to start `lmx`:

| To | Run | Notes |
| --- | --- | --- |
| Open the terminal UI | `lmx` | Works in the current directory |
| Open it in a directory | `lmx -C DIR` | Every command takes `-C` |
| Open it with a first prompt | `lmx --prompt TEXT` | Sends `TEXT` as the first message once the session is up: after first-run provider setup and the repository MCP servers question, never before. It shows in the transcript as if you had typed it, and the session stays open. Write `--prompt=TEXT` when `TEXT` starts with `-` |
| Answer one prompt and exit | `lmx run "PROMPT"` | Prints the answer and exits: 0 answered, 1 other, 2 usage, 3 credentials, 4 limit reached, 5 cancelled, 6 provider error ([exit status](cli.md#exit-status)) |
| Resume | `lmx -c`, `lmx --resume ID` | `-c` resumes the newest session that ran in this directory. With `--prompt`, the prompt is the resumed session's next message |
| Skip permission prompts | nothing | Permissions are off by default, so tools run without asking. `--sandbox` and `--permission-mode` are opt-ins ([permissions](configuration.md#permissions)) |
| Find settings and sessions | `~/.lmx` (or `$LMX_HOME`) | Updates and `lmx desktop uninstall` leave it alone |

`lmx "fix the bug"` is refused rather than read as a prompt. It names the
two commands that would have taken it: `lmx run 'fix the bug'` and
`lmx --prompt 'fix the bug'`.

An `omarchy-agent` adapter for `lmx` is one more arm in that script's `case`
statement:

```bash
lmx)
  # Permissions are off by default, so there is nothing to skip.
  command=(lmx)
  [[ -n ${prompt:-} ]] && command+=("--prompt=$prompt")
  ;;
```

`--prompt=` keeps a prompt that starts with `-` from being read as a flag.
Making `lmx` selectable as Omarchy's default agent needs that arm, and `lmx`
in `omarchy-default-agent`'s list of agents, added upstream in Omarchy:
`lmx` does not patch Omarchy's packaged files. Usage reporting for Omarchy's
agents widget is not provided yet.
