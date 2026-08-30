# 📸 Immich Home Media Server for macOS

A personal media server (a Google Photos alternative) running on your Mac.
Photos and videos from your iPhone are backed up automatically, stored at home,
and reachable from anywhere.

What makes this setup different:

- **Hybrid storage** — a single variable switches the library between the Mac's
  internal disk and an external SSD.
- **Lightweight** — hard CPU/RAM limits on every container; the ML model is
  unloaded from memory after 5 minutes of inactivity.
- **Plug & Play** — connect the SSD and the server starts by itself. Hotkeys for
  starting up and safely ejecting the drive.
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
STORAGE_TYPE=local                                  # local or ssd
LOCAL_STORAGE_PATH=/Users/YOUR_NAME/Pictures/ImmichData
DB_PASSWORD=...                                     # a fresh one: make secret
```

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

## 4. Switching from the local Mac disk to an SSD in 30 seconds

```bash
# 1. Stop the server
make stop

# 2. Move the data to the SSD (once; duration depends on library size)
rsync -avh --progress /Users/YOU/Pictures/ImmichData/ /Volumes/MySSD/ImmichData/

# 3. Change two lines in .env:
#    STORAGE_TYPE=ssd
#    SSD_STORAGE_PATH=/Volumes/MySSD/ImmichData
#    SSD_VOLUME_NAME=MySSD          <- volume name exactly as shown in Finder

# 4. Start
make start
```

Going back to the internal disk is the same steps with `STORAGE_TYPE=local` and
a reverse `rsync`.

**How it works.** The scripts derive `UPLOAD_LOCATION` and `DB_DATA_LOCATION`
from `STORAGE_TYPE` and pass them into `docker-compose.yml`. You never edit
those paths in `.env` yourself.

### What happens with the SSD automatically

- **Plug the cable in** → the LaunchAgent notices the new volume in `/Volumes`
  and calls `start.sh`. The server comes up on its own.
- **Want to disconnect** → `⌃⌥⌘O` (or `make stop`): containers stop, buffers are
  flushed, the disk is ejected via `diskutil eject`. The "SSD извлечён"
  notification means the cable is safe to pull.
- **Cable yanked without stopping** → the LaunchAgent sees the volume disappear
  and shuts the containers down so the database does not write into nowhere.
  Best avoided.
- **Trying to start without the disk** → a red notification with a clear message;
  nothing is started.

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
make shell-db   psql console
make secret     Generate a database password
make prune      Remove unused images
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

Full reset (⚠️ deletes the entire library):

```bash
make stop
rm -rf /path/to/ImmichData
make start
```

---

## 10. Backups

Immich keeps everything in two directories inside `STORAGE_ROOT`:

- `library/` — original photos and videos;
- `postgres/` — the database (albums, faces, metadata).

Copy **both** — either one alone is useless:

```bash
make stop
rsync -avh --delete /Volumes/MySSD/ImmichData/ /Volumes/Backup/ImmichData/
make start
```

Time Machine works too, but exclude `postgres/` from hot backups — the database
must only be copied while the containers are stopped.
