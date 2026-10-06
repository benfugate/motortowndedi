#!/usr/bin/env bash
# One-time interactive Steam login.
#
# Steam Guard cannot be answered by a container that is already running, so the first login on
# a new machine has to be done by hand:
#
#   docker compose run --rm motortown login
#
# steamcmd caches the result under $HOME/Steam (the persisted STEAM_DIR volume), so every
# later start logs in non-interactively. Re-run this if the container ever logs
# "Invalid Password" or asks for a Steam Guard code in `docker logs`.
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$*"; }

: "${PUID:=99}" "${PGID:=100}" "${STEAM_USERNAME:=}"

groupmod -o -g "${PGID}" users 2>/dev/null || true
usermod -o -u "${PUID}" -g "${PGID}" steam

mkdir -p "${STEAMCMD_DIR}" "${STEAM_DIR}"
chown -R "${PUID}:${PGID}" "${STEAMCMD_DIR}" "${STEAM_DIR}"

if [[ ! -f "${STEAMCMD_DIR}/steamcmd.sh" ]]; then
    log "Installing steamcmd"
    curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
        | tar -xz -C "${STEAMCMD_DIR}"
    chown -R "${PUID}:${PGID}" "${STEAMCMD_DIR}"
fi

if [[ -z "${STEAM_USERNAME}" ]]; then
    log "ERROR: STEAM_USERNAME is not set in .env"
    exit 1
fi

log "Logging in as ${STEAM_USERNAME}. Enter the password and Steam Guard code when asked."
log "Nothing is written to the repo; credentials are cached in the Steam volume."

exec setpriv --reuid "${PUID}" --regid "${PGID}" --init-groups \
    "${STEAMCMD_DIR}/steamcmd.sh" +login "${STEAM_USERNAME}" +quit
