# nfc-spool

Tap an NFC tag on your phone, Spoolman identifies the spool, and Happy Hare gets
`MMU_GATE_MAP NEXT_SPOOLID=<id>`. Then you insert the filament and run
`MMU_PRELOAD` for the gate (the page has a button per gate).

> **Status:** the installer was tested in a fake Pi layout (stubbed `sudo`,
> `nginx`, `systemctl`), not on a real printer. The Moonraker component API calls
> and the `MMU_PRELOAD GATE=` syntax are from memory and docs; check them first
> (see "Verify before trusting").

## Quick start (on the Pi, as the printer user, not root)

```
git clone https://github.com/ItzEarthy/nfc-spool ~/nfc-spool
cd ~/nfc-spool
./install.sh --dry-run     # see what it will do
./install.sh
```

Most values are auto-detected. If your Spoolman is not in `moonraker.conf`'s
`[spoolman]` section, pass it: `./install.sh --spoolman-url http://truenas.lan:7912`.

## What the installer does

1. Symlinks `nfc_spool.py` into `~/moonraker/moonraker/components/` and adds it to
   Moonraker's `.git/info/exclude` so Moonraker's updater doesn't call itself dirty.
2. Adds a managed `# BEGIN/END nfc-spool` block to `moonraker.conf`:
   `[nfc_spool]` and an `[update_manager nfc-spool]` entry (so Mainsail's
   Machine page can update it). Your original is backed up as `moonraker.conf.bak.<time>`.
3. Writes `web/config.js` (gate count, preload command; gitignored).
4. Merges a "Spool Scan" entry into `.theme/navi.json` (other entries kept).
5. Writes an nginx snippet to `/etc/nginx/snippets/nfc-spool.conf` serving `web/`
   at `/nfc/`, includes it in the Mainsail site, runs `nginx -t`, reloads. If the
   test fails it restores the site file. Uses `sudo` for this step only.
6. Restarts Moonraker and checks `/server/nfc/status` answers.

Safe to re-run; it replaces its own block instead of duplicating it.

## Parameters and flags

| Flag | Default | Notes |
|---|---|---|
| `--spoolman-url URL` | `server:` in `[spoolman]` of moonraker.conf | **Required** if not auto-detected (prompts if interactive, errors with `--yes`) |
| `--timeout SEC` | `pending_spool_id_timeout` from `mmu_parameters.cfg`, else 20 | **Must equal Happy Hare's value.** Only drives the UI countdown |
| `--gates N` | `num_gates` from your Happy Hare config, else 4 | Number of gate buttons. Check it matches your MMU |
| `--preload-cmd CMD` | `MMU_PRELOAD GATE={gate}` | `{gate}` is replaced by the gate number |
| `--config-dir DIR` | `~/printer_data/config`, else `~/klipper_config` | Folder with `moonraker.conf` |
| `--moonraker-dir DIR` | `~/moonraker` | |
| `--service NAME` | `moonraker` | systemd unit; change for multi-instance (e.g. `moonraker-1`) |
| `--moonraker-port PORT` | `7125` | Only for the post-install check |
| `--nginx-site FILE` | `/etc/nginx/sites-enabled/mainsail` | Site file that serves Mainsail |
| `--nginx-snippet-dir DIR` | `/etc/nginx/snippets` | |
| `--no-nginx` | off | Skip nginx; serve `web/` at `/nfc/` yourself |
| `--no-update-manager` | off | Skip the update_manager entry |
| `--no-restart` | off | Don't restart Moonraker or reload nginx |
| `-y`, `--yes` | off | Never prompt |
| `--dry-run` | off | Print changes, make none |
| `--uninstall` | | Remove everything the installer added (repo folder is kept) |

Re-run the installer after changing any value; it rewrites the block and `config.js`.

## After installing

1. In Spoolman (v0.27.0+): open a spool, Tags, Add tag (one per physical tag).
2. Mainsail must be reachable over **HTTPS** or Web NFC won't work. If HTTPS is
   terminated elsewhere (Cloudflare tunnel, a reverse proxy) pointing at the Pi's
   port 80, `/nfc/` works through it with no extra setup.
3. On the phone (Chrome, Android, NFC on): `https://<your-host>/nfc/`, or the
   "Spool Scan" entry in Mainsail's sidebar (hard-refresh once).

## Pieces

| File | What it is |
|---|---|
| `install.sh` | Installer / uninstaller |
| `nfc_spool.py` | Moonraker component: `POST /server/nfc/scan`, `GET /server/nfc/status` |
| `web/index.html`, `web/nfc.js` | Phone page: Web NFC read, pending spool + countdown, gate buttons |
| `navi.json` | Mainsail sidebar entry (merged in by the installer) |
| `nginx-nfc.conf` | Reference snippet; the installer generates the real one |

Mainsail has no documented custom-panel API, so this is a separate page linked
from the sidebar, not a card inside the Happy Hare section.

## Verify before trusting

- [ ] `journalctl -u moonraker` shows the component loaded with no errors.
- [ ] `curl http://localhost:7125/server/nfc/status` returns `{"result": {"pending": null}}`.
- [ ] `curl -X POST http://localhost:7125/server/nfc/scan -H 'Content-Type: application/json' -d '{"uid":"<linked uid>"}'` returns the spool and the Mainsail console shows `MMU_GATE_MAP NEXT_SPOOLID=...`.
- [ ] `MMU_PRELOAD GATE=n` is the right syntax for your Happy Hare version (Command Reference); otherwise use `--preload-cmd`.
- [ ] Spoolman's `GET /api/v1/spool?tag=<uid>` returns the spool.
- [ ] The UID Chrome reports matches the UID Spoolman stored (link tags from the phone's Add tag dialog to be safe).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| nginx 403/404 on `/nfc/` | nginx's user can't read your home dir: `chmod o+x ~` |
| "Web NFC is not available" | Not Chrome on Android, or page isn't on HTTPS |
| "not linked to a spool" | Tag not added in Spoolman, or a different UID was linked |
| Component didn't answer after install | `journalctl -u moonraker -n 50`; check the `[nfc_spool]` block and Spoolman URL |
| Happy Hare ignores the spool | `pending_spool_id_timeout` expired before `MMU_PRELOAD`; raise it and `--timeout` together |

## Security

Neither Spoolman nor these endpoints add authentication. Anyone who can reach
Moonraker can send a scan or a gate command. Keep it on your LAN or behind a VPN,
and keep Moonraker's `trusted_clients` tight.
