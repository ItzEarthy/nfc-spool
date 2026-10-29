// Spool Scan page: read an NFC tag with Web NFC (Chrome on Android, HTTPS only),
// send the UID to the Moonraker nfc_spool component, show the pending spool
// and let you run MMU_PRELOAD for a gate.
(function () {
  "use strict";

  // Written by install.sh into web/config.js (gitignored). Defaults apply
  // if that file is missing.
  var CFG = window.NFC_CONFIG || {};
  var GATE_COUNT = parseInt(CFG.gates, 10) || 4;
  var PRELOAD_CMD = CFG.preload || "MMU_PRELOAD GATE={gate}";

  var els = {
    scan: document.getElementById("scan"),
    msg: document.getElementById("msg"),
    card: document.getElementById("card"),
    name: document.getElementById("name"),
    detail: document.getElementById("detail"),
    swatch: document.getElementById("swatch"),
    bar: document.querySelector("#bar > div"),
    left: document.getElementById("left"),
    gates: document.getElementById("gates"),
  };

  var lastUid = null;
  var lastAt = 0;
  var totalSeconds = 20;
  var pollTimer = null;

  function say(text, isError) {
    els.msg.textContent = text;
    els.msg.className = isError ? "err" : "";
  }

  function unwrap(json) {
    return json && json.result !== undefined ? json.result : json;
  }

  async function api(method, path, body) {
    var opts = { method: method, headers: {} };
    if (body !== undefined) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    var resp = await fetch(path, opts);
    var json = null;
    try { json = await resp.json(); } catch (e) { /* non-JSON */ }
    if (!resp.ok) {
      var m = json && json.error && json.error.message;
      throw new Error(m || ("HTTP " + resp.status));
    }
    return unwrap(json);
  }

  function showPending(p) {
    if (!p) {
      els.card.style.display = "none";
      return;
    }
    els.card.style.display = "block";
    els.name.textContent = "#" + p.spool_id + " " + (p.name || "");
    els.detail.textContent = [p.vendor, p.material].filter(Boolean).join(" · ");
    els.swatch.style.background = p.color_hex ? "#" + p.color_hex : "transparent";
    var left = Math.max(0, p.seconds_left);
    els.left.textContent = left > 0 ? Math.ceil(left) + "s left to load" : "expired - scan again";
    els.bar.style.width = Math.min(100, (left / totalSeconds) * 100) + "%";
  }

  async function poll() {
    try {
      var s = await api("GET", "/server/nfc/status");
      showPending(s.pending);
    } catch (e) {
      /* keep quiet; scan errors are reported separately */
    }
  }

  async function handleUid(uid) {
    var now = Date.now();
    if (uid === lastUid && now - lastAt < 3000) return;
    lastUid = uid;
    lastAt = now;
    say("Tag " + uid + " ...");
    try {
      var r = await api("POST", "/server/nfc/scan", { uid: uid });
      if (!r.matched) {
        say("Tag " + r.uid + " is not linked to a spool in Spoolman.", true);
        return;
      }
      totalSeconds = Math.max(r.seconds_left, 1);
      say("Spool #" + r.spool_id + " is pending.");
      showPending(r);
    } catch (e) {
      say(e.message, true);
    }
  }

  async function startScan() {
    if (!("NDEFReader" in window)) {
      say("Web NFC is not available. Use Chrome on Android over HTTPS.", true);
      return;
    }
    try {
      var reader = new NDEFReader();
      await reader.scan();
      reader.onreadingerror = function () { say("Could not read that tag.", true); };
      reader.onreading = function (ev) { handleUid(ev.serialNumber); };
      els.scan.textContent = "Scanning - hold a tag to the back of the phone";
      els.scan.disabled = true;
      say("");
    } catch (e) {
      say("NFC error: " + e.message, true);
    }
  }

  async function preload(gate) {
    var script = PRELOAD_CMD.replace("{gate}", String(gate));
    say("Running " + script + " ...");
    try {
      await api("POST", "/printer/gcode/script", { script: script });
      say("Sent " + script);
    } catch (e) {
      say(e.message, true);
    }
  }

  for (var g = 0; g < GATE_COUNT; g++) {
    (function (gate) {
      var b = document.createElement("button");
      b.textContent = String(gate);
      b.addEventListener("click", function () { preload(gate); });
      els.gates.appendChild(b);
    })(g);
  }

  els.scan.addEventListener("click", startScan);
  pollTimer = setInterval(poll, 1000);
  poll();
})();
