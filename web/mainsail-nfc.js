// nfc-spool: adds a "Scan spool" section to the top of Mainsail's Happy Hare
// (MMU) panel on the dashboard. Injected into Mainsail's index.html by nginx
// (see install.sh). Runs in the Mainsail page itself, so nothing opens a new
// tab and it works inside the installed Mainsail app.
//
// Web NFC needs Chrome on Android over HTTPS. On other devices the section only
// appears while a spool is pending (e.g. scanned from a phone).
(function () {
  "use strict";
  if (window.__nfcSpoolLoaded) return;
  window.__nfcSpoolLoaded = true;

  var HAS_NFC = "NDEFReader" in window;
  var PANEL_SELECTOR = ".mmu-panel";
  var FALLBACK_DELAY_MS = 2500;

  var state = {
    pending: null,          // from /server/nfc/status (our countdown)
    choose: null,           // tag is on a filament with several spools
    updateRequired: false,
    mmu: null,              // Happy Hare status (num_gates, gate_status, ...)
    printing: false,
    scanning: false,
    busyGate: null,
    msg: "",
    msgErr: false,
    lastHHPending: -1,
  };
  var reader = null;
  var abort = null;
  var lastUid = null;
  var lastUidAt = 0;
  var pollTimer = null;
  var dashboardSince = 0;

  // ---------- DOM ----------------------------------------------------------
  var root = document.createElement("div");
  root.className = "nfc-spool";
  var floatBox = null;

  var css = document.createElement("style");
  css.textContent = [
    ".nfc-spool{padding:12px 16px 4px}",
    ".nfc-spool .nfc-row{display:flex;align-items:center;gap:8px;flex-wrap:wrap}",
    ".nfc-spool .nfc-msg{font-size:.85rem;opacity:.85;min-height:1.2em;margin:6px 0 0}",
    ".nfc-spool .nfc-msg.err{color:#ff5252;opacity:1}",
    ".nfc-spool .nfc-swatch{width:16px;height:16px;border-radius:50%;border:1px solid rgba(128,128,128,.6);flex:none}",
    ".nfc-spool .nfc-spool-name{font-weight:500}",
    ".nfc-spool .nfc-sub{font-size:.8rem;opacity:.7}",
    ".nfc-spool .nfc-bar{height:4px;border-radius:2px;background:rgba(128,128,128,.25);overflow:hidden;margin:8px 0 4px}",
    ".nfc-spool .nfc-bar>div{height:100%;background:var(--v-primary-base,#2196f3);transition:width 1s linear}",
    ".nfc-spool .nfc-gates{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}",
    ".nfc-spool .nfc-gates .v-btn{min-width:40px!important}",
    ".nfc-spool .nfc-banner{font-size:.85rem;padding:6px 10px;border-radius:4px;background:rgba(255,152,0,.15);margin-bottom:8px}",
    ".nfc-spool hr{margin-top:10px}",
    ".nfc-spool-float{position:fixed;right:16px;bottom:16px;z-index:6;max-width:calc(100vw - 32px);width:360px;",
    "border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.4)}",
  ].join("");
  document.head.appendChild(css);

  function theme() {
    var app = document.querySelector(".v-application");
    return app && app.classList.contains("theme--light") ? "theme--light" : "theme--dark";
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function btn(label, attrs, opts) {
    opts = opts || {};
    var cls = "v-btn v-btn--outlined " + theme() + " v-size--" + (opts.size || "small");
    if (opts.color) cls += " " + opts.color + "--text";
    if (opts.disabled) cls += " v-btn--disabled";
    return '<button type="button" class="' + cls + '" ' + (attrs || "") +
      (opts.disabled ? " disabled" : "") + '><span class="v-btn__content">' + esc(label) + "</span></button>";
  }

  // ---------- data ---------------------------------------------------------
  async function getJson(url, opts) {
    var resp = await fetch(url, Object.assign({ credentials: "same-origin" }, opts || {}));
    var json = null;
    try { json = await resp.json(); } catch (e) { /* not JSON */ }
    if (!resp.ok) {
      var m = json && json.error && json.error.message;
      throw new Error(m || "HTTP " + resp.status);
    }
    return json && json.result !== undefined ? json.result : json;
  }

  async function poll() {
    if (document.hidden || !root.isConnected) return schedule();
    try {
      var s = await getJson("/server/nfc/status");
      state.pending = s.pending;
      state.choose = s.choose || null;
      state.updateRequired = !!s.update_required;
    } catch (e) {
      state.pending = null;
    }
    try {
      var q = await getJson("/printer/objects/query?mmu=enabled,num_gates,gate_status,gate_spool_id,pending_spool_id&print_stats=state");
      var st = (q && q.status) || {};
      state.mmu = st.mmu || null;
      state.printing = st.print_stats && st.print_stats.state === "printing";
    } catch (e) {
      state.mmu = null;
    }
    noticeAssignment();
    render();
    schedule();
  }

  function schedule() {
    clearTimeout(pollTimer);
    pollTimer = setTimeout(poll, state.pending ? 1000 : 3000);
  }

  // Happy Hare clears pending_spool_id once a gate takes the spool.
  function noticeAssignment() {
    var hh = state.mmu && typeof state.mmu.pending_spool_id === "number" ? state.mmu.pending_spool_id : null;
    if (hh === null) return;
    if (state.lastHHPending > 0 && hh <= 0 && state.mmu.gate_spool_id) {
      var gate = state.mmu.gate_spool_id.indexOf(state.lastHHPending);
      if (gate >= 0) say("Spool #" + state.lastHHPending + " assigned to gate " + gate + ".");
    }
    state.lastHHPending = hh;
  }

  function pendingSpool() {
    var p = state.pending;
    if (!p) return null;
    var hh = state.mmu && typeof state.mmu.pending_spool_id === "number" ? state.mmu.pending_spool_id : null;
    // If Happy Hare reports its own pending id, trust it over our timer.
    if (hh !== null && hh !== p.spool_id) return null;
    return p;
  }

  function say(text, isErr) {
    state.msg = text;
    state.msgErr = !!isErr;
    render();
  }

  // ---------- actions ------------------------------------------------------
  async function handleUid(uid) {
    var now = Date.now();
    if (uid === lastUid && now - lastUidAt < 3000) return;
    lastUid = uid;
    lastUidAt = now;
    say("Looking up tag " + uid + "...");
    try {
      var r = await getJson("/server/nfc/scan", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ uid: uid }),
      });
      if (!r.matched) {
        if (r.reason === "choose") {
          state.choose = r.choose;
          return say("This tag is on the filament, not a spool. Tap the spool you are loading.");
        }
        if (r.reason === "no_spools") {
          return say("Tag is on filament \"" + (r.filament_name || "#" + r.filament_id) +
            "\", which has no active spools in Spoolman.", true);
        }
        return say("Tag " + r.uid + " isn't linked in Spoolman. Add it under the spool's Tags.", true);
      }
      state.choose = null;
      state.pending = r;
      if (navigator.vibrate) navigator.vibrate(60);
      say("Insert the filament into a gate, then tap that gate's number.");
      poll();
    } catch (e) {
      say(e.message, true);
    }
  }

  async function toggleScan() {
    if (state.scanning) {
      if (abort) abort.abort();
      state.scanning = false;
      return say("");
    }
    try {
      reader = new NDEFReader();
      abort = new AbortController();
      await reader.scan({ signal: abort.signal });
      reader.onreading = function (ev) { handleUid(ev.serialNumber || ""); };
      reader.onreadingerror = function () { say("Couldn't read that tag. Try again.", true); };
      state.scanning = true;
      say("Hold a spool's tag to the back of the phone.");
    } catch (e) {
      state.scanning = false;
      say("NFC: " + e.message, true);
    }
  }

  async function selectSpool(id) {
    say("Using spool #" + id + "...");
    try {
      var r = await getJson("/server/nfc/select", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ spool_id: id }),
      });
      state.choose = null;
      state.pending = r;
      say("Insert the filament into a gate, then tap that gate's number.");
      poll();
    } catch (e) {
      say(e.message, true);
    }
  }

  async function preload(gate) {
    state.busyGate = gate;
    say("Preloading gate " + gate + "...");
    try {
      await getJson("/printer/gcode/script", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ script: "MMU_PRELOAD GATE=" + gate }),
      });
      say("Gate " + gate + " preloaded.");
    } catch (e) {
      say(e.message, true);
    } finally {
      state.busyGate = null;
      poll();
    }
  }

  root.addEventListener("click", function (ev) {
    var b = ev.target.closest("button");
    if (!b || b.disabled) return;
    if (b.dataset.act === "scan") toggleScan();
    else if (b.dataset.gate !== undefined) preload(parseInt(b.dataset.gate, 10));
    else if (b.dataset.spool !== undefined) selectSpool(parseInt(b.dataset.spool, 10));
    else if (b.dataset.act === "close") { closeFloat(); }
  });

  // ---------- render -------------------------------------------------------
  // Always shown inside the MMU panel (so it's clear the add-on loaded).
  // The floating fallback only appears when there's something to act on.
  function visible() {
    return !!floatBox || isInPanel() || HAS_NFC || !!pendingSpool() || !!state.choose || state.updateRequired;
  }
  function isInPanel() {
    var p = root.parentNode && root.parentNode.parentNode;
    return !!(p && p.matches && p.matches(PANEL_SELECTOR));
  }
  function whyNoScan() {
    if (!window.isSecureContext) return "Scanning needs HTTPS. Open Mainsail via its https:// address on an Android phone.";
    return "Scanning works in Chrome on Android. Spools scanned on a phone show up here.";
  }

  function render() {
    if (!visible()) { root.style.display = "none"; return; }
    root.style.display = "";
    var html = "";
    if (state.updateRequired) {
      html += '<div class="nfc-banner">nfc-spool was updated. Run <code>~/nfc-spool/install.sh --update</code> on the Pi.</div>';
    }
    html += '<div class="nfc-row">';
    if (HAS_NFC) {
      html += btn(state.scanning ? "Stop scanning" : "Scan spool", 'data-act="scan"', { color: "primary" });
    }
    var p = pendingSpool();
    if (p) {
      html += '<span class="nfc-swatch" style="background:' + (p.color_hex ? "#" + esc(p.color_hex) : "transparent") + '"></span>';
      html += '<span><span class="nfc-spool-name">#' + esc(p.spool_id) + " " + esc(p.name) + "</span>";
      var sub = [p.vendor, p.material].filter(Boolean).join(" \u00b7 ");
      if (sub) html += ' <span class="nfc-sub">' + esc(sub) + "</span>";
      html += "</span>";
    } else if (HAS_NFC && !state.scanning) {
      html += '<span class="nfc-sub">Tap a spool tag to assign it to the next gate you load.</span>';
    } else if (!HAS_NFC) {
      html += '<span class="nfc-sub">NFC spool scan: ' + esc(whyNoScan()) + "</span>";
    }
    if (floatBox) html += '<span style="flex:1"></span>' + btn("Close", 'data-act="close"', { size: "x-small" });
    html += "</div>";

    var c = !p && state.choose;
    if (c) {
      html += '<div class="nfc-row" style="margin-top:8px">';
      html += '<span class="nfc-swatch" style="background:' + (c.color_hex ? "#" + esc(c.color_hex) : "transparent") + '"></span>';
      html += '<span class="nfc-spool-name">' + esc(c.name) + "</span>";
      var csub = [c.vendor, c.material].filter(Boolean).join(" \u00b7 ");
      if (csub) html += ' <span class="nfc-sub">' + esc(csub) + "</span>";
      html += "</div><div class=\"nfc-gates\">";
      c.spools.forEach(function (sp) {
        var label = "#" + sp.spool_id + (sp.remaining != null ? " \u00b7 " + sp.remaining + "g" : "");
        var tip = [sp.location, sp.lot_nr ? "lot " + sp.lot_nr : ""].filter(Boolean).join(", ");
        html += btn(label, 'data-spool="' + esc(sp.spool_id) + '" title="' + esc(tip) + '"', {});
      });
      html += "</div>";
    }

    if (p) {
      var total = p.timeout || 20;
      var left = Math.max(0, p.seconds_left);
      html += '<div class="nfc-bar"><div style="width:' + Math.min(100, (left / total) * 100) + '%"></div></div>';
      html += '<div class="nfc-sub">' + (left > 0 ? Math.ceil(left) + "s to load it" : "Expired, scan again") + "</div>";
      var n = state.mmu && state.mmu.num_gates;
      if (n) {
        html += '<div class="nfc-gates">';
        for (var g = 0; g < n; g++) {
          var empty = state.mmu.gate_status && state.mmu.gate_status[g] === 0;
          html += btn(String(g), 'data-gate="' + g + '" title="MMU_PRELOAD GATE=' + g + (empty ? " (empty gate)" : "") + '"', {
            color: empty ? "primary" : "",
            disabled: state.printing || state.busyGate !== null || left <= 0,
          });
        }
        html += "</div>";
        if (state.printing) html += '<div class="nfc-sub">Preload is disabled while printing.</div>';
      }
    }
    html += '<p class="nfc-msg' + (state.msgErr ? " err" : "") + '">' + esc(state.msg) + "</p>";
    if (!floatBox) html += '<hr class="v-divider ' + theme() + '">';
    root.innerHTML = html;
  }

  // ---------- placement ----------------------------------------------------
  function panelBody(panel) {
    // Mainsail Panel.vue: v-card > .panel-toolbar + div(v-show wrapper) > content
    var bar = panel.querySelector(":scope > .panel-toolbar");
    return bar && bar.nextElementSibling;
  }

  function closeFloat() {
    if (floatBox) { floatBox.remove(); floatBox = null; }
    dashboardSince = Infinity; // stay closed until the next visit to the dashboard
  }

  function place() {
    var panel = document.querySelector(PANEL_SELECTOR);
    var body = panel && panelBody(panel);
    if (body) {
      if (floatBox) { floatBox.remove(); floatBox = null; }
      if (root.parentNode !== body || body.firstChild !== root) body.insertBefore(root, body.firstChild);
      render();
      return;
    }
    // No Happy Hare panel (hidden or not loaded yet): float on the dashboard.
    var onDashboard = location.pathname === "/" || location.pathname === "";
    if (!onDashboard) {
      dashboardSince = 0;
      if (floatBox) { floatBox.remove(); floatBox = null; }
      return;
    }
    if (!dashboardSince) dashboardSince = Date.now();
    if (!floatBox && (HAS_NFC || !!pendingSpool() || state.updateRequired) && Date.now() - dashboardSince > FALLBACK_DELAY_MS) {
      floatBox = document.createElement("div");
      floatBox.className = "nfc-spool-float v-card v-sheet " + theme();
      floatBox.appendChild(root);
      (document.querySelector(".v-application") || document.body).appendChild(floatBox);
      render();
    }
  }

  var queued = false;
  function queuePlace() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(function () {
      queued = false;
      var inPanel = root.isConnected && root.parentNode && root.parentNode.parentNode &&
        root.parentNode.parentNode.matches && root.parentNode.parentNode.matches(PANEL_SELECTOR);
      if (!inPanel) place();
    });
  }

  new MutationObserver(queuePlace).observe(document.documentElement, { childList: true, subtree: true });
  setInterval(queuePlace, 1000); // also catches route changes with no DOM churn
  document.addEventListener("visibilitychange", function () { if (!document.hidden) poll(); });
  render();
  queuePlace();
  poll();
})();
