import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "arggon.localai"

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Service {
    id: llama
    settings: root.settings
  }

  readonly property color barIconColor: {
    // Spec: green = serving, red = offline (unit present but stopped),
    // dim grey = binary or unit missing. Colors defined in Service.qml.
    if (!llama.installed || !llama.hasService)
      return llama.unsetDim
    if (llama.running)
      return llama.runGreen
    return llama.offRed
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: {
      if (!llama.installed) return "llama-server not found (see README)"
      if (!llama.hasService) return "No service yet — pick a model in the panel"
      var t = llama.running ? "ArggonLocalAI · Serving" : "ArggonLocalAI · Offline"
      if (llama.running && llama.vramUsed !== "") t += " · VRAM " + llama.vramUsed
      return t
    }
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          // Nerd Font chip glyph (nf-md-chip)
          text: "󰍛"
          color: root.barIconColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          textFormat: Text.PlainText

          Behavior on color { ColorAnimation { duration: 240 } }
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) llama.toggleService()
      else if (buttonCode === Qt.MiddleButton) llama.refresh()
    }
  }
}
