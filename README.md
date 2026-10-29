# nfc-spool

Tap an NFC tag on your phone, Spoolman identifies the spool, and Happy Hare gets
`MMU_GATE_MAP NEXT_SPOOLID=<id>`. Then you insert the filament and run
`MMU_PRELOAD` for the gate.

> **Status:** written without access to a Pi, Moonraker or Happy Hare, so it is
> untested. The Moonraker component API calls and the `MMU_PRELOAD GATE=` syntax
> are from memory and docs; check them first (see "Verify before trusting").

## Pieces

| File | What it is |
|---|---|
| `nfc_spool.py` | Moonraker component: `POST /server/nfc/scan`, `GET /server/nfc/status` |
| `web/index.html`, `web/nfc.js` | Phone page: Web NFC read, pending spool + countdown, gate buttons |
| `navi.json` | Adds a "Spool Scan" entry to Mainsail's sidebar |
| `nginx-nfc.conf` | Serves `web/` at `/nfc/` on your HTTPS site |

Mainsail has no documented custom-panel API, so this is a separate page linked
from the sidebar, not a card inside the Happy Hare section.

## Install (on the Pi)

1. Copy this folder to `~/nfc-spool`.
2. Link the component into Moonraker:
   `ln -s ~/nfc-spool/nfc_spool.py ~/moonraker/moonraker/components/nfc_spool.py`
3. Add to `moonraker.conf`:
   ```
   [nfc_spool]
   spoolman_url: http://<spoolman-host>:7912
   pending_timeout: 20
   ```
   Keep `pending_timeout` equal to `pending_spool_id_timeout` in `mmu_parameters.cfg`.
4. Add `nginx-nfc.conf` inside your HTTPS server block, fix the path, then
   `sudo nginx -t && sudo systemctl reload nginx`.
5. Copy `navi.json` into your config's `.theme/` folder (create it if needed).
6. `sudo systemctl restart moonraker`, then hard-refresh Mainsail.
7. In Spoolman (v0.27.0+), link each tag: spool -> Tags -> Add tag.
8. On the phone (Chrome, Android, NFC on), open `https://<your-host>/nfc/`.
   Edit `GATE_COUNT` in `web/nfc.js` to match your MMU.

## Verify before trusting

- [ ] `journalctl -u moonraker` shows the component loaded with no errors.
- [ ] `curl https://<host>/server/nfc/status` returns `{"result": {"pending": null}}`.
- [ ] `curl -X POST https://<host>/server/nfc/scan -H 'Content-Type: application/json' -d '{"uid":"<linked uid>"}'` returns the spool and the Mainsail console shows `MMU_GATE_MAP NEXT_SPOOLID=...`.
- [ ] `MMU_PRELOAD GATE=n` is the right syntax for your Happy Hare version (Command Reference).
- [ ] Spoolman's `GET /api/v1/spool?tag=<uid>` returns the spool (the wiki documents this).
- [ ] The tag UID Chrome reports matches the UID Spoolman stored when you linked it.

## Security

Neither Spoolman nor these endpoints add authentication. Anyone who can reach
Moonraker can send a scan. Keep it on your LAN or behind a VPN, and keep
Moonraker's `trusted_clients` tight.
