# motortowndedi

Motor Town: Behind The Wheel dedicated server in Docker, built for Unraid.

Forked from [sazquatch17/motortowndedi](https://github.com/sazquatch17/motortowndedi), which in
turn comes from tizon9804, mattieserver, ich777 and nodiaque.

## How it works

The dedicated server (Steam app `2223650`) is **Windows-only** — Steam's appinfo lists
`oslist: windows` and there is no Linux depot — so it runs under **Wine**.

### Wine, not Proton

Proton always launches its own fake `steam.exe` shim. With it present the Steamworks
game-server login never completes, and the server reports:

    [Session] URL: 192.168.29.120:7777 (Steam: N, Relay: Y, SteamNet: Y)

— its raw local address instead of a `steam.<id>` identity. Clients then fail with
`UNetConnection::Tick: Connection TIMED OUT`, and the Steam query port is never bound. Under
plain Wine the login succeeds:

    [Session] URL: steam.90294222981200909:7777 (Steam: Y, Relay: Y, SteamNet: Y)

and **27015 binds while 7777 is not bound at all** — game traffic rides Steam's relay, which
is why only the query port needs forwarding.

### Host requirement: vm.max_map_count

The server reaches ~65,500 memory mappings, just past the default `vm.max_map_count` of
65530. Beyond it, wine cannot map `rsaenh.dll`, `dssenh.dll` and `cryptnet.dll` — the crypto
DLLs Steam auth needs — which looks like `Cannot allocate memory`, critical-section stalls,
and the server dying at `Creating Session..`. The entrypoint refuses to start below 262144.

    sysctl -w vm.max_map_count=1048576

On Unraid, add that line to `/boot/config/go` so it survives a reboot.

The image contains **steamcmd and Proton only**. The server itself is downloaded by steamcmd on
every container start, so:

* **Updating the server is `docker restart motortown`.** No image rebuild, no Steam GUI.
* The published image does not go stale when the game updates.

## Setup

```bash
cp .env.example .env     # fill in STEAM_USERNAME and STEAM_BETA_PASSWORD
docker compose run --rm motortown login     # once, to answer Steam Guard
docker compose up -d
```

### Steam account

App `2223650` is a Tool that requires an account owning Motor Town. Anonymous login only sees a
43-byte stub on the `public` branch, so a real login is mandatory.

The live build lives on a **private, password-protected branch named `beta`** (shown in Steam as
"Live Version"). Older community images target `-beta test`, which is the previous branch name
and no longer gets the live build.

`docker compose run --rm motortown login` runs steamcmd interactively so Steam Guard can be
answered once. The result is cached in the `Steam` volume, so later starts are non-interactive.
Re-run it if the logs ever show `Invalid Password` or a Steam Guard prompt.

## Configuration

`DedicatedServerConfig.json` lives in the server volume at
`${APPDATA}/serverfiles/DedicatedServerConfig.json`, the same place the Windows build keeps it.
If it is missing on first start, it is seeded from the sample the game ships.

**Edit it with the container stopped** — the server rewrites the file on shutdown, so a live
edit is overwritten.

After a game update, `DedicatedServerConfig_Sample.json` in the same folder is regenerated and is
the only reliable list of newly added settings. Keys missing from your config fall back to the
game's defaults silently.

| Setting | Notes |
| --- | --- |
| `MaxHousingPlotRentalPerPlayer` | How many properties one player can hold. Stock default is 1. |
| `MaxHousingPlotRentalDays` | Rental length. Stock default 7. |
| `TimeOfDayMinutes` | Real minutes per in-game day. Was `DriveTimeOfDayMinutes` in older builds. |
| `bPauseSimulationWhileNoPlayers` | Stops the world ticking when the server is empty. |
| `HostWebAPIServerPort` | Must match `WEB_API_PORT` in `.env` for the published port to line up. |

## Data and backups

Everything that matters is in `${APPDATA}/serverfiles`:

```
serverfiles/DedicatedServerConfig.json
serverfiles/MotorTown/Saved/SaveGames/Worlds/0/Island.world     # the world, ~2 MB
serverfiles/MotorTown/Saved/SaveGames/Characters/0.sav          # characters
serverfiles/MotorTown/Saved/ServerLog/                          # logs, safe to prune
```

The game keeps three rolling `.Backup0/1/2` copies of each save of its own accord.

## Shutdown

`docker stop` sends SIGTERM, which is turned into a SIGINT for the server process — the server
treats that as a console close and writes the world before exiting. `stop_grace_period` is set
above `SHUTDOWN_TIMEOUT` so Docker does not kill it mid-save. Do not `docker kill` it.

## Migrating from a Windows install

Copy these out of
`...\steamapps\common\Motor Town Behind The Wheel - Dedicated Server\` into
`${APPDATA}/serverfiles/`, then `chown -R 99:100`:

* `DedicatedServerConfig.json`
* `MotorTown\Saved\SaveGames\`

steamcmd downloads the rest on first start.

## Ports and networking

Runs with **host networking**. On bridge the engine puts the container's internal address in
its session URL (`172.17.0.x:7777`), which no client can reach; on host it advertises the
host's real address.

| Port | Protocol | Purpose |
| --- | --- | --- |
| 27015 | UDP | Steam query — the only one that needs forwarding |
| 7777 | UDP | Game. Not bound when `Steam: Y`; traffic uses the Steam relay |
| `HostWebAPIServerPort` | TCP | Web admin API, only if `bEnableHostWebAPIServer` is true |

Because it is on host networking, `HostWebAPIServerPort` in `DedicatedServerConfig.json` binds
directly on the host, so it must not collide with anything else running there.

## Image

`ghcr.io/benfugate/motortowndedi:latest`, built and pushed on every push to `main`.
Dependabot tracks the Debian base image digest (auto-merged once CI passes) and the GitHub
Actions. Wine comes from the WineHQ `staging` repo and moves with the base image rebuild.
