# leticl

A Common Lisp head for [letibot](https://github.com/deadtrickster/letibot) — the same
session, daemon and tools, drawn differently.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/deadtrickster/leticl/main/install.sh | sh
```

One line. It downloads the prebuilt archive for your platform from the
[latest release](https://github.com/deadtrickster/leticl/releases/latest) and unpacks it into
`~/.local/bin` — **no Lisp needed**, because the head is a frozen SBCL image saved with
`:executable t` that carries its own runtime.

Runs on Linux x86_64 and aarch64. macOS is not covered yet; the installer says so by name
rather than failing obscurely.

`LETICL_INSTALL_DIR` puts everything elsewhere; `LETICL_VERSION` selects a tag;
`LETICL_NO_DAEMON=1` installs the head only and leaves your existing `harnessd` alone.

The script is [`install.sh`](install.sh) in this repository — short, and worth reading before
you pipe a URL into a shell.

## What the install gives you

Eleven files, and which of them you are expected to provide is the part worth reading:

| from the archive | what it is |
|---|---|
| `leticl-head` | the head image, with SBCL inside it |
| `harnessd` | the daemon — from [letibot](https://github.com/deadtrickster/letibot)'s release |
| `letibot` | the launcher that finds or starts this folder's daemon |
| `letibot-askpass` | the helper `harnessd` execs when a command needs a `sudo` password |
| `libleticl_hl.so` | rano's tree-sitter highlighter behind a C ABI — the syntax colour |
| `libllama.so.0`, `libggml.so.0`, `libggml-cpu.so.0`, `libggml-base.so.0` | what `harnessd` links |
| `leticl`, `leticl-head-launch` | the seat, and the argument translator |

**Three libraries come from your system, not from here**, and the installer names them if
they are missing: `libstdc++6` (for `libllama`), `libgomp1` (for `libggml-cpu`) and
`libsqlite3-0` (for `harnessd`).

```sh
sudo apt-get install libstdc++6 libgomp1 libsqlite3-0    # Debian, Ubuntu
sudo dnf install libstdc++ libgomp sqlite-libs           # Fedora, RHEL
```

## What you have now — and what you do not

**A daemon, a head, and the libraries they link. They do not include a MODEL.**

Two things a fresh box still needs, and neither is a package:

- **A MODEL to tokenise with.** `harnessd` needs a vocabulary GGUF on every start —
  **a cloud provider too**, because the token ledger counts locally. Point it with
  `LETIBOT_VOCAB=/path/to/model.gguf`. It must be a single file: a split model's first shard
  is metadata only, carries no tensors, and `libllama` refuses it as a vocabulary.
- **AN AUTHORISATION ORACLE.** The `automode-edits` mode — the one `leticl` seats — refuses
  to open without one, and says so rather than opening at a weaker mode. Put its address in
  `~/.config/letibot/providers.toml` under `[gatekeeper] endpoint`, or pass `--oracle
  HOST:PORT`.

The head will tell you which one is missing. Neither is silent.

For a cloud provider instead of a local model, give the key one of three ways and they are
all documented in the `providers.toml` the installer writes:

```sh
export DEEPSEEK_API_KEY=sk-...        # then: leticl --provider deepseek
```

## Usage

```sh
leticl                    # attach to this folder's daemon, starting one if needed
leticl --continue         # reopen the newest session in this folder
leticl --session ID        # attach to a particular one
leticl --new TITLE        # attach, then open a fresh session
leticl --provider deepseek  # answer from a cloud provider rather than a local model
```

Everything `letibot` takes is forwarded unchanged — `leticl` is the same launcher with
`LETIBOT_HEAD` pointing at this head.

`leticl-head --help` prints the head's own usage. **`--help` and `--version` on their own
belong to SBCL**, whose runtime parses them before any Lisp runs — the head says so in its
usage rather than pretending otherwise.

## Build

The head is frozen from a running image:

```sh
sbcl --script freeze.lisp          # writes bin/leticl-head
scripts/freeze-safe                # the same, refusing to overwrite a good image on failure
```

The highlighting shim is a Rust crate in `native/hl` that takes rano by `tag = "v0.2.1"`:

```sh
cargo build --release --manifest-path native/hl/Cargo.toml
```

The seven Lisp libraries the head loads through ASDF are committed under `vendor/`, with
their upstream URLs and exact commits in [`vendor/SOURCES.txt`](vendor/SOURCES.txt).

Releases are built by [`.github/workflows/release.yml`](.github/workflows/release.yml) on a
`v*` tag. **One archive per platform, and its file list is a single declaration** —
`ARCHIVE_FILES` in `install.sh` — which `make-dist.sh` and the workflow both read rather than
keeping copies, because a list in two places separates and the one a person runs is not the
one CI checks.
