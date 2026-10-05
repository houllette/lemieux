# Records docs/assets/lmx-preview.gif, the demo at the top of the README, with
# VHS (https://github.com/charmbracelet/vhs). From the repository root:
#
#     rm -rf /tmp/lmx-preview-home && mkdir /tmp/lmx-preview-home
#     vhs scripts/lmx-preview.tape
#
# The recording shows lmx editing a small sample project, the project check
# lmx runs after an edit (/verify reports it), and /undo taking the edit back.
#
# Before you run it:
#
#   * Install vhs (it needs ttyd and ffmpeg) and have git on PATH.
#   * Have lmx on PATH. To record from a source checkout instead, export
#       LMX_DEMO_COMMAND="mise -C /path/to/lemieux exec -- mix lmx"
#     and keep mise, Mix and Hex reachable under the fresh HOME below:
#       export MISE_DATA_DIR="$HOME/.local/share/mise" MIX_HOME="$HOME/.mix" HEX_HOME="$HOME/.hex"
#   * Give it a model, which this recording uses for a few requests: export
#     one provider's key (ANTHROPIC_API_KEY, OPENAI_API_KEY, ...), or run
#     Ollama with a model that can call tools and OLLAMA_CONTEXT_LENGTH=65536
#     (docs/getting-started.md, "Use a local model"). lmx picks the model as
#     it always does; export LMX_MODEL=PROVIDER:MODEL to choose one. A model
#     whose price ReqLLM knows shows a cost on the status line.
#   * Start from an empty /tmp/lmx-preview-home, as above: an earlier take
#     leaves its session, history and sample project there.
#
# lmx runs with a fresh, empty HOME (/tmp/lmx-preview-home), so no personal
# settings, history, memory or saved keys appear, and no path on screen
# carries your user name. The sample project is a shell script and its test,
# created in that HOME; tests/run.sh is the check lmx discovers, and its
# --shout case fails until the agent adds the flag. Nothing here lists a
# directory with `ls -la`, which would print the file owner.
#
# The tape also writes tmp/lmx-social-preview.png, a 1280x640 still for
# GitHub's social preview (Settings > General > Social preview); tmp/ is
# ignored by git. Keep the GIF under about 1.5 MB: if it comes out larger,
# lower the Framerate or shorten the visible Sleeps.

Output docs/assets/lmx-preview.gif

Require git

Set Shell "bash"
Set FontSize 16
Set Width 1280
Set Height 640
Set Padding 16
Set Framerate 20
Set TypingSpeed 40ms
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set WaitTimeout 5m

# Setup, off camera. Hide must be the first command after the settings: only
# then does VHS run this block before it starts recording, so no frame of the
# bare prompt is captured. The Env lines take effect before the shell starts
# wherever they sit. Then a dark theme so the terminal is not probed, and the
# sample project, committed so /undo has a git repository to snapshot.
Hide
Env HOME "/tmp/lmx-preview-home"
Env LMX_CHECK_UPDATES "0"
Env COLORTERM "truecolor"
Type@1ms "mkdir -p tmp ~/.lmx ~/greet/tests && cd ~/greet"
Enter
Type@1ms `printf '{"version": 1, "theme": "dark", "notifications": false}\n' > ~/.lmx/config.json && chmod 600 ~/.lmx/config.json`
Enter
Type@1ms `printf '%s\n' '#!/bin/sh' '# Usage: sh greet.sh [NAME]' 'name=${1:-world}' 'echo "Hello, $name!"' > greet.sh`
Enter
Type@1ms `printf '%s\n' '#!/bin/sh' 'set -eu' 'cd "$(dirname "$0")/.."' '[ "$(sh greet.sh Ada)" = "Hello, Ada!" ] || { echo "FAIL: greet.sh Ada"; exit 1; }' '[ "$(sh greet.sh --shout Ada)" = "HELLO, ADA!" ] || { echo "FAIL: greet.sh --shout Ada"; exit 1; }' 'echo "all tests passed"' > tests/run.sh`
Enter
Type@1ms `git init -q -b main && git add . && git -c user.name=demo -c user.email=demo@example.com commit -qm "greet.sh and its test" && clear`
Enter
Type@1ms `${LMX_DEMO_COMMAND:-lmx} -C "$PWD"`
Enter
# The header reads "lemieux (vX) · ~/greet · NAME · ..." once the screen is up.
Wait+Screen@3m /lemieux \(v/
Sleep 2s
Show

# The prompt, and the first seconds of the agent reading and editing.
Sleep 1s
Type "Add a --shout flag to greet.sh that prints the greeting in capital letters. Don't run the tests yourself: lmx runs them after your edit."
Sleep 500ms
Enter
Sleep 8s

# Cut the wait for the model. The turn's closing summary line ends with
# "N tool calls"; by then lmx has run tests/run.sh.
Hide
Wait+Screen@5m /\d+ tool calls?/
Sleep 1s
Show
Sleep 5s
Screenshot tmp/lmx-social-preview.png

# What the post-edit check found. /verify and /undo take arguments, so Enter
# on the bare name only completes it and opens the argument menu; typed with
# the trailing space, the first Enter runs the command.
Type "/verify "
Sleep 300ms
Enter
Wait+Screen@30s /verify: (on|off)|verify is not part of this session/
Sleep 3s

# Take the turn back.
Type "/undo "
Sleep 300ms
Enter
Wait+Screen@1m /undid turn|nothing (was )?put back|nothing to (put back|undo)|not undone yet|no checkpoints are recorded/
Sleep 5s

# Leave cleanly, off camera, so the transcript is closed.
Hide
Type "/quit"
Enter
Sleep 2s
