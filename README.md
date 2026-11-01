# nfc-spool

Scan a spool's NFC tag from Mainsail's dashboard. Spoolman identifies the spool,
Happy Hare gets `MMU_GATE_MAP NEXT_SPOOLID=<id>`, and you tap the gate you loaded
it into (`MMU_PRELOAD GATE=n`, the same command Mainsail's gate menu uses).

The scanner sits at the top of Mainsail's **Happy Hare (MMU) panel**. It runs
inside Mainsail itself, so nothing opens in a new tab and it works in the
installed Mainsail app.

> **Status:** the installer and the dashboard card are tested in a fake Pi
> layout and a mocked browser page built from Mainsail 2.19's panel markup. Not
> yet tested on a real printer, and nginx's `sub_filter` injection was not run
> against real nginx.

## Install (on the Pi, as the printer user, not root)

```
git clone https://github.com/ItzEarthy/nfc-spool ~/nfc-spool
cd ~/nfc-spool
./install.sh --dry-run     # see what it will do
./install.sh
```

Most values are auto-detected. If Spoolman isn't in `moonraker.conf`'s
`[spoolman]` section, pass it: `./install.sh --spoolman-url http://truenas:7912`.

## Updating

- **Normal updates:** Mainsail -> Machine -> Update Manager -> nfc-spool -> Update.
  Moonraker restarts and the new version is live.
- **If Mainsail then shows a warning** "nfc-spool was updated and needs its
  installer re-run" (or the card shows a banner), run:
  `~/nfc-spool/install.sh --update`
- `--update` can also be run any time on its own. It does `git pull`, then re-runs
  the new installer with your saved settings. It is safe to repeat.
- **Coming from the first version** (the sidebar "Spool Scan" page): that
  installer doesn't know `--update`, so run `cd ~/nfc-spool && git pull && ./install.sh`
  once. It removes the old sidebar link and page config.

How it knows: `SCHEMA` in the repo is bumped whenever an update needs the
installer, and the installer records the version it applied in `moonraker.conf`.

## Using it

1. In Spoolman (v0.27.0+), link the tag to the **spool** (spool page, Tags, Add tag).
   A tag linked to the **filament** also works: if that filament has one active
   spool it's used directly, otherwise the card lists its spools to pick from.
2. Open Mainsail over **HTTPS** in Chrome on Android, on the dashboard.
3. In the Happy Hare panel tap **Scan spool** and hold the tag to the phone.
4. Insert the filament into a gate and tap that gate's number before the
   countdown ends. Empty gates are highlighted.

On a desktop or without Web NFC there's no scan button. The section appears
only while a spool is pending, e.g. one you scanned on your phone. Gate buttons
are disabled while printing. If the Happy Hare panel is hidden, the scanner floats
in the corner of the dashboard instead.

## What the installer does

1. Symlinks `nfc_spool.py` into `~/moonraker/moonraker/components/` and adds it to
   Moonraker's `.git/info/exclude`, so Moonraker's own updater doesn't flag it.
2. Writes a managed `# BEGIN/END nfc-spool` block in `moonraker.conf` with
   `[nfc_spool]` and `[update_manager nfc-spool]`. The file is backed up first,
   and only when it actually changes.
3. Writes `/etc/nginx/snippets/nfc-spool.conf` and includes it in Mainsail's
   nginx site. The snippet serves `web/` at `/nfc/` and uses `sub_filter` to add
   `<script src="/nfc/mainsail-nfc.js">` to Mainsail's page. It also tags the
   `index.html` revision inside Mainsail's `sw.js`, so browsers holding a cached
   copy of the page fetch the new one. The installer runs `nginx -t` and reloads,
   and undoes its nginx change if the test fails.
4. Removes leftovers from older versions (sidebar link, `web/config.js`).
5. Saves your settings to `.install.conf` (gitignored) for later runs.
6. Restarts Moonraker, checks the component answers and that Mainsail's page
   includes the script.

## Flags

| Flag | Default | Notes |
|---|---|---|
| `--update` | | `git pull`, then re-run with saved settings |
| `--spoolman-url URL` | `[spoolman] server:` in moonraker.conf | **Required** if not found (prompts if interactive) |
| `--timeout SEC` | `pending_spool_id_timeout` from `mmu_parameters.cfg`, else 20 | Must equal Happy Hare's value (countdown only) |
| `--config-dir DIR` | `~/printer_data/config`, else `~/klipper_config` | |
| `--moonraker-dir DIR` | `~/moonraker` | |
| `--service NAME` | `moonraker` | e.g. `moonraker-1` for multi-instance |
| `--moonraker-port PORT` | `7125` | Post-install check only |
| `--nginx-site FILE` | `/etc/nginx/sites-enabled/mainsail` | |
| `--nginx-snippet-dir DIR` | `/etc/nginx/snippets` | |
| `--no-nginx` | | Don't touch nginx. You must serve `web/` at `/nfc/` and inject the script yourself |
| `--no-update-manager` | | Skip the update_manager entry |
| `--no-restart` | | Don't restart Moonraker or reload nginx |
| `--reset` | | Ignore saved settings and auto-detect again |
| `-y`, `--yes` | | Never prompt |
| `--dry-run` | | Print changes, make none |
| `--uninstall` | | Remove everything the installer added (repo folder is kept) |

Saved settings are reused on every run; a flag overrides the saved value and
becomes the new saved value. Gate count and preload command are no longer
settings: they come live from Happy Hare.

## Files

| File | What it is |
|---|---|
| `install.sh` | Installer, updater, uninstaller |
| `nfc_spool.py` | Moonraker component: `POST /server/nfc/scan`, `GET /server/nfc/status` |
| `web/mainsail-nfc.js` | Script injected into Mainsail; builds the scanner in the MMU panel |
| `web/index.html` | Notice for anyone who still has the old `/nfc/` link |
| `SCHEMA` | Bumped when an update needs `install.sh --update` |

## Verify after installing

- [ ] `curl http://localhost:7125/server/nfc/status` shows `"update_required": false`.
- [ ] `curl -s http://localhost/ | grep mainsail-nfc.js` finds the script tag.
- [ ] On the phone, the Happy Hare panel shows **Scan spool**.
- [ ] Scanning a linked tag shows the spool and the Mainsail console logs `MMU_GATE_MAP NEXT_SPOOLID=...`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| No Scan spool button on the phone | Page not on HTTPS, or not Chrome on Android. On desktop the button is hidden by design |
| Section missing everywhere | Script not injected: check `curl -s http://localhost/ \| grep mainsail-nfc`; wrong `--nginx-site`; nginx lacks `sub_filter` (`sudo apt install nginx-full`) |
| Missing on a device that used Mainsail before | Mainsail's service worker cached the old page. The installer tags `sw.js` so browsers refetch it: reload twice (accept Mainsail's update prompt if shown). Still missing: clear the site's data once. Check: `curl -s http://localhost/sw.js \| grep -o 'revision:"nfcspool[0-9]*-'` |
| Happy Hare: `Remote method 'spoolman_push_gate_map' not registered` right after install/update | Moonraker was restarting. Run `MMU_SPOOLMAN SYNC=1` once |
| `/nfc/mainsail-nfc.js` gives 403 | nginx can't read your home dir: `chmod o+x ~` |
| "isn't linked in Spoolman" | Tag not added in Spoolman, or a different UID was linked (add it from the phone with "Read a tag with this phone") |
| "no active spools" | Tag is on a filament whose spools are all archived or missing |
| "can't reach Spoolman at ..." | Pi can't reach Spoolman: `curl http://<spoolman>:7912/api/v1/info` from the Pi |
| Banner/warning: installer re-run needed | `~/nfc-spool/install.sh --update` |
| Gate tap errors | Happy Hare refused the preload (e.g. filament loaded on a selector MMU); the message shows why |

## Security

Spoolman and these endpoints have no authentication. Anyone who can reach
Moonraker can send a scan or gate command. Keep it on your LAN or tailnet.
