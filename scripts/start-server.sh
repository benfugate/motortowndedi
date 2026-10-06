#!/usr/bin/env bash
# Runs as the steam user: update the server from Steam, then launch it under Proton.
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Credentials come from the environment and are not declared in the image, so give them
# empty defaults rather than letting `set -u` abort.
: "${STEAM_USERNAME:=}" "${STEAM_PASSWORD:=}" "${STEAM_BETA_PASSWORD:=}"

# Launched by its path RELATIVE to SERVER_DIR, exactly as the game's own
# RunDedicatedServer.bat does. Handing wine an absolute Linux path makes it pass
# Z:\serverdata\... to the engine, and UE then hangs during startup: one thread, ~0% CPU,
# no log, forever. This is the single most confusing failure in the whole setup.
SERVER_EXE_REL="MotorTown/Binaries/Win64/MotorTownServer-Win64-Shipping.exe"
SERVER_EXE="${SERVER_DIR}/${SERVER_EXE_REL}"
CONFIG_FILE="${SERVER_DIR}/DedicatedServerConfig.json"

if [[ ! -f "${STEAMCMD_DIR}/steamcmd.sh" ]]; then
    log "Installing steamcmd"
    curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
        | tar -xz -C "${STEAMCMD_DIR}"
fi

# App 2223650 is a Tool that requires an account owning the game: anonymous login only sees a
# 43-byte stub on the `public` branch. The live build is on a private password-protected branch.
if [[ -z "${STEAM_USERNAME}" ]]; then
    log "ERROR: STEAM_USERNAME is empty. This app cannot be downloaded anonymously."
    exit 1
fi

steamcmd_args=(
    +@sSteamCmdForcePlatformType windows
    +force_install_dir "${SERVER_DIR}"
    +login "${STEAM_USERNAME}" ${STEAM_PASSWORD:+"${STEAM_PASSWORD}"}
    +app_update "${STEAM_APP_ID}"
)
[[ -n "${STEAM_BRANCH}" ]] && steamcmd_args+=(-beta "${STEAM_BRANCH}")
[[ -n "${STEAM_BETA_PASSWORD}" ]] && steamcmd_args+=(-betapassword "${STEAM_BETA_PASSWORD}")
[[ "${VALIDATE,,}" == "true" ]] && steamcmd_args+=(validate)
steamcmd_args+=(+quit)

log "Updating server (app ${STEAM_APP_ID}, branch ${STEAM_BRANCH:-public})"
update_ok=true
"${STEAMCMD_DIR}/steamcmd.sh" "${steamcmd_args[@]}" || update_ok=false

if [[ "${update_ok}" != "true" ]]; then
    # Do not silently run a stale build without saying so — a steamcmd failure that goes
    # unnoticed is how a server ends up months behind the clients that connect to it.
    log "WARNING: steamcmd did not finish successfully."
    if [[ ! -f "${SERVER_EXE}" ]]; then
        log "ERROR: no server executable present, nothing to run."
        exit 1
    fi
    log "WARNING: starting the existing install anyway; it may be out of date."
fi

if [[ ! -f "${SERVER_EXE}" ]]; then
    log "ERROR: ${SERVER_EXE} missing after update."
    exit 1
fi

# Report the installed build so a wedged update is visible in `docker logs`.
manifest="${SERVER_DIR}/steamapps/appmanifest_${STEAM_APP_ID}.acf"
if [[ -f "${manifest}" ]]; then
    log "Installed buildid: $(grep -oP '"buildid"\s+"\K[0-9]+' "${manifest}" | head -1)"
fi

# The Steamworks redistributable DLLs land at the install root; the server looks for them
# beside its own binary.
find "${SERVER_DIR}" -maxdepth 1 -type f -name '*.dll' \
    -exec cp -f {} "${SERVER_DIR}/MotorTown/Binaries/Win64/" \;

if [[ ! -f "${CONFIG_FILE}" ]]; then
    sample="${SERVER_DIR}/DedicatedServerConfig_Sample.json"
    if [[ -f "${sample}" ]]; then
        log "No DedicatedServerConfig.json found, seeding one from the sample"
        cp "${sample}" "${CONFIG_FILE}"
    else
        log "WARNING: no DedicatedServerConfig.json and no sample to copy from."
    fi
fi

# Initialise the wine prefix up front so a first-run wineboot does not race the server.
mkdir -p "${WINEPREFIX}" "${XDG_CACHE_HOME}" "${XDG_RUNTIME_DIR}"
if [[ ! -f "${WINEPREFIX}/system.reg" ]]; then
    log "Creating wine prefix at ${WINEPREFIX}"
    wineboot --init >/dev/null 2>&1 || true
    wineserver -w || true
fi

# `-log` is deliberately NOT passed, and neither is `-ABSLOG`. Either one makes UE allocate a
# console; wine spawns conhost.exe, and with no display driver in the container the first
# console write blocks forever - the process sits at ~0% CPU and never loads the world. A TTY
# on the container does not help. Without them the engine writes its log to a file under
# MotorTown/Saved, which is mirrored to stdout below so `docker logs` still works.
LOG_DIRS=("${SERVER_DIR}/MotorTown/Saved/ServerLog" "${SERVER_DIR}/MotorTown/Saved/Logs")
mkdir -p "${LOG_DIRS[@]}"

# Marker file so the tail below can only ever pick up a log from THIS run. Matching on
# "recently modified" instead would latch onto the previous run's log after a quick restart.
LAUNCH_MARKER="$(mktemp)"
(
    newest=""
    for _ in $(seq 1 180); do
        newest="$(find "${LOG_DIRS[@]}" -maxdepth 1 -type f -name '*.log' \
                    -newer "${LAUNCH_MARKER}" -printf '%T@ %p\n' 2>/dev/null \
                    | sort -rn | head -1 | cut -d' ' -f2-)"
        [[ -n "${newest}" ]] && break
        sleep 1
    done
    rm -f "${LAUNCH_MARKER}"
    [[ -n "${newest}" ]] && exec tail -n +1 -F "${newest}" 2>/dev/null
) &

log "Starting Motor Town dedicated server"
cd "${SERVER_DIR}"
exec wine "${SERVER_EXE_REL}" ${SERVER_PARAMS}
