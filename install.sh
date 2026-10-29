#!/usr/bin/env bash
# nfc-spool installer. Run on the Pi as the user that owns Moonraker
# (NOT root; it calls sudo only for nginx and the service restart).
#
#   ./install.sh                      auto-detect everything
#   ./install.sh --spoolman-url http://truenas.lan:7912
#   ./install.sh --dry-run            show what would change
#   ./install.sh --uninstall
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- defaults (override with flags) -----------------------------------------
CONFIG_DIR=""
MOONRAKER_DIR="$HOME/moonraker"
SERVICE="moonraker"
MOONRAKER_PORT="7125"
SPOOLMAN_URL=""
TIMEOUT=""
GATES=""
PRELOAD_CMD="MMU_PRELOAD GATE={gate}"
NGINX_SITE=""
NGINX_SNIPPET_DIR="/etc/nginx/snippets"
DO_NGINX=1
DO_UPDATE_MGR=1
DO_RESTART=1
ASSUME_YES=0
DRY_RUN=0
UNINSTALL=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Everything is auto-detected where possible. Flags override detection.

  --spoolman-url URL     Spoolman base URL, e.g. http://truenas.lan:7912
                         Default: "server:" from the [spoolman] section of
                         moonraker.conf. Required if neither is available.
  --timeout SECONDS      Pending-spool window shown in the UI. Must equal
                         pending_spool_id_timeout in Happy Hare's
                         mmu_parameters.cfg. Default: read from that file, else 20.
  --gates N              Number of MMU gates (buttons on the page).
                         Default: num_gates from your Happy Hare config, else 4.
  --preload-cmd CMD      Gcode run by a gate button; {gate} is replaced by the
                         gate number. Default: "MMU_PRELOAD GATE={gate}"
  --config-dir DIR       Klipper config dir (holds moonraker.conf).
                         Default: ~/printer_data/config, else ~/klipper_config
  --moonraker-dir DIR    Moonraker source dir. Default: ~/moonraker
  --service NAME         Moonraker systemd service. Default: moonraker
  --moonraker-port PORT  Used for the post-install check. Default: 7125
  --nginx-site FILE      nginx site file that serves Mainsail.
                         Default: /etc/nginx/sites-enabled/mainsail
  --nginx-snippet-dir D  Where to write the nginx snippet.
                         Default: /etc/nginx/snippets
  --no-nginx             Do not touch nginx (serve web/ at /nfc/ yourself)
  --no-update-manager    Do not add the Moonraker update_manager entry
  --no-restart           Do not restart Moonraker/nginx
  -y, --yes              Never prompt (fail instead if a value is missing)
  --dry-run              Print what would change; change nothing
  --uninstall            Remove everything this script added
  -h, --help             This help
EOF
}

# ---- arg parsing ------------------------------------------------------------
need_val() { [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: $1 needs a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --spoolman-url)      need_val "$@"; SPOOLMAN_URL="$2"; shift 2 ;;
    --timeout)           need_val "$@"; TIMEOUT="$2"; shift 2 ;;
    --gates)             need_val "$@"; GATES="$2"; shift 2 ;;
    --preload-cmd)       need_val "$@"; PRELOAD_CMD="$2"; shift 2 ;;
    --config-dir)        need_val "$@"; CONFIG_DIR="$2"; shift 2 ;;
    --moonraker-dir)     need_val "$@"; MOONRAKER_DIR="$2"; shift 2 ;;
    --service)           need_val "$@"; SERVICE="$2"; shift 2 ;;
    --moonraker-port)    need_val "$@"; MOONRAKER_PORT="$2"; shift 2 ;;
    --nginx-site)        need_val "$@"; NGINX_SITE="$2"; shift 2 ;;
    --nginx-snippet-dir) need_val "$@"; NGINX_SNIPPET_DIR="$2"; shift 2 ;;
    --no-nginx)          DO_NGINX=0; shift ;;
    --no-update-manager) DO_UPDATE_MGR=0; shift ;;
    --no-restart)        DO_RESTART=0; shift ;;
    -y|--yes)            ASSUME_YES=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --uninstall)         UNINSTALL=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- helpers ----------------------------------------------------------------
say()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
act()  { if [[ $DRY_RUN -eq 1 ]]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }
can_prompt() { [[ $ASSUME_YES -eq 0 && -t 0 ]]; }

[[ $EUID -ne 0 ]] || die "run as the printer user, not root (config files must stay owned by that user)"
command -v python3 >/dev/null || die "python3 is required"
[[ $DRY_RUN -eq 1 ]] && say "DRY RUN: nothing will be changed"

# ---- locate things ----------------------------------------------------------
if [[ -z "$CONFIG_DIR" ]]; then
  for d in "$HOME/printer_data/config" "$HOME/klipper_config"; do
    [[ -f "$d/moonraker.conf" ]] && CONFIG_DIR="$d" && break
  done
fi
[[ -n "$CONFIG_DIR" && -f "$CONFIG_DIR/moonraker.conf" ]] \
  || die "could not find moonraker.conf; pass --config-dir"
MOONRAKER_CONF="$CONFIG_DIR/moonraker.conf"
COMPONENTS_DIR="$MOONRAKER_DIR/moonraker/components"
[[ -d "$COMPONENTS_DIR" ]] || die "no $COMPONENTS_DIR; pass --moonraker-dir"
COMPONENT_LINK="$COMPONENTS_DIR/nfc_spool.py"
THEME_DIR="$CONFIG_DIR/.theme"
SNIPPET_FILE="$NGINX_SNIPPET_DIR/nfc-spool.conf"
INCLUDE_LINE="include $SNIPPET_FILE;"
MARK_BEGIN="# BEGIN nfc-spool (managed by install.sh, do not edit)"
MARK_END="# END nfc-spool"

if [[ -z "$NGINX_SITE" ]]; then
  for f in /etc/nginx/sites-enabled/mainsail /etc/nginx/conf.d/mainsail.conf; do
    [[ -f "$f" ]] && NGINX_SITE="$f" && break
  done
fi

backup() { # backup FILE
  [[ -e "$1" ]] || return 0
  act cp -p "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)"
}

restart_services() {
  [[ $DO_RESTART -eq 1 ]] || { say "skipping restart (--no-restart); restart $SERVICE yourself"; return; }
  say "restarting $SERVICE"
  act sudo systemctl restart "$SERVICE"
}

# Edits the managed block in moonraker.conf. Usage: edit_conf add|remove
edit_conf() {
  MODE="$1" CONF="$MOONRAKER_CONF" BEGIN="$MARK_BEGIN" END="$MARK_END" \
  SPOOLMAN="$SPOOLMAN_URL" TIMEOUT="$TIMEOUT" REPO="$REPO_DIR" \
  UPDMGR="$DO_UPDATE_MGR" DRY="$DRY_RUN" python3 - <<'PY'
import os, re, subprocess, sys
e = os.environ
text = open(e["CONF"]).read()
begin, end = e["BEGIN"], e["END"]
pat = re.compile(r"\n?" + re.escape(begin) + r".*?" + re.escape(end) + r"[ \t]*\n?", re.S)
had_block = bool(pat.search(text))
stripped = pat.sub("\n", text) if had_block else text

if e["MODE"] == "remove":
    if not had_block:
        print("moonraker.conf: no managed block found"); sys.exit(0)
    new = stripped.rstrip("\n") + "\n"
    action = "remove managed block from"
else:
    if re.search(r"^\[nfc_spool\]", stripped, re.M):
        print("warning: moonraker.conf already has an unmanaged [nfc_spool] section; "
              "leaving it alone. Remove it and re-run to let the installer manage it.",
              file=sys.stderr)
        sys.exit(0)
    try:
        origin = subprocess.check_output(
            ["git", "-C", e["REPO"], "remote", "get-url", "origin"],
            stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        origin = "https://github.com/ItzEarthy/nfc-spool.git"
    if origin.startswith("https://") and not origin.endswith(".git"):
        origin += ".git"
    lines = [begin, "[nfc_spool]",
             "spoolman_url: " + e["SPOOLMAN"],
             "pending_timeout: " + e["TIMEOUT"]]
    if e["UPDMGR"] == "1":
        if re.search(r"^\[update_manager nfc-spool\]", stripped, re.M):
            print("warning: an unmanaged [update_manager nfc-spool] already exists; skipping ours.",
                  file=sys.stderr)
        else:
            lines += ["", "[update_manager nfc-spool]", "type: git_repo",
                      "path: " + e["REPO"], "origin: " + origin,
                      "primary_branch: main", "is_system_service: False",
                      "managed_services: moonraker"]
    lines.append(end)
    new = stripped.rstrip("\n") + "\n\n" + "\n".join(lines) + "\n"
    action = "write managed block in"

if e["DRY"] == "1":
    print("[dry-run] would %s %s" % (action, e["CONF"]))
    if e["MODE"] == "add":
        print("\n".join("[dry-run]   " + l for l in lines))
    sys.exit(0)
open(e["CONF"], "w").write(new)
print("moonraker.conf: %s" % action)
PY
}

# Edits .theme/navi.json. Usage: edit_navi add|remove
edit_navi() {
  MODE="$1" THEME="$THEME_DIR" SRC="$REPO_DIR/navi.json" DRY="$DRY_RUN" python3 - <<'PY'
import json, os, sys
e = os.environ
path = os.path.join(e["THEME"], "navi.json")
title = "Spool Scan"
items = []
if os.path.exists(path):
    try:
        items = json.load(open(path))
        assert isinstance(items, list)
    except Exception:
        print("error: %s is not a JSON list; fix or remove it first" % path, file=sys.stderr)
        sys.exit(1)
items = [i for i in items if i.get("title") != title]
if e["MODE"] == "add":
    items.append(json.load(open(e["SRC"]))[0])
if e["DRY"] == "1":
    print("[dry-run] would %s navi entry in %s" % (e["MODE"], path)); sys.exit(0)
os.makedirs(e["THEME"], exist_ok=True)
if not items and e["MODE"] == "remove":
    if os.path.exists(path): os.remove(path)
else:
    json.dump(items, open(path, "w"), indent=2); open(path, "a").write("\n")
print("navi.json: %s entry" % e["MODE"])
PY
}

# Reads an option from moonraker.conf: ini_get SECTION KEY
ini_get() {
  CONF="$MOONRAKER_CONF" SECTION="$1" KEY="$2" python3 - <<'PY' 2>/dev/null || true
import configparser, os
c = configparser.ConfigParser(strict=False, interpolation=None, inline_comment_prefixes=("#",))
try:
    c.read(os.environ["CONF"])
    print(c.get(os.environ["SECTION"], os.environ["KEY"]).strip())
except Exception:
    pass
PY
}

# ---- uninstall --------------------------------------------------------------
if [[ $UNINSTALL -eq 1 ]]; then
  say "uninstalling"
  backup "$MOONRAKER_CONF"
  edit_conf remove
  if [[ -L "$COMPONENT_LINK" ]]; then act rm -f "$COMPONENT_LINK"; say "removed $COMPONENT_LINK"; fi
  if [[ -f "$MOONRAKER_DIR/.git/info/exclude" ]]; then
    act sed -i '\#^moonraker/components/nfc_spool\.py$#d' "$MOONRAKER_DIR/.git/info/exclude"
  fi
  [[ -f "$THEME_DIR/navi.json" ]] && { backup "$THEME_DIR/navi.json"; edit_navi remove; }
  act rm -f "$REPO_DIR/web/config.js"
  if [[ $DO_NGINX -eq 1 && -n "$NGINX_SITE" && -f "$NGINX_SITE" ]] && grep -qF "$INCLUDE_LINE" "$NGINX_SITE"; then
    say "removing nginx include (sudo)"
    act sudo cp -p "$NGINX_SITE" "$NGINX_SITE.bak.$(date +%Y%m%d-%H%M%S)"
    act sudo sed -i "\\#$INCLUDE_LINE#d" "$NGINX_SITE"
    act sudo rm -f "$SNIPPET_FILE"
    [[ $DO_RESTART -eq 1 ]] && act sudo nginx -t && act sudo systemctl reload nginx
  fi
  restart_services
  say "done. The repo folder $REPO_DIR was left in place; delete it yourself if you want."
  exit 0
fi

# ---- resolve parameters -----------------------------------------------------
if [[ -z "$SPOOLMAN_URL" ]]; then
  SPOOLMAN_URL="$(ini_get spoolman server)"
  [[ -n "$SPOOLMAN_URL" ]] && say "Spoolman URL from moonraker.conf [spoolman]: $SPOOLMAN_URL"
fi
if [[ -z "$SPOOLMAN_URL" ]] && can_prompt; then
  read -r -p "Spoolman URL (e.g. http://truenas.lan:7912): " SPOOLMAN_URL
fi
[[ -n "$SPOOLMAN_URL" ]] || die "Spoolman URL unknown; pass --spoolman-url"
SPOOLMAN_URL="${SPOOLMAN_URL%/}"
[[ "$SPOOLMAN_URL" =~ ^https?://[^[:space:]]+$ ]] || die "bad Spoolman URL: $SPOOLMAN_URL"

if [[ -z "$TIMEOUT" ]]; then
  while IFS= read -r f; do
    v="$(sed -nE 's/^[[:space:]]*pending_spool_id_timeout[[:space:]]*[:=][[:space:]]*([0-9.]+).*/\1/p' "$f" | head -1)"
    [[ -n "$v" ]] && TIMEOUT="$v" && say "timeout from $f: ${TIMEOUT}s" && break
  done < <(find "$CONFIG_DIR" -maxdepth 4 -name 'mmu_parameters.cfg' 2>/dev/null)
fi
if [[ -z "$TIMEOUT" ]]; then
  TIMEOUT=20
  warn "could not read pending_spool_id_timeout from Happy Hare config; using 20 (Happy Hare's default). Pass --timeout if yours differs."
fi
[[ "$TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--timeout must be a number"

if [[ -z "$GATES" ]]; then
  GATES="$(grep -rhE --include='*.cfg' '^[[:space:]]*num_gates[[:space:]]*[:=]' "$CONFIG_DIR" 2>/dev/null \
           | head -1 | sed -E 's/^[^:=]*[:=][[:space:]]*([0-9]+).*/\1/')" || true
  [[ -n "$GATES" ]] && say "gates from Happy Hare config: $GATES"
fi
if [[ -z "$GATES" ]]; then
  GATES=4
  warn "could not find num_gates in your config; using 4 buttons. Pass --gates N."
fi
[[ "$GATES" =~ ^[0-9]+$ && "$GATES" -ge 1 && "$GATES" -le 32 ]] || die "--gates must be 1-32"
[[ "$PRELOAD_CMD" == *"{gate}"* ]] || die "--preload-cmd must contain {gate}"

say "settings: spoolman=$SPOOLMAN_URL timeout=${TIMEOUT}s gates=$GATES"
say "           config=$CONFIG_DIR moonraker=$MOONRAKER_DIR service=$SERVICE"

# ---- 1. component symlink ---------------------------------------------------
if [[ -e "$COMPONENT_LINK" || -L "$COMPONENT_LINK" ]]; then
  if [[ "$(readlink -f "$COMPONENT_LINK")" == "$(readlink -f "$REPO_DIR/nfc_spool.py")" ]]; then
    say "component already linked"
  else
    die "$COMPONENT_LINK exists and is not ours; move it away first"
  fi
else
  say "linking component into Moonraker"
  act ln -s "$REPO_DIR/nfc_spool.py" "$COMPONENT_LINK"
fi
# keep Moonraker's update_manager from calling its own repo "dirty"
if [[ -d "$MOONRAKER_DIR/.git/info" ]] && ! grep -qxF 'moonraker/components/nfc_spool.py' "$MOONRAKER_DIR/.git/info/exclude" 2>/dev/null; then
  act sh -c "echo 'moonraker/components/nfc_spool.py' >> '$MOONRAKER_DIR/.git/info/exclude'"
fi

# ---- 2. moonraker.conf ------------------------------------------------------
backup "$MOONRAKER_CONF"
edit_conf add

# ---- 3. page config ---------------------------------------------------------
say "writing web/config.js"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "[dry-run] gates=$GATES preload=$PRELOAD_CMD"
else
  GATES="$GATES" PRELOAD="$PRELOAD_CMD" OUT="$REPO_DIR/web/config.js" python3 - <<'PY'
import json, os
e = os.environ
open(e["OUT"], "w").write("window.NFC_CONFIG = %s;\n" %
    json.dumps({"gates": int(e["GATES"]), "preload": e["PRELOAD"]}))
PY
fi

# ---- 4. Mainsail sidebar entry ----------------------------------------------
[[ -f "$THEME_DIR/navi.json" ]] && backup "$THEME_DIR/navi.json"
edit_navi add

# ---- 5. nginx ---------------------------------------------------------------
NGINX_DONE=0
if [[ $DO_NGINX -eq 0 ]]; then
  say "skipping nginx (--no-nginx). Serve $REPO_DIR/web at /nfc/ on your Mainsail host."
elif ! command -v nginx >/dev/null 2>&1 && ! [[ -x /usr/sbin/nginx ]]; then
  warn "nginx not found; skipping. Serve $REPO_DIR/web at /nfc/ yourself."
elif [[ -z "$NGINX_SITE" || ! -f "$NGINX_SITE" ]]; then
  warn "no Mainsail nginx site file found; pass --nginx-site FILE or --no-nginx."
else
  say "configuring nginx via $NGINX_SITE (sudo)"
  SNIPPET_TMP="$(mktemp)"
  trap 'rm -f "$SNIPPET_TMP"' EXIT
  cat >"$SNIPPET_TMP" <<EOF
# managed by nfc-spool install.sh
location = /nfc { return 301 /nfc/; }
location /nfc/ {
    alias $REPO_DIR/web/;
    index index.html;
}
EOF
  act sudo mkdir -p "$NGINX_SNIPPET_DIR"
  act sudo install -m 644 "$SNIPPET_TMP" "$SNIPPET_FILE"
  if grep -qF "$INCLUDE_LINE" "$NGINX_SITE"; then
    say "nginx include already present"
    NGINX_DONE=1
  elif grep -qE '^[[:space:]]*location[[:space:]]+/[[:space:]]*\{' "$NGINX_SITE"; then
    act sudo cp -p "$NGINX_SITE" "$NGINX_SITE.bak.$(date +%Y%m%d-%H%M%S)"
    # insert before the first "location / {"
    act sudo sed -i -E "0,/^([[:space:]]*)location[[:space:]]+\\/[[:space:]]*\\{/s||\\1$INCLUDE_LINE\n&|" "$NGINX_SITE" \
      && NGINX_DONE=1
    if [[ $DRY_RUN -eq 0 ]]; then
      if sudo nginx -t 2>&1; then
        [[ $DO_RESTART -eq 1 ]] && sudo systemctl reload nginx && say "nginx reloaded"
      else
        warn "nginx -t failed; restoring $NGINX_SITE"
        latest="$(ls -1t "$NGINX_SITE".bak.* | head -1)"
        sudo cp -p "$latest" "$NGINX_SITE"
        NGINX_DONE=0
      fi
    fi
  else
    warn "could not find 'location / {' in $NGINX_SITE. Add this line inside the HTTPS server block yourself:"
    warn "    $INCLUDE_LINE"
  fi
  # nginx runs as www-data and must be able to read the repo under $HOME
  if [[ $DRY_RUN -eq 0 ]] && id www-data >/dev/null 2>&1 \
     && ! sudo -u www-data test -r "$REPO_DIR/web/index.html" 2>/dev/null; then
    warn "nginx's user cannot read $REPO_DIR/web. Usually your home dir is private. Fix with:"
    warn "    chmod o+x \"$HOME\""
  fi
fi

# ---- 6. restart + check -----------------------------------------------------
restart_services
if [[ $DRY_RUN -eq 0 && $DO_RESTART -eq 1 ]] && command -v curl >/dev/null; then
  say "waiting for the component to come up"
  ok=0
  for _ in $(seq 1 20); do
    if curl -fsS "http://127.0.0.1:$MOONRAKER_PORT/server/nfc/status" >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  if [[ $ok -eq 1 ]]; then
    say "component is up: /server/nfc/status answers"
  else
    warn "component did not answer. Check: journalctl -u $SERVICE -n 50   (or moonraker.log)"
  fi
fi

cat <<EOF

Done. Remaining manual steps:
  1. In Spoolman (v0.27.0+) link each tag: spool -> Tags -> Add tag.
  2. Make sure Mainsail is reachable over HTTPS (Web NFC will not work on http://).
  3. On the phone (Chrome, NFC on) open https://<your-host>/nfc/
     (also in Mainsail's sidebar as "Spool Scan"; hard-refresh once).
  4. Confirm $PRELOAD_CMD is valid for your Happy Hare version.
EOF
