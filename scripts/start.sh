#!/usr/bin/env bash
# Runs as root: fixes up ownership for the host's UID/GID, then hands off to the steam user.
# Its other job is shutdown — Motor Town writes its world on exit, so the container must not
# be killed out from under it.
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$*"; }

SERVER_EXE_NAME="MotorTownServer-Win64-Shipping.exe"

# A one-off interactive login, used once per machine to satisfy Steam Guard and cache the
# credentials in the steamcmd volume: `docker compose run --rm motortown login`.
if [[ "${1:-}" == "login" ]]; then
    exec /opt/scripts/steam-login.sh
fi

log "Setting UID:GID to ${PUID}:${PGID}"
groupmod -o -g "${PGID}" users 2>/dev/null || true
usermod -o -u "${PUID}" -g "${PGID}" steam
umask "${UMASK}"

mkdir -p "${STEAMCMD_DIR}" "${SERVER_DIR}" "${STEAM_DIR}" "${WINEPREFIX}" "${XDG_CACHE_HOME}" "${XDG_RUNTIME_DIR}"
chown "${PUID}:${PGID}" "${WINEPREFIX}" "${XDG_CACHE_HOME}" "${XDG_RUNTIME_DIR}" 2>/dev/null || true

# The server climbs to ~65.5k memory mappings. Below that it cannot map the crypto DLLs Steam
# auth needs and dies at "Creating Session..", so refuse to start rather than fail obscurely.
map_limit="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
if (( map_limit < 262144 )); then
    log "ERROR: vm.max_map_count is ${map_limit}; this server needs at least 262144."
    log "       Set it on the HOST (not in the container): sysctl -w vm.max_map_count=1048576"
    exit 1
fi

# A recursive chown over the server install costs several seconds, so only do it when the
# ownership actually looks wrong — which is really just the first start, or after seeding the
# volume from somewhere else.
for d in "${STEAMCMD_DIR}" "${SERVER_DIR}" "${STEAM_DIR}"; do
    if [[ "$(stat -c %u "${d}")" != "${PUID}" || "$(stat -c %g "${d}")" != "${PGID}" ]]; then
        log "Taking ownership of ${d}"
        chown -R "${PUID}:${PGID}" "${d}"
    fi
done

# Save data seeded from a Windows install usually arrives without the directory execute bit,
# because Compress-Archive/zip carries no Unix permissions. The engine then cannot create
# MotorTown/Saved/... and the server exits before it starts.
if [[ -d "${SERVER_DIR}" ]]; then
    broken="$(find "${SERVER_DIR}" -type d ! -perm -u+x -print -quit 2>/dev/null || true)"
    if [[ -n "${broken}" ]]; then
        log "Repairing directory permissions under ${SERVER_DIR} (seeded data missing +x)"
        find "${SERVER_DIR}" -type d ! -perm -u+x -exec chmod u+rwx,g+rwx {} + 2>/dev/null || true
    fi
fi

server_pid=""

# SIGINT is what the server treats as a console close: it saves the world and exits. SIGKILL
# or a plain container kill loses everything since the last autosave, so wait for it.
term_handler() {
    log "Shutdown requested, signalling the server to save and exit"
    local pid
    pid="$(pgrep -f "${SERVER_EXE_NAME}" || true)"
    if [[ -n "${pid}" ]]; then
        kill -INT ${pid} 2>/dev/null || true
        for _ in $(seq 1 "${SHUTDOWN_TIMEOUT:-120}"); do
            pgrep -f "${SERVER_EXE_NAME}" >/dev/null || break
            sleep 1
        done
        if pgrep -f "${SERVER_EXE_NAME}" >/dev/null; then
            log "WARNING: server still running after ${SHUTDOWN_TIMEOUT:-120}s, killing it"
            pkill -KILL -f "${SERVER_EXE_NAME}" 2>/dev/null || true
        else
            log "Server exited cleanly"
        fi
    fi
    [[ -n "${server_pid}" ]] && wait "${server_pid}" 2>/dev/null || true
    exit 0
}
trap term_handler SIGTERM SIGINT

# `setpriv` keeps the environment and does not fork a shell, so signals and the exit code are
# not swallowed the way `su -c` swallows them.
setpriv --reuid "${PUID}" --regid "${PGID}" --init-groups /opt/scripts/start-server.sh &
server_pid=$!

# `wait` on its own returns as soon as a trap fires, so loop until the child is really gone.
while kill -0 "${server_pid}" 2>/dev/null; do
    wait "${server_pid}" && rc=$? || rc=$?
done
log "Server process exited with code ${rc:-0}"
exit "${rc:-0}"
