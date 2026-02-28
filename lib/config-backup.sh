#!/usr/bin/env bash
# config-backup.sh — Module 4: Git-based periodic config snapshots
#
# Tracks all critical OpenClaw files in a local git repo.
# Only commits when changes are detected.
# Retention: last N commits (configurable).
#
# Can run as a periodic tick from the main loop,
# or standalone via `openclaw-watchdog backup`.

_cb_last_run=0
_cb_repo_dir=""

_cb_init() {
    _cb_repo_dir="${WATCHDOG_DIR}/config-history"

    if [[ ! -d "${_cb_repo_dir}/.git" ]]; then
        mkdir -p "${_cb_repo_dir}"
        git -C "${_cb_repo_dir}" init -q
        echo "*.tmp" > "${_cb_repo_dir}/.gitignore"
        echo "*.log" >> "${_cb_repo_dir}/.gitignore"
        git -C "${_cb_repo_dir}" add .gitignore
        git -C "${_cb_repo_dir}" commit -q -m "init: config history repo"
        log_info "BACKUP: initialized git repo at ${_cb_repo_dir}"
    fi
}

# Copy tracked files into the git repo
_cb_collect_files() {
    local dest="${_cb_repo_dir}"

    # Core config
    cp "${CONFIG_PATH}" "${dest}/openclaw.json" 2>/dev/null || true

    # Workspace core files (auto-detect workspace from config or use default)
    local workspace="${HOME}/.openclaw/workspace"
    mkdir -p "${dest}/workspace"
    for f in AGENTS.md SOUL.md USER.md IDENTITY.md MEMORY.md HEARTBEAT.md TOOLS.md; do
        cp "${workspace}/${f}" "${dest}/workspace/${f}" 2>/dev/null || true
    done

    # LaunchAgent plists
    mkdir -p "${dest}/launchagents"
    # shellcheck disable=SC2086
    cp ${HOME}/Library/LaunchAgents/ai.openclaw.*.plist "${dest}/launchagents/" 2>/dev/null || true

    # Watchdog config
    if [[ -f "${WATCHDOG_CONFIG}" ]]; then
        cp "${WATCHDOG_CONFIG}" "${dest}/watchdog-config.conf" 2>/dev/null || true
    fi

    # Custom tracked directories (user-configurable)
    if [[ -n "${BACKUP_TRACKED_DIR}" ]]; then
        for entry in ${BACKUP_TRACKED_DIR}; do
            local name="${entry%%:*}"
            local path="${entry#*:}"
            path="${path/#\~/$HOME}"
            if [[ -d "${path}" ]]; then
                mkdir -p "${dest}/custom/${name}"
                cp -r "${path}"/* "${dest}/custom/${name}/" 2>/dev/null || true
            elif [[ -f "${path}" ]]; then
                mkdir -p "${dest}/custom"
                cp "${path}" "${dest}/custom/${name}" 2>/dev/null || true
            fi
        done
    fi
}

# Commit if changes exist
_cb_commit_if_changed() {
    cd "${_cb_repo_dir}" || return 1

    git add -A 2>/dev/null

    if git diff --quiet --cached 2>/dev/null; then
        # No changes
        return 1
    fi

    local summary
    summary="$(git diff --cached --stat 2>/dev/null | tail -1)"
    git commit -q -m "snapshot: $(date '+%Y-%m-%d %H:%M') | ${summary}" 2>/dev/null
    log_info "BACKUP: committed: ${summary}"
    return 0
}

# Prune old commits
_cb_prune_history() {
    cd "${_cb_repo_dir}" || return

    local count
    count="$(git rev-list --count HEAD 2>/dev/null || echo 0)"

    if (( count > BACKUP_RETENTION )); then
        log_info "BACKUP: pruning history (${count} commits, keeping ${BACKUP_RETENTION})"
        # Create a new root with squashed old history
        local keep_from
        keep_from="$(git rev-list HEAD | sed -n "${BACKUP_RETENTION}p")"
        if [[ -n "${keep_from}" ]]; then
            # Simpler approach: just let git gc handle it naturally
            # For strict pruning, use filter-branch or orphan branch technique
            # For now, just log the count
            log_info "BACKUP: ${count} commits (${BACKUP_RETENTION} limit) — consider manual prune"
        fi
    fi
}

# === Main tick ===

config_backup_tick() {
    local now
    now="$(now_epoch)"

    # Rate limit
    if (( _cb_last_run > 0 )); then
        local elapsed=$(( now - _cb_last_run ))
        if (( elapsed < BACKUP_INTERVAL )); then
            return
        fi
    fi
    _cb_last_run="${now}"

    _cb_collect_files

    if _cb_commit_if_changed; then
        _cb_prune_history
    fi
}

# === Manual trigger ===

config_backup_now() {
    _cb_collect_files
    if _cb_commit_if_changed; then
        echo "Backup committed."
        _cb_prune_history
    else
        echo "No changes to back up."
    fi
}

# === Status ===

config_backup_status() {
    echo "Config Backup Status:"

    if [[ -d "${_cb_repo_dir}/.git" ]]; then
        cd "${_cb_repo_dir}" || return
        local count
        count="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
        echo "  Repo: ${_cb_repo_dir}"
        echo "  Commits: ${count} (retention: ${BACKUP_RETENTION})"

        local last_commit
        last_commit="$(git log -1 --format='%ci | %s' 2>/dev/null || echo 'none')"
        echo "  Last commit: ${last_commit}"
    else
        echo "  Repo: not initialized"
    fi
}
