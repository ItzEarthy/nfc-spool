#!/usr/bin/env bash
# nfc-spool installer. Run on the Pi as the user that owns Moonraker
# (NOT root; it calls sudo only for nginx and the service restart).
#
#   ./install.sh                  install (auto-detects everything it can)
#   ./install.sh --update         git pull, then re-apply with saved settings
#   ./install.sh --dry-run        show what would change
#   ./install.sh --uninstall
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_FILE="$REPO_DIR/.install.conf"
SCHEMA="$(cat "$REPO_DIR/SCHEMA" 2>/dev/null || echo 1)"
ORIG_ARGS=("$@")

# ---- defaults ---------------------------------------------------------------
CONFIG_DIR=""
MOONRAKER_DIR="$HOME/moonraker"
SERVICE="moonraker"
MOONRAKER_PORT="7125"
SPOOLMAN_URL=""
TIMEOUT=""
NGINX_SITE=""
NGINX_SNIPPET_DIR="/etc/nginx/snippets"
DO_NGINX=1
DO_UPDATE_MGR=1
# Not saved between runs:
DO_RESTART=1
ASSUME_YES=0
DRY_RUN=0
UNINSTALL=0
DO_UPDATE=0
RESET=0

# Settings from the previous run, so updates need no flags. Flags still win.
LOADED_SETTINGS=0
if [[ -f "$SETTINGS_FILE" ]] && [[ " $* " != *" --reset "* ]]; then
  # shellcheck source=/dev/null
  source "$SETTINGS_FILE"
  LOADED_SETTINGS=1
fi

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Settings are auto-detected on the first run and saved to .install.conf in this
folder, so later runs (and --update) reuse them. Flags override saved values.

  --update               git pull this repo, then re-run the install with
                         saved settings (use after updating, or any time)
  --spoolman-url URL     Spoolman base URL, e.g. http://truenas:7912
                         Default: "server:" in [spoolman] of moonraker.conf.
                         Required if neither that nor a saved value exists.
  --timeout SECONDS      Countdown shown in the card. Must equal
                         pending_spool_id_timeout in Happy Hare's
                         mmu_parameters.cfg (read from there, else 20).
  --config-dir DIR       Klipper config dir (has moonraker.conf).
                         Default: ~/printer_data/config, else ~/klipper_config
  --moonraker-dir DIR    Moonraker source dir. Default: ~/moonraker
  --service NAME         Moonraker systemd service. Default: moonraker
  --moonraker-port PORT  For the post-install check. Default: 7125
  --nginx-site FILE      nginx site file serving Mainsail.
                         Default: /etc/nginx/sites-enabled/mainsail
  --nginx-snippet-dir D  Default: /etc/nginx/snippets
  --no-nginx             Don't touch nginx. You must then serve web/ at /nfc/
                         and inject /nfc/mainsail-nfc.js into Mainsail yourself.
  --no-update-manager    Don't add the Moonraker update_manager entry
  --no-restart           Don't restart Moonraker or reload nginx
  --reset                Ignore saved settings and auto-detect again
  -y, --yes              Never prompt (fail if a required value is missing)
  --dry-run              Print what would change; change nothing
  --uninstall            Remove everything this script added
  -h, --help             This help
EOF
}

need_val() { [[ $# -ge 2 && -n "${2:-}" ]] || { echo "error: $1 needs a value" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update)            DO_UPDATE=1; shift ;;
    --spoolman-url)      need_val "$@"; SPOOLMAN_URL="$2"; shift 2 ;;
    --timeout)           need_val "$@"; TIMEOUT="$2"; shift 2 ;;
    --config-dir)        need_val "$@"; CONFIG_DIR="$2"; shift 2 ;;
    --moonraker-dir)     need_val "$@"; MOONRAKER_DIR="$2"; shift 2 ;;
    --service)           need_val "$@"; SERVICE="$2"; shift 2 ;;
    --moonraker-port)    need_val "$@"; MOONRAKER_PORT="$2"; shift 2 ;;
    --nginx-site)        need_val "$@"; NGINX_SITE="$2"; shift 2 ;;
    --nginx-snippet-dir) need_val "$@"; NGINX_SNIPPET_DIR="$2"; shift 2 ;;
    --no-nginx)          DO_NGINX=0; shift ;;
    --no-update-manager) DO_UPDATE_MGR=0; shift ;;
    --no-restart)        DO_RESTART=0; shift ;;
    --reset)             RESET=1; shift ;;
    -y|--yes)            ASSUME_YES=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --uninstall)         UNINSTALL=1; shift ;;
    --gates|--preload-cmd)
      need_val "$@"; echo "note: $1 is no longer needed (read live from Happy Hare); ignoring" >&2; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
act()  { if [[ $DRY_RUN -eq 1 ]]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }
can_prompt() { [[ $ASSUME_YES -eq 0 && -t 0 ]]; }

[[ $EUID -ne 0 ]] || die "run as the printer user, not root (config files must stay owned by that user)"
command -v python3 >/dev/null || die "python3 is required"
[[ $DRY_RUN -eq 1 ]] && say "DRY RUN: nothing will be changed"
[[ $LOADED_SETTINGS -eq 1 ]] && say "using saved settings from .install.conf (flags override; --reset to re-detect)"

# ---- --update: pull, then re-run the (possibly new) installer ---------------
if [[ $DO_UPDATE -eq 1 && -z "${NFC_SPOOL_REEXEC:-}" ]]; then
  command -v git >/dev/null || die "git is required for --update"
  before="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
  say "updating repo (git pull --ff-only)"
  if [[ $DRY_RUN -eq 0 ]]; then
    git -C "$REPO_DIR" pull --ff-only \
      || die "git pull failed. Local edits in $REPO_DIR? Check 'git -C $REPO_DIR status'."
  else
    echo "[dry-run] git -C $REPO_DIR pull --ff-only"
  fi
  after="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
  if [[ "$before" == "$after" ]]; then say "already at $after"; else say "updated $before -> $after"; fi
  if [[ $DRY_RUN -eq 0 ]]; then
    args=()
    for a in "${ORIG_ARGS[@]}"; do [[ "$a" == "--update" ]] || args+=("$a"); done
    exec env NFC_SPOOL_REEXEC=1 "$REPO_DIR/install.sh" "${args[@]}"
  fi
fi

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
NGINX_BIN="$(command -v nginx 2>/dev/null || echo /usr/sbin/nginx)"

if [[ -z "$NGINX_SITE" ]]; then
  for f in /etc/nginx/sites-enabled/mainsail /etc/nginx/conf.d/mainsail.conf; do
    [[ -f "$f" ]] && NGINX_SITE="$f" && break
  done
fi

backup() { [[ -e "$1" ]] || return 0; act cp -p "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)"; }

restart_services() {
  [[ $DO_RESTART -eq 1 ]] || { say "skipping restart (--no-restart); restart $SERVICE yourself"; return; }
  say "restarting $SERVICE"
  act sudo systemctl restart "$SERVICE"
}

# Managed block in moonraker.conf. Usage: edit_conf add|remove
edit_conf() {
  MODE="$1" CONF="$MOONRAKER_CONF" BEGIN="$MARK_BEGIN" END="$MARK_END" \
  SPOOLMAN="$SPOOLMAN_URL" TIMEOUT="$TIMEOUT" REPO="$REPO_DIR" SCHEMA="$SCHEMA" \
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
    action, lines = "remove managed block from", []
else:
    if re.search(r"^\[nfc_spool\]", stripped, re.M):
        print("error: moonraker.conf has an [nfc_spool] section outside the installer's "
              "block. Remove it, then re-run.", file=sys.stderr)
        sys.exit(1)
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
             "pending_timeout: " + e["TIMEOUT"],
             "installed_schema: " + e["SCHEMA"]]
    if e["UPDMGR"] == "1":
        if re.search(r"^\[update_manager nfc-spool\]", stripped, re.M):
            print("warning: an unmanaged [update_manager nfc-spool] exists; leaving it.",
                  file=sys.stderr)
        else:
            lines += ["", "[update_manager nfc-spool]", "type: git_repo",
                      "path: " + e["REPO"], "origin: " + origin,
                      "primary_branch: main", "is_system_service: False",
                      "managed_services: moonraker"]
    lines.append(end)
    new = stripped.rstrip("\n") + "\n\n" + "\n".join(lines) + "\n"
    action = "write managed block in"

if new == text:
    print("moonraker.conf: already up to date"); sys.exit(0)
if e["DRY"] == "1":
    print("[dry-run] would %s %s" % (action, e["CONF"]))
    for l in lines: print("[dry-run]   " + l)
    sys.exit(0)
import shutil, time
bak = e["CONF"] + ".bak." + time.strftime("%Y%m%d-%H%M%S")
shutil.copy2(e["CONF"], bak)
print("moonraker.conf: backup at " + bak)
open(e["CONF"], "w").write(new)
print("moonraker.conf: %s" % action)
PY
}

# v1 added a "Spool Scan" sidebar link; remove it. Usage: remove_navi_entry
remove_navi_entry() {
  local f="$THEME_DIR/navi.json"
  [[ -f "$f" ]] && grep -q '"Spool Scan"' "$f" || return 0
  backup "$f"
  NAVI="$f" DRY="$DRY_RUN" python3 - <<'PY'
import json, os, sys
p = os.environ["NAVI"]
try:
    items = json.load(open(p))
except Exception:
    print("warning: %s is not valid JSON; remove the Spool Scan entry by hand" % p, file=sys.stderr)
    sys.exit(0)
items = [i for i in items if not (isinstance(i, dict) and i.get("title") == "Spool Scan")]
if os.environ["DRY"] == "1":
    print("[dry-run] would remove old Spool Scan sidebar link from " + p); sys.exit(0)
if items:
    with open(p, "w") as f:
        json.dump(items, f, indent=2); f.write("\n")
else:
    os.remove(p)
print("navi.json: removed old Spool Scan sidebar link")
PY
}

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

nginx_remove() {
  [[ -n "$NGINX_SITE" && -f "$NGINX_SITE" ]] || return 0
  if grep -qF "$INCLUDE_LINE" "$NGINX_SITE"; then
    say "removing nginx include from $NGINX_SITE (sudo)"
    act sudo cp -p "$NGINX_SITE" "$NGINX_SITE.bak.$(date +%Y%m%d-%H%M%S)"
    act sudo sed -i --follow-symlinks "\\#$INCLUDE_LINE#d" "$NGINX_SITE"
  fi
  [[ -f "$SNIPPET_FILE" ]] && act sudo rm -f "$SNIPPET_FILE"
  if [[ $DO_RESTART -eq 1 ]]; then act sudo "$NGINX_BIN" -t && act sudo systemctl reload nginx; fi
}

# ---- uninstall --------------------------------------------------------------
if [[ $UNINSTALL -eq 1 ]]; then
  say "uninstalling"
  edit_conf remove
  if [[ -L "$COMPONENT_LINK" ]]; then act rm -f "$COMPONENT_LINK"; say "removed $COMPONENT_LINK"; fi
  if [[ -f "$MOONRAKER_DIR/.git/info/exclude" ]]; then
    act sed -i '\#^moonraker/components/nfc_spool\.py$#d' "$MOONRAKER_DIR/.git/info/exclude"
  fi
  remove_navi_entry
  act rm -f "$REPO_DIR/web/config.js" "$SETTINGS_FILE"
  nginx_remove   # always: removes our include/snippet only if present
  restart_services
  say "done. $REPO_DIR was left in place; delete it if you want."
  exit 0
fi

# ---- resolve parameters -----------------------------------------------------
if [[ -z "$SPOOLMAN_URL" ]]; then
  SPOOLMAN_URL="$(ini_get spoolman server)"
  [[ -n "$SPOOLMAN_URL" ]] && say "Spoolman URL from moonraker.conf [spoolman]: $SPOOLMAN_URL"
fi
if [[ -z "$SPOOLMAN_URL" ]] && can_prompt; then
  read -r -p "Spoolman URL (e.g. http://truenas:7912): " SPOOLMAN_URL
fi
[[ -n "$SPOOLMAN_URL" ]] || die "Spoolman URL unknown; pass --spoolman-url"
SPOOLMAN_URL="${SPOOLMAN_URL%/}"
# tidy "http:///host", "host:port" and a trailing "/api"
SPOOLMAN_URL="$(printf %s "$SPOOLMAN_URL" | sed -E 's#^(https?):/+#\1://#; s#/api$##')"
[[ "$SPOOLMAN_URL" == http*://* ]] || SPOOLMAN_URL="http://$SPOOLMAN_URL"
[[ "$SPOOLMAN_URL" =~ ^https?://[^/[:space:]]+(/[^[:space:]]*)?$ ]] \
  || die "bad Spoolman URL: $SPOOLMAN_URL (expected http://host:port)"

if [[ -z "$TIMEOUT" ]]; then
  while IFS= read -r f; do
    v="$(sed -nE 's/^[[:space:]]*pending_spool_id_timeout[[:space:]]*[:=][[:space:]]*([0-9.]+).*/\1/p' "$f" | head -1)"
    [[ -n "$v" ]] && TIMEOUT="$v" && say "timeout from $f: ${TIMEOUT}s" && break
  done < <(find "$CONFIG_DIR" -maxdepth 4 -name 'mmu_parameters.cfg' 2>/dev/null)
fi
if [[ -z "$TIMEOUT" ]]; then
  TIMEOUT=20
  warn "couldn't read pending_spool_id_timeout from Happy Hare config; using 20. Pass --timeout if yours differs."
fi
[[ "$TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--timeout must be a number"

say "settings: spoolman=$SPOOLMAN_URL timeout=${TIMEOUT}s schema=$SCHEMA"
say "          config=$CONFIG_DIR moonraker=$MOONRAKER_DIR service=$SERVICE nginx=${NGINX_SITE:-none}"

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
if [[ -d "$MOONRAKER_DIR/.git/info" ]] && ! grep -qxF 'moonraker/components/nfc_spool.py' "$MOONRAKER_DIR/.git/info/exclude" 2>/dev/null; then
  act sh -c "echo 'moonraker/components/nfc_spool.py' >> '$MOONRAKER_DIR/.git/info/exclude'"
fi

# ---- 2. moonraker.conf ------------------------------------------------------
edit_conf add

# ---- 3. clean up things older versions added --------------------------------
remove_navi_entry
[[ -f "$REPO_DIR/web/config.js" ]] && act rm -f "$REPO_DIR/web/config.js"

# ---- 4. nginx: serve web/ at /nfc/ and inject the script into Mainsail ------
NGINX_OK=0
if [[ $DO_NGINX -eq 0 ]]; then
  say "skipping nginx (--no-nginx)"
elif [[ ! -x "$NGINX_BIN" ]]; then
  warn "nginx not found; skipping. The dashboard card needs it (or equivalent)."
elif [[ -z "$NGINX_SITE" || ! -f "$NGINX_SITE" ]]; then
  warn "no Mainsail nginx site found; pass --nginx-site FILE or --no-nginx."
elif ! "$NGINX_BIN" -V 2>&1 | grep -q 'http_sub_module'; then
  warn "your nginx lacks the sub_filter module, needed to add the card to Mainsail."
  warn "install a fuller build (sudo apt install nginx-full) and re-run."
else
  say "configuring nginx via $NGINX_SITE (sudo)"
  SNIPPET_TMP="$(mktemp)"
  trap 'rm -f "$SNIPPET_TMP"' EXIT
  cat >"$SNIPPET_TMP" <<EOF
# managed by nfc-spool install.sh (schema $SCHEMA). Re-run the installer to change.
location = /nfc { return 301 /nfc/; }
location /nfc/ {
    alias $REPO_DIR/web/;
    index index.html;
    add_header Cache-Control "no-cache";
}
# Adds the scanner card to Mainsail's dashboard.
sub_filter '</head>' '<script src="/nfc/mainsail-nfc.js" defer></script></head>';
sub_filter_once on;
# Mainsail's service worker serves a cached copy of the page from before the
# script was added. Changing the precache revision of index.html in sw.js makes
# every browser fetch the page again once. Applies to sw.js only.
location = /sw.js {
    sub_filter_types application/javascript text/javascript;
    sub_filter 'url:"index.html",revision:"' 'url:"index.html",revision:"nfcspool$SCHEMA-';
    sub_filter_once on;
    add_header Cache-Control "no-cache";
}
EOF
  if [[ -f "$SNIPPET_FILE" ]] && cmp -s "$SNIPPET_TMP" "$SNIPPET_FILE"; then
    say "nginx snippet already up to date"
    SNIPPET_CHANGED=0
  else
    act sudo mkdir -p "$NGINX_SNIPPET_DIR"
    act sudo install -m 644 "$SNIPPET_TMP" "$SNIPPET_FILE"
    SNIPPET_CHANGED=1
  fi
  SITE_CHANGED=0
  if grep -qF "$INCLUDE_LINE" "$NGINX_SITE"; then
    say "nginx include already present"
  elif grep -qE '^[[:space:]]*location[[:space:]]+/[[:space:]]*\{' "$NGINX_SITE"; then
    act sudo cp -p "$NGINX_SITE" "$NGINX_SITE.bak.$(date +%Y%m%d-%H%M%S)"
    act sudo sed -i --follow-symlinks -E "0,/^([[:space:]]*)location[[:space:]]+\\/[[:space:]]*\\{/s||\\1$INCLUDE_LINE\n&|" "$NGINX_SITE"
    SITE_CHANGED=1
  else
    warn "couldn't find 'location / {' in $NGINX_SITE. Add this line inside its server block yourself:"
    warn "    $INCLUDE_LINE"
  fi
  NGINX_OK=1
  if [[ $DRY_RUN -eq 0 && ( $SNIPPET_CHANGED -eq 1 || $SITE_CHANGED -eq 1 ) ]]; then
    if sudo "$NGINX_BIN" -t 2>&1; then
      if [[ $DO_RESTART -eq 1 ]]; then sudo systemctl reload nginx && say "nginx reloaded"; fi
    else
      NGINX_OK=0
      warn "nginx -t failed; undoing the nginx changes"
      if [[ $SITE_CHANGED -eq 1 ]]; then
        latest="$(ls -1t "$NGINX_SITE".bak.* | head -1)"
        sudo cp -p "$latest" "$NGINX_SITE"
      fi
      sudo rm -f "$SNIPPET_FILE"
    fi
  fi
  if [[ $DRY_RUN -eq 0 ]] && id www-data >/dev/null 2>&1 \
     && ! sudo -u www-data test -r "$REPO_DIR/web/mainsail-nfc.js" 2>/dev/null; then
    warn "nginx (www-data) can't read $REPO_DIR/web; your home dir is probably private. Fix:"
    warn "    chmod o+x \"$HOME\""
  fi
fi

# ---- 5. save settings for next time -----------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
  {
    echo "# nfc-spool install settings (written by install.sh; safe to edit or delete)"
    for v in SPOOLMAN_URL TIMEOUT CONFIG_DIR MOONRAKER_DIR SERVICE MOONRAKER_PORT \
             NGINX_SITE NGINX_SNIPPET_DIR DO_NGINX DO_UPDATE_MGR; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } >"$SETTINGS_FILE"
fi

# ---- 6. restart + checks ----------------------------------------------------
restart_services
if [[ $DRY_RUN -eq 0 && $DO_RESTART -eq 1 ]] && command -v curl >/dev/null; then
  say "waiting for Moonraker"
  status=""
  for _ in $(seq 1 20); do
    status="$(curl -fsS "http://127.0.0.1:$MOONRAKER_PORT/server/nfc/status" 2>/dev/null)" && break
    sleep 1
  done
  if [[ -z "$status" ]]; then
    warn "component didn't answer. Check: journalctl -u $SERVICE -n 50   (or moonraker.log)"
  elif [[ "$status" == *'"update_required": true'* || "$status" == *'"update_required":true'* ]]; then
    warn "component reports it still needs an update; check moonraker.conf's nfc-spool block"
  else
    say "component is up"
  fi
  if [[ $NGINX_OK -eq 1 ]]; then
    if curl -fsS "http://127.0.0.1/" 2>/dev/null | grep -q '/nfc/mainsail-nfc.js'; then
      say "Mainsail page includes the scanner script"
    else
      warn "Mainsail's page doesn't include the scanner script yet. Check that $NGINX_SITE is"
      warn "the site actually serving Mainsail, and that no location there sets its own sub_filter."
    fi
    if curl -fsS "http://127.0.0.1/sw.js" 2>/dev/null | grep -q "revision:\"nfcspool$SCHEMA-"; then
      say "Mainsail's service worker will refresh cached pages"
    else
      warn "couldn't tag Mainsail's sw.js, so browsers that opened Mainsail before may keep a"
      warn "cached page without the scanner. Clear that site's data in the browser once."
    fi
  fi
  say "Moonraker restarted. If Happy Hare logged a Spoolman 'not registered' error just now,"
  say "that was the restart gap; run MMU_SPOOLMAN SYNC=1 in the console to re-sync."
fi

cat <<EOF

Done (schema $SCHEMA). Next:
  1. Spoolman (v0.27.0+): link each tag (spool -> Tags -> Add tag).
  2. Open Mainsail over HTTPS on an Android phone in Chrome. The "Scan spool"
     button is at the top of the Happy Hare (MMU) panel on the dashboard.
  3. Browsers that opened Mainsail before refresh their cached copy on their own:
     Mainsail reloads once (it may show an "update available" prompt; accept it).
     If the button still isn't there after two reloads, clear the site's data once.

Updating later: Mainsail's Machine page updates nfc-spool like any other
component. If it then shows an "nfc-spool ... install.sh --update" warning,
run: $REPO_DIR/install.sh --update
EOF
