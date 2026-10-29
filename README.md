# 📸 Immich Home Media Server for macOS

A personal media server (a Google Photos alternative) running on your Mac.
Photos and videos from your iPhone are backed up automatically, stored at home,
and reachable from anywhere.

What makes this setup different:

- **Hybrid storage** — a single variable switches the library between the Mac's
  internal disk and an external drive, which is used in full as the cloud.
- **Lightweight** — hard CPU/RAM limits on every container; the ML model is
  unloaded from memory after 5 minutes of inactivity.
- **Plug & Play** — connect the drive and the server starts by itself: the
  LaunchAgent waits for the volume, launches Docker Desktop if it is not running
  and brings the stack up. Hotkeys for starting up and safely ejecting the drive.
- **No manual builds** — official images only; any change is applied with
  `make restart`.

---

## 1. Prerequisites

| What | How |
|---|---|
| Docker | [Docker Desktop](https://www.docker.com/products/docker-desktop/) or [OrbStack](https://orbstack.dev) (lighter and faster — recommended) |
| Xcode CLI Tools | `xcode-select --install` (provides `git` and `make`) |

In Docker Desktop settings, allocate **4 CPUs and 6 GB RAM** — that is plenty.
OrbStack allocates resources dynamically, so there is nothing to configure.

---

## 2. Start from scratch (5 minutes)

```bash
git clone <repository-url> homelab && cd homelab
cp .env.example .env
```

Open `.env` and adjust three things:

```bash
STORAGE_TYPE=ssd                                    # local or ssd
SSD_STORAGE_PATH=/Volumes/External                  # the whole drive is the cloud
SSD_VOLUME_NAME=External                            # volume name exactly as in Finder
DB_PASSWORD=...                                     # a fresh one: make secret
```

> ⚠️ **Format the external drive as APFS** (Disk Utility → Erase → APFS, GUID
> partition map). On macOS 26 an exFAT volume is mounted through FSKit with no
> POSIX ownership and no symlinks; Docker bind mounts on it are slow and
> unreliable. APFS gives normal permissions and native speed.

> ⚠️ The password in `.env.example` is public — it lives in the repository.
> Generate your own with `make secret` and put it into `DB_PASSWORD`
> **before the first start** (once the database is initialized, changing the
> password requires recreating the volume).

Check the configuration and start:

```bash
make doctor
make start
```

The first start downloads ~3 GB of images. When the "Immich запущен"
notification appears, open **http://localhost:2283** and create the admin user.

Then install the macOS automations (once):

```bash
make install
```

---

## 3. Connecting from an iPhone

### At home, over Wi-Fi

1. Install the **Immich** app from the App Store.
2. Find the Mac's address on the network: `make doctor` → the `LAN-адрес` line.
3. In the app, enter the **Server Endpoint URL**: `http://192.168.x.x:2283/api`
4. Sign in with your login and password.
5. `Settings → Backup` → enable **Foreground/Background Backup** and pick the
   albums to upload.

> To keep the Mac's address stable, reserve a static IP for it in your router
> settings (DHCP reservation).

### Away from home, via Tailscale (free, no port forwarding)

1. Install [Tailscale](https://tailscale.com) on both the Mac and the iPhone and
   sign in with the same account.
2. Find the Mac's address inside the Tailscale network:
   ```bash
   tailscale ip -4
   ```
3. In the Immich app, use `http://100.x.x.x:2283/api` — this address works both
   at home and on any other network.
4. Optionally enable **MagicDNS** in Tailscale and use
   `http://your-mac.your-tailnet.ts.net:2283/api`.

The Mac must stay powered on and awake. Disable automatic sleep:
`System Settings → Battery → Options → Prevent automatic sleeping`.

---

## 4. The external drive as the cloud

`SSD_STORAGE_PATH` points at the **root of the volume** — the drive is used in
full. The scripts lay out two directories there:

```
/Volumes/External/library      originals, thumbnails, Immich's own structure
/Volumes/External/db-backup    database dumps (the last DB_BACKUP_KEEP ones)
```

The PostgreSQL data directory is **not** on the drive: on macOS it lives in a
Docker named volume (`immich_db_ssd`), because postgres refuses to start on a
bind mount under Docker Desktop. That is why `make stop` dumps the database onto
the drive first — the library plus the latest dump is a complete backup.

Switching from the local Mac disk (once, with a library already in place):

```bash
make stop
rsync -avh --progress /Users/YOU/Pictures/ImmichData/library/ /Volumes/External/library/
# in .env: STORAGE_TYPE=ssd, SSD_STORAGE_PATH=/Volumes/External, SSD_VOLUME_NAME=External
make start
```

The `local` and `ssd` modes have **independent databases** (separate named
volumes), so an existing library is carried over with
`make backup-db` → `make restore-db FILE=...`, not by copying volume directories.

### What happens with the drive automatically

- **Plug the cable in** → the LaunchAgent sees the new volume in `/Volumes`,
  waits for it to mount, starts Docker Desktop if needed and calls `start.sh`.
  Open `http://localhost:2283` and the gallery is there.
- **Want to disconnect** → `⌃⌥⌘O` (or `make stop`): the database is dumped onto
  the drive, containers stop, buffers are flushed and the disk is ejected via
  `diskutil eject`. The "Диск извлечён" notification means the cable is safe to
  pull.
- **Cable yanked without stopping** → the LaunchAgent sees the volume disappear
  and shuts the containers down. The library survives (Immich writes files
  atomically), but the newest database changes may be lost — avoid this.
- **Starting without the drive** → nothing comes up. `immich-server` is bound to
  the library with `create_host_path: false`, so Docker refuses to start it
  rather than silently creating an empty folder and writing to the Mac's disk.
- **Stack stopped by hand** (`make restart`, `make stop --no-eject`) → a pause
  flag is set and the watcher leaves it alone. The flag is cleared by `make
  start` or by replugging the drive.
- **Self-healing** → besides `/Volumes` events the watcher also runs at login and
  every `WATCH_INTERVAL` seconds, so the stack comes back after a reboot or sleep.

Watcher log: `make watch-log`.

---

## 5. Hotkeys and one-click launch

| Action | Shortcut | Alternative |
|---|---|---|
| Start Immich | `⌃⌥⌘I` | `~/Applications/Immich Start.app` |
| Stop + eject SSD | `⌃⌥⌘O` | `~/Applications/Immich Stop.app` |

Installed by `make install`. If a shortcut does not work right away:
`System Settings → Keyboard → Keyboard Shortcuts → Services` — tick the boxes for
**Immich Start** and **Immich Stop** (a re-login is sometimes required).

Both `.app` bundles can be dragged into the Dock, launched from Spotlight, or
added to the **Shortcuts** app (the "Open App" action) with a custom key
combination assigned there.

---

## 6. Updating

```bash
make update
```

Pulls fresh official images, restarts the stack, cleans up old layers and shows a
notification with the new version. There is nothing to build — Immich ships as
ready-made containers.

---

## 7. All commands

```
make start      Start the server
make stop       Stop it (+ eject the SSD in ssd mode)
make restart    Apply changes to .env / docker-compose.yml
make update     Update Immich to the latest version
make install    Install the macOS automations
make uninstall  Remove the macOS automations
make logs       Live logs
make ps         Container status
make status     CPU / RAM usage
make doctor     Check the environment and .env
make watch-log  Auto-start watcher log
make shell-db   psql console
make secret     Generate a database password
make prune      Remove unused images
make backup-db  Dump the database to <storage>/db-backup
make restore-db Restore the database: make restore-db FILE=...
```

---

## 8. Performance tuning

Edited in `.env`, applied with `make restart`.

| Variable | Default | What it does |
|---|---|---|
| `ML_CPU_LIMIT` / `ML_MEM_LIMIT` | `2.0` / `2g` | Ceiling for face recognition and smart search |
| `ML_MODEL_TTL` | `300` | Seconds of inactivity before the model is unloaded from RAM |
| `ML_WORKERS` | `1` | ML workers. More than 1 only on a powerful Mac |
| `SERVER_CPU_LIMIT` / `SERVER_MEM_LIMIT` | `2.0` / `2g` | Ceiling for the API and background jobs |
| `SERVER_NODE_HEAP_MB` | `1536` | Node.js heap ceiling |
| `DB_CPU_LIMIT` / `DB_MEM_LIMIT` | `1.0` / `1g` | Ceiling for PostgreSQL |

**If the Mac is still noisy.** Most of the load comes from Immich background
jobs. Go to the web UI → `Administration → Settings → Jobs` and lower the
concurrency of `Thumbnail Generation`, `Video Conversion` and `Smart Search` to
1. These settings live in the database, not in `.env`.

**Fully quiet mode** — disable ML entirely (face and text search stop working,
everything else keeps running):

```bash
docker compose stop immich-machine-learning
```

To see actual consumption: `make status`.

---

## 9. Troubleshooting

| Symptom | What to do |
|---|---|
| `Docker не запущен` | Open Docker Desktop / OrbStack and wait for the green status |
| `Внешний диск не подключён` | Plug the SSD in, or set `STORAGE_TYPE=local` in `.env` |
| The disk could not be ejected | `make logs` shows what is holding files. Waiting 10 seconds and repeating `make stop` usually helps |
| The web UI does not open | `make ps` — are all containers `healthy`? The first database start can take up to 2 minutes |
| The iPhone cannot see the server | Check that the phone is on the same Wi-Fi network and that the URL ends with `/api` |
| Port 2283 is busy | Change `IMMICH_PORT` in `.env` and run `make restart` |
| The drive keeps disappearing from `/Volumes` | A bus-powered HDD browning out: plug it straight into the Mac, not through a hub, and try another cable. Check with `diskutil list external` |
| `I/O error` when the container writes to the drive | Either the volume dropped off the bus, or it is still exFAT. Reformat as APFS |
| Nothing starts after plugging the drive in | `make watch-log`; `make doctor` shows whether the LaunchAgent is loaded and whether a manual pause is set |

Full reset (⚠️ deletes the entire library):

```bash
make stop
rm -rf /path/to/ImmichData
make start
```

---

## 10. Backups

Two things make up a complete backup, and neither is useful alone:

- `library/` on the drive — originals, thumbnails, Immich's own layout;
- a database dump in `db-backup/` — albums, faces, metadata.

`make stop` writes a fresh dump automatically and keeps the last
`DB_BACKUP_KEEP` of them. On demand:

```bash
make backup-db
```

Copying the whole drive elsewhere:

```bash
make backup-db
make stop --no-eject
rsync -avh --delete /Volumes/External/ /Volumes/Backup/Immich/
make start
```

Restoring onto a clean install: put `library/` back in place, start the stack and
run `make restore-db FILE=/Volumes/External/db-backup/immich-….sql.gz`.

Time Machine can back the drive up as well — `library/` and `db-backup/` are
ordinary files. The database itself is not on the drive, so there is nothing
there that must not be copied hot.
