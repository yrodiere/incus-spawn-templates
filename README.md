# incus-spawn-templates

Community template images and tool definitions for [incus-spawn](https://github.com/Sanne/incus-spawn).

These extend the built-in image chain (`tpl-minimal` → `tpl-dev` → `tpl-java`) with project-specific environments that include pre-cloned repositories, build tools, and primed dependency caches.

## Setup

Add this directory as a search path in `~/.config/incus-spawn/config.yaml`:

```yaml
searchPaths:
  - /path/to/incus-spawn-templates
```

Then build and branch:

```shell
isx build tpl-quarkus
isx branch tpl-quarkus my-feature
```

## Templates

Most templates inherit the `tpl-java` chain (JDK 25, Maven, Claude Code, GitHub CLI, tmux) through two intermediate base layers:

| Template | Parent | Description |
|----------|--------|-------------|
| `tpl-dev-base` | `tpl-java` | Base dev environment: Podman, IntelliJ IDEA backend, Gradle |
| `tpl-dev` | `tpl-dev-base` | Personal dev environment with Zsh, host resources, settings |
| `tpl-quarkus` | `tpl-dev` | Quarkus + quickstarts source |
| `tpl-quarkus-aot` | `tpl-quarkus` | Quarkus AOT experiments (includes Hibernate ORM and Models) |
| `tpl-quarkus-infra` | `tpl-dev` | Quarkus infrastructure projects (lottery, bot, search, GitHub app/action/api) |
| `tpl-hibernate-orm` | `tpl-dev` | Hibernate ORM source, Podman |
| `tpl-hibernate-reactive` | `tpl-hibernate-orm` | Hibernate Reactive source (includes ORM) |
| `tpl-wildfly` | `tpl-dev` | WildFly and WildFly Core source |
| `tpl-tamboui` | `tpl-dev` | TamboUI TUI framework source, selected skills |
| `tpl-incus-spawn` | `tpl-dev` | incus-spawn itself — recursive development with Incus and COPR tools |
| `tpl-tools` | `tpl-dev` | Development tools (shell-tools, git-tools, activity-report) |
| `tpl-websites` | `tpl-dev` | Hibernate websites (hibernate.org, in.relation.to, beanvalidation.org) |

### Coordinator

The `tpl-coordinator` template is a lightweight instance for driving work across other isx instances via the isx MCP server. It inherits directly from `tpl-minimal` (no Java/Maven overhead) and carries Claude Code (Sonnet), GitHub CLI, Atlassian MCP, and Zsh.

| Template | Parent | Description |
|----------|--------|-------------|
| `tpl-coordinator` | `tpl-minimal` | Lightweight coordinator for driving work across isx instances |

Build and branch with `--mcp-client` to enable MCP access:

```shell
isx build tpl-coordinator
isx branch coord --from tpl-coordinator --proxy-only --mcp-client
```

The `--mcp-client` flag registers the isx MCP server with Claude Code inside the instance, giving it access to tools like `create_instance`, `delegate`, `wait_any`, `get_diff`, and `destroy_instance`. The `--proxy-only` flag restricts network access to the proxy (Claude API + GitHub), which is all a coordinator needs.

Once inside, Claude Code can use the `/mcp__isx__coordinate` prompt for the full coordination playbook, or drive instances directly through the MCP tools.

## Tools

| Tool | Description |
|------|-------------|
| `atlassian-mcp` | Atlassian MCP server for Jira and Confluence |
| `develocity-mcp` | Develocity MCP server for build scans and test history |
| `code-assistant` | Smart code assistant launcher — resumes the most recent AI coding session |
| `firewalld` | Firewall with permissive defaults for container networking |
| `incus` | Nested Incus daemon for recursive development |
| `opencode` | Open source AI coding agent (opencode.ai) |
| `pinchtab` | [PinchTab](https://github.com/pinchtab/pinchtab) browser control for agents — headless Chromium, the `pinchtab` skill (params: `allowed_domains`, `mcp`) |
| `podman-custom` | Rootless podman with compose, Testcontainers support, and permissive short image names |
| `sdkman` | SDKMAN! — manager for JVM ecosystem tools |
| `sdkman-java` | OpenJDK installed via SDKMAN! |
| `sdkman-jbang` | JBang — run Java scripts and apps without build tools |
| `sdkman-maven` | Apache Maven installed via SDKMAN! |
| `sdkman-mvnd` | Maven Daemon (mvnd) for faster Maven builds |
| `sdkman-quarkus` | Quarkus CLI installed via SDKMAN! |
| `zsh` | Zsh as default shell |

### Code assistant choices

Configure the first-launch menu through tool parameters in an image definition:

```yaml
tools:
  - code-assistant:
      default: claude:opus
      choices: "claude:opus,claude:sonnet,codex,opencode:anthropic/claude-sonnet-4-6,bob"
```

`choices` is a comma-separated list with no spaces. Each entry is an assistant
name, optionally followed by `:` and its model ID or alias. Only installed
assistants appear. Entries without a model use the assistant's existing model
configuration; omitting `choices` offers all installed assistants this way.
Bob supports only the plain `bob` entry because its CLI has no model flag.
`default` prefers a listed combination (or all entries for that assistant when
it has no model suffix); it does not add a choice to the list.

The menu combines these choices with discovered working directories and skips
prompting when only one combination is available. Subsequent launches resume
the most recent session with its saved model. Run `code-assistant --new` inside
the container to choose a new assistant/model session instead.

The launcher and parameter configuration are written when the tool is installed.
Updating this definition does not update them on restart of an existing
container; existing containers need the tool reinstalled, or a new branch from
a rebuilt template.

## Contributing

To add a new template, create a YAML file in `images/` — see the [incus-spawn documentation](https://github.com/Sanne/incus-spawn) for the image definition format. Custom tools go in `tools/`.
