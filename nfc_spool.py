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
        self.server.register_endpoint("/server/nfc/scan", _POST, self._handle_scan)
        self.server.register_endpoint("/server/nfc/status", _GET, self._handle_status)
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

    async def _lookup_spool(self, uid: str) -> Optional[Dict[str, Any]]:
        client = self.server.lookup_component("http_client")
        url = f"{self.spoolman_url}/api/v1/spool?tag={uid}"
        resp = await client.get(
            url, connect_timeout=5., request_timeout=5., enable_cache=False
        )
        if resp.has_error():
            err = getattr(resp, "error", None) or getattr(resp, "_error", None)
            code = getattr(resp, "status_code", 0)
            if code in (400, 404, 422):
                raise Exception(
                    f"Spoolman at {self.spoolman_url} answered {code}. "
                    "Tag lookup needs Spoolman v0.27.0 or newer.")
            raise Exception(f"can't reach Spoolman at {self.spoolman_url} "
                            f"({type(err).__name__}: {err})")
        data = resp.json()
        if isinstance(data, list):
            return data[0] if data else None
        return data or None

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

    async def _handle_scan(self, web_request: WebRequest) -> Dict[str, Any]:
        raw = web_request.get_str("uid")
        try:
            uid = self._normalize_uid(raw)
        except ValueError:
            raise self.server.error("Invalid tag UID", 400)
        try:
            spool = await self._lookup_spool(uid)
        except Exception as e:
            logging.exception("NFC: Spoolman lookup failed")
            raise self.server.error(f"Spoolman lookup failed: {e}", 502)
        if spool is None:
            return {"uid": uid, "matched": False}
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
        logging.info(f"NFC: pending spool {info['spool_id']} for tag {uid}")
        return {"uid": uid, "matched": True, **self._public(info)}

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
            "update_required": self.update_required,
            "schema": {
                "installed": self.installed_schema,
                "required": self.required_schema,
            },
        }


def load_component(config: ConfigHelper) -> NfcSpool:
    return NfcSpool(config)
