# Moonraker component: tap an NFC tag -> look up spool in Spoolman ->
# tell Happy Hare which spool to assign to the next gate you load.
#
# Installed by install.sh (symlinked into moonraker/components/).
# moonraker.conf (written by install.sh):
#   [nfc_spool]
#   spoolman_url: http://localhost:7912
#   pending_timeout: 20
#   installed_schema: 2
#
# Endpoints:
#   POST /server/nfc/scan    {"uid": "04:A2:B3:C4"}
#   GET  /server/nfc/status
#   POST /server/nfc/select  {"spool_id": 12}   (pick one when a tag is on a filament)
from __future__ import annotations
import logging
import os
import re
import time
from typing import TYPE_CHECKING, Any, Dict, Optional

try:
    from ..common import RequestType
    _POST = RequestType.POST
    _GET = RequestType.GET
except ImportError:  # older Moonraker
    _POST = ["POST"]
    _GET = ["GET"]

if TYPE_CHECKING:
    from ..confighelper import ConfigHelper
    from ..common import WebRequest

UID_RE = re.compile(r"^[0-9A-F]{4,40}$")
# This file is a symlink into the repo; SCHEMA sits next to the real file.
REPO_DIR = os.path.dirname(os.path.realpath(__file__))


def _required_schema() -> int:
    try:
        with open(os.path.join(REPO_DIR, "SCHEMA")) as f:
            return int(f.read().strip())
    except Exception:
        return 1


class SpoolmanHTTPError(Exception):
    def __init__(self, code: int, msg: str) -> None:
        super().__init__(msg)
        self.code = code


class NfcSpool:
    def __init__(self, config: ConfigHelper) -> None:
        self.server = config.get_server()
        self.spoolman_url = self._clean_url(
            config.get("spoolman_url", "http://localhost:7912"))
        # Keep this equal to pending_spool_id_timeout in Happy Hare's
        # mmu_parameters.cfg. It only drives the countdown shown in the UI.
        self.pending_timeout = config.getfloat("pending_timeout", 20., above=0.)
        self.installed_schema = config.getint("installed_schema", 1)
        self.required_schema = _required_schema()
        self.update_required = self.installed_schema < self.required_schema
        self.pending: Optional[Dict[str, Any]] = None
        self.choices: Optional[Dict[str, Any]] = None
        self.server.register_endpoint("/server/nfc/scan", _POST, self._handle_scan)
        self.server.register_endpoint("/server/nfc/status", _GET, self._handle_status)
        self.server.register_endpoint("/server/nfc/select", _POST, self._handle_select)
        if self.update_required:
            msg = (
                "nfc-spool was updated and needs its installer re-run: "
                f"{REPO_DIR}/install.sh --update"
            )
            logging.warning(msg)
            try:
                self.server.add_warning(msg)  # shown in Mainsail's dashboard
            except Exception:
                pass

    @staticmethod
    def _normalize_uid(raw: str) -> str:
        uid = re.sub(r"[^0-9A-Fa-f]", "", raw).upper()
        if not UID_RE.match(uid):
            raise ValueError("not a valid tag UID")
        return uid

    @staticmethod
    def _clean_url(raw: str) -> str:
        # Accept "http:///host:port", "host:port", trailing "/" or "/api".
        url = raw.strip().rstrip("/")
        m = re.match(r"^(https?):/*(.*)$", url, re.I)
        scheme, rest = (m.group(1).lower(), m.group(2)) if m else ("http", url)
        rest = rest.lstrip("/")
        if rest.endswith("/api"):
            rest = rest[:-4]
        return f"{scheme}://{rest}"

    async def _request(self, method: str, path: str, body: Any = None) -> Any:
        client = self.server.lookup_component("http_client")
        url = f"{self.spoolman_url}{path}"
        resp = await client.request(
            method, url, body, connect_timeout=5., request_timeout=5.)
        if resp.has_error():
            err = getattr(resp, "error", None)
            code = getattr(resp, "status_code", 0)
            if code:
                raise SpoolmanHTTPError(code, f"Spoolman answered {code} for {path}")
            raise Exception(f"can't reach Spoolman at {self.spoolman_url} "
                            f"({type(err).__name__}: {err})")
        return resp.json()

    async def _resolve(self, uid: str) -> Dict[str, Any]:
        """Return {"spool": {...}} | {"filament": {...}, "spools": [...]} | {}."""
        try:
            scan = await self._request(
                "POST", "/api/v1/tag/scan",
                {"uid": uid, "reader_id": "nfc-spool", "name": "Mainsail (nfc-spool)"})
        except SpoolmanHTTPError as e:
            if e.code not in (404, 405):
                raise
            # Older Spoolman without /tag/scan: spool tags only.
            data = await self._request("GET", f"/api/v1/spool?tag={uid}")
            return {"spool": data[0]} if data else {}
        if scan.get("spool"):
            return {"spool": scan["spool"]}
        fid = scan.get("matched_filament_id")
        if fid is None:
            return {}
        spools = await self._request("GET", f"/api/v1/spool?filament.id={int(fid)}")
        return {"filament": scan.get("filament") or {"id": fid}, "spools": spools or []}

    @staticmethod
    def _describe(spool: Dict[str, Any]) -> Dict[str, Any]:
        fil = spool.get("filament") or {}
        vendor = fil.get("vendor") or {}
        return {
            "spool_id": spool.get("id"),
            "name": fil.get("name") or "Unnamed filament",
            "vendor": vendor.get("name"),
            "material": fil.get("material"),
            "color_hex": fil.get("color_hex"),
        }

    def _expire_if_needed(self) -> None:
        if self.pending and time.time() >= self.pending["expires_at"]:
            self.pending = None

    @staticmethod
    def _choice(spool: Dict[str, Any]) -> Dict[str, Any]:
        rem = spool.get("remaining_weight")
        return {
            "spool_id": spool.get("id"),
            "remaining": None if rem is None else round(rem),
            "location": spool.get("location"),
            "lot_nr": spool.get("lot_nr"),
        }

    async def _set_pending(self, spool: Dict[str, Any], uid: Optional[str]) -> Dict[str, Any]:
        info = self._describe(spool)
        klippy_apis = self.server.lookup_component("klippy_apis")
        try:
            await klippy_apis.run_gcode(
                f"MMU_GATE_MAP NEXT_SPOOLID={info['spool_id']}"
            )
        except self.server.error as e:
            raise self.server.error(f"Happy Hare rejected the command: {e}", 502)
        info["uid"] = uid
        info["expires_at"] = time.time() + self.pending_timeout
        self.pending = info
        self.choices = None
        logging.info(f"NFC: pending spool {info['spool_id']} (tag {uid})")
        return {"uid": uid, "matched": True, **self._public(info)}

    async def _handle_scan(self, web_request: WebRequest) -> Dict[str, Any]:
        raw = web_request.get_str("uid")
        try:
            uid = self._normalize_uid(raw)
        except ValueError:
            raise self.server.error("Invalid tag UID", 400)
        try:
            found = await self._resolve(uid)
        except Exception as e:
            logging.exception("NFC: Spoolman lookup failed")
            raise self.server.error(f"Spoolman lookup failed: {e}", 502)
        if "spool" in found:
            return await self._set_pending(found["spool"], uid)
        if "filament" in found:
            fil = found["filament"]
            spools = found["spools"]
            if len(spools) == 1:
                return await self._set_pending(spools[0], uid)
            if not spools:
                return {"uid": uid, "matched": False, "reason": "no_spools",
                        "filament_name": fil.get("name"), "filament_id": fil.get("id")}
            # Several active spools of this filament: let the user pick.
            self.choices = {
                "uid": uid, "expires_at": time.time() + 120,
                "filament": self._describe({"filament": fil}),
                "spools": [self._choice(sp) for sp in spools][:24],
            }
            return {"uid": uid, "matched": False, "reason": "choose",
                    "choose": self._public_choices()}
        return {"uid": uid, "matched": False, "reason": "unlinked"}

    async def _handle_select(self, web_request: WebRequest) -> Dict[str, Any]:
        spool_id = web_request.get_int("spool_id")
        try:
            spool = await self._request("GET", f"/api/v1/spool/{spool_id}")
        except Exception as e:
            raise self.server.error(f"Spoolman lookup failed: {e}", 502)
        uid = self.choices["uid"] if self.choices else None
        return await self._set_pending(spool, uid)

    def _public_choices(self) -> Optional[Dict[str, Any]]:
        c = self.choices
        if not c or time.time() >= c["expires_at"]:
            self.choices = None
            return None
        f = c["filament"]
        return {"name": f["name"], "vendor": f["vendor"], "material": f["material"],
                "color_hex": f["color_hex"], "spools": c["spools"]}

    def _public(self, info: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "spool_id": info["spool_id"],
            "name": info["name"],
            "vendor": info["vendor"],
            "material": info["material"],
            "color_hex": info["color_hex"],
            "seconds_left": max(0, round(info["expires_at"] - time.time(), 1)),
            "timeout": self.pending_timeout,
        }

    async def _handle_status(self, web_request: WebRequest) -> Dict[str, Any]:
        self._expire_if_needed()
        return {
            "pending": self._public(self.pending) if self.pending else None,
            "choose": self._public_choices(),
            "update_required": self.update_required,
            "schema": {
                "installed": self.installed_schema,
                "required": self.required_schema,
            },
        }


def load_component(config: ConfigHelper) -> NfcSpool:
    return NfcSpool(config)
