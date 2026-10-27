import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property var settings: ({})

  // ── State ─────────────────────────────────────────────────────────
  property bool installed: false       // llama-server binary exists + executable
  property bool hasService: false      // llama-server.service user unit exists
  property bool running: false
  property bool busy: false
  property string actionLabel: ""
  property string lastError: ""

  // ── API probe ─────────────────────────────────────────────────────
  property string servedModel: ""      // basename of what the server serves
  property int servedCtx: -1           // n_ctx the server enforces

  // ── GPU info (NVIDIA only; silently absent elsewhere) ─────────────
  property bool gpuUsable: false
  property string vramUsed: ""         // e.g. "8.4 G"
  property string vramTotal: ""        // e.g. "12 G"

  // ── Model listing (bounded) ──────────────────────────────────────
  readonly property int maxModels: 50
  property var models: []              // [{name, sizeBytes, sizeStr, isServed}]
  property bool modelsDirMissing: false
  property string firstModelFile: ""   // resolved default for unit generation
  property string activeSince: ""

  // ── Process deadlines (timeout primary + QML watchdog backup) ─────
  readonly property int processTimeoutSec: 8
  readonly property int unitTimeoutSec: 12
  readonly property int watchdogMs: 12000

  // ── Output caps at the OS pipe level ──────────────────────────────
  readonly property int capCheck: 256
  readonly property int capStatus: 2048
  readonly property int capModels: 16384
  readonly property int capApi: 2048
  readonly property int capGpu: 128
  readonly property int capAction: 1024
  readonly property int capUnit: 512

  // ── Colors (icon states; explicit so they don't shift per theme) ──
  readonly property color runGreen: "#4ade80"
  readonly property color offRed: "#f87171"
  readonly property color unsetDim: "#6b7280"

  // ── Settings ──────────────────────────────────────────────────────
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 300)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // Resolve a `$HOME`-relative (or absolute) path — no /home/<user> anywhere.
  function homePath(value) {
    var s = String(value || "").trim()
    if (s === "") return ""
    if (s.charAt(0) === "/") return s
    if (s.indexOf("~/") === 0) s = s.substring(2)
    var home = Quickshell.env("HOME")
    while (home.length > 1 && home.charAt(home.length - 1) === "/") home = home.slice(0, -1)
    return home + "/" + s
  }

  // Display form: mask $HOME as ~ so no username ever reaches the panel
  // or tooltips (parallels homePath; resolution itself stays $HOME-based).
  function displayPath(path) {
    var s = String(path || "")
    var home = Quickshell.env("HOME")
    while (home.length > 1 && home.charAt(home.length - 1) === "/") home = home.slice(0, -1)
    return (home !== "" && s.indexOf(home + "/") === 0) ? "~/" + s.substring(home.length + 1) : s
  }

  readonly property string modelsDir: homePath(setting("modelsDir", "LLM/models"))
  readonly property string binary: homePath(setting("binary", "/usr/bin/llama-server"))
  readonly property bool useRocm: intSetting("useRocm", 0, 0, 1) === 1
  readonly property string rocmBinary: homePath(setting("rocmBinary", ""))
  readonly property string rocmLibPath: homePath(setting("rocmLibPath", ""))
  readonly property string hsaOverrideGfxVersion: String(setting("hsaOverrideGfxVersion", "") || "").trim()
  readonly property string activeBinary: (useRocm && rocmBinary !== "") ? rocmBinary : binary
  readonly property int port: intSetting("port", 8080, 1024, 65535)
  readonly property int ctxSize: intSetting("ctxSize", 147456, 4096, 524288)
  readonly property string modelFileSetting: String(setting("modelFile", "") || "").trim()
  readonly property string extraArgs: String(setting("extraArgs", "--batch-size 2048 --ubatch-size 2048 --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn on --override-tensor 'blk\\.[0-9]+\\.ffn_.*_exps\\.weight=CPU' --jinja --metrics --slots --no-ui") || "").trim()

  // ── Sanitize external strings for safe display ──────────────────────
  function sanitize(str) {
    return String(str || "").replace(/[<>&]/g, function(c) {
      if (c === "<") return "&lt;"
      if (c === ">") return "&gt;"
      if (c === "&") return "&amp;"
      return c
    })
  }

  function truncate(str, maxLen) {
    var s = String(str || "")
    if (s.length <= maxLen) return s
    return s.substring(0, maxLen) + "…"
  }

  function humanSize(bytes) {
    var b = parseFloat(bytes)
    if (!isFinite(b) || b <= 0) return ""
    var g = b / 1073741824
    if (g >= 1) return g.toFixed(1) + " G"
    var m = b / 1048576
    if (m >= 1) return m.toFixed(0) + " M"
    return b + " B"
  }

  function _actionError(output, verb) {
    var s = String(output || "").trim()
    if (/request dismissed|dismissed by user|cancelled|canceled/i.test(s)) {
      return (verb === "start" ? "Start" : "Stop") + " cancelled."
    }
    if (/failed|error/i.test(s)) {
      return "Failed to " + verb + " llama-server:\n" + truncate(s, 240) +
             "\nDetails: journalctl --user -u llama-server -n 20"
    }
    return "Failed to " + verb + " llama-server" + (s !== "" ? ": " + truncate(s, 160) : "")
  }

  // ── Process lifecycle helpers ─────────────────────────────────────
  function launch(process, watchdog) {
    if (!process.running) {
      process.running = true
      watchdog.restart()
    }
  }

  function reap(process, watchdog) {
    watchdog.stop()
    if (process.running) process.running = false
  }

  function refresh() {
    launch(modelsProcess, modelsWatchdog)   // catalog regardless of service state
    if (!installed) {
      launch(checkProcess, checkWatchdog)
      return
    }
    launch(statusProcess, statusWatchdog)
    if (running) {
      launch(apiProcess, apiWatchdog)
      launch(gpuProcess, gpuWatchdog)
    } else {
      servedModel = ""
      servedCtx = -1
    }
  }

  function startService() {
    if (busy || !installed || !hasService) {
      if (!installed) lastError = "llama-server binary not found at " + truncate(displayPath(activeBinary), 80) + "."
      return
    }
    busy = true
    actionLabel = "Starting llama-server…"
    lastError = ""
    startProcess.running = true
    startActionWatchdog.restart()
  }

  function stopService() {
    if (busy || !installed || !hasService) return
    busy = true
    actionLabel = "Stopping llama-server…"
    lastError = ""
    stopProcess.running = true
    stopActionWatchdog.restart()
  }

  function toggleService() {
    if (!installed || !hasService) {
      lastError = actionableState()
      refresh()
      return
    }
    if (running) stopService()
    else startService()
  }

  function actionableState() {
    if (!installed) {
      return "llama-server binary not found at: " + truncate(displayPath(activeBinary), 80) +
        "\nSet the \u201cbinary\u201d (or \u201crocmBinary\u201d) path per the README to your llama-server location."
    }
    if (!hasService) {
      return "No \"llama-server.service\" user unit yet.\nPick a model below and press \"Serve\"."
    }
    return ""
  }

  // Debug channel (bounded): runtime state over IPC.
  function statusJson() {
    return JSON.stringify({
      installed: installed,
      hasService: hasService,
      running: running,
      modelsDir: modelsDir,
      models: models.length,
      servedModel: servedModel,
      servedCtx: servedCtx,
      vramUsed: vramUsed,
      vramTotal: vramTotal
    })
  }

  // ── Unit generation ────────────────────────────────────────────────
  function mmprojFor(model) {
    if (model === "" || !mmprojFiles || mmprojFiles.length === 0) return ""
    var candidate = "mmproj-" + model
    for (var i = 0; i < mmprojFiles.length; i++) {
      if (mmprojFiles[i] === candidate) return mmprojFiles[i]
    }
    // Fallback: if only one mmproj exists, pair it with this model.
    if (mmprojFiles.length === 1) return mmprojFiles[0]
    // Fallback: suffix match (mmproj file ends with the model name).
    for (var j = 0; j < mmprojFiles.length; j++) {
      if (mmprojFiles[j].indexOf(model) !== -1) return mmprojFiles[j]
    }
    return ""
  }

  function buildUnitContent(model) {
    if (model === "") return ""
    var autoMmproj = ""
    var mp = mmprojFor(model)
    if (mp !== "" && extraArgs.indexOf("--mmproj") === -1) {
      autoMmproj = " --mmproj " + modelsDir + "/" + mp
    }
    var unit = "[Unit]\n" +
      "Description=llama.cpp OpenAI-compatible server (llama-server)\n" +
      "\n" +
      "[Service]\n" +
      "Type=simple\n"
    // ROCm (nightly) backend: expose the nightly libs and (optionally) the
    // gfx1031 compatibility override. Native gfx1031 wheels need no override.
    if (useRocm) {
      if (hsaOverrideGfxVersion !== "") {
        unit += "Environment=\"HSA_OVERRIDE_GFX_VERSION=" + hsaOverrideGfxVersion + "\"\n"
      }
      if (rocmLibPath !== "") {
        unit += "Environment=\"LD_LIBRARY_PATH=" + rocmLibPath + "\"\n"
      }
    }
    unit += "ExecStart=" + activeBinary + " --host 127.0.0.1 --port " + port + " -c " + ctxSize +
      (extraArgs !== "" ? " " + extraArgs : "") + autoMmproj +
      " -m " + modelsDir + "/" + model + "\n" +
      "Restart=on-failure\n" +
      "RestartSec=5\n" +
      "WorkingDirectory=" + Quickshell.env("HOME") + "\n" +
      "\n" +
      "[Install]\n" +
      "WantedBy=default.target\n"
    return unit
  }

  // Write/replace the unit (env-passed content; no quoting path surgery),
  // verify it, then daemon-reload + restart/start per flags.
  function applyUnit(model, startWhenDone) {
    if (busy || !installed) {
      if (!installed) lastError = actionableState()
      return
    }
    var unit = buildUnitContent(model)
    if (unit === "") {
      lastError = "No model chosen — pick one from the models list below."
      return
    }
    busy = true
    actionLabel = modelFileSetting === "" && model === firstModelFile && !hasService
        ? "Creating service unit…"
        : (startWhenDone ? "Switching model…" : "Updating service unit…")
    lastError = ""

    applyUnitProcess.environment = {
      "PLUGIN_UNIT": unit,
      "PLUGIN_RESTART": startWhenDone ? "1" : "0"
    }
    applyUnitProcess.running = true
    applyUnitWatchdog.restart()
  }

  // Convenience wrappers for the panel:
  // - first-time unit creation (uses selected or first-found model)
  // - switching the served model from the list
  function createUnit() {
    applyUnit(modelFileSetting !== "" ? modelFileSetting : firstModelFile, true)
  }
  function serveModel(model) {
    applyUnit(model, true)
  }

  // ── Output buffers (each capped) ──────────────────────────────────

  property string _checkBuffer: ""
  property string _statusBuffer: ""
  property string _apiBuffer: ""
  property string _gpuBuffer: ""
  property var _modelList: []
  property var _mmprojList: []
  property var mmprojFiles: []
  property bool _modelsDirMissingFlag: false
  property string _unitBuffer: ""
  property string _startBuffer: ""
  property string _stopBuffer: ""

  function bufferedAppend(buffer, line, cap) {
    var s = String(line || "")
    if (buffer.length + s.length + 1 <= cap) return buffer + s + "\n"
    return buffer
  }

  function _parseCheck() {
    var output = truncate(_checkBuffer.trim(), 256)
    _checkBuffer = ""
    var binToken = /BIN:([012])/.exec(output)
    var unitToken = /UNIT:([01])/.exec(output)
    var binState = binToken ? parseInt(binToken[1], 10) : 0
    installed = binState === 1
    hasService = unitToken ? unitToken[1] === "1" : false
    if (!installed && binState === 2) {
      lastError = "Path exists but is not executable: " + truncate(displayPath(binary), 80)
    }
    if (installed && hasService) {
      launch(statusProcess, statusWatchdog)
    } else {
      running = false
      servedModel = ""
      servedCtx = -1
      activeSince = ""
    }
  }

  function _parseStatus() {
    var raw = _statusBuffer
    _statusBuffer = ""
    var lines = raw.trim().length > 0 ? raw.trim().split("\n").slice(0, 12) : []
    var state = "", subState = "", since = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("ActiveState=") === 0) state = truncate(line.substring(12), 64)
      else if (line.indexOf("SubState=") === 0) subState = truncate(line.substring(9), 64)
      else if (line.indexOf("ActiveEnterTimestamp=") === 0) since = truncate(line.substring(21), 128)
    }
    var wasRunning = running
    running = (state === "active" && subState === "running")
    activeSince = since
    if (running) {
      launch(apiProcess, apiWatchdog)
      launch(gpuProcess, gpuWatchdog)
    } else if (wasRunning) {
      servedModel = ""
      servedCtx = -1
    }
  }

  function _onModelsLine(line) {
    var s = String(line || "").trim()
    if (s === "MISSING" || s === "\rMISSING") { _modelsDirMissingFlag = true; return }
    if (s === "") return
    var tab = s.indexOf("\t")
    if (tab <= 0) return
    var name = truncate(s.substring(tab + 1), 160)
    // mmproj files are vision projectors, not serveable models — track separately.
    if (/^mmproj[-_]/i.test(name)) {
      if (_mmprojList.indexOf(name) === -1) _mmprojList.push(name)
      return
    }
    if (_modelList.length >= maxModels) return
    _modelList.push({
      name: name,
      sizeBytes: s.substring(0, tab),
      sizeStr: humanSize(s.substring(0, tab))
    })
  }

  function _applyModelList() {
    if (_modelsDirMissingFlag) {
      // The folder genuinely doesn't exist (yet) → empty UI.
      _modelsDirMissingFlag = false
      models = []
      modelsDirMissing = true
      firstModelFile = ""
      return
    }
    modelsDirMissing = false
    var next = _modelList
    _modelList = []
    // Publish the mmproj list (reset the buffer for the next cycle).
    root.mmprojFiles = _mmprojList.slice()
    _mmprojList = []
    var served = root.servedModel
    for (var i = 0; i < next.length; i++) {
      next[i].isServed = served !== "" && next[i].name === served
    }
    if (next.length > 0) {
      models = next
      if (firstModelFile === "") firstModelFile = next[0].name
    } else if (models.length === 0) {
      models = []
    }
    // else: a clean-but-empty cycle is transient — retain the catalog.
  }

  function _parseApi() {
    var raw = truncate(_apiBuffer.trim(), 2048)
    _apiBuffer = ""
    if (raw === "" || raw.charAt(0) !== "{") { servedModel = ""; servedCtx = -1; _applyModelList(); return }
    try {
      var obj = JSON.parse(raw)
      var data = Array.isArray(obj && obj.data) ? obj.data : []
      var m = data.length > 0 ? data[0] : null
      var id = m && typeof m.id === "string" ? m.id : ""
      var base = id.split("/").pop() || id
      servedModel = truncate(base, 160)
      var ctx = m && m.meta && m.meta.n_ctx
      servedCtx = Number.isFinite(ctx) && ctx > 0 ? ctx : -1
    } catch (e) {
      servedModel = ""
      servedCtx = -1
    }
    _applyModelList()
  }

  function _parseGpu() {
    var raw = truncate(_gpuBuffer.trim(), 128)
    _gpuBuffer = ""
    if (raw === "") { gpuUsable = false; vramUsed = ""; vramTotal = ""; return }
    var parts = raw.split(",").map(function(x) { return parseInt(String(x).trim(), 10) })
    var usedMiB = isFinite(parts[0]) ? parts[0] : -1
    var totalMiB = isFinite(parts[1]) ? parts[1] : -1
    if (usedMiB < 0) { gpuUsable = false; vramUsed = ""; vramTotal = ""; return }
    gpuUsable = true
    vramUsed = (usedMiB / 1024).toFixed(1) + " G"
    vramTotal = totalMiB > 0 ? (totalMiB / 1024).toFixed(0) + " G" : ""
  }

  function _parseUnitBuffer() {
    var out = truncate(_unitBuffer.trim(), 512)
    _unitBuffer = ""
    var written = out.indexOf("WRITTEN") !== -1
    var verifyRc = /VERIFY_DONE rc=(\d+)/.exec(out)
    var rejected = out.indexOf("REJECTED") !== -1
    if (!written) {
      lastError = "Could not write the unit file. Check that ~/.config/systemd/user is writable."
    } else if (rejected || (verifyRc && verifyRc[1] !== "0")) {
      // Show verify's diagnostic text only: everything from WRITTEN/REJECTED
      // markers aside, i.e. the raw systemd-analyze message lines.
      var detail = out
        .replace(/ ?WRITTEN\n?/g, "")
        .replace(/ ?VERIFY_DONE rc=\d+\n?/g, "")
        .replace(/ ?REJECTED\n?/g, "")
        .trim()
      lastError = (rejected ? "systemd-analyze verify rejected the unit:\n"
                            : "systemd-analyze verify failed the unit:\n") +
        truncate(detail, 300)
    } else if (verifyRc) {
      lastError = ""
    } else {
      lastError = "Unit verification did not finish cleanly — is systemd available?"
    }
  }

  // ── Processes ──────────────────────────────────────────────────────
  //
  // Every command: `timeout -k 2 N` (process-group killer) wrapping
  // `bash -c "set -o pipefail; … | head -c CAP"` (OS-pipe-level output
  // cap). Output parsed only when exitCode === 0 (124/137/141 discarded).

  // User-scope provision: ensure the configured models folder exists (no sudo).
  Process {
    id: provisionProcess
    running: false
    environment: ({ "PLUGIN_DIR": root.modelsDir })
    command: ["bash", "-c", "set -o pipefail; mkdir -p \"$PLUGIN_DIR\" && echo OK | head -c 8"]
    onExited: function(exitCode) { provisionWatchdog.stop(); refresh() }
  }

  Timer {
    id: provisionWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: root.reap(root.provisionProcess, provisionWatchdog)
  }

  Process {
    id: checkProcess
    running: false
    environment: ({ "PLUGIN_BIN": root.activeBinary })
    command: ["timeout", "-k", "2", "" + root.processTimeoutSec,
              "bash", "-c",
              "set -o pipefail; b=\"$PLUGIN_BIN\"; echo \"BIN:$([ -f \"$b\" ] && { [ -x \"$b\" ] && echo 1 || echo 2; } || echo 0) UNIT:$([ -f \"$HOME/.config/systemd/user/llama-server.service\" ] && echo 1 || echo 0)\" | head -c " + root.capCheck]
    stdout: SplitParser { onRead: function(line) { root._checkBuffer = root.bufferedAppend(root._checkBuffer, line, root.capCheck) } }
    onExited: function(exitCode) {
      checkWatchdog.stop()
      if (exitCode === 0) _parseCheck()
      else { _checkBuffer = ""; installed = false; hasService = false; running = false }
    }
  }

  Process {
    id: statusProcess
    running: false
    command: ["timeout", "-k", "2", "" + root.processTimeoutSec,
              "bash", "-c", "set -o pipefail; systemctl --user show llama-server --property=ActiveState,SubState,ActiveEnterTimestamp 2>&1 | head -c " + root.capStatus]
    stdout: SplitParser { onRead: function(line) { root._statusBuffer = root.bufferedAppend(root._statusBuffer, line, root.capStatus) } }
    onExited: function(exitCode) {
      statusWatchdog.stop()
      if (exitCode === 0) _parseStatus()
      else { _statusBuffer = ""; running = false; activeSince = "" }
    }
  }

  Process {
    id: modelsProcess
    running: false
    environment: ({ "PLUGIN_DIR": root.modelsDir })
    command: ["timeout", "-k", "2", "" + root.processTimeoutSec,
              "bash", "-c",
              "set -o pipefail; d=\"$PLUGIN_DIR\"; [ -d \"$d\" ] && find -H \"$d\" -maxdepth 1 -name '*.gguf' -type f -printf '%s\\t%f\\n' 2>/dev/null | sort -k2 | head -c " + root.capModels + " || echo MISSING"]
    stdout: SplitParser { onRead: function(line) { root._onModelsLine(line) } }
    onExited: function(exitCode) {
      modelsWatchdog.stop()
      // Bad cycle (timeout/truncation): discard the partial buffer, keep
      // the previous catalog — the disk listing changes rarely and a
      // transient CPU spike during model load shouldn't blank the UI.
      if (exitCode === 0) _applyModelList()
      else _modelList = []
    }
  }

  Process {
    id: apiProcess
    running: false
    command: ["timeout", "-k", "2", "" + root.processTimeoutSec,
              "bash", "-c",
              "set -o pipefail; curl -s --connect-timeout 2 --max-time 6 http://127.0.0.1:" + root.port + "/v1/models 2>/dev/null | head -c " + root.capApi]
    stdout: SplitParser { onRead: function(line) { root._apiBuffer = root.bufferedAppend(root._apiBuffer, line, root.capApi) } }
    onExited: function(exitCode) {
      apiWatchdog.stop()
      if (exitCode === 0) _parseApi()
      else { _apiBuffer = ""; servedModel = ""; servedCtx = -1 }
    }
  }

  Process {
    id: gpuProcess
    running: false
    command: ["timeout", "-k", "2", "" + root.processTimeoutSec,
              "bash", "-c",
              "set -o pipefail; command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | head -c " + root.capGpu]
    stdout: SplitParser { onRead: function(line) { root._gpuBuffer = root.bufferedAppend(root._gpuBuffer, line, root.capGpu) } }
    onExited: function(exitCode) {
      gpuWatchdog.stop()
      if (exitCode === 0 && _gpuBuffer.trim() !== "") _parseGpu()
      else { gpuUsable = false; vramUsed = ""; vramTotal = "" }
    }
  }

  Process {
    id: startProcess
    running: false
    command: ["timeout", "-k", "2", "" + root.unitTimeoutSec,
              "bash", "-c", "set -o pipefail; systemctl --user start llama-server.service 2>&1 | head -c " + root.capAction]
    stdout: SplitParser { onRead: function(line) { root._startBuffer = root.bufferedAppend(root._startBuffer, line, root.capAction) } }
    onExited: function(exitCode) {
      startActionWatchdog.stop()
      busy = false
      actionLabel = ""
      if (exitCode !== 0 && _startBuffer.trim() !== "") lastError = _actionError(_startBuffer, "start")
      else lastError = ""
      _startBuffer = ""
      refresh()
    }
  }

  Process {
    id: stopProcess
    running: false
    command: ["timeout", "-k", "2", "" + root.unitTimeoutSec,
              "bash", "-c", "set -o pipefail; systemctl --user stop llama-server.service 2>&1 | head -c " + root.capAction]
    stdout: SplitParser { onRead: function(line) { root._stopBuffer = root.bufferedAppend(root._stopBuffer, line, root.capAction) } }
    onExited: function(exitCode) {
      stopActionWatchdog.stop()
      busy = false
      actionLabel = ""
      if (exitCode !== 0 && _stopBuffer.trim() !== "") lastError = _actionError(_stopBuffer, "stop")
      else lastError = ""
      _stopBuffer = ""
      refresh()
    }
  }

  Process {
    id: applyUnitProcess
    running: false
    environment: ({ "PLUGIN_UNIT": "", "PLUGIN_RESTART": "0" })
    command: ["timeout", "-k", "2", "" + root.unitTimeoutSec,
              "bash", "-c",
              "set -o pipefail; u=\"$HOME/.config/systemd/user/llama-server.service\"; " +
              "mkdir -p \"$HOME/.config/systemd/user\" && " +
              "printf '%s' \"$PLUGIN_UNIT\" > \"$u\" && chmod 0644 \"$u\" && echo WRITTEN && " +
              "{ v=$(systemd-analyze verify \"$u\" 2>&1); rc=$?; if [ -n \"$v\" ]; then printf '%s\\n' \"$v\" | head -c " + root.capUnit + "; fi; if [ $rc -ne 0 ]; then echo REJECTED; fi; echo \"VERIFY_DONE rc=$rc\"; " +
              "if [ $rc -eq 0 ]; then systemctl --user daemon-reload; " +
              "if [ \"$PLUGIN_RESTART\" = \"1\" ]; then systemctl --user restart llama-server.service >/dev/null 2>&1 || systemctl --user start llama-server.service >/dev/null 2>&1; fi; fi; }"]
    stdout: SplitParser { onRead: function(line) { root._unitBuffer = root.bufferedAppend(root._unitBuffer, line, root.capUnit) } }
    onExited: function(exitCode) {
      applyUnitWatchdog.stop()
      busy = false
      actionLabel = ""
      if (exitCode === 0) _parseUnitBuffer()
      else lastError = "Unit apply did not finish cleanly (exit " + exitCode + ")."
      _unitBuffer = ""
      if (lastError === "") launch(checkProcess, checkWatchdog)
    }
  }

  // ── Watchdog timers (backup killers) ──────────────────────────────

  Timer {
    id: checkWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: root.reap(root.checkProcess, checkWatchdog)
  }

  Timer {
    id: statusWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: root.reap(root.statusProcess, statusWatchdog)
  }

  Timer {
    id: modelsWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: root.reap(root.modelsProcess, modelsWatchdog)
  }

  Timer {
    id: apiWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: root.reap(root.apiProcess, apiWatchdog)
  }

  Timer {
    id: gpuWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: root.reap(root.gpuProcess, gpuWatchdog)
  }

  Timer {
    id: startActionWatchdog
    interval: 18000
    repeat: false
    onTriggered: if (root.startProcess.running) root.startProcess.running = false
  }

  Timer {
    id: stopActionWatchdog
    interval: 18000
    repeat: false
    onTriggered: if (root.stopProcess.running) root.stopProcess.running = false
  }

  Timer {
    id: applyUnitWatchdog
    interval: 30000
    repeat: false
    onTriggered: if (root.applyUnitProcess.running) root.applyUnitProcess.running = false
  }

  // ── Refresh timer ─────────────────────────────────────────────────

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Run provision first at startup, then refresh normally.
  Component.onCompleted: {
    provisionProcess.running = true
  }
}
