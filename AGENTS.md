# Template and Tool Authoring Reference

This repo provides custom image and tool definitions for [incus-spawn](https://github.com/Sanne/incus-spawn) (`isx`). It is registered as a search path in `~/.config/incus-spawn/config.yaml` and discovered automatically.

## Repo Layout

```
images/          # Image definitions (YAML)
tools/           # Tool definitions (YAML)
```

## Resolution Order

Both images and tools are discovered from four layers (later overrides earlier by `name`):

1. **Built-in** — bundled with isx
2. **User** — `~/.config/incus-spawn/{images,tools}/`
3. **Search paths** — directories in `config.yaml` `searchPaths` (this repo)
4. **Project-local** — `.incus-spawn/{images,tools}/`

---

## Image Definition

Each YAML file in `images/` defines a template. All fields optional except `name`.

### Core Fields

| Field | Type | Description |
|---|---|---|
| `name` | string | **Required.** Template name (e.g. `tpl-myproject`). |
| `description` | string | Human-readable label shown in the TUI. |
| `parent` | string | Parent template name. Omit for root images. |
| `type` | string | `container` (default), `vm`, or `kvm`. Inherits from parent chain. |

### Packages and Tools

| Field | Type | Description |
|---|---|---|
| `packages` | list of strings | dnf packages to install. Deduplicated against parent chain. |
| `remove_packages` | list of strings | dnf packages to remove. |
| `package_repos` | list of `{type, name}` | Extra package repos (e.g. `{type: copr, name: jdxcode/mise}`). |
| `tools` | list of tool refs | Tools to install (see [Tool References](#tool-references)). |

### Git Repos

```yaml
repos:
  - url: https://github.com/org/repo.git  # required, HTTPS only
    path: ~/repo                           # optional, derived from URL
    branch: main                           # optional
    prime: mvn -B dependency:go-offline    # optional, runs after clone
```

Declared repos are auto-trusted in `.claude.json`. Cloned with `--single-branch`, refspec widened for lazy fetch.

### Host Resources

```yaml
host-resources:
  - source: ~/.m2/repository       # host path (~ expanded)
    path: ~/.m2/repository         # container path (defaults to source)
    mode: overlay                  # readonly (default) | overlay | copy
```

| Mode | Behavior |
|---|---|
| `readonly` | Read-only bind mount (Incus disk device). |
| `overlay` | Read-only lower from host + writable upper in container. Persists across reboots via systemd. |
| `copy` | Copied into the template at build time. Also supports URL sources. |

Missing host paths are skipped with a warning. Child entries override parent entries matched by container path. On VMs, file-level resources (not directories) fall back to `copy`.

### Environment Variables

```yaml
env:
  - name: JAVA_HOME
    value: /usr/lib/jvm/java-25-openjdk
  - name: PATH
    value: /opt/bin
    strategy: append
    separator: ":"
```

See [Environment Variables](#environment-variables) for the full model.

### Shell and Actions

| Field | Type | Description |
|---|---|---|
| `workdir` | string | Working directory on shell entry. Defaults to first repo's path. |
| `shell-command` | string | Command to run instead of login shell (e.g. `claude`). |
| `default-action` | string | Action for Enter in TUI / `isx run`. Format: `tool-name` or `tool-name:action-id`. Inherits from parent. Changing it does **not** trigger a rebuild. |

### Skills

```yaml
# List shorthand (all fully qualified):
skills:
  - owner/repo@skill-name
  - owner/repo                    # all skills from a repo

# Object form (bare names resolved via repo):
skills:
  repo: myorg/claude-skills
  list:
    - security-review             # resolved as myorg/claude-skills@security-review
    - other-org/catalog@specific
```

### Base Image Fields (root images only)

| Field | Type | Description |
|---|---|---|
| `image` | string | Base OS image identifier. |
| `image_url` | string | Download URL for base image. Supports `{tag}`, `{arch}` placeholders. |
| `image_tag` | string | Tag substituted into `{tag}`. |
| `image_sha256` | map | Per-arch checksums: `{x86_64: ..., aarch64: ...}`. |
| `vm_image_url` | string | Download URL for VM base image. |
| `vm_image_sha256` | map | Per-arch checksums for VM image. |

### Other Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `mask_services` | list of strings | `[]` | Systemd services to mask. |
| `gui` | boolean | `false` | Enable GUI passthrough support. |
| `pinned` | boolean | `false` | Prevent automatic cleanup. |

---

## Tool Definition

Each YAML file in `tools/` defines a tool. All fields optional except `name`.

### Fields

| Field | Type | Description |
|---|---|---|
| `name` | string | **Required.** Tool identifier. |
| `description` | string | Human-readable description. |
| `requires` | list of tool refs | Dependencies, installed first. Resolved transitively; circular deps rejected. |
| `packages` | list of strings | dnf packages. All tool packages are batched into a single `dnf install` before any tool runs. |
| `package_repos` | list of `{type, name}` | Extra package repos. |
| `downloads` | list | Archives to download and extract (see [Downloads](#downloads)). |
| `run` | list of strings | Shell commands run as **root**, in order. |
| `run_as_user` | list of strings | Shell commands run as **agentuser**, in order. |
| `files` | list | Files to write (see [Files](#files)). |
| `env` | list | Environment variables (see [Environment Variables](#environment-variables)). |
| `verify` | string | Verification command (logged, non-fatal). |
| `ready` | string | Readiness check at instance start time (e.g. `systemctl is-active sshd`). |
| `parameters` | map | Build-time parameters (see [Parameters](#parameters)). |
| `actions` | list | TUI/CLI actions (see [Actions](#actions)). |

### Execution Order

All tool packages are installed in bulk first, then per-tool setup runs in this order:

`downloads` → `run` → `run_as_user` → `files` → `verify`

Environment variables are collected from all tools and the template chain after all installs, then written centrally to `/etc/profile.d/isx-env.sh`.

### Tool References

Used in image `tools` and tool `requires`. Two formats:

```yaml
tools:
  - maven-3                      # simple string
  - idea-backend:                # map with parameters
      memory: "8g"
```

### Downloads

```yaml
downloads:
  - url: https://example.com/tool-1.0.tar.gz   # required
    sha256: abc123...                            # recommended, enables caching
    extract: /opt                                # required, container directory
    links:                                       # optional, symlinks after extraction
      /opt/tool-1.0/bin/tool: /usr/local/bin/tool
    arch: x86_64                                 # optional, architecture filter (x86_64 | aarch64)
    extract_in_container: true                   # optional, for large archives
```

Downloads are cached on the host at `~/.cache/incus-spawn/downloads/`. Extraction happens on the host (container needs no `tar`/`curl`). Supported formats: `.tar.gz`, `.tgz`, `.tar.bz2`, `.tar.xz`, `.zip`.

For multi-arch tools, use separate entries with `arch: x86_64` and `arch: aarch64`.

### Files

```yaml
files:
  - path: /home/agentuser/.config/app.toml   # required, absolute path
    content: |                                # required
      key = "value"
    owner: agentuser                          # optional, user or user:group
```

Parent directories under `/home/` are chowned to the specified owner if created.

### Parameters

```yaml
parameters:
  memory:
    type: string                # string | integer | boolean | enum
    default: "2g"
    description: "JVM heap size"
    pattern: "^[0-9]+[gGmM]$"  # regex, for string type
  # integer: supports min, max
  # enum: supports options (list of strings)
  # boolean: "true" / "false" string values
```

Reference in `run`, `run_as_user`, `files`, `verify` via `${param_<name>}` (e.g. `${param_memory}`).

### Actions

```yaml
actions:
  - label: "Open '${repo_name}' in VS Code"   # supports template vars
    type: url                                   # url | command | shell | copy-to-clipboard
    id: launch                                  # optional, for default-action reference
    expand: repos                               # optional, duplicates action per declared repo
    requires_running: true                      # default: true
    auto_return: false                          # default: false
    url: "vscode://vscode-remote/ssh-remote+${name}${repo_path}"
```

Template variables: `${ip}`, `${name}`, `${parent}`. With `expand: repos`: `${repo_name}`, `${repo_path}`, `${repo_url}`.

---

## Environment Variables

Shared model for image `env` and tool `env`.

### Structured form

```yaml
env:
  - name: MAVEN_HOME
    value: /opt/maven
    # strategy: set (default) | set-if-unset | prepend | append
    # separator: " " (default, for prepend/append)
```

| Strategy | Behavior |
|---|---|
| `set` | Unconditional assignment. Two tools setting the same var to different values → build error. |
| `set-if-unset` | Only assign if not already defined. |
| `prepend` | Prepend to existing value using separator. |
| `append` | Append to existing value using separator. |

### Raw form (backward-compatible)

```yaml
env:
  - export FOO=bar    # written verbatim, no conflict detection
```

---

## Built-in Image Chain

Templates in this repo extend these built-in images:

```
tpl-minimal          Fedora 44 base: agentuser (UID 1000), systemd, passwordless sudo
  └─ tpl-dev         + tmux, starship, podman, gh, claude
       └─ tpl-java   + JDK 25, Maven 3.9, JAVA_HOME
```

### What each level provides

**tpl-minimal** — Bare Fedora 44 with `agentuser`, systemd, sudo. No dev tools.

**tpl-dev** — Adds tmux, starship prompt, podman (with Docker compat), GitHub CLI (`gh`), Claude Code (`claude`). Sets `DOCKER_HOST`, `TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED`.

**tpl-java** — Adds JDK 25 (`java-25-openjdk-devel`, javadoc, src), Maven 3.9.16. Sets `JAVA_HOME=/usr/lib/jvm/java-25-openjdk`, `MAVEN_HOME=/opt/apache-maven-3.9.16`.

### Built-in tools

| Tool | What it does |
|---|---|
| `maven-3` | Downloads Maven tarball, symlinks `mvn`, sets `MAVEN_HOME`. |
| `podman` | Installs podman + podman-docker + fuse-overlayfs, configures systemd socket + Docker symlinks, sets `DOCKER_HOST`. |
| `sshd` | Installs openssh-server, configures pubkey-only auth. Has `ready` check. |
| `tmux` | Installs tmux, writes `.tmux.conf`. Parameter: `auto_attach` (boolean). |
| `starship` | Multi-arch binary download, installs to `/usr/local/bin`, writes config, appends to `.bashrc`. |
| `idea-backend` | Requires `sshd`. Multi-arch IntelliJ download (`extract_in_container`). Parameter: `memory` (string, e.g. `"8g"`). Actions: URL-type with `expand: repos`. |
| `vscode-remote` | Requires `sshd`. Writes VS Code settings. Actions: URL-type with `expand: repos`. |
| `zmx` | Multi-arch binary download. Parameter: `auto_attach` (boolean). Sets `ZMX_DIR`. |

Java-only tools (no YAML, implemented in isx code): `claude`, `gh`, `pi`.

---

## Container Environment

- **User:** `agentuser` (UID 1000, passwordless sudo)
- **OS:** Fedora 44 (dnf)
- **Init:** systemd
- **Env file:** `/etc/profile.d/isx-env.sh` (generated by build)
- **Auto-set vars:** `ISX_CONTAINER`, `ISX_TEMPLATE`, `JAVA_TOOL_OPTIONS` (truststore for MITM CA)
- **Git:** HTTPS only (SSH URLs don't work through the proxy)
- **Credentials:** Containers hold placeholders (`sk-ant-placeholder`, `gho_placeholder`). The host MITM proxy injects real credentials into HTTPS traffic transparently.
- **Credential gate:** Building a template that includes `claude`/`pi` requires Anthropic auth; `gh` requires a GitHub token; `bob` requires a Bob API key — all configured on the host via `isx init`.

---

## Build Behavior

- Building an image auto-builds missing parents recursively.
- **From parent** (most templates): CoW-copies parent, installs only delta packages/tools.
- **Package deduplication:** packages already in ancestor chain are skipped.
- **Staleness:** templates are fingerprinted (image def + tool defs). The TUI flags stale templates. `isx build --out-of-sync` rebuilds them.
- **VMs:** `buildFromScratch` applies the full ancestor chain from YAML without needing parent instances. File-level host resources fall back to `copy`.
