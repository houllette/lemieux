# Installing and updating lmx

`lmx` ships as a native archive for each platform. An archive carries its own
Erlang runtime, so the machine you install it on needs no Erlang or Elixir.
Each [GitHub release](https://github.com/houllette/lemieux/releases) holds the
archives, an installer, a checksum list (`SHA256SUMS`) and signatures. This
page covers installing, verifying, updating and removing `lmx`. To run it from
a source checkout instead, see [First session with lmx](getting-started.md).

## Platforms

| Platform | Archive | Status |
| --- | --- | --- |
| macOS, Apple Silicon | `lmx_macos_silicon.tar.gz` | Supported; not signed by Apple |
| macOS, Intel | `lmx_macos.tar.gz` | Supported; not signed by Apple |
| Linux x86-64 | `lmx_linux.tar.gz` | Supported with glibc 2.34 or newer |
| Windows x86-64 | `lmx_windows.tar.gz` | Experimental; needs Git Bash, which Git for Windows installs |
| Linux arm64, musl distributions such as Alpine, anything else | none | Use the [source checkout](getting-started.md) |

The Linux archive carries its own OpenSSL and terminal handling. From the
system it needs:

- glibc 2.34 or newer, with its `libgcc_s`: Ubuntu 22.04 and later, Debian
  12 and later, Fedora, RHEL 9 and its rebuilds (Rocky, Alma), openSUSE and
  Amazon Linux 2023;
- CA certificates, to reach HTTPS providers
  ([below](#linux-ca-certificates-and-containers));
- `awk`, which the archive's start scripts use. Every full installation has
  it; a slim container image may not, and then each start prints
  `awk: command not found`.

`tar` and `gzip` matter only if you unpack an archive by hand: the installer
unpacks with Python. Every release build runs the archive in clean Fedora,
Rocky Linux 9, Amazon Linux 2023, openSUSE Tumbleweed, Debian 12 slim and
Ubuntu 24.04 images. Each release's notes state the minimum macOS version of
its macOS archives.

An installation belongs to the user who installs it. Nothing is installed
system-wide, and the installer refuses to run as root unless you choose the
prefix yourself.

## Install a release

On macOS and Linux:

```sh
curl -fsSL https://github.com/houllette/lemieux/releases/latest/download/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"   # add this line to your shell profile
lmx --version
```

`install.sh` needs `curl` and Python 3.8 or newer. It uses `LMX_PYTHON` when
you set it, and otherwise the first of `python3`, `python3.15` … `python3.8`
on your `PATH`. Then:

1. It downloads `install.py`, `SHA256SUMS` and `SHA256SUMS.sig` from the
   latest release, checks `install.py` against `SHA256SUMS`, and runs it.
2. `install.py` verifies `SHA256SUMS.sig` with the release key pinned in it,
   and requires the signed `SHA256SUMS` to list `install.py` itself.
3. It downloads `update.json` and your platform's archive, checks both against
   the signed checksums, rejects unsafe archive entries, and installs. Nothing
   from the archive runs while it installs.

A successful install ends with:

```text
Installed /home/you/.local/bin/lmx. Add /home/you/.local/bin to PATH, then run lmx --version.
Signature and checksum verified: SHA256SUMS is signed with lmx's release key, and the archive matches it. Nothing from the archive was executed.
```

followed by the paths of the license files. Pass options after `sh -s --`:

| Option | Effect |
| --- | --- |
| `--prefix DIR` | Install under `DIR` instead of `~/.local` |
| `--release X.Y.Z` | Install that release instead of the latest |
| `--replace` | Install over a `PREFIX/bin/lmx` that this installer did not write |

```sh
curl -fsSL https://github.com/houllette/lemieux/releases/latest/download/install.sh | sh -s -- --prefix ~/tools
```

To upgrade, run `lmx update` ([Updating](#updates-from-the-tui)), or run the
installer again: it recognises the launcher it wrote and upgrades its own
installation without `--replace`. `--replace` is for a `PREFIX/bin/lmx` that
is something else — another program, or a launcher written for another
prefix — and says so when it is needed.

What goes where:

| Path | What it is |
| --- | --- |
| `PREFIX/bin/lmx` | A small launcher that runs the current version |
| `PREFIX/share/lmx/` | The installation, readable only by you (mode 0700) |
| `PREFIX/share/lmx/versions/VERSION-BUILD/` | One directory per installed version, kept for rollback |
| `PREFIX/share/lmx/current` | A link to the version that runs |
| `PREFIX/share/lmx/current/LICENSE`, `NOTICE`, `THIRD_PARTY_NOTICES` | The licenses of everything in the archive |

Your settings, keys and sessions are not in the installation. They live in
`~/.lmx`; see [where lmx keeps its data](../SECURITY.md#where-lmx-keeps-its-data).

The installer does not touch your desktop. On Linux, `lmx desktop install`
adds `lmx` to your application launcher when you want it there; see
[Desktop launchers and Omarchy](desktop.md).

Because an installation is yours alone, the launcher stops at once, with one
line and exit status 1, rather than run one that is not: "lmx: this
installation belongs to another user; reinstall it as yourself with
install.sh". It does the same when the installation is not writable (`lmx`
records each launch there). Those lines appear only when the launcher can
start at all. Usually another user's shell stops first, with "Permission
denied", because the installation directory is private; and when the
installation was deleted but `PREFIX/bin/lmx` was not, the shell reports
"not found".

### What the installer refuses

Each of these stops the installer before it installs anything, with a
sentence that says what to do instead:

- running as root without `--prefix`: an installation made with `sudo` could
  be run and updated only by root. Run it as the user who will use `lmx`. In
  a container where root runs `lmx`, pass `--prefix` yourself;
- Linux without glibc, such as Alpine, and Linux with glibc older than 2.34;
- Linux arm64, which has no build yet;
- Windows, MSYS and Cygwin, where the installer points to the
  [Windows](#windows-experimental) steps below;
- Python older than 3.8;
- a release without `SHA256SUMS.sig`: `lmx` does not install unsigned
  releases.

`install.py` prints `install.py: error:` before its refusals and exits with
status 2. The Python version checks, and `install.sh`'s own failures (no
`curl`, a download that failed), exit with status 1. `install.py`'s
downloads fail after 30 seconds without data, after 30 minutes in total, or
above 150 MB.

### Install an archive you downloaded

Download the archive, `install.py`, `SHA256SUMS` and `SHA256SUMS.sig` from the
same release, keep the archive's name, and run:

```sh
python3 install.py lmx_macos_silicon.tar.gz --checksums SHA256SUMS --signature SHA256SUMS.sig
```

`--prefix` and `--replace` work as above. Without `--signature` the installer
checks the archive against the `SHA256SUMS` you gave it, warns that it checked
no signature, and reports "Checksum verified against the SHA256SUMS you
supplied; no signature was checked, so its origin is unverified. Nothing
from the archive was executed."

### macOS and Gatekeeper

The macOS archives are not signed or notarized by Apple. `install.sh` and
`install.py` do not set the quarantine flag, so Gatekeeper does not block what
they install. An archive downloaded in a browser and unpacked with Finder or
`tar` carries `com.apple.quarantine` on every file, and Gatekeeper then blocks
the runtime's programs one by one.

So install a downloaded archive with `install.py`, as above. If you unpacked
one yourself, [verify it](#verify-a-download) first, then clear the flag on
the unpacked directory:

```sh
xattr -dr com.apple.quarantine ./lmx
```

Clearing the flag is your decision to trust what you verified; the installer
never does it for you. An archive you unpacked yourself also never updates
itself: it tells you when a new release is out and says where to download
it. An `lmx` installed with `install.sh`, or with `install.py` from an
archive you downloaded, updates itself.

### Linux, CA certificates and containers

`lmx` reaches HTTPS providers through the system's CA certificates:
`/etc/ssl/certs/ca-certificates.crt` or the other usual bundle locations.
Without one, the installer prints "warning: no CA certificates found; install
ca-certificates or lmx cannot reach HTTPS providers" and installs anyway.
Slim container images such as `debian:12-slim` and `ubuntu` ship without
one; install `ca-certificates` first.

A corporate certificate authority has to be added to the system store
(`update-ca-certificates`, `update-ca-trust`). `lmx` does not read
`SSL_CERT_FILE`, and it does not use `HTTP_PROXY` or `HTTPS_PROXY` either,
although the installer does; see
[proxies and private certificate authorities](troubleshooting.md#proxies-and-private-certificate-authorities).

On an Apple Silicon Mac, an x86-64 Linux container runs under Rosetta, where
the runtime's just-in-time compiler fails at startup. Set
`ERL_FLAGS='+JMsingle true'` in such a container, or use the macOS build on
the Mac itself.

### Windows (experimental)

There is no Windows installer. To install:

1. Install [Git for Windows](https://gitforwindows.org/). `lmx` runs the
   agent's commands and hooks with its Git Bash, and never uses WSL's
   `bash.exe`.
2. Download `lmx_windows.tar.gz`, `SHA256SUMS` and `SHA256SUMS.sig` from the
   [latest release](https://github.com/houllette/lemieux/releases/latest) and
   [verify them](#verify-a-download).
3. Unpack the archive into a new directory, for example
   `mkdir lmx && tar -xzf lmx_windows.tar.gz -C lmx`.
4. Run `lmx\bin\lmx.cmd`, or `lmx/bin/lmx` from Git Bash. Put that `bin`
   directory on your `PATH` to type `lmx`.

`lmx.cmd` starts PowerShell with `-ExecutionPolicy Bypass` for its own script
only; a Group Policy that disables scripts still stops it. Windows gets no
automatic or live updates: `lmx` says when a new release is out, and you
install it by unpacking the new archive into a fresh directory. The Ctrl-G
external editor does not work on native Windows yet.

Under WSL2, run `install.sh` inside WSL to get the Linux build instead.

## Verify a download

You can check a release yourself before you run any of it. You need OpenSSL 3
or newer and `sha256sum` (on macOS, `shasum -a 256`). macOS's own
`/usr/bin/openssl` is LibreSSL, which cannot load Ed25519 keys: run
`brew install openssl`, open a new terminal, and check that `openssl version`
says OpenSSL 3 or newer before you start.

From a directory holding the files you downloaded from release `vX.Y.Z`,
`SHA256SUMS` and `SHA256SUMS.sig` among them:

```sh
KEY=$(curl -fsSL https://raw.githubusercontent.com/houllette/lemieux/vX.Y.Z/dist/lmx/release-signing.pub)
echo "$KEY"   # compare it with the key in SECURITY.md
printf -- '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA%s\n-----END PUBLIC KEY-----\n' "$KEY" > lmx-release.pem
openssl base64 -d -A -in SHA256SUMS.sig -out SHA256SUMS.sig.bin
openssl pkeyutl -verify -pubin -inkey lmx-release.pem -rawin -in SHA256SUMS -sigfile SHA256SUMS.sig.bin
sha256sum -c --ignore-missing SHA256SUMS   # macOS: shasum -a 256 -c --ignore-missing SHA256SUMS
```

`openssl` prints "Signature Verified Successfully", and `sha256sum` prints
`OK` for each file you have. Compare the key with the copy in
[SECURITY.md](../SECURITY.md#release-signing-key), so that one channel vouches
for the other. (`MCowBQYDK2VwAyEA` is the fixed prefix that turns a raw
Ed25519 key into the PEM form OpenSSL reads.)

`SHA256SUMS` lists every other file in the release except the signatures:
the archives, `install.sh`, `install.py`, `update.json`, `LICENSE`, `NOTICE`,
the release notes, the upgrade plan and, once an earlier release exists, each
platform's upgrade qualification report. A verified `SHA256SUMS` therefore
covers them all.

Two more checks are available:

- With a source checkout, from `dist/lmx`:
  `mise exec -- mix lmx.release.verify --public-key "$KEY" /path/to/SHA256SUMS /path/to/update.json`.
  Each file needs its `.sig` beside it.
- Each release build publishes a build-provenance attestation, which shows
  that a file came from the release workflow at that tag. With the GitHub
  CLI:

  ```sh
  gh attestation verify lmx_linux.tar.gz --repo houllette/lemieux \
    --source-ref refs/tags/vX.Y.Z \
    --signer-workflow houllette/lemieux/.github/workflows/release.yml
  ```

When the checks pass, install with the `install.py` you verified (download
it with the others), from the same directory. Either install the archive you
verified, naming your platform's archive:

```sh
python3 install.py lmx_linux.tar.gz --checksums SHA256SUMS --signature SHA256SUMS.sig
```

or let it download the release itself: `python3 install.py --release X.Y.Z`.
Either way it checks the signature with the key pinned in the copy you
verified, and every file against the signed checksums. Do not finish with
`install.sh`: it downloads a fresh `install.py` and checksums from the latest
release every time it runs, so checking `install.sh` vouches for none of what
it then runs.

What signing covers: the maintainer signs `SHA256SUMS` (which `install.py`
checks) and `update.json` (which an installed `lmx` checks) with a key kept
offline, and the release workflow never signs. Your first `curl … | sh`
trusts HTTPS and GitHub unless you verify as above.

## Updates from the TUI

From a terminal:

```sh
lmx update            # install a newer release, after the checks below
lmx update --check    # only say whether one is available
```

`lmx update` needs no session, model key or readable config file, so it works
while a mistake in `~/.lmx/config.json` keeps the screen from opening. It
exits 0 when `lmx` is up to date or an update was installed, 1 when the check
or the installation failed, and 2 for a usage error. The new version runs the
next time `lmx` starts: a terminal UI that is open keeps running the version
it started on until you restart it, is never stopped by the update, and the
two never install at once. `/update` in the terminal UI does the same from
inside a session.

An `lmx` installed with `install.sh` or `install.py` also checks for updates
from its terminal UI and, on macOS and Linux, installs them too. An archive
you unpacked yourself, and the Windows build, only announce a new release.
`lmx run` and embedding applications never check.

The terminal UI checks after its first session is ready, after `/new` and
`/resume`, and hourly while it is open. A check that fails or finds no network
stays quiet. Each check asks GitHub for:

1. `update.json` from the latest release (at most 100 KB);
2. only when that names a newer stable version, the version's
   `update.json.sig` (at most 1 KB);
3. then the archive for your platform (at most 150 MB).

Requests carry the user agent `lemieux/VERSION`, so GitHub sees your IP
address and your `lmx` version.

Nothing is staged until `update.json.sig` verifies as an Ed25519 signature by
the key compiled into the running `lmx`, and staging verifies it again before
using any digest in it. The archive must match the signed SHA-256, pass the
archive safety checks, and carry a release identity that matches the signed
entry. Only a strictly newer stable version is offered, so an older manifest,
signed or not, cannot downgrade you.

When a newer release cannot be verified, `lmx` keeps running the version it
has and says so once per version:

- "… its update manifest is not signed yet, so lmx cannot verify it and did
  not install it": a release whose signatures are not uploaded yet. Wait; the
  next check installs it once they are.
- "… its update manifest failed signature verification, so the release may
  have been tampered with": do not install that release by hand, and report
  it through [SECURITY.md](../SECURITY.md#reporting-a-vulnerability). After
  the signing key changes, an installation that missed the release carrying
  the new key ends up here too; the release notes then say to reinstall with
  `install.sh`.

A verified update installs on its own:

- When the release declares a compatible path for your platform, only one
  `lmx` is running and you have selected no extensions of your own, the new
  code loads into the running terminal UI once it is idle: no turn running,
  no queued prompt, no session switching. Input pauses while it loads. The
  update is kept only when the same screen answers on the new version;
  otherwise it is rolled back.
- Otherwise `lmx` stages the full release and says to "restart lmx for it to
  take effect". Restarting is up to you; an active session is never stopped
  for an update. Save an unsent draft, quit, and start `lmx -c` to resume
  where you were.

`lmx update` and `/update` check now and, in an installation the installer
made, install a verified update. To change the defaults:

| Setting | Effect |
| --- | --- |
| `LMX_CHECK_UPDATES=0` | No automatic checks; `lmx update` and `/update` still check when you run them |
| `LMX_AUTO_UPDATE=0` | Notices only; `lmx update` and `/update` install, after the same verification |
| Selecting your own extensions | Turns automatic installation off, because a new version can break a bundle built for the old one; `lmx update` and `/update` still install, and say to rebuild them; see [upgrading extensions](support.md#upgrading-lemieux-and-extensions) |

A source checkout checks nothing on its own. There, `mix lmx update` and
`/update` fetch the configured Git upstream and fast-forward a clean branch,
then ask you to run `mix deps.get` and restart. They refuse local changes, a
detached `HEAD`, a
missing upstream, a Git operation in progress, and a branch that is ahead of
or diverged from its upstream. It never stashes or resets your work.

## Recovery and rollback

A live update that fails its health check is rolled back while you keep
working, and that build is set aside so no automatic retry selects it again;
wait for a newer release. If the rollback fails too, `lmx` says "The live
update and rollback failed. Save your draft and restart lmx to restore a
verified runtime." An update waiting for a restart keeps checking hourly, and
a newer release can replace it.

To go back to an earlier version, stop every running `lmx`, then point
`current` at a directory in `versions`:

```sh
ls ~/.local/share/lmx/versions
ln -sfn ~/.local/share/lmx/versions/VERSION-BUILD ~/.local/share/lmx/current
```

The next hourly check would install the newer release again; set
`LMX_AUTO_UPDATE=0` to stay on the version you chose.

A version that took a live update was changed in place, so its directory is
no longer a clean copy of the old release. To get one back, install that
release into a fresh prefix and use that launcher:

```sh
curl -fsSL https://github.com/houllette/lemieux/releases/latest/download/install.sh | sh -s -- --release X.Y.Z --prefix ~/lmx-X.Y.Z
```

The latest installer checks every release with the release-signing key it
pins. If the maintainers changed that key after X.Y.Z (the release notes say
so), it cannot verify X.Y.Z and refuses it. Install X.Y.Z with its own
installer instead, which checks it with the key it was signed with:

```sh
curl -fsSLO https://github.com/houllette/lemieux/releases/download/vX.Y.Z/install.py
python3 install.py --release X.Y.Z --prefix ~/lmx-X.Y.Z
```

An older `lmx` may refuse a transcript that a newer one extended; keep a copy
of the session directory before you go back. See
[transcript compatibility](transcript-compatibility.md). If an install or
update was interrupted, see
[interrupted installs](support.md#if-an-install-or-update-was-interrupted).

## Uninstall

If you added a desktop entry, run `lmx desktop uninstall` first. Then remove
the launcher and the installation, using your prefix if you chose one:

```sh
rm ~/.local/bin/lmx
rm -rf ~/.local/share/lmx
```

and the `PATH` line from your shell profile. On Windows, delete the directory
you unpacked.

Your own data stays behind in `~/.lmx`: settings and saved keys, MCP sign-in
tokens, transcripts, checkpoints, logs and crash dumps. Delete it too if you
want it gone (`rm -rf ~/.lmx`), together with the plugin cache
(`~/Library/Caches/lemieux` on macOS, `~/.cache/lemieux` on Linux).

## What an archive contains

- `bin/lmx`, the launcher (on Windows: `bin\lmx.cmd`, the PowerShell script it
  runs, and `bin/lmx` for Git Bash);
- the Erlang runtime, Elixir, Lemieux, the terminal UI's native library and
  the bundled [Jev compaction extension](https://github.com/houllette/lemieux/blob/main/dist/lmx/extensions/jev_compaction/README.md);
- `releases/VERSION/release.json`, the build identity the installer and the
  updater check;
- `LICENSE`, `NOTICE` and `THIRD_PARTY_NOTICES` at its root.
  `THIRD_PARTY_NOTICES` covers what the archive bundles: Erlang/OTP and the
  code inside its runtime, Elixir, OpenSSL and how it is linked, every Hex
  package with its own license files, the Go runtime in a command-runner
  helper, and the Rust crates in the terminal UI's native library. The
  installer keeps all three in `PREFIX/share/lmx/current/` and prints their
  paths.

No Erlang cookie ships in an archive, and neither do Erlang's development
tools (`erlc`, `escript`, `dialyzer` and the like), so the agent's commands
find your own. Each archive carries only its own platform's process helper,
and the Linux runtime and native libraries are stripped of debug symbols;
the macOS Apple Silicon archive is about 21 MB.

## How the binary behaves

- It never reads a `.env` from the directory it starts in; keep keys in your
  environment or in `~/.lmx/config.json`. The
  [trust model](../SECURITY.md#guarded-by-default) says why.
- An interrupt (Ctrl-C at `lmx run`), closing the terminal and `SIGTERM`
  cancel the running turn: the cancellation is recorded in the transcript and
  the running command's process group is killed. Then `lmx` stops and exits
  with 130 (interrupt), 129 (closed terminal) or 143 (`SIGTERM`); otherwise it
  exits with its own status. `SIGTERM` sent to the runtime's own process
  does the same and exits 143; the terminal UI first leaves its screen. If
  the launcher is killed outright, the runtime notices within about a second,
  stops the same way and then writes `lmx: the launcher is gone; stopping`
  on standard error; your shell reports the launcher's own status (137 for
  `SIGKILL`). `nohup lmx …` works. In the terminal UI, Ctrl-C is a key: it
  cancels a running turn, and pressed twice when nothing is running, it
  quits.
- Log lines go to `~/.lmx/logs/lmx.log` rather than the terminal, and only
  errors are logged. Setting `LMX_LOG_LEVEL` (`debug`, `info`, `warning` or
  `error`) changes the level and also prints them on standard error, except
  over the terminal UI's screen: while it is up, standard error gets no log
  lines unless you redirected it when you started `lmx` (on Windows, none
  at all), and the log file still has every one.
- A crash dump goes to `~/.lmx/crash/erl_crash.dump` (on Windows,
  `.lmx\crash` in your home directory), unless `ERL_CRASH_DUMP` names another
  file. A dump holds provider keys and transcript text: never attach one to
  a public issue.
- The commands the agent runs, hooks, MCP servers and the editor Ctrl-G
  opens get the environment you started `lmx` in: your own `PATH`, so your
  own `erl`, `elixir` and `mix` run rather than the bundled runtime's, and
  none of the variables the release sets for itself, its `ERL_CRASH_DUMP`
  included. The [trust model](../SECURITY.md#guarded-by-default) lists them.
  This needs the launcher: `bin/lmx-release` started directly cannot tell
  which variables were yours, so it takes the runtime's own directories off
  the front of `PATH` and removes those variables, even ones you had set.
- File names are UTF-8 whatever the locale says (`+fnu`), so a container,
  cron or `ssh host lmx` with no locale set prints no warning about a
  `latin1` encoding, not even on the first start after an install.
- `lmx` always runs without Erlang distribution and opens no port for it.
  Only when you start the underlying `bin/lmx-release` script yourself does
  `RELEASE_DISTRIBUTION=sname` (or `name`) turn distribution on; without
  `RELEASE_COOKIE`, the first such start writes a private cookie for that
  installation.
- `lmx --version` and `lmx help` write nothing to standard error (on Linux,
  given `awk`; see [Platforms](#platforms)).

`~/.lmx` above means `$LMX_HOME` when that is set. The log file also moves
with a config file kept elsewhere (`--config PATH`, `LMX_CONFIG`), and
`--config none` without `LMX_HOME` keeps none; crash dumps stay in
`~/.lmx/crash` either way.

## Build and inspect locally

To build an archive from a source checkout, on the platform you target:

```sh
cd dist/lmx
mise exec -- mix deps.get
LMX_TARGET=macos_silicon MIX_ENV=prod mise exec -- mix release --overwrite
_build/prod/rel/lmx/bin/lmx --version
```

`LMX_TARGET` is `macos_silicon`, `macos`, `linux` or `windows`. The archive
is `_build/prod/lmx-VERSION.tar.gz`. A local Linux build uses the Erlang your
toolchain installed, so it runs only on systems like the one that built it;
release builds use a static runtime from `scripts/build-static-otp.sh`. The
[release host README](https://github.com/houllette/lemieux/blob/main/dist/lmx/README.md)
shows how to install a local archive with `install.py` and how to test it. A
local build has no release signature, and the installer says so.

Maintainers cut releases with
[RELEASING.md](https://github.com/houllette/lemieux/blob/main/RELEASING.md).
