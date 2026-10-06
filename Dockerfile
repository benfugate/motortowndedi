# Motor Town: Behind The Wheel - dedicated server.
#
# The dedicated server (Steam app 2223650) is a Windows-only tool: Steam's appinfo lists
# `oslist: windows` and there is no Linux depot, so the server runs under Wine.
#
# WINE, NOT PROTON, and this is load-bearing. Proton always launches its own fake steam.exe
# shim; with it present the Steamworks game-server login never completes, so the server
# reports `(Steam: N)`, advertises its raw local IP in the session URL instead of a
# `steam.<id>` identity, and never binds the Steam query port. Clients then time out with
# "UNetConnection::Tick: Connection TIMED OUT" against an unroutable address. Under plain Wine
# there is no shim, the game-server login succeeds, `(Steam: Y)` comes back and 27015 binds -
# matching what the original Windows host did. Verified both ways on the same host.
#
# The image contains Wine and steamcmd only. The server itself is downloaded by steamcmd on
# every container start, which is also how it stays up to date: restart the container and you
# are on the current build. That is why this image does not need rebuilding when the game
# updates.
#
# HOST REQUIREMENT: vm.max_map_count must be well above the 65530 default. The server reaches
# ~65.5k mappings and then cannot map rsaenh.dll / dssenh.dll / cryptnet.dll - the crypto DLLs
# Steam auth needs - which surfaces as "Cannot allocate memory", wine critical-section stalls,
# and the server dying at "Creating Session..". See the README.
FROM debian:13-slim

ENV DEBIAN_FRONTEND=noninteractive \
    DATA_DIR=/serverdata \
    HOME=/serverdata

ENV STEAMCMD_DIR=${DATA_DIR}/steamcmd \
    SERVER_DIR=${DATA_DIR}/serverfiles \
    STEAM_DIR=${DATA_DIR}/Steam \
    WINEPREFIX=${DATA_DIR}/wineprefix \
    XDG_CACHE_HOME=${DATA_DIR}/.cache \
    XDG_RUNTIME_DIR=/run/user/steam

# Steam app 2223650 ships its live build on a private, password-protected branch named
# `beta` (described in Steam as "Live Version"). The `public` branch is a 43-byte stub, and
# the `test` branch that older community images target is no longer the live one.
# Credentials are deliberately not declared here, even empty: they are runtime-only, and
# baking the names in as ENV makes them show up in `docker inspect` on every image.
ENV STEAM_APP_ID=2223650 \
    STEAM_BRANCH=beta \
    VALIDATE=false \
    SERVER_PARAMS="Jeju_World?listen? -server -useperfthreads" \
    PUID=99 \
    PGID=100 \
    UMASK=000

RUN set -eux; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dbus \
        lib32gcc-s1 \
        libfreetype6 \
        locales \
        procps \
        tar \
        wget \
        winbind \
        xz-utils; \
    mkdir -p /etc/apt/keyrings; \
    wget -qO /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key; \
    wget -qNP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/debian/dists/trixie/winehq-trixie.sources; \
    apt-get update; \
    apt-get install -y --install-recommends winehq-staging; \
    echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen; \
    locale-gen; \
    # Wine refuses to start without a machine-id.
    rm -f /etc/machine-id; \
    dbus-uuidgen --ensure=/etc/machine-id; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8

# GID 100 (`users`) already exists on Debian, which is also Unraid's default group.
RUN set -eux; \
    useradd --home-dir "${DATA_DIR}" --shell /bin/bash --gid 100 --uid 99 --no-create-home steam; \
    mkdir -p "${DATA_DIR}" "${XDG_RUNTIME_DIR}"; \
    chown steam:users "${DATA_DIR}" "${XDG_RUNTIME_DIR}"

COPY scripts/ /opt/scripts/
RUN chmod 0755 /opt/scripts/*.sh

# 7777 is the game port, 27015 the Steam query port. Listed for documentation only: the
# container runs with host networking, because on bridge the engine advertises the
# container's internal address and no client can reach it.
EXPOSE 7777/udp 27015/udp

ENTRYPOINT ["/opt/scripts/start.sh"]
