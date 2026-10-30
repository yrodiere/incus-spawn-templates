#!/bin/bash
# scripts/instance-inventory.sh — Inventory of what's inside stopped isx instances
#
# Enumerates every stopped isx instance and reports raw data: git repos (branch, HEAD, remotes,
# dirty files, unpushed commits, stashes) and agent session artifacts (claude, codex, bob,
# opencode, pi). Deep inspection (starting the instance) is limited to allowed templates.
#
# Strictly read-only: starts stopped instances briefly to inspect, then stops them again.
# Never deletes, pushes, commits or modifies anything inside an inspected instance.
#
# Configuration (environment variables):
#   ISX_INVENTORY_TEMPLATES  Comma-separated template names to deeply inspect.
#                            Default: dev,dev-vm
#                            Instances from other templates get metadata only.
#
# Requires: isx, incus, jq
#
# Usage:
#   scripts/instance-inventory.sh
#   ISX_INVENTORY_TEMPLATES=dev,dev-vm,dev-java scripts/instance-inventory.sh
set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }

for cmd in isx incus jq; do
    command -v "$cmd" >/dev/null || die "'$cmd' is required but not found on PATH"
done

IFS=',' read -ra ALLOWED_TEMPLATES <<< "${ISX_INVENTORY_TEMPLATES:-dev,dev-vm}"

is_allowed_template() {
    local parent="$1"
    [ -z "$parent" ] && return 1
    for tpl in "${ALLOWED_TEMPLATES[@]}"; do
        [ "$parent" = "$tpl" ] && return 0
    done
    return 1
}

stopped_json=$(isx list --status=stopped --format=json 2>/dev/null)
instance_count=$(printf '%s' "$stopped_json" | jq 'length')

if [ "$instance_count" -eq 0 ]; then
    echo "# Instance Inventory"
    echo ""
    echo "No stopped instances found."
    exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# --- Helpers for in-instance inspection ---

declare -A _repo_owner

repo_owner() {
    local instance="$1" repo="$2"
    local key="$instance:$repo"
    if [ -z "${_repo_owner[$key]+x}" ]; then
        _repo_owner[$key]=$(incus exec "$instance" -- stat -c '%U' "$repo" 2>/dev/null || echo "root")
    fi
    printf '%s' "${_repo_owner[$key]}"
}

igit() {
    local instance="$1" repo="$2"; shift 2
    local owner
    owner=$(repo_owner "$instance" "$repo")
    if [ "$owner" = "root" ]; then
        incus exec "$instance" -- git -C "$repo" "$@" 2>/dev/null
    else
        local cmd="git -C $(printf '%q' "$repo")"
        local arg; for arg in "$@"; do cmd+=" $(printf '%q' "$arg")"; done
        incus exec "$instance" -- su -s /bin/sh "$owner" -c "$cmd" 2>/dev/null
    fi
}

iexec_user() {
    local instance="$1" user="$2"; shift 2
    local cmd=""
    local arg; for arg in "$@"; do cmd+="${cmd:+ }$(printf '%q' "$arg")"; done
    incus exec "$instance" -- su -s /bin/sh "$user" -c "$cmd" 2>/dev/null
}

# Detect agent sessions. Runs inside a started instance as the given user.
detect_sessions() {
    local instance="$1" user="$2" out="$3"
    local home
    home=$(incus exec "$instance" -- su -s /bin/sh "$user" -c 'echo $HOME' 2>/dev/null || echo "/home/$user")

    local found=false

    # Claude Code
    local claude_sessions
    claude_sessions=$(iexec_user "$instance" "$user" \
        find "$home/.claude/projects" -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -3 || true)
    if [ -n "$claude_sessions" ]; then
        found=true
        echo "- **Claude Code sessions**:" >> "$out"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local path="${line#* }"
            local cwd
            cwd=$(incus exec "$instance" -- su -s /bin/sh "$user" -c \
                "grep -m1 -o '\"cwd\":\"[^\"]*\"' $(printf '%q' "$path")" 2>/dev/null \
                | cut -d'"' -f4 || true)
            local ts="${line%%.*}"
            local when
            when=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
            echo "  - \`$path\` (last active: $when${cwd:+, cwd: \`$cwd\`})" >> "$out"
        done <<< "$claude_sessions"
    fi

    # Codex
    local codex_sessions
    codex_sessions=$(iexec_user "$instance" "$user" \
        find "$home/.codex/sessions" -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -3 || true)
    if [ -n "$codex_sessions" ]; then
        found=true
        echo "- **Codex sessions**:" >> "$out"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local path="${line#* }"
            local cwd
            cwd=$(incus exec "$instance" -- su -s /bin/sh "$user" -c \
                "grep -m1 -o '\"cwd\":\"[^\"]*\"' $(printf '%q' "$path")" 2>/dev/null \
                | cut -d'"' -f4 || true)
            local ts="${line%%.*}"
            local when
            when=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
            echo "  - \`$path\` (last active: $when${cwd:+, cwd: \`$cwd\`})" >> "$out"
        done <<< "$codex_sessions"
    fi

    # Pi
    local pi_sessions
    pi_sessions=$(iexec_user "$instance" "$user" \
        find "$home/.pi/agent/sessions" -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -3 || true)
    if [ -n "$pi_sessions" ]; then
        found=true
        echo "- **Pi sessions**:" >> "$out"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local path="${line#* }"
            local ts="${line%%.*}"
            local when
            when=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
            echo "  - \`$path\` (last active: $when)" >> "$out"
        done <<< "$pi_sessions"
    fi

    # Bob (SQLite)
    local bob_row
    bob_row=$(iexec_user "$instance" "$user" \
        sqlite3 -separator '|' -noheader "$home/.bob/db/bob.db" \
        "SELECT updated_at/1000, REPLACE(project_id,'file:',''), title FROM tasks WHERE parent_id IS NULL ORDER BY updated_at DESC LIMIT 3" \
        2>/dev/null || true)
    if [ -n "$bob_row" ]; then
        found=true
        echo "- **Bob tasks**:" >> "$out"
        while IFS= read -r row; do
            [ -z "$row" ] && continue
            local ts dir title
            ts=$(printf '%s' "$row" | cut -d'|' -f1)
            dir=$(printf '%s' "$row" | cut -d'|' -f2)
            title=$(printf '%s' "$row" | cut -d'|' -f3-)
            local when
            when=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
            echo "  - \`$dir\`: $title (last active: $when)" >> "$out"
        done <<< "$bob_row"
    fi

    # OpenCode (SQLite)
    local oc_row
    oc_row=$(iexec_user "$instance" "$user" \
        sqlite3 -separator '|' -noheader "$home/.local/share/opencode/opencode.db" \
        "SELECT CAST(strftime('%s', time_updated) AS INTEGER), directory, title FROM session ORDER BY time_updated DESC LIMIT 3" \
        2>/dev/null || true)
    if [ -n "$oc_row" ]; then
        found=true
        echo "- **OpenCode sessions**:" >> "$out"
        while IFS= read -r row; do
            [ -z "$row" ] && continue
            local ts dir title
            ts=$(printf '%s' "$row" | cut -d'|' -f1)
            dir=$(printf '%s' "$row" | cut -d'|' -f2)
            title=$(printf '%s' "$row" | cut -d'|' -f3-)
            local when
            when=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
            echo "  - \`$dir\`: $title (last active: $when)" >> "$out"
        done <<< "$oc_row"
    fi

    # Gemini (config presence only — no session JSONL)
    if incus exec "$instance" -- su -s /bin/sh "$user" -c \
            "test -f $home/.gemini/settings.json" 2>/dev/null; then
        found=true
        echo "- **Gemini**: installed (config present)" >> "$out"
    fi

    if ! $found; then
        echo "- No agent sessions found." >> "$out"
    fi
}

# Inspect a single instance. Writes markdown to $tmpdir/$name.md.
# Expects the instance to be stopped; starts it, inspects, stops it.
inspect_instance() {
    local name="$1" parent="$2" runtime="$3" created="$4" mcp_state="$5" mcp_purpose="$6"
    local out="$tmpdir/$name.md"
    local started=false

    stop_if_started() {
        if $started; then
            echo "  [$name] Stopping..." >&2
            incus stop "$name" 2>/dev/null || true
        fi
    }
    trap stop_if_started RETURN

    echo "## $name" >> "$out"
    echo "" >> "$out"
    echo "- **Parent**: ${parent:-unknown}" >> "$out"
    echo "- **Runtime**: $runtime" >> "$out"
    echo "- **Created**: ${created:-unknown}" >> "$out"
    [ "$mcp_state" != "null" ] && [ -n "$mcp_state" ] && \
        echo "- **MCP state**: $mcp_state" >> "$out"
    [ "$mcp_purpose" != "null" ] && [ -n "$mcp_purpose" ] && \
        echo "- **MCP purpose**: $mcp_purpose" >> "$out"
    echo "" >> "$out"

    if ! is_allowed_template "$parent"; then
        echo "_Skipped deep inspection (template \`$parent\` not in: ${ALLOWED_TEMPLATES[*]})._" >> "$out"
        echo "" >> "$out"
        echo "---" >> "$out"
        echo "" >> "$out"
        return 0
    fi

    echo "  [$name] Starting for inspection..." >&2
    if ! incus start "$name" 2>/dev/null; then
        echo "**Could not start instance.** Skipping deep inspection." >> "$out"
        echo "" >> "$out"
        echo "---" >> "$out"
        echo "" >> "$out"
        return 1
    fi
    started=true

    local ready=false
    for _ in $(seq 1 30); do
        if incus exec "$name" -- true 2>/dev/null; then
            ready=true
            break
        fi
        sleep 1
    done
    if ! $ready; then
        echo "**Exec not available after 30s.** Skipping deep inspection." >> "$out"
        echo "" >> "$out"
        echo "---" >> "$out"
        echo "" >> "$out"
        return 1
    fi

    # --- Git repositories ---
    local git_dirs
    git_dirs=$(incus exec "$name" -- find /home /root /opt /srv \
        -maxdepth 4 -name .git -type d 2>/dev/null || true)

    echo "### Git Repositories" >> "$out"
    echo "" >> "$out"

    if [ -z "$git_dirs" ]; then
        echo "No git repositories found." >> "$out"
        echo "" >> "$out"
    else
        while IFS= read -r git_dir; do
            [ -z "$git_dir" ] && continue
            local repo_dir="${git_dir%/.git}"

            echo "#### \`$repo_dir\`" >> "$out"
            echo "" >> "$out"

            local branch head_sha
            branch=$(igit "$name" "$repo_dir" rev-parse --abbrev-ref HEAD || echo "(detached)")
            head_sha=$(igit "$name" "$repo_dir" rev-parse --short=12 HEAD || echo "unknown")

            echo "- **Branch**: \`$branch\`" >> "$out"
            echo "- **HEAD**: \`$head_sha\`" >> "$out"

            # Remotes
            local remotes_raw fetch_lines
            remotes_raw=$(igit "$name" "$repo_dir" remote -v || true)
            fetch_lines=$(printf '%s\n' "$remotes_raw" | grep '(fetch)' || true)
            if [ -n "$fetch_lines" ]; then
                echo "- **Remotes**:" >> "$out"
                while IFS= read -r line; do
                    echo "  - \`$(printf '%s' "$line" | awk '{print $1}')\`: $(printf '%s' "$line" | awk '{print $2}')" >> "$out"
                done <<< "$fetch_lines"
            else
                echo "- **Remotes**: none" >> "$out"
            fi

            # Uncommitted changes
            local status_output
            status_output=$(igit "$name" "$repo_dir" status --porcelain || true)
            if [ -n "$status_output" ]; then
                local change_count
                change_count=$(printf '%s\n' "$status_output" | wc -l | tr -d ' ')
                echo "- **Uncommitted changes**: $change_count file(s)" >> "$out"
            else
                echo "- **Uncommitted changes**: none" >> "$out"
            fi

            # Stashes
            local stash_count
            stash_count=$(igit "$name" "$repo_dir" stash list | wc -l | tr -d ' ')
            [ "$stash_count" -gt 0 ] && echo "- **Stashes**: $stash_count" >> "$out"

            # Unpushed commits / untracked branch
            if [ "$branch" != "(detached)" ] && [ -n "$fetch_lines" ]; then
                local remote_names_list
                remote_names_list=$(printf '%s\n' "$fetch_lines" | awk '/\(fetch\)/{print $1}' | sort -u)
                local any_tracked=false
                while IFS= read -r rname; do
                    [ -z "$rname" ] && continue
                    if igit "$name" "$repo_dir" rev-parse --verify "$rname/$branch" >/dev/null 2>&1; then
                        any_tracked=true
                        local ahead
                        ahead=$(igit "$name" "$repo_dir" rev-list --count "$rname/$branch..HEAD" || echo "0")
                        [ "$ahead" -gt 0 ] && echo "- **Ahead of $rname/$branch**: $ahead commit(s)" >> "$out"
                    fi
                done <<< "$remote_names_list"
                if ! $any_tracked && [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
                    echo "- **Branch not on any remote**" >> "$out"
                fi
            fi

            # Last commit message (one line, for context)
            local last_msg
            last_msg=$(igit "$name" "$repo_dir" log -1 --format=%s || true)
            [ -n "$last_msg" ] && echo "- **Last commit**: $last_msg" >> "$out"

            echo "" >> "$out"
        done <<< "$git_dirs"
    fi

    # --- Agent sessions ---
    echo "### Agent Sessions" >> "$out"
    echo "" >> "$out"

    # Detect user accounts that might have sessions.
    local users
    users=$(incus exec "$name" -- find /home -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null || true)
    [ -z "$users" ] && users="agentuser"

    while IFS= read -r user; do
        [ -z "$user" ] && continue
        detect_sessions "$name" "$user" "$out"
    done <<< "$users"

    echo "" >> "$out"
    echo "---" >> "$out"
    echo "" >> "$out"
}

# --- Main: dispatch inspections, parallelizing containers ---
pids=()
names=()

for i in $(seq 0 $((instance_count - 1))); do
    name=$(printf '%s' "$stopped_json" | jq -r ".[$i].name")
    parent=$(printf '%s' "$stopped_json" | jq -r ".[$i].parent // empty")
    runtime=$(printf '%s' "$stopped_json" | jq -r ".[$i].runtime // \"container\"")
    created=$(printf '%s' "$stopped_json" | jq -r ".[$i].created // empty")
    mcp_state=$(printf '%s' "$stopped_json" | jq -r ".[$i].mcp_state // empty")
    mcp_purpose=$(printf '%s' "$stopped_json" | jq -r ".[$i].mcp_purpose // empty")

    names+=("$name")

    if [ "$runtime" = "virtual-machine" ] || ! is_allowed_template "$parent"; then
        # VMs sequentially (heavy), non-inspected templates inline (instant).
        inspect_instance "$name" "$parent" "$runtime" "$created" "$mcp_state" "$mcp_purpose"
    else
        # Containers in parallel.
        inspect_instance "$name" "$parent" "$runtime" "$created" "$mcp_state" "$mcp_purpose" &
        pids+=($!)
    fi
done

# Wait for all parallel inspections.
failed=0
for pid in "${pids[@]}"; do
    wait "$pid" || failed=$((failed + 1))
done

# Assemble report in instance order.
echo "# Instance Inventory"
echo ""
echo "_Generated $(date -Iseconds)_"
echo ""
echo "**Stopped instances**: $instance_count | **Inspecting templates**: ${ALLOWED_TEMPLATES[*]}"
echo ""

for name in "${names[@]}"; do
    if [ -f "$tmpdir/$name.md" ]; then
        cat "$tmpdir/$name.md"
    fi
done
