import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "arggon.localai"
  ipcTarget: "arggon.localai"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // Widget settings live on the BarWidget instance (injected by the shell);
  // this panel is loaded eagerly by the host's Loader, so resolve through it.
  readonly property var settings: hostWidget && hostWidget.settings ? hostWidget.settings : ({})

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color success: "#4ade80"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string statusText: {
    if (llama.busy) return llama.actionLabel
    if (!llama.installed) return "Not installed"
    if (!llama.hasService) return "No service"
    if (llama.running) return "Running"
    return "Stopped"
  }
  readonly property color statusColor: {
    if (llama.busy) return foreground
    if (!llama.installed) return urgent
    if (!llama.hasService) return urgent
    if (llama.running) return success
    return dim
  }
  readonly property string toggleHint: {
    if (!llama.installed || !llama.hasService) return ""
    return llama.running ? "Turn llama-server off" : "Turn llama-server on"
  }
  property string focusSection: "header"
  property bool cursorActive: false
  property string searchQuery: ""
  property var searchResults: []
  property bool searching: false
  property bool downloading: false
  property string downloadStatus: ""
  property var _searchModelList: []
  property string backendSelection: "0"
  function syncBackendSelection() {
    if (llama.settings && llama.settings.useRocm !== undefined && llama.settings.useRocm !== null)
      backendSelection = String(llama.settings.useRocm)
  }

  function _onSearchLine(line) {
    var s = String(line || "").trim()
    if (s === "") return
    var tab = s.indexOf("\t")
    if (tab <= 0) return
    var downloads = parseInt(s.substring(0, tab), 10)
    var id = s.substring(tab + 1)
    if (!isFinite(downloads)) downloads = 0
    _searchModelList.push({ id: id, downloads: downloads })
  }

  function _applySearchResults() {
    var next = _searchModelList
    _searchModelList = []
    searchResults = next
    if (next.length === 0) downloadStatus = "No GGUF models found."
    else downloadStatus = ""
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function openFolder() {
    // User-scope action (no privileges): open the models folder in the file manager.
    const dir = llama.modelsDir
    if (dir === "") return
    openDirProcess.environment = { "PLUGIN_DIR": dir }
    openDirProcess.running = true   // Quickshell Process: set running, no .start()
    openDirWatchdog.restart()
  }

  function browseHuggingFace() {
    // Outbound link only — the plugin never downloads or executes code.
    hfProcess.running = true
    hfWatchdog.restart()
  }

  Timer {
    id: openDirWatchdog
    interval: 8000
    repeat: false
    onTriggered: if (openDirProcess.running) openDirProcess.running = false
  }

  Timer {
    id: hfWatchdog
    interval: 8000
    repeat: false
    onTriggered: if (hfProcess.running) hfProcess.running = false
  }

  Process {
    id: openDirProcess
    running: false
    // Env-passed path: argv is not shell-parsed, so $PLUGIN_DIR must be
    // expanded by an explicit bash layer — never interpolated into text.
    command: ["timeout", "-k", "2", "8", "bash", "-c", "exec xdg-open \"$PLUGIN_DIR\""]
    environment: ({"PLUGIN_DIR": ""})
  }

  Process {
    id: hfProcess
    running: false
    command: ["timeout", "-k", "2", "8", "bash", "-c", "exec xdg-open \"https://huggingface.co/models?sort=trending&library=gguf\""]
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    syncBackendSelection()
    llama.refresh()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  Service {
    id: llama
    settings: root.settings
  }
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function startService(): string { llama.startService(); return "ok" }
    function stopService(): string { llama.stopService(); return "ok" }
    function refresh(): string { llama.refresh(); return "ok" }
    function createUnit(): string { llama.createUnit(); return "ok" }
    function serve(model: string): string { llama.serveModel(String(model || "")); return "ok" }
    function status(): string { return llama.statusJson() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) root.cursorActive = true
      }
      onActivateRequested: {
        if (root.cursorActive && root.focusSection === "header") llama.toggleService()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") llama.startService()
        else if (t === "x" || t === "X") llama.stopService()
        else if (t === "r" || t === "R") llama.refresh()
      }
    }

    Flickable {
      id: panelFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: panelFlick.width
        spacing: Style.space(12)

        // ── Hero ────────────────────────────────────────────────────
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

          Text {
            id: heroIcon
            // Nerd Font chip glyph — literal PUA character
            text: "󰍛"
            color: root.statusColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            textFormat: Text.PlainText
            opacity: llama.installed ? 1.0 : 0.5
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          RowLayout {
            id: heroActions
            spacing: Style.space(8)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            ToggleSwitch {
              id: powerSwitch
              visible: llama.installed && llama.hasService
              checked: llama.running
              busy: llama.busy
              hasCursor: root.cursorActive && root.focusSection === "header"
              foreground: root.foreground
              Layout.alignment: Qt.AlignVCenter
              onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "header" } }
              onToggled: llama.toggleService()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.toggleHint
                fontFamily: root.fontFamily
              }
            }

            Button {
              visible: llama.installed && !llama.hasService
              text: "Serve first model"
              bordered: true
              foreground: root.foreground
              enabled: !llama.busy
              hasCursor: root.cursorActive && root.focusSection === "header"
              Layout.alignment: Qt.AlignVCenter
              onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "header" } }
              onClicked: llama.createUnit()
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: heroActions.width > 0 ? heroActions.width + Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "ArggonLocalAI"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.statusText.toUpperCase()
              color: root.statusColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }
          }
        }

        // ── Error / state hint ─────────────────────────────────────
        Text {
          visible: llama.lastError !== "" || llama.actionableState() !== ""
          width: parent.width
          text: llama.sanitize(llama.lastError !== "" ? llama.lastError : llama.actionableState())
          color: llama.lastError !== "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
        }

        // ── Not installed (unit missing) ────────────────────────────
        CursorSurface {
          visible: llama.installed && !llama.hasService
          width: parent.width
          implicitHeight: noServiceText.implicitHeight + Style.spacing.rowPaddingX
          foreground: root.foreground

          Text {
            id: noServiceText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(12)
            text: "No \"llama-server.service\" user unit yet.\nPick a model below, then press \u201cServe\u201d to create the service and run it.\n\nService unit lives in ~/.config/systemd/user/ (user-only, no sudo)."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
          }
        }

        // ── Service details ─────────────────────────────────────────
        Column {
          visible: llama.installed && llama.hasService
          width: parent.width
          spacing: Style.spacing.labelGap

          GridLayout {
            width: parent.width
            columns: 2
            columnSpacing: Style.space(20)
            rowSpacing: Style.spacing.labelGap

            InfoLabel { text: "Status" }
            InfoValue {
              text: llama.running ? "Running" : "Stopped"
              color: root.statusColor
            }

            InfoLabel { visible: llama.running && llama.vramTotal !== ""; text: "VRAM" }
            InfoValue {
              visible: llama.running && llama.vramTotal !== ""
              text: llama.vramUsed !== "" ? llama.vramUsed + " / " + llama.vramTotal : "\u2014"
            }

            InfoLabel {
              visible: llama.running && llama.servedModel !== ""
              text: "Model"
            }
            InfoValue {
              visible: llama.running && llama.servedModel !== ""
              text: llama.sanitize(llama.servedModel)
            }

            InfoLabel {
              visible: llama.running && llama.servedCtx > 0
              text: "Context"
            }
            InfoValue {
              visible: llama.running && llama.servedCtx > 0
              text: llama.servedCtx.toLocaleString("en-GB")
            }

            InfoLabel {
              visible: llama.running && llama.activeSince !== ""
              text: "Since"
            }
            InfoValue {
              visible: llama.running && llama.activeSince !== ""
              text: llama.activeSince ? llama.sanitize(llama.activeSince.replace(/^\w+\s+/, "")) : ""
            }

            InfoLabel { text: "Port" }
            InfoValue { text: String(llama.port) }
          }
        }

        // ── Backend selector (Vulkan/CPU vs ROCm nightly) ────────────
        PanelSeparator {
          visible: llama.installed
          foreground: root.foreground
        }

        Column {
          visible: llama.installed
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "BACKEND"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Dropdown {
            id: backendDropdown
            width: parent.width
            showLabel: false
            options: [
              { value: "0", label: "Vulkan / CPU" },
              { value: "1", label: "ROCm (nightly)" }
            ]
            value: root.backendSelection
            foreground: root.foreground
            fontFamily: root.fontFamily
            onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "backend" } }
            onChanged: function(v) {
              root.backendSelection = String(v)
              backendSetProcess.environment = { "PLUGIN_VAL": String(v) }
              backendSetProcess.running = true
              backendSetWatchdog.restart()
            }
          }

          Text {
            visible: backendSetProcess.running
            text: "Applying backend\u2026"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }
          Text {
            visible: !backendSetProcess.running && llama.installed && llama.hasService
            text: "Backend applies on next \u201cServe\u201d."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }
        }

        // ── Search models online ─────────────────────────────────────
        PanelSeparator {
          visible: llama.installed
          foreground: root.foreground
        }

        Column {
          visible: llama.installed
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "SEARCH ONLINE (HuggingFace GGUF)"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: searchField
              Layout.fillWidth: true
              placeholderText: "model name (e.g. gemma 4)"
              text: root.searchQuery
              onTextChanged: root.searchQuery = text
              onAccepted: {
                if (root.searchQuery.trim() !== "" && !root.searching) {
                  root.searchResults = []
                  root._searchModelList = []
                  root.searching = true
                  searchProcess.environment = { "PLUGIN_QUERY": root.searchQuery.trim() }
                  searchProcess.running = true
                  searchWatchdog.restart()
                }
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Button {
              text: root.searching ? "..." : "Search"
              bordered: true
              foreground: root.foreground
              enabled: !root.searching && root.searchQuery.trim() !== ""
              onClicked: searchField.accepted()
            }
          }

          Text {
            visible: root.searching
            text: "Searching HuggingFace..."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }

          Text {
            visible: root.downloadStatus !== ""
            text: root.downloadStatus
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.searchResults.length > 0

            Repeater {
              model: root.searchResults

              CursorSurface {
                required property var modelData
                width: parent.width
                foreground: root.foreground
                implicitHeight: row.implicitHeight + Style.spacing.rowPaddingX

                RowLayout {
                  id: row
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    Text {
                      Layout.fillWidth: true
                      text: llama.sanitize(modelData.id || "")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }
                    Text {
                      Layout.fillWidth: true
                      text: (modelData.downloads || 0).toLocaleString("en-GB") + " downloads"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                    }
                  }

                  Button {
                    text: root.downloading ? "..." : "Download"
                    bordered: true
                    foreground: root.foreground
                    enabled: !root.downloading
                    onClicked: {
                      root.downloading = true
                      root.downloadStatus = "Downloading " + modelData.id + "..."
                      downloadProcess.environment = { "PLUGIN_REPO": String(modelData.id || ""), "PLUGIN_DIR": llama.modelsDir }
                      downloadProcess.running = true
                      downloadWatchdog.restart()
                    }
                  }
                }
              }
            }
          }
        }

        // ── Models on disk ──────────────────────────────────────────
        PanelSeparator {
          visible: llama.models.length > 0
          foreground: root.foreground
        }

        Column {
          visible: llama.models.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "MODELS · " + llama.displayPath(llama.modelsDir)
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: llama.models

              CursorSurface {
                required property var modelData
                width: parent.width
                foreground: root.foreground
                implicitHeight: modelRow.implicitHeight + Style.spacing.rowPaddingX

                RowLayout {
                  id: modelRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Text {
                    text: modelData.isServed === true ? "\u25cf" : "\u25cb"
                    color: modelData.isServed === true ? root.success : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    textFormat: Text.PlainText
                    Layout.alignment: Qt.AlignVCenter
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    Text {
                      Layout.fillWidth: true
                      text: llama.sanitize(modelData.name || "Unknown")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }

                    Text {
                      Layout.fillWidth: true
                      text: llama.sanitize(modelData.sizeStr || "")
                      visible: text !== ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }
                  }

                  Button {
                    visible: modelData.isServed !== true
                    text: "Serve"
                    bordered: true
                    foreground: root.foreground
                    enabled: !llama.busy
                    hasCursor: root.cursorActive && root.focusSection === "models"
                    Layout.alignment: Qt.AlignVCenter
                    onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "models" } }
                    onClicked: llama.serveModel(String(modelData.name || ""))
                  }
                }
              }
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: "Open models folder"
              bordered: true
              foreground: root.foreground
              enabled: !llama.busy
              hasCursor: root.cursorActive && root.focusSection === "models"
              Layout.fillWidth: true
              onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "models" } }
              onClicked: openFolder()
            }

            Button {
              text: "Get models on HuggingFace"
              bordered: true
              foreground: root.foreground
              enabled: !llama.busy
              hasCursor: root.cursorActive && root.focusSection === "models"
              Layout.fillWidth: true
              onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "models" } }
              onClicked: browseHuggingFace()
            }
          }
        }

        // ── No models / empty state ────────────────────────────────
        PanelSeparator {
          visible: llama.models.length === 0 && llama.actionableState() === ""
          foreground: root.foreground
        }

        Text {
          visible: llama.models.length === 0 && llama.actionableState() === ""
          width: parent.width
          text: llama.modelsDirMissing
            ? llama.sanitize(llama.displayPath(llama.modelsDir)) + " doesn't exist yet — it will be created on next start.\nDrop a .gguf there, or grab one from HuggingFace, then refresh."
            : "No .gguf models in " + llama.sanitize(llama.displayPath(llama.modelsDir)) + " yet.\nDrop a .gguf there, or grab one from HuggingFace, then refresh."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // ── Inline components matching Omarchy panel style ──────────────────

  component InfoLabel: Text {
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
  }

  component InfoValue: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
  }
  Process {
    id: backendSetProcess
    running: false
    environment: ({ "PLUGIN_VAL": "0" })
    command: ["timeout", "-k", "2", "8", "bash", "-c",
              "set -o pipefail; omarchy bar set arggon.localai useRocm \"$PLUGIN_VAL\" 2>&1 | head -c 256"]
    onExited: function(exitCode) {
      backendSetWatchdog.stop()
      llama.refresh()
      syncBackendSelection()
    }
  }

  Timer {
    id: backendSetWatchdog
    interval: 8000
    repeat: false
    onTriggered: if (backendSetProcess.running) backendSetProcess.running = false
  }


  Process {
    id: searchProcess
    running: false
    environment: ({ "PLUGIN_QUERY": "" })
    command: ["timeout", "-k", "2", "30", "bash", "/home/arggon/.config/omarchy/plugins/arggon.localai/search-models.sh"]
    stdout: SplitParser { onRead: function(line) { root._onSearchLine(line) } }
    onExited: function(exitCode) {
      searchWatchdog.stop()
      root.searching = false
      if (exitCode === 0) root._applySearchResults()
      else { root._searchModelList = []; root.searchResults = []; root.downloadStatus = "Search failed." }
    }
  }

  Timer {
    id: searchWatchdog
    interval: 30000
    repeat: false
    onTriggered: if (searchProcess.running) searchProcess.running = false
  }

  Process {
    id: downloadProcess
    running: false
    environment: ({ "PLUGIN_REPO": "", "PLUGIN_DIR": "" })
    command: ["timeout", "-k", "5", "600", "bash", "/home/arggon/.config/omarchy/plugins/arggon.localai/download-model.sh"]
    stdout: SplitParser { onRead: function(line) { root.downloadStatus = root.downloadStatus + line + " " } }
    onExited: function(exitCode) {
      downloadWatchdog.stop()
      root.downloading = false
      if (exitCode === 0) { root.downloadStatus = "Download finished."; llama.refresh() }
      else root.downloadStatus = "Download failed (exit " + exitCode + ")."
    }
  }

  Timer {
    id: downloadWatchdog
    interval: 600000
    repeat: false
    onTriggered: if (downloadProcess.running) downloadProcess.running = false
  }

}
