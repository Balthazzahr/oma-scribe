import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "balthazzahr.oma-scribe"

  property var stateObj: ({
    is_recording: false,
    is_processing: false,
    mode: "meeting",
    title: "",
    start_time: 0,
    current_audio_file: "",
    last_processed_file: "",
    last_notes_file: "",
    status_message: "Ready"
  })

  property var settingsObj: ({
    provider: "gemini",
    gemini_api_key: "",
    groq_api_key: "",
    openai_api_key: "",
    model: "gemini-3.7-flash",
    groq_model: "llama-3.3-70b-versatile",
    openai_model: "gpt-4o-mini",
    local_model: "base",
    storage_path: "",
    auto_transcribe_on_stop: true,
    default_mode: "meeting"
  })

  property string selectedProvider: "gemini"
  property string selectedModel: "gemini-3.7-flash"
  property string selectedGroqModel: "llama-3.3-70b-versatile"
  property string selectedOpenAIModel: "gpt-4o-mini"
  property string selectedLocalModel: "base"

  property var localWhisperStatus: ({
    installed: false,
    engine: null,
    cached_models: [],
    install_command: "sudo pacman -S python-openai-whisper"
  })

  function checkWhisper() {
    checkWhisperProc.command = ["python3", enginePath, "check-local-whisper"]
    checkWhisperProc.running = true
  }

  function pickDirectory() {
    pickDirProc.command = ["python3", enginePath, "pick-directory"]
    pickDirProc.running = true
  }

  function copyText(val) {
    copyProc.command = ["wl-copy", val]
    copyProc.running = true
  }

  property var historyList: []
  property int activeTabIndex: 0 // 0: record, 1: notes, 2: settings
  property string historyFilter: "all" // "all" | "meetings" | "memos"
  property string selectedMode: "meeting"
  property int elapsedSeconds: 0
  property bool showApiKey: false
  property string saveFeedbackText: ""

  // Pre-meeting Form Properties
  property string meetingTitleText: ""
  property string meetingTopicsText: ""
  property string meetingNotesText: ""

  // Voice memo fields
  property string memoTitleText: ""
  property string memoTopicsText: ""
  property string memoNotesText: ""

  // Post-recording Name & Speakers Dialog State
  property bool showPostRecordPrompt: false
  property string pendingAudioFile: ""
  property string pendingMode: "meeting"
  property string pendingTitle: ""
  property string pendingSpeakers: ""

  // Dynamic Attendees List (Default: 3 attendees)
  ListModel {
    id: attendeesModel
    ListElement { name: ""; sex: "" }
    ListElement { name: ""; sex: "" }
    ListElement { name: ""; sex: "" }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // --- ENGINE PROCESSES ---
  readonly property string enginePath: Qt.resolvedUrl("backend/audio_notes_engine.py").toString().replace("file://", "")

  function updateStatus() {
    statusProc.command = ["python3", enginePath, "status"]
    statusProc.running = true
  }

  function loadSettings() {
    settingsProc.command = ["python3", enginePath, "get-settings"]
    settingsProc.running = true
  }

  function loadHistory() {
    historyProc.command = ["python3", enginePath, "list"]
    historyProc.running = true
  }

  function startRecord() {
    root.showPostRecordPrompt = false
    var mode = root.selectedMode
    var meta = {}

    if (mode === "meeting") {
      var attendees = []
      for (var i = 0; i < attendeesModel.count; ++i) {
        var item = attendeesModel.get(i)
        if (item.name && item.name.trim()) {
          attendees.push({ name: item.name.trim(), sex: (item.sex || "").trim() })
        }
      }

      meta = {
        title: root.meetingTitleText.trim(),
        topics: root.meetingTopicsText.trim(),
        attendees: attendees,
        notes: root.meetingNotesText.trim()
      }
    } else {
      meta = {
        title: root.memoTitleText.trim(),
        topics: root.memoTopicsText.trim(),
        notes: root.memoNotesText.trim()
      }
    }

    var metaJson = JSON.stringify(meta)
    actionProc.command = ["python3", enginePath, "start", mode, metaJson]
    actionProc.running = true
  }

  function stopRecord() {
    var wasTitleSet = (root.selectedMode === "meeting" ? !!root.meetingTitleText.trim() : !!root.memoTitleText.trim())
    var currentFile = root.stateObj.current_audio_file
    var currentMode = root.stateObj.mode || root.selectedMode

    actionProc.command = ["python3", enginePath, "stop"]
    actionProc.running = true

    if (!wasTitleSet && currentFile) {
      root.pendingAudioFile = currentFile
      root.pendingMode = currentMode
      root.pendingTitle = ""
      root.pendingSpeakers = ""
      root.showPostRecordPrompt = true
      popupCard.open = true
    }
  }

  function triggerTranscribe(audioFile, mode, title, speakers) {
    var t = (title || "").trim()
    var spk = (speakers || "").trim()
    actionProc.command = ["python3", enginePath, "transcribe", audioFile, mode || "meeting", t, spk]
    actionProc.running = true
    root.showPostRecordPrompt = false
    root.activeTabIndex = 1
  }

  function deleteItem(audioFile) {
    if (!audioFile) return
    actionProc.command = ["python3", enginePath, "delete", audioFile]
    actionProc.running = true
  }

  function renameNote(targetPath, newTitle) {
    if (!targetPath || !newTitle || !newTitle.trim()) return
    actionProc.command = ["python3", enginePath, "rename", targetPath, newTitle.trim()]
    actionProc.running = true
  }

  function openFolder() {
    execProc.command = ["python3", enginePath, "open-storage-folder"]
    execProc.running = true
  }

  function openInEditor(filePath) {
    if (!filePath) return
    editorProc.command = ["python3", enginePath, "open-editor", filePath]
    editorProc.running = true
  }

  function getFilteredHistory() {
    if (!root.historyList || !Array.isArray(root.historyList)) return []
    if (root.historyFilter === "meetings") {
      return root.historyList.filter(function(item) { return item.mode === "meeting" })
    }
    if (root.historyFilter === "memos") {
      return root.historyList.filter(function(item) { return item.mode === "mic" })
    }
    return root.historyList
  }

  function getCurrentApiKey() {
    if (root.selectedProvider === "groq") return root.settingsObj.groq_api_key || ""
    if (root.selectedProvider === "openai") return root.settingsObj.openai_api_key || ""
    return root.settingsObj.gemini_api_key || ""
  }

  function setCurrentApiKey(val) {
    if (root.selectedProvider === "groq") root.settingsObj.groq_api_key = val
    else if (root.selectedProvider === "openai") root.settingsObj.openai_api_key = val
    else root.settingsObj.gemini_api_key = val
  }

  // --- PROCESS DEFINITIONS ---
  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          root.stateObj = parsed
          if (parsed.is_recording && parsed.start_time > 0) {
            root.elapsedSeconds = Math.max(0, Math.floor((Date.now() / 1000) - parsed.start_time))
          } else {
            root.elapsedSeconds = 0
          }
        } catch(e) {}
      }
    }
  }

  Process {
    id: settingsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          root.settingsObj = parsed
          if (parsed.provider) root.selectedProvider = parsed.provider
          if (parsed.model) root.selectedModel = parsed.model
          if (parsed.groq_model) root.selectedGroqModel = parsed.groq_model
          if (parsed.openai_model) root.selectedOpenAIModel = parsed.openai_model
          if (parsed.local_model) root.selectedLocalModel = parsed.local_model
          if (parsed.default_mode) root.selectedMode = parsed.default_mode
          if (parsed.storage_path) {
            root.settingsObj.storage_path = parsed.storage_path
            if (typeof storagePathInput !== "undefined" && storagePathInput) {
              storagePathInput.text = parsed.storage_path
            }
          }
          apiKeyInput.text = root.getCurrentApiKey()
        } catch(e) {}
      }
    }
  }

  Process {
    id: historyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          root.historyList = JSON.parse(raw)
        } catch(e) {}
      }
    }
  }

  Process {
    id: actionProc
    onExited: {
      root.updateStatus()
      root.loadHistory()
    }
  }

  Process { id: execProc }
  Process { id: editorProc }
  Process { id: copyProc }

  Process {
    id: pickDirProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var res = JSON.parse(raw)
          if (res.status === "ok" && res.path) {
            root.settingsObj.storage_path = res.path
            if (typeof storagePathInput !== "undefined" && storagePathInput) {
              storagePathInput.text = res.path
            }
            var settingsJson = JSON.stringify(root.settingsObj)
            actionProc.command = ["python3", root.enginePath, "save-settings", settingsJson]
            actionProc.running = true
            root.saveFeedbackText = "✓ Storage folder updated!"
            feedbackTimer.restart()
            root.loadHistory()
          }
        } catch(e) {}
      }
    }
  }

  Process {
    id: checkWhisperProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          root.localWhisperStatus = JSON.parse(raw)
        } catch(e) {}
      }
    }
  }

  Process {
    id: pasteProc
    command: ["wl-paste", "-n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw) {
          root.setCurrentApiKey(raw)
          apiKeyInput.text = raw
        }
      }
    }
  }

  // --- TIMERS ---
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: {
      root.updateStatus()
      if (root.stateObj.is_recording) {
        root.elapsedSeconds += 1
      }
      if (popupCard.open && root.activeTabIndex === 1) {
        root.loadHistory()
      }
    }
  }

  Timer {
    id: feedbackTimer
    interval: 3000
    running: false
    repeat: false
    onTriggered: root.saveFeedbackText = ""
  }

  Component.onCompleted: {
    root.updateStatus()
    root.loadSettings()
    root.loadHistory()
    root.checkWhisper()
  }

  function formatDuration(sec) {
    var m = Math.floor(sec / 60)
    var s = sec % 60
    var h = Math.floor(m / 60)
    m = m % 60
    var pad = function(n) { return (n < 10 ? "0" : "") + n }
    if (h > 0) return pad(h) + ":" + pad(m) + ":" + pad(s)
    return pad(m) + ":" + pad(s)
  }

  function getBarText() {
    if (root.stateObj.is_recording) {
      return root.formatDuration(root.elapsedSeconds) + (root.stateObj.mode === "meeting" ? " (Meeting)" : " (Memo)")
    }
    if (root.stateObj.is_processing) {
      return "󰑮 Transcribing..."
    }
    return "\ued03"
  }

  // --- BAR WIDGET BUTTON (ICON: \ued03) ---
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: (root.stateObj.is_recording ? "● " : "") + root.getBarText()
    labelVisible: false
    horizontalMargin: 8
    verticalPadding: 6

    RowLayout {
      anchors.centerIn: parent
      spacing: 6

      // Pulsing Red Recording Dot
      Rectangle {
        id: recDot
        visible: root.stateObj.is_recording
        width: 8
        height: 8
        radius: 4
        color: Color.urgent

        SequentialAnimation on opacity {
          running: root.stateObj.is_recording
          loops: Animation.Infinite
          NumberAnimation { from: 1.0; to: 0.25; duration: 600; easing.type: Easing.InOutQuad }
          NumberAnimation { from: 0.25; to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
        }

        SequentialAnimation on scale {
          running: root.stateObj.is_recording
          loops: Animation.Infinite
          NumberAnimation { from: 1.0; to: 1.25; duration: 600; easing.type: Easing.InOutQuad }
          NumberAnimation { from: 1.25; to: 1.0; duration: 600; easing.type: Easing.InOutQuad }
        }
      }

      Text {
        text: root.getBarText()
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        color: Color.foreground
        renderType: Text.NativeRendering
      }
    }

    onPressed: function(btn) {
      if (btn === Qt.RightButton) {
        if (root.stateObj.is_recording) {
          root.stopRecord()
        } else {
          root.startRecord()
        }
      } else {
        popupCard.open = !popupCard.open
        if (popupCard.open) {
          root.updateStatus()
          root.loadHistory()
          root.loadSettings()
        }
      }
    }
  }

  // --- POPUP PANEL ---
  KeyboardPanel {
    id: popupCard
    anchorItem: button
    bar: root.bar
    owner: root
    open: false
    contentWidth: popupCard.fittedContentWidth(700)
    contentHeight: popupCard.fittedContentHeight(750)

    ColumnLayout {
      id: layout
      anchors.fill: parent
      spacing: 8

      // --- HEADER ---
      RowLayout {
        Layout.fillWidth: true
        spacing: 8

        Text {
          text: "\ued03 Oma Scribe"
          font.family: "JetBrainsMono Nerd Font"
          font.pixelSize: Style.font.title
          font.bold: true
          color: Color.foreground
        }

        Item { Layout.fillWidth: true }

        // Close Button
        Rectangle {
          width: 24
          height: 24
          radius: 4
          color: closeMouse.containsMouse ? Util.alpha(Color.urgent, 0.25) : "transparent"

          Text {
            anchors.centerIn: parent
            text: "󰅖"
            font.family: "JetBrainsMono Nerd Font"
            font.pixelSize: Style.font.body
            color: Color.foreground
          }

          MouseArea {
            id: closeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: popupCard.open = false
          }
        }
      }

      // --- TOP TAB SWITCHER (3 TABS) ---
      RowLayout {
        Layout.fillWidth: true
        spacing: 4

        Repeater {
          model: [
            { idx: 0, label: "󰑊 Record" },
            { idx: 1, label: "󰈙 Notes" },
            { idx: 2, label: "󰒓 Settings" }
          ]

          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            radius: 4
            color: root.activeTabIndex === modelData.idx ? Color.accent : (tabMouse.containsMouse ? Util.alpha(Color.foreground, 0.1) : "transparent")

            Text {
              anchors.centerIn: parent
              text: modelData.label
              font.family: "JetBrainsMono Nerd Font"
              font.pixelSize: Style.font.small
              font.bold: root.activeTabIndex === modelData.idx
              color: root.activeTabIndex === modelData.idx ? Color.pick("background", "#1e1e2e") : Color.foreground
            }

            MouseArea {
              id: tabMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.activeTabIndex = modelData.idx
                if (modelData.idx === 1) root.loadHistory()
                if (modelData.idx === 2) {
                  root.loadSettings()
                  apiKeyInput.text = root.getCurrentApiKey()
                }
              }
            }
          }
        }
      }

      Rectangle {
        Layout.fillWidth: true
        height: 1
        color: Util.alpha(Color.foreground, 0.15)
      }

      // ==========================================
      // STACKED TABS CONTAINER
      // ==========================================
      StackLayout {
        id: tabStack
        Layout.fillWidth: true
        Layout.fillHeight: true
        currentIndex: root.activeTabIndex

        // ------------------------------------------
        // TAB 0: RECORD VIEW
        // ------------------------------------------
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 8

          // ========================================
          // POST-RECORDING NAME & SPEAKERS PROMPT (IF UNTITLED)
          // ========================================
          Rectangle {
            visible: root.showPostRecordPrompt
            Layout.fillWidth: true
            Layout.preferredHeight: promptCol.implicitHeight + 20
            radius: 8
            border.width: 1
            border.color: Color.accent
            color: Util.alpha(Color.accent, 0.1)

            ColumnLayout {
              id: promptCol
              anchors.fill: parent
              anchors.margins: 10
              spacing: 8

              RowLayout {
                spacing: 6
                Text {
                  text: root.pendingMode === "meeting" ? "\uf4fd" : "󰍬"
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: Style.font.body
                  color: Color.accent
                }
                Text {
                  text: root.pendingMode === "meeting" ? "Would you like to name this meeting?" : "Would you like to name this audio note?"
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: Style.font.body
                  color: Color.foreground
                }
              }

              // Title Input
              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                radius: 4
                color: Util.alpha(Color.foreground, 0.08)
                border.width: 1
                border.color: postTitleInput.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.15)

                TextInput {
                  id: postTitleInput
                  anchors.fill: parent
                  anchors.margins: 8
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: Style.font.small
                  color: Color.foreground
                  text: root.pendingTitle
                  onTextChanged: root.pendingTitle = text

                  Text {
                    text: root.pendingMode === "meeting" ? "Meeting Title" : "Memo Title"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: Style.font.small
                    color: Color.muted
                    visible: !postTitleInput.text && !postTitleInput.activeFocus
                  }
                }
              }

              // Speakers Input (for Meetings)
              ColumnLayout {
                visible: root.pendingMode === "meeting"
                Layout.fillWidth: true
                spacing: 3

                Text {
                  text: "Please name the speakers in this meeting (optional):"
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: Style.font.small
                  color: Color.foreground
                }

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 34
                  radius: 4
                  color: Util.alpha(Color.foreground, 0.08)
                  border.width: 1
                  border.color: speakersInput.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.15)

                  TextInput {
                    id: speakersInput
                    anchors.fill: parent
                    anchors.margins: 8
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: Style.font.small
                    color: Color.foreground
                    text: root.pendingSpeakers
                    onTextChanged: root.pendingSpeakers = text

                    Text {
                      text: "e.g. Alice (me), Bob, Sarah, Alex"
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: Style.font.small
                      color: Color.muted
                      visible: !speakersInput.text && !speakersInput.activeFocus
                    }
                  }
                }
              }

              // Modal Action Buttons
              RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 34
                  radius: 6
                  color: Color.accent

                  RowLayout {
                    anchors.centerIn: parent
                    spacing: 4
                    Text {
                      text: "\ued03"
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: 11
                      color: Color.pick("background", "#1e1e2e")
                    }
                    Text {
                      text: "Transcribe & Generate Notes"
                      font.family: "JetBrainsMono Nerd Font"
                      font.bold: true
                      font.pixelSize: 11
                      color: Color.pick("background", "#1e1e2e")
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.triggerTranscribe(root.pendingAudioFile, root.pendingMode, root.pendingTitle, root.pendingSpeakers)
                    }
                  }
                }

                Rectangle {
                  Layout.preferredWidth: 100
                  Layout.preferredHeight: 34
                  radius: 6
                  color: Util.alpha(Color.foreground, 0.1)

                  Text {
                    anchors.centerIn: parent
                    text: "Skip"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 11
                    color: Color.foreground
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.showPostRecordPrompt = false
                    }
                  }
                }
              }
            }
          }

          // Top Mode Selector
          RowLayout {
            Layout.fillWidth: true
            spacing: 8

            // Meeting Mode Button
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 36
              radius: 6
              border.width: 1
              border.color: root.selectedMode === "meeting" ? Color.accent : Util.alpha(Color.foreground, 0.15)
              color: root.selectedMode === "meeting" ? Util.alpha(Color.accent, 0.15) : (m1Mouse.containsMouse ? Util.alpha(Color.foreground, 0.05) : "transparent")

              RowLayout {
                anchors.centerIn: parent
                spacing: 6
                Text {
                  text: "\uf4fd"
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: Style.font.body
                  color: root.selectedMode === "meeting" ? Color.accent : Color.foreground
                }
                Text {
                  text: "Meeting"
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: Style.font.body
                  color: root.selectedMode === "meeting" ? Color.accent : Color.foreground
                }
              }

              MouseArea {
                id: m1Mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                enabled: !root.stateObj.is_recording
                onClicked: root.selectedMode = "meeting"
              }
            }

            // Voice Memo Button
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 36
              radius: 6
              border.width: 1
              border.color: root.selectedMode === "mic" ? Color.accent : Util.alpha(Color.foreground, 0.15)
              color: root.selectedMode === "mic" ? Util.alpha(Color.accent, 0.15) : (m2Mouse.containsMouse ? Util.alpha(Color.foreground, 0.05) : "transparent")

              RowLayout {
                anchors.centerIn: parent
                spacing: 6
                Text {
                  text: "󰍬"
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: Style.font.body
                  color: root.selectedMode === "mic" ? Color.accent : Color.foreground
                }
                Text {
                  text: "Voice Memo"
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: Style.font.body
                  color: root.selectedMode === "mic" ? Color.accent : Color.foreground
                }
              }

              MouseArea {
                id: m2Mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                enabled: !root.stateObj.is_recording
                onClicked: root.selectedMode = "mic"
              }
            }
          }

          // ==========================================
          // SCROLLABLE PRE-MEETING / PRE-RECORD FORM (FULL WIDTH)
          // ==========================================
          ScrollView {
            id: formScroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth

            ColumnLayout {
              width: formScroll.availableWidth
              Layout.fillWidth: true
              spacing: 10

              // --- MEETING MODE FORM ---
              ColumnLayout {
                visible: root.selectedMode === "meeting"
                Layout.fillWidth: true
                width: parent.width
                spacing: 10

                // Meeting Title
                ColumnLayout {
                  Layout.fillWidth: true
                  width: parent.width
                  spacing: 3
                  Text {
                    text: "Meeting Title:"
                    font.family: "JetBrainsMono Nerd Font"
                    font.bold: true
                    font.pixelSize: Style.font.small
                    color: Color.foreground
                  }
                  Rectangle {
                    Layout.fillWidth: true
                    width: parent.width
                    Layout.preferredHeight: 34
                    radius: 4
                    color: Util.alpha(Color.foreground, 0.08)
                    border.width: 1
                    border.color: mTitleIn.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.18)
                    TextInput {
                      id: mTitleIn
                      anchors.fill: parent
                      anchors.margins: 8
                      activeFocusOnTab: true
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: Style.font.small
                      color: Color.foreground
                      enabled: !root.stateObj.is_recording
                      text: root.meetingTitleText
                      onTextChanged: root.meetingTitleText = text
                      Keys.onTabPressed: mTopicsIn.forceActiveFocus()
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Meeting Title"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: Style.font.small
                        color: Color.muted
                        visible: !mTitleIn.text && !mTitleIn.activeFocus
                      }
                    }
                  }
                }

                // Meeting Topics
                ColumnLayout {
                  Layout.fillWidth: true
                  width: parent.width
                  spacing: 3
                  Text {
                    text: "Meeting Topics:"
                    font.family: "JetBrainsMono Nerd Font"
                    font.bold: true
                    font.pixelSize: Style.font.small
                    color: Color.foreground
                  }
                  Rectangle {
                    Layout.fillWidth: true
                    width: parent.width
                    Layout.preferredHeight: 34
                    radius: 4
                    color: Util.alpha(Color.foreground, 0.08)
                    border.width: 1
                    border.color: mTopicsIn.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.18)
                    TextInput {
                      id: mTopicsIn
                      anchors.fill: parent
                      anchors.margins: 8
                      activeFocusOnTab: true
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: Style.font.small
                      color: Color.foreground
                      enabled: !root.stateObj.is_recording
                      text: root.meetingTopicsText
                      onTextChanged: root.meetingTopicsText = text
                      Keys.onTabPressed: {
                        if (attendeesRepeater.count > 0) {
                          attendeesRepeater.itemAt(0).focusName()
                        } else {
                          mNotesIn.forceActiveFocus()
                        }
                      }
                      Keys.onBacktabPressed: mTitleIn.forceActiveFocus()
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Meeting Topics"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: Style.font.small
                        color: Color.muted
                        visible: !mTopicsIn.text && !mTopicsIn.activeFocus
                      }
                    }
                  }
                }

                // Dynamic Attendees Section (3 by default + Add Button)
                ColumnLayout {
                  Layout.fillWidth: true
                  width: parent.width
                  spacing: 8

                  RowLayout {
                    Layout.fillWidth: true
                    Text {
                      text: "Meeting Attendees:"
                      font.family: "JetBrainsMono Nerd Font"
                      font.bold: true
                      font.pixelSize: Style.font.small
                      color: Color.foreground
                    }
                    Item { Layout.fillWidth: true }
                  }

                  Repeater {
                    id: attendeesRepeater
                    model: attendeesModel

                    RowLayout {
                      id: attRowItem
                      Layout.fillWidth: true
                      width: parent.width
                      spacing: 8

                      function focusName() { nameIn.forceActiveFocus() }

                      // Attendee Name (60% of window width)
                      ColumnLayout {
                        Layout.preferredWidth: Math.floor(formScroll.availableWidth * 0.60)
                        Layout.fillWidth: false
                        spacing: 2
                        Text {
                          text: "Attendee " + (index + 1) + ":"
                          font.family: "JetBrainsMono Nerd Font"
                          font.bold: true
                          font.pixelSize: 11
                          color: Color.foreground
                        }
                        Rectangle {
                          Layout.fillWidth: true
                          width: parent.width
                          Layout.preferredHeight: 34
                          radius: 4
                          color: Util.alpha(Color.foreground, 0.08)
                          border.width: 1
                          border.color: nameIn.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.18)
                          TextInput {
                            id: nameIn
                            anchors.fill: parent
                            anchors.margins: 8
                            activeFocusOnTab: true
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: Style.font.small
                            color: Color.foreground
                            enabled: !root.stateObj.is_recording
                            text: model.name
                            onTextChanged: model.name = text
                            Keys.onTabPressed: {
                              if (index + 1 < attendeesRepeater.count) {
                                attendeesRepeater.itemAt(index + 1).focusName()
                              } else {
                                mNotesIn.forceActiveFocus()
                              }
                            }
                            Keys.onBacktabPressed: {
                              if (index > 0) {
                                attendeesRepeater.itemAt(index - 1).focusName()
                              } else {
                                mTopicsIn.forceActiveFocus()
                              }
                            }
                            Text {
                              anchors.verticalCenter: parent.verticalCenter
                              text: "Name"
                              font.family: "JetBrainsMono Nerd Font"
                              font.pixelSize: Style.font.small
                              color: Color.muted
                              visible: !nameIn.text && !nameIn.activeFocus
                            }
                          }
                        }
                      }

                      // Attendee Gender Radio Group (Male / Female)
                      ColumnLayout {
                        Layout.preferredWidth: 160
                        Layout.leftMargin: 8
                        spacing: 2
                        Text {
                          text: "Gender:"
                          font.family: "JetBrainsMono Nerd Font"
                          font.bold: true
                          font.pixelSize: Style.font.small
                          color: Color.foreground
                        }

                        RowLayout {
                          Layout.fillWidth: true
                          Layout.preferredHeight: 34
                          spacing: 4

                          // Male Option
                          Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            RowLayout {
                              anchors.verticalCenter: parent.verticalCenter
                              anchors.left: parent.left
                              spacing: 5

                              // Round Radio Outer Circle
                              Rectangle {
                                width: 14
                                height: 14
                                radius: 7
                                color: "transparent"
                                border.width: 2
                                border.color: model.sex === "Male" ? Color.accent : (maleMouse.containsMouse ? Color.foreground : Util.alpha(Color.foreground, 0.35))

                                // Inner Filled Circle
                                Rectangle {
                                  anchors.centerIn: parent
                                  width: 6
                                  height: 6
                                  radius: 3
                                  color: Color.accent
                                  visible: model.sex === "Male"
                                }
                              }

                              Text {
                                text: "Male"
                                font.family: "JetBrainsMono Nerd Font"
                                font.bold: model.sex === "Male"
                                font.pixelSize: Style.font.small
                                color: model.sex === "Male" ? Color.accent : (maleMouse.containsMouse ? Color.foreground : Util.alpha(Color.foreground, 0.85))
                              }
                            }

                            MouseArea {
                              id: maleMouse
                              anchors.fill: parent
                              hoverEnabled: true
                              cursorShape: Qt.PointingHandCursor
                              enabled: !root.stateObj.is_recording
                              onClicked: model.sex = (model.sex === "Male" ? "" : "Male")
                            }
                          }

                          // Female Option
                          Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            RowLayout {
                              anchors.verticalCenter: parent.verticalCenter
                              anchors.left: parent.left
                              spacing: 5

                              // Round Radio Outer Circle
                              Rectangle {
                                width: 14
                                height: 14
                                radius: 7
                                color: "transparent"
                                border.width: 2
                                border.color: model.sex === "Female" ? Color.accent : (femaleMouse.containsMouse ? Color.foreground : Util.alpha(Color.foreground, 0.35))

                                // Inner Filled Circle
                                Rectangle {
                                  anchors.centerIn: parent
                                  width: 6
                                  height: 6
                                  radius: 3
                                  color: Color.accent
                                  visible: model.sex === "Female"
                                }
                              }

                              Text {
                                text: "Female"
                                font.family: "JetBrainsMono Nerd Font"
                                font.bold: model.sex === "Female"
                                font.pixelSize: Style.font.small
                                color: model.sex === "Female" ? Color.accent : (femaleMouse.containsMouse ? Color.foreground : Util.alpha(Color.foreground, 0.85))
                              }
                            }

                            MouseArea {
                              id: femaleMouse
                              anchors.fill: parent
                              hoverEnabled: true
                              cursorShape: Qt.PointingHandCursor
                              enabled: !root.stateObj.is_recording
                              onClicked: model.sex = (model.sex === "Female" ? "" : "Female")
                            }
                          }
                        }
                      }

                      // Delete Attendee Row (if > 1)
                      Rectangle {
                        visible: attendeesModel.count > 1
                        Layout.alignment: Qt.AlignBottom
                        Layout.preferredWidth: 34
                        Layout.preferredHeight: 34
                        radius: 4
                        color: delAttMouse.containsMouse ? Util.alpha(Color.urgent, 0.25) : Util.alpha(Color.foreground, 0.06)

                        Text {
                          anchors.centerIn: parent
                          text: "󰅖"
                          font.family: "JetBrainsMono Nerd Font"
                          font.pixelSize: 11
                          color: delAttMouse.containsMouse ? Color.urgent : Color.muted
                        }

                        MouseArea {
                          id: delAttMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: attendeesModel.remove(index)
                        }
                      }
                    }
                  }

                  // Add Attendee Button
                  Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: 4
                    color: addAttMouse.containsMouse ? Util.alpha(Color.accent, 0.25) : Util.alpha(Color.accent, 0.12)
                    border.width: 1
                    border.color: Util.alpha(Color.accent, 0.4)

                    RowLayout {
                      anchors.centerIn: parent
                      spacing: 6
                      Text {
                        text: "󰐕"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 12
                        color: Color.accent
                      }
                      Text {
                        text: "Add Attendee"
                        font.family: "JetBrainsMono Nerd Font"
                        font.bold: true
                        font.pixelSize: Style.font.small
                        color: Color.accent
                      }
                    }

                    MouseArea {
                      id: addAttMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: attendeesModel.append({ name: "", sex: "" })
                    }
                  }
                }

                // Additional Notes
                ColumnLayout {
                  Layout.fillWidth: true
                  width: parent.width
                  spacing: 3
                  Text {
                    text: "Additional Notes:"
                    font.family: "JetBrainsMono Nerd Font"
                    font.bold: true
                    font.pixelSize: Style.font.small
                    color: Color.foreground
                  }
                  Rectangle {
                    Layout.fillWidth: true
                    width: parent.width
                    Layout.preferredHeight: 52
                    radius: 4
                    color: Util.alpha(Color.foreground, 0.08)
                    border.width: 1
                    border.color: mNotesIn.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.18)
                    TextInput {
                      id: mNotesIn
                      anchors.fill: parent
                      anchors.margins: 8
                      activeFocusOnTab: true
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: Style.font.small
                      color: Color.foreground
                      enabled: !root.stateObj.is_recording
                      text: root.meetingNotesText
                      onTextChanged: root.meetingNotesText = text
                      Keys.onBacktabPressed: {
                        if (attendeesRepeater.count > 0) {
                          attendeesRepeater.itemAt(attendeesRepeater.count - 1).focusName()
                        } else {
                          mTopicsIn.forceActiveFocus()
                        }
                      }
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Additional Notes"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: Style.font.small
                        color: Color.muted
                        visible: !mNotesIn.text && !mNotesIn.activeFocus
                      }
                    }
                  }
                }
              }

              // --- VOICE MEMO FORM ---
              ColumnLayout {
                visible: root.selectedMode === "mic"
                Layout.fillWidth: true
                width: parent.width
                spacing: 10

                // Memo Title
                ColumnLayout {
                  Layout.fillWidth: true
                  width: parent.width
                  spacing: 3
                  Text {
                    text: "Memo Title:"
                    font.family: "JetBrainsMono Nerd Font"
                    font.bold: true
                    font.pixelSize: Style.font.small
                    color: Color.foreground
                  }
                  Rectangle {
                    Layout.fillWidth: true
                    width: parent.width
                    Layout.preferredHeight: 34
                    radius: 4
                    color: Util.alpha(Color.foreground, 0.08)
                    border.width: 1
                    border.color: memoTitleIn.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.18)
                    TextInput {
                      id: memoTitleIn
                      anchors.fill: parent
                      anchors.margins: 8
                      activeFocusOnTab: true
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: Style.font.small
                      color: Color.foreground
                      enabled: !root.stateObj.is_recording
                      text: root.memoTitleText
                      onTextChanged: root.memoTitleText = text
                      Keys.onTabPressed: memoTopicsIn.forceActiveFocus()
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Memo Title"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: Style.font.small
                        color: Color.muted
                        visible: !memoTitleIn.text && !memoTitleIn.activeFocus
                      }
                    }
                  }
                }

                // Memo Topics
                ColumnLayout {
                  Layout.fillWidth: true
                  width: parent.width
                  spacing: 3
                  Text {
                    text: "Memo Context / Key Topics:"
                    font.family: "JetBrainsMono Nerd Font"
                    font.bold: true
                    font.pixelSize: Style.font.small
                    color: Color.foreground
                  }
                  Rectangle {
                    Layout.fillWidth: true
                    width: parent.width
                    Layout.preferredHeight: 34
                    radius: 4
                    color: Util.alpha(Color.foreground, 0.08)
                    border.width: 1
                    border.color: memoTopicsIn.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.18)
                    TextInput {
                      id: memoTopicsIn
                      anchors.fill: parent
                      anchors.margins: 8
                      activeFocusOnTab: true
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: Style.font.small
                      color: Color.foreground
                      enabled: !root.stateObj.is_recording
                      text: root.memoTopicsText
                      onTextChanged: root.memoTopicsText = text
                      Keys.onTabPressed: memoNotesIn.forceActiveFocus()
                      Keys.onBacktabPressed: memoTitleIn.forceActiveFocus()
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Memo Context"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: Style.font.small
                        color: Color.muted
                        visible: !memoTopicsIn.text && !memoTopicsIn.activeFocus
                      }
                    }
                  }
                }

                // Memo Additional Notes
                ColumnLayout {
                  Layout.fillWidth: true
                  width: parent.width
                  spacing: 3
                  Text {
                    text: "Additional Notes:"
                    font.family: "JetBrainsMono Nerd Font"
                    font.bold: true
                    font.pixelSize: Style.font.small
                    color: Color.foreground
                  }
                  Rectangle {
                    Layout.fillWidth: true
                    width: parent.width
                    Layout.preferredHeight: 52
                    radius: 4
                    color: Util.alpha(Color.foreground, 0.08)
                    border.width: 1
                    border.color: memoNotesIn.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.18)
                    TextInput {
                      id: memoNotesIn
                      anchors.fill: parent
                      anchors.margins: 8
                      activeFocusOnTab: true
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: Style.font.small
                      color: Color.foreground
                      enabled: !root.stateObj.is_recording
                      text: root.memoNotesText
                      onTextChanged: root.memoNotesText = text
                      Keys.onBacktabPressed: memoTopicsIn.forceActiveFocus()
                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Additional Notes"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: Style.font.small
                        color: Color.muted
                        visible: !memoNotesIn.text && !memoNotesIn.activeFocus
                      }
                    }
                  }
                }
              }
            }
          }

          // ==========================================
          // PINNED BOTTOM ACTION SECTION
          // ==========================================
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 6

            // Mode Description Line
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 26
              radius: 4
              color: Util.alpha(Color.foreground, 0.05)

              RowLayout {
                anchors.centerIn: parent
                spacing: 6
                Text {
                  text: root.selectedMode === "meeting" ? "\uf4fd" : "󰍬"
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 11
                  color: Color.accent
                }
                Text {
                  text: root.selectedMode === "meeting" ? "Captures mic + system audio (Zoom, Signal, Teams, Calls, etc.)" : "Captures microphone only (solo dictation, ideas, memos)"
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 11
                  color: Color.muted
                }
              }
            }

            // Big Record Button
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 56
              radius: 8
              color: root.stateObj.is_recording ? Color.urgent : Color.accent

              RowLayout {
                anchors.centerIn: parent
                spacing: 12

                Text {
                  text: root.stateObj.is_recording ? "󰓛" : "󰑊"
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 24
                  color: root.stateObj.is_recording ? "#ffffff" : Color.pick("background", "#1e1e2e")
                }

                Text {
                  text: root.stateObj.is_recording ? ("STOP RECORDING (" + root.formatDuration(root.elapsedSeconds) + ")") : (root.selectedMode === "meeting" ? "Start Meeting Recording" : "Start Voice Memo")
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: Style.font.title
                  color: root.stateObj.is_recording ? "#ffffff" : Color.pick("background", "#1e1e2e")
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.stateObj.is_recording) {
                    root.stopRecord()
                  } else {
                    root.startRecord()
                  }
                }
              }
            }
          }
        }

        // ------------------------------------------
        // TAB 1: NOTES VIEW (WITH DELETE BUTTON & DIRECT ACTIONS)
        // ------------------------------------------
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 8

          // Header + Sub-Tabs
          RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Repeater {
              model: [
                { id: "all", label: "󰈙 All" },
                { id: "meetings", label: "\uf4fd Meeting Notes" },
                { id: "memos", label: "󰍬 Audio Notes" }
              ]

              Rectangle {
                Layout.preferredHeight: 26
                Layout.preferredWidth: filterText.implicitWidth + 16
                radius: 4
                color: root.historyFilter === modelData.id ? Color.accent : (subTabMouse.containsMouse ? Util.alpha(Color.foreground, 0.1) : Util.alpha(Color.foreground, 0.05))

                Text {
                  id: filterText
                  anchors.centerIn: parent
                  text: modelData.label
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 11
                  font.bold: root.historyFilter === modelData.id
                  color: root.historyFilter === modelData.id ? Color.pick("background", "#1e1e2e") : Color.foreground
                }

                MouseArea {
                  id: subTabMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.historyFilter = modelData.id
                }
              }
            }

            Item { Layout.fillWidth: true }

            Rectangle {
              width: 76
              height: 26
              radius: 4
              color: Util.alpha(Color.foreground, 0.08)
              RowLayout {
                anchors.centerIn: parent
                spacing: 4
                Text {
                  text: "󰉋"
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 11
                  color: Color.foreground
                }
                Text {
                  text: "Folder"
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 11
                  color: Color.foreground
                }
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openFolder()
              }
            }
          }

          // History List
          ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ListView {
              model: root.getFilteredHistory()
              spacing: 6
              delegate: Rectangle {
                id: itemCard
                width: parent ? parent.width : 660
                height: 58
                radius: 6
                color: Util.alpha(Color.foreground, 0.05)
                border.width: 1
                border.color: Util.alpha(Color.foreground, 0.1)

                property bool isTranscribingThis: root.stateObj.is_processing && (!modelData.has_notes || root.stateObj.last_processed_file === modelData.audio_file)
                property bool isEditingTitle: false

                // Left column: Mode icon, Title, metadata
                ColumnLayout {
                  anchors.left: parent.left
                  anchors.leftMargin: 12
                  anchors.right: actionTray.left
                  anchors.rightMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 3

                  // Title Row (Display or Edit mode)
                  RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Text {
                      text: modelData.mode === "meeting" ? "\uf4fd" : "󰍬"
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: Style.font.small
                      color: Color.accent
                    }

                    // Normal Title Display with Edit Pencil Icon
                    RowLayout {
                      visible: !itemCard.isEditingTitle
                      Layout.fillWidth: true
                      spacing: 6

                      Text {
                        text: modelData.title || modelData.filename
                        font.family: "JetBrainsMono Nerd Font"
                        font.bold: true
                        font.pixelSize: Style.font.small
                        color: Color.foreground
                        elide: Text.ElideRight
                      }

                      // Rename Pencil Icon Button
                      Rectangle {
                        width: 20
                        height: 20
                        radius: 3
                        color: editMouse.containsMouse ? Util.alpha(Color.accent, 0.2) : "transparent"

                        Text {
                          anchors.centerIn: parent
                          text: "󰏫"
                          font.family: "JetBrainsMono Nerd Font"
                          font.pixelSize: 11
                          color: editMouse.containsMouse ? Color.accent : Util.alpha(Color.foreground, 0.4)
                        }

                        MouseArea {
                          id: editMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            itemCard.isEditingTitle = true
                            editInput.text = modelData.title || modelData.filename
                            editInput.forceActiveFocus()
                          }
                        }
                      }
                    }

                    // Inline Title Edit Field with Save / Cancel Buttons
                    RowLayout {
                      visible: itemCard.isEditingTitle
                      Layout.fillWidth: true
                      spacing: 4

                      Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 24
                        radius: 4
                        color: Util.alpha(Color.foreground, 0.08)
                        border.width: 1
                        border.color: Color.accent

                        TextInput {
                          id: editInput
                          anchors.fill: parent
                          anchors.leftMargin: 6
                          anchors.rightMargin: 6
                          verticalAlignment: TextInput.AlignVCenter
                          font.family: "JetBrainsMono Nerd Font"
                          font.pixelSize: Style.font.small
                          font.bold: true
                          color: Color.foreground
                          selectByMouse: true
                          Keys.onReturnPressed: {
                            if (text.trim() && text.trim() !== modelData.title) {
                              root.renameNote(modelData.audio_file, text.trim())
                            }
                            itemCard.isEditingTitle = false
                          }
                          Keys.onEscapePressed: {
                            itemCard.isEditingTitle = false
                          }
                        }
                      }

                      // Save Button (✓)
                      Rectangle {
                        width: 22
                        height: 22
                        radius: 3
                        color: saveEditMouse.containsMouse ? Color.accent : Util.alpha(Color.accent, 0.2)

                        Text {
                          anchors.centerIn: parent
                          text: "✓"
                          font.family: "JetBrainsMono Nerd Font"
                          font.bold: true
                          font.pixelSize: 11
                          color: saveEditMouse.containsMouse ? Color.pick("background", "#1e1e2e") : Color.accent
                        }

                        MouseArea {
                          id: saveEditMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            if (editInput.text.trim() && editInput.text.trim() !== modelData.title) {
                              root.renameNote(modelData.audio_file, editInput.text.trim())
                            }
                            itemCard.isEditingTitle = false
                          }
                        }
                      }

                      // Cancel Button (✕)
                      Rectangle {
                        width: 22
                        height: 22
                        radius: 3
                        color: cancelEditMouse.containsMouse ? Util.alpha(Color.urgent, 0.2) : Util.alpha(Color.foreground, 0.1)

                        Text {
                          anchors.centerIn: parent
                          text: "✕"
                          font.family: "JetBrainsMono Nerd Font"
                          font.pixelSize: 10
                          color: cancelEditMouse.containsMouse ? Color.urgent : Color.muted
                        }

                        MouseArea {
                          id: cancelEditMouse
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            itemCard.isEditingTitle = false
                          }
                        }
                      }
                    }
                  }

                  Text {
                    Layout.fillWidth: true
                    text: modelData.date + "  •  " + modelData.size_kb + " KB  •  " + (modelData.mode === "meeting" ? "Meeting" : "Voice Memo")
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 10
                    color: Color.muted
                    elide: Text.ElideRight
                  }
                }

                // Right column: Action Buttons Tray
                RowLayout {
                  id: actionTray
                  anchors.right: parent.right
                  anchors.rightMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 6

                  // ACTION BUTTON: Notes
                  Rectangle {
                    visible: modelData.has_notes
                    width: 78
                    height: 28
                    radius: 4
                    color: notesMouse.containsMouse ? Util.alpha(Color.accent, 0.35) : Util.alpha(Color.accent, 0.18)
                    border.width: 1
                    border.color: Color.accent

                    RowLayout {
                      anchors.centerIn: parent
                      spacing: 4
                      Text {
                        text: "󰈙"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 10
                        color: Color.accent
                      }
                      Text {
                        text: "Notes"
                        font.family: "JetBrainsMono Nerd Font"
                        font.bold: true
                        font.pixelSize: 10
                        color: Color.accent
                      }
                    }

                    MouseArea {
                      id: notesMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openInEditor(modelData.notes_file)
                    }
                  }

                  // ACTION BUTTON: Transcript
                  Rectangle {
                    visible: modelData.has_transcript
                    width: 98
                    height: 28
                    radius: 4
                    color: transMouse.containsMouse ? Util.alpha(Color.accent, 0.35) : Util.alpha(Color.accent, 0.18)
                    border.width: 1
                    border.color: Color.accent

                    RowLayout {
                      anchors.centerIn: parent
                      spacing: 4
                      Text {
                        text: "󰈙"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 10
                        color: Color.accent
                      }
                      Text {
                        text: "Transcript"
                        font.family: "JetBrainsMono Nerd Font"
                        font.bold: true
                        font.pixelSize: 10
                        color: Color.accent
                      }
                    }

                    MouseArea {
                      id: transMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openInEditor(modelData.transcript_file)
                    }
                  }

                  // ACTION BUTTON: Transcribe Status / Pulsing Transcribing Badge
                  Rectangle {
                    id: transBadge
                    visible: !modelData.has_notes
                    implicitWidth: transContentRow.implicitWidth + 24
                    implicitHeight: 28
                    radius: 4
                    color: itemCard.isTranscribingThis ? Util.alpha(Color.urgent, 0.18) : (trMouse.containsMouse ? Color.pick("accent-hover", Color.accent) : Color.accent)
                    border.width: itemCard.isTranscribingThis ? 1 : 0
                    border.color: Color.urgent

                    SequentialAnimation on opacity {
                      running: itemCard.isTranscribingThis
                      loops: Animation.Infinite
                      NumberAnimation { from: 1.0; to: 0.35; duration: 650; easing.type: Easing.InOutQuad }
                      NumberAnimation { from: 0.35; to: 1.0; duration: 650; easing.type: Easing.InOutQuad }
                    }

                    RowLayout {
                      id: transContentRow
                      anchors.centerIn: parent
                      spacing: 6

                      Text {
                        text: itemCard.isTranscribingThis ? "󰑮" : "󰑊"
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 12
                        color: itemCard.isTranscribingThis ? Color.urgent : Color.pick("background", "#1e1e2e")
                      }

                      Text {
                        text: itemCard.isTranscribingThis ? "Transcribing..." : "Transcribe"
                        font.family: "JetBrainsMono Nerd Font"
                        font.bold: true
                        font.pixelSize: 11
                        color: itemCard.isTranscribingThis ? Color.urgent : Color.pick("background", "#1e1e2e")
                      }
                    }

                    MouseArea {
                      id: trMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: itemCard.isTranscribingThis ? Qt.ArrowCursor : Qt.PointingHandCursor
                      enabled: !itemCard.isTranscribingThis
                      onClicked: root.triggerTranscribe(modelData.audio_file, modelData.mode, modelData.title, "")
                    }
                  }

                  // ACTION BUTTON: Delete Recording & Folder
                  Rectangle {
                    implicitWidth: 30
                    implicitHeight: 28
                    radius: 4
                    color: deleteMouse.containsMouse ? Util.alpha(Color.urgent, 0.25) : Util.alpha(Color.foreground, 0.08)

                    Text {
                      anchors.centerIn: parent
                      text: "✕"
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: 11
                      color: deleteMouse.containsMouse ? Color.urgent : Color.muted
                    }

                    MouseArea {
                      id: deleteMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.deleteItem(modelData.audio_file)
                    }
                  }
                }
              }
            }
          }
        }

        // ------------------------------------------
        // TAB 2: MULTI-PROVIDER SETTINGS VIEW (WITH FREE TIER GUIDES)
        // ------------------------------------------
        ScrollView {
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          contentWidth: availableWidth

          ColumnLayout {
            width: parent.width
            Layout.fillWidth: true
            spacing: 12

            // Section 1: AI Provider Selector
            Text {
              text: "Select AI Provider:"
              font.family: "JetBrainsMono Nerd Font"
              font.bold: true
              font.pixelSize: Style.font.small
              color: Color.foreground
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: 6

              Repeater {
                model: [
                  { id: "gemini", icon: "󰊭", name: "Google Gemini", badge: "Free (1,500/day)" },
                  { id: "groq",   icon: "󱐋", name: "Groq Cloud",   badge: "Free (Fast LPU)" },
                  { id: "local",  icon: "󰒋", name: "Local Whisper", badge: "100% Offline Free" },
                  { id: "openai", icon: "󰘚", name: "OpenAI",       badge: "Pay-As-You-Go" }
                ]

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 48
                  radius: 6
                  border.width: 1
                  border.color: root.selectedProvider === modelData.id ? Color.accent : Util.alpha(Color.foreground, 0.15)
                  color: root.selectedProvider === modelData.id ? Util.alpha(Color.accent, 0.15) : (provMouse.containsMouse ? Util.alpha(Color.foreground, 0.05) : "transparent")

                  ColumnLayout {
                    anchors.centerIn: parent
                    spacing: 2

                    RowLayout {
                      Layout.alignment: Qt.AlignHCenter
                      spacing: 4
                      Text {
                        text: modelData.icon
                        font.family: "JetBrainsMono Nerd Font"
                        font.pixelSize: 12
                        color: root.selectedProvider === modelData.id ? Color.accent : Color.foreground
                      }
                      Text {
                        text: modelData.name
                        font.family: "JetBrainsMono Nerd Font"
                        font.bold: true
                        font.pixelSize: 11
                        color: root.selectedProvider === modelData.id ? Color.accent : Color.foreground
                      }
                    }

                    Text {
                      Layout.alignment: Qt.AlignHCenter
                      text: modelData.badge
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: 9
                      color: root.selectedProvider === modelData.id ? Color.accent : Color.muted
                    }
                  }

                  MouseArea {
                    id: provMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.selectedProvider = modelData.id
                      root.settingsObj.provider = modelData.id
                      apiKeyInput.text = root.getCurrentApiKey()
                    }
                  }
                }
              }
            }

            // Section 2: Dynamic Provider Setup & Guide Box
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: guideCol.implicitHeight + 18
              radius: 6
              color: root.selectedProvider === "local" ? (root.localWhisperStatus.installed ? Util.alpha(Color.accent, 0.08) : Util.alpha(Color.urgent, 0.08)) : Util.alpha(Color.foreground, 0.04)
              border.width: 1
              border.color: root.selectedProvider === "local" ? (root.localWhisperStatus.installed ? Color.accent : Color.urgent) : Util.alpha(Color.foreground, 0.12)

              ColumnLayout {
                id: guideCol
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6

                RowLayout {
                  spacing: 6
                  Text {
                    text: {
                      if (root.selectedProvider === "local") {
                        return root.localWhisperStatus.installed ? "󰄬" : "󰅖"
                      }
                      return "󰋼"
                    }
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 12
                    color: root.selectedProvider === "local" ? (root.localWhisperStatus.installed ? Color.accent : Color.urgent) : Color.accent
                  }
                  Text {
                    text: {
                      if (root.selectedProvider === "gemini") return "Google Gemini Setup (Free Tier: 1,500 Requests/Day)"
                      if (root.selectedProvider === "groq") return "Groq Cloud Setup (Free Tier: Blazing Fast LPU Inference)"
                      if (root.selectedProvider === "local") {
                        return root.localWhisperStatus.installed ? ("Local Whisper Ready (" + root.localWhisperStatus.engine + ")") : "Local Whisper Not Installed"
                      }
                      return "OpenAI Setup (Whisper-1 + GPT-4o)"
                    }
                    font.family: "JetBrainsMono Nerd Font"
                    font.bold: true
                    font.pixelSize: 11
                    color: Color.foreground
                  }
                  Item { Layout.fillWidth: true }
                  Rectangle {
                    visible: root.selectedProvider === "local"
                    width: 70
                    height: 22
                    radius: 3
                    color: Util.alpha(Color.foreground, 0.1)
                    RowLayout {
                      anchors.centerIn: parent
                      spacing: 3
                      Text { text: "󰑐"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9; color: Color.foreground }
                      Text { text: "Re-check"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 9; color: Color.foreground }
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.checkWhisper()
                    }
                  }
                }

                Text {
                  Layout.fillWidth: true
                  wrapMode: Text.WordWrap
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 10
                  color: Color.muted
                  text: {
                    if (root.selectedProvider === "gemini") {
                      return "1. Visit aistudio.google.com and sign in with any Google account (Free, no credit card required).\n2. Click 'Get API key' -> 'Create API key in new project'.\n3. Paste the key (AIzaSy...) below. Direct multimodal audio with speaker intonation recognition."
                    }
                    if (root.selectedProvider === "groq") {
                      return "1. Visit console.groq.com and create a free account.\n2. Navigate to 'API Keys' -> 'Create API Key'.\n3. Paste the key (gsk_...) below. Groq transcribes 1-hour audio in ~3 seconds using Whisper Large v3 on LPUs."
                    }
                    if (root.selectedProvider === "local") {
                      if (root.localWhisperStatus.installed) {
                        var cachedInfo = (root.localWhisperStatus.cached_models && root.localWhisperStatus.cached_models.length > 0) ? ("\n• Cached models ready offline: " + root.localWhisperStatus.cached_models.join(", ")) : ""
                        return "• Engine is installed and ready for 100% offline transcription." + cachedInfo + "\n• Model weights automatically download on your very first transcription and remain cached permanently."
                      }
                      return "Local Whisper runs 100% on your device with zero data leaving your machine.\nTo install the official package on Arch Linux, run the command below in your terminal:"
                    }
                    return "1. Visit platform.openai.com/api-keys and log in to your OpenAI account.\n2. Generate a Secret API Key (sk-...) and ensure your account has usage credits.\n3. Uses OpenAI Whisper-1 transcription paired with GPT-4o for meeting summarization."
                  }
                }

                // Interactive Install Command Box for Local Whisper (if not installed)
                Rectangle {
                  visible: root.selectedProvider === "local" && !root.localWhisperStatus.installed
                  Layout.fillWidth: true
                  Layout.preferredHeight: 32
                  radius: 4
                  color: Util.alpha(Color.foreground, 0.08)
                  border.width: 1
                  border.color: Util.alpha(Color.foreground, 0.15)

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: 6
                    spacing: 8

                    Text {
                      Layout.fillWidth: true
                      text: root.localWhisperStatus.install_command || "sudo pacman -S python-openai-whisper"
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: 10
                      color: Color.accent
                      elide: Text.ElideRight
                    }

                    Rectangle {
                      width: 80
                      height: 22
                      radius: 3
                      color: copyMouse.containsMouse ? Color.accent : Util.alpha(Color.accent, 0.2)

                      RowLayout {
                        anchors.centerIn: parent
                        spacing: 3
                        Text {
                          text: "󰅍"
                          font.family: "JetBrainsMono Nerd Font"
                          font.pixelSize: 9
                          color: copyMouse.containsMouse ? Color.pick("background", "#1e1e2e") : Color.accent
                        }
                        Text {
                          text: "Copy"
                          font.family: "JetBrainsMono Nerd Font"
                          font.bold: true
                          font.pixelSize: 9
                          color: copyMouse.containsMouse ? Color.pick("background", "#1e1e2e") : Color.accent
                        }
                      }

                      MouseArea {
                        id: copyMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.copyText(root.localWhisperStatus.install_command || "sudo pacman -S python-openai-whisper")
                          root.saveFeedbackText = "✓ Copied install command to clipboard!"
                          feedbackTimer.restart()
                        }
                      }
                    }
                  }
                }
              }
            }

            // Section 3: API Key Input (Hidden for Local Whisper)
            ColumnLayout {
              visible: root.selectedProvider !== "local"
              Layout.fillWidth: true
              spacing: 6

              Text {
                text: {
                  if (root.selectedProvider === "groq") return "Groq Cloud API Key:"
                  if (root.selectedProvider === "openai") return "OpenAI Secret API Key:"
                  return "Google Gemini API Key:"
                }
                font.family: "JetBrainsMono Nerd Font"
                font.bold: true
                font.pixelSize: Style.font.small
                color: Color.foreground
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 36
                  radius: 6
                  clip: true
                  color: Util.alpha(Color.foreground, 0.08)
                  border.width: 1
                  border.color: apiKeyInput.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.18)

                  TextInput {
                    id: apiKeyInput
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    echoMode: root.showApiKey ? TextInput.Normal : TextInput.Password
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: Style.font.small
                    color: Color.foreground
                    text: root.getCurrentApiKey()
                    onTextChanged: root.setCurrentApiKey(text)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.selectedProvider === "groq" ? "Paste your Groq API key (gsk_...)" : (root.selectedProvider === "openai" ? "Paste your OpenAI key (sk-...)" : "Paste your Google AI Studio key (AIzaSy...)")
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: Style.font.small
                      color: Color.muted
                      visible: !apiKeyInput.text && !apiKeyInput.activeFocus
                    }
                  }
                }

                // Eye toggle
                Rectangle {
                  width: 36
                  height: 36
                  radius: 6
                  color: eyeMouse.containsMouse ? Util.alpha(Color.foreground, 0.15) : Util.alpha(Color.foreground, 0.08)
                  Text {
                    anchors.centerIn: parent
                    text: root.showApiKey ? "󰈉" : "󰈈"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: Style.font.body
                    color: Color.foreground
                  }
                  MouseArea {
                    id: eyeMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.showApiKey = !root.showApiKey
                  }
                }

                // Paste button
                Rectangle {
                  width: 76
                  height: 36
                  radius: 6
                  color: pasteMouse.containsMouse ? Util.alpha(Color.accent, 0.3) : Util.alpha(Color.accent, 0.15)
                  RowLayout {
                    anchors.centerIn: parent
                    spacing: 4
                    Text { text: "󰅍"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11; color: Color.accent }
                    Text { text: "Paste"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: 11; color: Color.accent }
                  }
                  MouseArea {
                    id: pasteMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: pasteProc.running = true
                  }
                }
              }
            }

            // Section 4: Model Selection Cards
            Text {
              text: "Select Model Architecture:"
              font.family: "JetBrainsMono Nerd Font"
              font.bold: true
              font.pixelSize: Style.font.small
              color: Color.foreground
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: 6

              // Gemini Models
              Repeater {
                model: root.selectedProvider === "gemini" ? [
                  { id: "gemini-3.7-flash", icon: "󱐋", name: "Gemini 3.7 Flash", desc: "Flagship (Default) • Latest acoustic reasoning & pitch/voice diarization" },
                  { id: "gemini-2.5-flash", icon: "󱐋", name: "Gemini 2.5 Flash", desc: "Ultra-Stable Backup • Rock-solid free tier uptime and balanced speed" }
                ] : []

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 44
                  radius: 6
                  border.width: 1
                  border.color: root.selectedModel === modelData.id ? Color.accent : Util.alpha(Color.foreground, 0.12)
                  color: root.selectedModel === modelData.id ? Util.alpha(Color.accent, 0.15) : (gMouse.containsMouse ? Util.alpha(Color.foreground, 0.05) : "transparent")

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 8
                    Text { text: modelData.icon; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Style.font.body; color: root.selectedModel === modelData.id ? Color.accent : Color.muted }
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 1
                      Text { text: modelData.name; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: Style.font.small; color: root.selectedModel === modelData.id ? Color.accent : Color.foreground }
                      Text { text: modelData.desc; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10; color: Color.muted; elide: Text.ElideRight }
                    }
                    Text { visible: root.selectedModel === modelData.id; text: "✓"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; color: Color.accent }
                  }
                  MouseArea { id: gMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.selectedModel = modelData.id; root.settingsObj.model = modelData.id } }
                }
              }

              // Groq Models
              Repeater {
                model: root.selectedProvider === "groq" ? [
                  { id: "llama-3.3-70b-versatile", icon: "󱐋", name: "Whisper Large v3 + Llama 3.3 70B", desc: "Recommended • 70B parameter deep reasoning and formatted synthesis" },
                  { id: "llama-3.1-8b-instant",     icon: "󱐋", name: "Whisper Large v3 + Llama 3.1 8B",  desc: "Instant • Lightweight high-speed summary generation" }
                ] : []

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 44
                  radius: 6
                  border.width: 1
                  border.color: root.selectedGroqModel === modelData.id ? Color.accent : Util.alpha(Color.foreground, 0.12)
                  color: root.selectedGroqModel === modelData.id ? Util.alpha(Color.accent, 0.15) : (grqMouse.containsMouse ? Util.alpha(Color.foreground, 0.05) : "transparent")

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 8
                    Text { text: modelData.icon; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Style.font.body; color: root.selectedGroqModel === modelData.id ? Color.accent : Color.muted }
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 1
                      Text { text: modelData.name; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: Style.font.small; color: root.selectedGroqModel === modelData.id ? Color.accent : Color.foreground }
                      Text { text: modelData.desc; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10; color: Color.muted; elide: Text.ElideRight }
                    }
                    Text { visible: root.selectedGroqModel === modelData.id; text: "✓"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; color: Color.accent }
                  }
                  MouseArea { id: grqMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.selectedGroqModel = modelData.id; root.settingsObj.groq_model = modelData.id } }
                }
              }

              // OpenAI Models
              Repeater {
                model: root.selectedProvider === "openai" ? [
                  { id: "gpt-4o-mini", icon: "󰘚", name: "Whisper-1 + GPT-4o-mini", desc: "Fast & Cost-Effective • High accuracy audio transcript + fast notes" },
                  { id: "gpt-4o",      icon: "󰘚", name: "Whisper-1 + GPT-4o",      desc: "Flagship • Maximum reasoning capability for complex discussions" }
                ] : []

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 44
                  radius: 6
                  border.width: 1
                  border.color: root.selectedOpenAIModel === modelData.id ? Color.accent : Util.alpha(Color.foreground, 0.12)
                  color: root.selectedOpenAIModel === modelData.id ? Util.alpha(Color.accent, 0.15) : (oaMouse.containsMouse ? Util.alpha(Color.foreground, 0.05) : "transparent")

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 8
                    Text { text: modelData.icon; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Style.font.body; color: root.selectedOpenAIModel === modelData.id ? Color.accent : Color.muted }
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 1
                      Text { text: modelData.name; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: Style.font.small; color: root.selectedOpenAIModel === modelData.id ? Color.accent : Color.foreground }
                      Text { text: modelData.desc; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10; color: Color.muted; elide: Text.ElideRight }
                    }
                    Text { visible: root.selectedOpenAIModel === modelData.id; text: "✓"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; color: Color.accent }
                  }
                  MouseArea { id: oaMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.selectedOpenAIModel = modelData.id; root.settingsObj.openai_model = modelData.id } }
                }
              }

              // Local Offline Models
              Repeater {
                model: root.selectedProvider === "local" ? [
                  { id: "base",   icon: "󰒋", name: "Whisper Base",   desc: "Fast (~140 MB model) • Low CPU usage, rapid offline turnaround" },
                  { id: "small",  icon: "󰒋", name: "Whisper Small",  desc: "Balanced (~460 MB model) • Higher accuracy for meeting dialogues" },
                  { id: "medium", icon: "󰒋", name: "Whisper Medium", desc: "High Accuracy (~1.5 GB model) • Optimal for noisy environments" }
                ] : []

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 44
                  radius: 6
                  border.width: 1
                  border.color: root.selectedLocalModel === modelData.id ? Color.accent : Util.alpha(Color.foreground, 0.12)
                  color: root.selectedLocalModel === modelData.id ? Util.alpha(Color.accent, 0.15) : (locMouse.containsMouse ? Util.alpha(Color.foreground, 0.05) : "transparent")

                  RowLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 8
                    Text { text: modelData.icon; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Style.font.body; color: root.selectedLocalModel === modelData.id ? Color.accent : Color.muted }
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 1
                      Text { text: modelData.name; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: Style.font.small; color: root.selectedLocalModel === modelData.id ? Color.accent : Color.foreground }
                      Text { text: modelData.desc; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10; color: Color.muted; elide: Text.ElideRight }
                    }
                    Text { visible: root.selectedLocalModel === modelData.id; text: "✓"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; color: Color.accent }
                  }
                  MouseArea { id: locMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.selectedLocalModel = modelData.id; root.settingsObj.local_model = modelData.id } }
                }
              }
            }

            // Section 5: Storage Folder Location
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 6

              Text {
                text: "Storage Location (Notes & Recordings):"
                font.family: "JetBrainsMono Nerd Font"
                font.bold: true
                font.pixelSize: Style.font.small
                color: Color.foreground
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 36
                  radius: 6
                  clip: true
                  color: Util.alpha(Color.foreground, 0.08)
                  border.width: 1
                  border.color: storagePathInput.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.18)

                  TextInput {
                    id: storagePathInput
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: Style.font.small
                    color: Color.foreground
                    text: root.settingsObj.storage_path || (Quickshell.env("HOME") + "/Documents/AudioNotes")
                    onTextChanged: root.settingsObj.storage_path = text
                  }
                }

                // Browse Button (opens Zenity directory picker)
                Rectangle {
                  width: 92
                  height: 36
                  radius: 6
                  color: browseMouse.containsMouse ? Util.alpha(Color.accent, 0.3) : Util.alpha(Color.accent, 0.15)

                  RowLayout {
                    anchors.centerIn: parent
                    spacing: 4
                    Text { text: "󰉋"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11; color: Color.accent }
                    Text { text: "Browse"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: 11; color: Color.accent }
                  }

                  MouseArea {
                    id: browseMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.pickDirectory()
                  }
                }
              }
            }

            Item { Layout.preferredHeight: 4 }

            // Save Settings Button
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 40
              radius: 6
              color: Color.accent

              RowLayout {
                anchors.centerIn: parent
                spacing: 6
                Text { text: "󰆓"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: Style.font.body; color: Color.pick("background", "#1e1e2e") }
                Text { text: "Save Settings"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: Style.font.body; color: Color.pick("background", "#1e1e2e") }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.settingsObj.provider = root.selectedProvider
                  root.settingsObj.model = root.selectedModel
                  root.settingsObj.groq_model = root.selectedGroqModel
                  root.settingsObj.openai_model = root.selectedOpenAIModel
                  root.settingsObj.local_model = root.selectedLocalModel
                  root.settingsObj.storage_path = storagePathInput.text.trim()
                  root.setCurrentApiKey(apiKeyInput.text.trim())

                  var settingsJson = JSON.stringify(root.settingsObj)
                  actionProc.command = ["python3", root.enginePath, "save-settings", settingsJson]
                  actionProc.running = true
                  var provTitle = root.selectedProvider === "gemini" ? "Google Gemini" : (root.selectedProvider === "groq" ? "Groq Cloud" : (root.selectedProvider === "local" ? "Local Whisper" : "OpenAI"))
                  root.saveFeedbackText = "✓ Settings saved (" + provTitle + ")!"
                  feedbackTimer.restart()
                }
              }
            }

            Text {
              visible: !!root.saveFeedbackText
              Layout.alignment: Qt.AlignHCenter
              text: root.saveFeedbackText
              font.family: "JetBrainsMono Nerd Font"
              font.bold: true
              font.pixelSize: Style.font.small
              color: Color.accent
            }

            Item { Layout.preferredHeight: 8 }
          }
        }
      }
    }
  }
}
