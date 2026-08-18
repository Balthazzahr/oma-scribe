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
    status_message: "Ready",
    processing_stage: "",
    progress_percent: 0,
    last_error: "",
    current_model: ""
  })

  property var settingsObj: ({
    groq_api_key: "",
    groq_model: "llama-3.1-70b-versatile",
    whisper_model: "whisper-large-v3",
    storage_path: "",
    notes_format: "md",
    audio_format: "opus",
    auto_transcribe_on_stop: true,
    default_mode: "meeting"
  })

  property string selectedGroqModel: "llama-3.1-70b-versatile"
  property var historyList: []
  property int activeTabIndex: 0 // 0: Record, 1: Library, 2: Settings
  property string historyFilter: "all" // "all" | "meetings" | "memos"
  property string historySearchQuery: ""
  property string selectedMode: "meeting" // "meeting" | "mic"
  property int elapsedSeconds: 0
  property int transcribeElapsedSeconds: 0
  property bool showApiKey: false
  property string saveFeedbackText: ""
  property string copyFeedbackText: ""
  property string selectedNotesFormat: "md"
  property string selectedAudioFormat: "opus"

  // Pre-meeting Form Properties
  property string meetingTitleText: ""
  property string meetingTopicsText: ""
  property string meetingNotesText: ""
  property string meetingAttendeesText: ""

  // In-App Reader State
  property bool isReaderOpen: false
  property var currentReaderItem: null
  property string activeReaderNotesText: ""
  property string activeReaderTransText: ""
  property int activeReaderSubTab: 0 // 0: Notes, 1: Transcript

  function resetMeetingForm() {
    meetingTitleText = ""
    meetingTopicsText = ""
    meetingNotesText = ""
    meetingAttendeesText = ""
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

  function startRecording(mode) {
    var m = mode || root.selectedMode || "meeting"
    var title = root.meetingTitleText.trim()
    var meta = {
      title: title,
      topics: root.meetingTopicsText.trim(),
      notes: root.meetingNotesText.trim(),
      attendees: root.meetingAttendeesText.trim(),
      mode: m
    }
    actionProc.command = ["python3", enginePath, "start", m, JSON.stringify(meta)]
    actionProc.running = true
    root.updateStatus()
  }

  function stopRecording() {
    var title = root.meetingTitleText.trim()
    var meta = {
      title: title,
      topics: root.meetingTopicsText.trim(),
      notes: root.meetingNotesText.trim(),
      attendees: root.meetingAttendeesText.trim(),
      mode: root.selectedMode
    }
    actionProc.command = ["python3", enginePath, "stop", JSON.stringify(meta)]
    actionProc.running = true
    root.resetMeetingForm()
    root.updateStatus()
  }

  function triggerTranscribe(audioFile, mode, title, speakers) {
    var t = (title || "").trim()
    var spk = (speakers || "").trim()
    transcribeProc.command = ["python3", enginePath, "transcribe", audioFile, mode || "meeting", t, spk]
    transcribeProc.running = true
    root.activeTabIndex = 1
  }

  function cancelTranscription() {
    var st = Object.assign({}, root.stateObj)
    st.is_processing = false
    st.transcribe_pid = null
    st.processing_stage = ""
    st.progress_percent = 0
    st.last_error = ""
    root.stateObj = st
    root.transcribeElapsedSeconds = 0
    cancelProc.command = ["python3", enginePath, "cancel"]
    cancelProc.running = true
    root.updateStatus()
  }

  function clearError() {
    var st = Object.assign({}, root.stateObj)
    st.last_error = ""
    root.stateObj = st
    actionProc.command = ["python3", enginePath, "clear-error"]
    actionProc.running = true
  }

  function deleteItem(audioFile) {
    if (!audioFile) return
    if (root.currentReaderItem && root.currentReaderItem.audio_file === audioFile) {
      root.isReaderOpen = false
      root.currentReaderItem = null
    }
    actionProc.command = ["python3", enginePath, "delete", audioFile]
    actionProc.running = true
  }

  function renameNote(targetPath, newTitle) {
    if (!targetPath || !newTitle || !newTitle.trim()) return
    actionProc.command = ["python3", enginePath, "rename", targetPath, newTitle.trim()]
    actionProc.running = true
  }

  function openFolder(folderPath) {
    if (folderPath) {
      execProc.command = ["xdg-open", folderPath]
    } else {
      execProc.command = ["python3", enginePath, "open-storage-folder"]
    }
    execProc.running = true
  }

  function openInEditor(filePath) {
    if (!filePath) return
    editorProc.command = ["python3", enginePath, "open-editor", filePath]
    editorProc.running = true
  }

  function copyText(val, label) {
    if (!val) return
    copyProc.command = ["wl-copy", val]
    copyProc.running = true
    root.copyFeedbackText = "✓ " + (label || "Copied to clipboard")
    copyFeedbackTimer.restart()
  }

  function openReader(item, subTab) {
    if (!item) return
    root.currentReaderItem = item
    root.activeReaderSubTab = (subTab !== undefined) ? subTab : (item.has_transcript ? 0 : (item.has_notes ? 1 : 0))
    root.activeReaderNotesText = "Loading notes..."
    root.activeReaderTransText = "Loading transcript..."
    root.isReaderOpen = true
    root.activeTabIndex = 1

    if (item.notes_file) {
      readNotesProc.command = ["python3", enginePath, "read-file", item.notes_file]
      readNotesProc.running = true
    } else {
      root.activeReaderNotesText = "No structured notes generated yet.\n\nClick 'Transcribe' to process this recording with Groq Whisper & Llama."
    }

    if (item.transcript_file) {
      readTransProc.command = ["python3", enginePath, "read-file", item.transcript_file]
      readTransProc.running = true
    } else {
      root.activeReaderTransText = "No verbatim transcript generated yet.\n\nClick 'Transcribe' to process this recording with Groq Whisper & Llama."
    }
  }

  function getFilteredHistory() {
    if (!root.historyList || !Array.isArray(root.historyList)) return []
    var list = root.historyList
    if (root.historyFilter === "meetings") {
      list = list.filter(function(item) { return item.mode === "meeting" })
    } else if (root.historyFilter === "memos") {
      list = list.filter(function(item) { return item.mode === "mic" })
    }
    if (root.historySearchQuery && root.historySearchQuery.trim()) {
      var q = root.historySearchQuery.toLowerCase().trim()
      list = list.filter(function(item) {
        return (item.title && item.title.toLowerCase().indexOf(q) !== -1) ||
               (item.filename && item.filename.toLowerCase().indexOf(q) !== -1)
      })
    }
    return list
  }

  function formatDuration(sec) {
    if (!sec || isNaN(sec)) return "00:00"
    var m = Math.floor(sec / 60)
    var s = Math.floor(sec % 60)
    var hh = Math.floor(m / 60)
    var mm = m % 60
    if (hh > 0) {
      return (hh < 10 ? "0" + hh : hh) + ":" + (mm < 10 ? "0" + mm : mm) + ":" + (s < 10 ? "0" + s : s)
    }
    return (mm < 10 ? "0" + mm : mm) + ":" + (s < 10 ? "0" + s : s)
  }

  function pickDirectory() {
    pickDirProc.command = ["python3", enginePath, "pick-directory"]
    pickDirProc.running = true
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
          if (parsed.groq_api_key !== undefined) root.settingsObj.groq_api_key = parsed.groq_api_key
          if (parsed.groq_model) {
            root.settingsObj.groq_model = parsed.groq_model
            root.selectedGroqModel = parsed.groq_model
          }
          if (parsed.default_mode) root.selectedMode = parsed.default_mode
          if (parsed.notes_format) root.selectedNotesFormat = parsed.notes_format
          if (parsed.audio_format) root.selectedAudioFormat = parsed.audio_format
          if (parsed.storage_path) {
            root.settingsObj.storage_path = parsed.storage_path
            if (typeof storagePathInput !== "undefined" && storagePathInput) {
              storagePathInput.text = parsed.storage_path
            }
          }
          if (typeof apiKeyInput !== "undefined" && apiKeyInput) {
            apiKeyInput.text = root.settingsObj.groq_api_key || ""
          }
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
          var parsed = JSON.parse(raw)
          if (Array.isArray(parsed)) {
            root.historyList = parsed
            if (root.currentReaderItem) {
              for (var i = 0; i < parsed.length; ++i) {
                if (parsed[i].folder === root.currentReaderItem.folder || parsed[i].audio_file === root.currentReaderItem.audio_file) {
                  root.currentReaderItem = parsed[i]
                  break
                }
              }
            }
          }
        } catch(e) {}
      }
    }
  }

  Process {
    id: readNotesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.activeReaderNotesText = String(text || "").trim() || "(Empty notes document)"
      }
    }
  }

  Process {
    id: readTransProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.activeReaderTransText = String(text || "").trim() || "(Empty transcript document)"
      }
    }
  }

  Process {
    id: transcribeProc
    onExited: {
      root.updateStatus()
      root.loadHistory()
    }
  }

  Process {
    id: cancelProc
    onExited: {
      root.updateStatus()
      root.loadHistory()
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
            root.saveFeedbackText = "✓ Storage folder updated"
            feedbackTimer.restart()
            root.loadHistory()
          }
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
          root.settingsObj.groq_api_key = raw
          if (typeof apiKeyInput !== "undefined" && apiKeyInput) {
            apiKeyInput.text = raw
          }
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
      if (root.stateObj.is_processing) {
        root.transcribeElapsedSeconds += 1
      } else {
        root.transcribeElapsedSeconds = 0
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

  Timer {
    id: copyFeedbackTimer
    interval: 2500
    running: false
    repeat: false
    onTriggered: root.copyFeedbackText = ""
  }

  Component.onCompleted: {
    root.loadSettings()
    root.loadHistory()
    root.updateStatus()
  }

  // --- BAR WIDGET BUTTON (ICON ONLY ON BAR) ---
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    horizontalMargin: 6
    verticalPadding: 4

    text: {
      if (root.stateObj.is_recording) {
        return "\udb81\uded3 " + root.formatDuration(root.elapsedSeconds)
      }
      if (root.stateObj.is_processing) {
        return "󰑮 " + root.formatDuration(root.transcribeElapsedSeconds)
      }
      return "\udb81\uded3"
    }

    onPressed: function(btn) {
      if (btn === Qt.RightButton) {
        if (root.stateObj.is_recording) {
          root.stopRecording()
        } else {
          root.startRecording(root.selectedMode || "meeting")
        }
      } else {
        root.updateStatus()
        root.loadHistory()
        popupCard.open = !popupCard.open
      }
    }
  }

  // --- MAIN POPUP WINDOW (KeyboardPanel) ---
  KeyboardPanel {
    id: popupCard
    anchorItem: button
    bar: root.bar
    owner: root
    open: false
    centerOnBar: true
    contentWidth: popupCard.fittedContentWidth(780)
    contentHeight: popupCard.fittedContentHeight(640)

    Rectangle {
      id: mainContainer
      anchors.fill: parent
      color: Color.background
      border.width: 1
      border.color: Util.alpha(Color.foreground, 0.12)
      radius: 12
      clip: true

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 12

        // ==========================================
        // HEADER BAR & SEGMENTED TAB NAVIGATION
        // ==========================================
        RowLayout {
          Layout.fillWidth: true
          spacing: 10

          // App Title with Feather Icon
          RowLayout {
            spacing: 8
            Rectangle {
              width: 32
              height: 32
              radius: 8
              color: Util.alpha(Color.accent, 0.15)
              Text {
                anchors.centerIn: parent
                text: "\udb81\uded3"
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 16
                color: Color.accent
              }
            }
            ColumnLayout {
              spacing: 0
              Text {
                text: "omaSCRIBE"
                font.family: "JetBrainsMono Nerd Font"
                font.bold: true
                font.pixelSize: Style.font.body
                color: Color.foreground
              }
              Text {
                text: "Groq LPU Audio Notes"
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 10
                color: Color.muted
              }
            }
          }

          Item { Layout.fillWidth: true }

          // Segmented Tab Controls (Nerd Font Icons + Labels)
          Rectangle {
            Layout.preferredHeight: 36
            Layout.preferredWidth: 360
            radius: 8
            color: Util.alpha(Color.foreground, 0.06)
            border.width: 1
            border.color: Util.alpha(Color.foreground, 0.10)

            RowLayout {
              anchors.fill: parent
              anchors.margins: 3
              spacing: 4

              // Tab 0: Record
              Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 6
                color: root.activeTabIndex === 0 ? Color.accent : "transparent"
                RowLayout {
                  anchors.centerIn: parent
                  spacing: 6
                  Text {
                    text: "\ued03"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 12
                    color: root.activeTabIndex === 0 ? Color.pick("background", "#1e1e2e") : Color.foreground
                  }
                  Text {
                    text: "Record"
                    font.family: "JetBrainsMono Nerd Font"
                    font.bold: true
                    font.pixelSize: Style.font.body
                    color: root.activeTabIndex === 0 ? Color.pick("background", "#1e1e2e") : Color.foreground
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.activeTabIndex = 0
                }
              }

              // Tab 1: Library
              Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 6
                color: root.activeTabIndex === 1 ? Color.accent : "transparent"
                RowLayout {
                  anchors.centerIn: parent
                  spacing: 6
                  Text {
                    text: "󰈙"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 12
                    color: root.activeTabIndex === 1 ? Color.pick("background", "#1e1e2e") : Color.foreground
                  }
                  Text {
                    text: "Library"
                    font.family: "JetBrainsMono Nerd Font"
                    font.bold: true
                    font.pixelSize: Style.font.body
                    color: root.activeTabIndex === 1 ? Color.pick("background", "#1e1e2e") : Color.foreground
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.activeTabIndex = 1
                    root.loadHistory()
                  }
                }
              }

              // Tab 2: Settings
              Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 6
                color: root.activeTabIndex === 2 ? Color.accent : "transparent"
                RowLayout {
                  anchors.centerIn: parent
                  spacing: 6
                  Text {
                    text: "󰒓"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 12
                    color: root.activeTabIndex === 2 ? Color.pick("background", "#1e1e2e") : Color.foreground
                  }
                  Text {
                    text: "Settings"
                    font.family: "JetBrainsMono Nerd Font"
                    font.bold: true
                    font.pixelSize: Style.font.body
                    color: root.activeTabIndex === 2 ? Color.pick("background", "#1e1e2e") : Color.foreground
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.activeTabIndex = 2
                }
              }
            }
          }

          // Close Button
          Rectangle {
            width: 32
            height: 32
            radius: 8
            color: closeMouse.containsMouse ? Util.alpha(Color.foreground, 0.15) : Util.alpha(Color.foreground, 0.06)
            Text {
              anchors.centerIn: parent
              text: "󰅖"
              font.family: "JetBrainsMono Nerd Font"
              font.pixelSize: 13
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

        // ==========================================
        // DISMISSIBLE ERROR BANNER
        // ==========================================
        Rectangle {
          visible: !!root.stateObj.last_error
          Layout.fillWidth: true
          Layout.preferredHeight: errCol.implicitHeight + 14
          radius: 8
          color: Util.alpha(Color.urgent, 0.12)
          border.width: 1
          border.color: Util.alpha(Color.urgent, 0.35)

          RowLayout {
            id: errCol
            anchors.fill: parent
            anchors.margins: 10
            spacing: 8

            Text {
              text: "󰅖"
              font.family: "JetBrainsMono Nerd Font"
              font.pixelSize: 14
              color: Color.urgent
            }

            Text {
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              font.family: "JetBrainsMono Nerd Font"
              font.pixelSize: 10
              color: Color.urgent
              text: root.stateObj.last_error || ""
            }

            Rectangle {
              width: 22
              height: 22
              radius: 4
              color: Util.alpha(Color.urgent, 0.2)
              Text {
                anchors.centerIn: parent
                text: "󰅖"
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 10
                color: Color.urgent
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.clearError()
              }
            }
          }
        }

        // ==========================================
        // LIVE TRANSCRIPTION HERO CARD (IN-PROGRESS)
        // ==========================================
        Rectangle {
          visible: root.stateObj.is_processing
          Layout.fillWidth: true
          Layout.preferredHeight: transCol.implicitHeight + 16
          radius: 8
          color: Util.alpha(Color.accent, 0.12)
          border.width: 1
          border.color: Color.accent

          ColumnLayout {
            id: transCol
            anchors.fill: parent
            anchors.margins: 10
            spacing: 8

            RowLayout {
              Layout.fillWidth: true
              spacing: 8

              Text {
                text: "󱐋"
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: 14
                color: Color.accent
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 1
                Text {
                  text: "Transcribing with Groq LPU (Whisper Large v3)"
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: Style.font.body
                  color: Color.foreground
                }
                Text {
                  text: root.stateObj.processing_stage || "Processing audio..."
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 10
                  color: Color.muted
                  elide: Text.ElideRight
                }
              }

              Text {
                text: root.formatDuration(root.transcribeElapsedSeconds)
                font.family: "JetBrainsMono Nerd Font"
                font.bold: true
                font.pixelSize: Style.font.body
                color: Color.accent
              }

              // Cancel Button
              Rectangle {
                width: 76
                height: 28
                radius: 5
                color: Util.alpha(Color.urgent, 0.18)
                border.width: 1
                border.color: Color.urgent
                RowLayout {
                  anchors.centerIn: parent
                  spacing: 4
                  Text { text: "󰅖"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10; color: Color.urgent }
                  Text { text: "Cancel"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: 10; color: Color.urgent }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.cancelTranscription()
                }
              }
            }

            // Pacing Progress Bar
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 6
              radius: 3
              color: Util.alpha(Color.foreground, 0.1)
              clip: true

              Rectangle {
                height: parent.height
                radius: 3
                color: Color.accent
                width: {
                  var basePct = (root.stateObj.progress_percent || 5) / 100.0
                  var est = root.stateObj.estimated_duration || 15
                  if (basePct < 0.88) {
                    var timeFrac = Math.min(0.85, 0.08 + (root.transcribeElapsedSeconds / est) * 0.77)
                    var effective = Math.max(basePct, timeFrac)
                    return Math.max(10, parent.width * Math.min(1.0, effective))
                  }
                  return Math.max(10, parent.width * Math.min(1.0, basePct))
                }
                Behavior on width {
                  NumberAnimation { duration: 300; easing.type: Easing.OutQuad }
                }
              }
            }
          }
        }

        // ==========================================
        // TAB 0: RECORD VIEW
        // ==========================================
        ColumnLayout {
          visible: root.activeTabIndex === 0
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 12

          // Active Hero Recording Card
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 110
            radius: 10
            color: root.stateObj.is_recording ? Util.alpha(Color.urgent, 0.12) : Util.alpha(Color.foreground, 0.04)
            border.width: 1
            border.color: root.stateObj.is_recording ? Color.urgent : Util.alpha(Color.foreground, 0.10)

            RowLayout {
              anchors.fill: parent
              anchors.margins: 14
              spacing: 14

              // Mode Switcher Pills (Meeting vs Voice Memo)
              ColumnLayout {
                spacing: 6
                Text {
                  text: "Recording Mode:"
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: Style.font.body
                  color: Color.foreground
                }

                RowLayout {
                  spacing: 8
                  Rectangle {
                    implicitWidth: meetingTextRow.implicitWidth + 24
                    height: 38
                    radius: 6
                    enabled: !root.stateObj.is_recording
                    color: root.selectedMode === "meeting" ? Util.alpha(Color.accent, 0.2) : Util.alpha(Color.foreground, 0.06)
                    border.width: 1
                    border.color: root.selectedMode === "meeting" ? Color.accent : "transparent"

                    RowLayout {
                      id: meetingTextRow
                      anchors.centerIn: parent
                      spacing: 6
                      Text { text: "󰋋"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13; color: root.selectedMode === "meeting" ? Color.accent : Color.muted }
                      Text { text: "Online Meeting"; font.family: "JetBrainsMono Nerd Font"; font.bold: root.selectedMode === "meeting"; font.pixelSize: Style.font.body; color: root.selectedMode === "meeting" ? Color.accent : Color.foreground }
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.selectedMode = "meeting"
                    }
                  }

                  Rectangle {
                    implicitWidth: memoTextRow.implicitWidth + 24
                    height: 38
                    radius: 6
                    enabled: !root.stateObj.is_recording
                    color: root.selectedMode === "mic" ? Util.alpha(Color.accent, 0.2) : Util.alpha(Color.foreground, 0.06)
                    border.width: 1
                    border.color: root.selectedMode === "mic" ? Color.accent : "transparent"

                    RowLayout {
                      id: memoTextRow
                      anchors.centerIn: parent
                      spacing: 6
                      Text { text: "\ued03"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13; color: root.selectedMode === "mic" ? Color.accent : Color.muted }
                      Text { text: "Voice Memo"; font.family: "JetBrainsMono Nerd Font"; font.bold: root.selectedMode === "mic"; font.pixelSize: Style.font.body; color: root.selectedMode === "mic" ? Color.accent : Color.foreground }
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.selectedMode = "mic"
                    }
                  }
                }
              }

              Item { Layout.fillWidth: true }

              // Live Timer & Status Display
              ColumnLayout {
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                spacing: 2
                Text {
                  text: root.stateObj.is_recording ? "RECORDING IN PROGRESS" : "READY TO RECORD"
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: 10
                  color: root.stateObj.is_recording ? Color.urgent : Color.muted
                }
                Text {
                  text: root.formatDuration(root.elapsedSeconds)
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: 22
                  color: root.stateObj.is_recording ? Color.urgent : Color.foreground
                }
              }

              // Primary Record / Stop Button
              Rectangle {
                width: 110
                height: 48
                radius: 8
                color: root.stateObj.is_recording ? Color.urgent : Color.accent

                RowLayout {
                  anchors.centerIn: parent
                  spacing: 6
                  Text {
                    text: root.stateObj.is_recording ? "󰓛" : "\ued03"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 14
                    color: Color.pick("background", "#1e1e2e")
                  }
                  Text {
                    text: root.stateObj.is_recording ? "Stop" : "Record"
                    font.family: "JetBrainsMono Nerd Font"
                    font.bold: true
                    font.pixelSize: Style.font.body
                    color: Color.pick("background", "#1e1e2e")
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (root.stateObj.is_recording) {
                      root.stopRecording()
                    } else {
                      root.startRecording(root.selectedMode)
                    }
                  }
                }
              }
            }
          }

          // Pre-Meeting Context Section
          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: 10
            color: Util.alpha(Color.foreground, 0.03)
            border.width: 1
            border.color: Util.alpha(Color.foreground, 0.08)

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: 12
              spacing: 10

              RowLayout {
                Layout.fillWidth: true
                Text {
                  text: "Meeting Context & Agenda (Optional)"
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: Style.font.body
                  color: Color.foreground
                }
                Item { Layout.fillWidth: true }
                Text {
                  text: "Provides AI context for speaker recognition"
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 10
                  color: Color.muted
                }
              }

              // Meeting Title
              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 36
                radius: 6
                color: Util.alpha(Color.foreground, 0.06)
                border.width: 1
                border.color: titleInput.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.12)

                TextInput {
                  id: titleInput
                  anchors.fill: parent
                  anchors.leftMargin: 10
                  anchors.rightMargin: 10
                  verticalAlignment: TextInput.AlignVCenter
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: Style.font.body
                  color: Color.foreground
                  text: root.meetingTitleText
                  onTextChanged: root.meetingTitleText = text

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Meeting Title"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: Style.font.body
                    color: Color.muted
                    visible: !titleInput.text && !titleInput.activeFocus
                  }
                }
              }

              // Agenda / Topics Input
              Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 6
                color: Util.alpha(Color.foreground, 0.06)
                border.width: 1
                border.color: topicsInput.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.12)

                ScrollView {
                  anchors.fill: parent
                  anchors.margins: 8
                  clip: true

                  TextArea {
                    id: topicsInput
                    wrapMode: Text.WordWrap
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: Style.font.body
                    color: Color.foreground
                    text: root.meetingTopicsText
                    onTextChanged: root.meetingTopicsText = text

                    Text {
                      anchors.top: parent.top
                      anchors.left: parent.left
                      text: "Agenda Topics and Notes"
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: Style.font.body
                      color: Color.muted
                      visible: !topicsInput.text && !topicsInput.activeFocus
                    }
                  }
                }
              }

              // Expected Attendees Input Row (Clean Full-Width Input)
              RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Text {
                  text: "Attendees:"
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: 11
                  color: Color.foreground
                }

                Rectangle {
                  Layout.fillWidth: true
                  Layout.preferredHeight: 34
                  radius: 6
                  color: Util.alpha(Color.foreground, 0.06)
                  border.width: 1
                  border.color: attInput.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.12)

                  TextInput {
                    id: attInput
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    selectByMouse: true
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 11
                    color: Color.foreground
                    text: root.meetingAttendeesText
                    onTextChanged: root.meetingAttendeesText = text

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Enter all Attendee Names and Male/Female to assist the transcription. Host should be first name."
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: 10
                      color: Color.muted
                      visible: !attInput.text && !attInput.activeFocus
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }
          }
        }

        // ==========================================
        // TAB 1: LIBRARY & IN-APP READER VIEW
        // ==========================================
        ColumnLayout {
          visible: root.activeTabIndex === 1
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: 10

          // ----------------------------------------------------
          // SUB-VIEW A: IN-APP NOTE & TRANSCRIPT READER
          // ----------------------------------------------------
          ColumnLayout {
            visible: root.isReaderOpen && !!root.currentReaderItem
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 10

            // ==========================================
            // READER HEADER ROW 1: Full-Width Title & Top External Actions
            // ==========================================
            RowLayout {
              Layout.fillWidth: true
              spacing: 10

              // Full-Width Title and Metadata
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Text {
                  Layout.fillWidth: true
                  text: root.currentReaderItem ? root.currentReaderItem.title : ""
                  font.family: "JetBrainsMono Nerd Font"
                  font.bold: true
                  font.pixelSize: Style.font.body + 3
                  color: Color.foreground
                  elide: Text.ElideRight
                }
                Text {
                  Layout.fillWidth: true
                  text: root.currentReaderItem ? (root.currentReaderItem.date + " • " + root.currentReaderItem.size_kb + " KB" + (root.currentReaderItem.has_notes ? " • Notes Ready" : " • Audio Only")) : ""
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 10
                  color: Color.muted
                  elide: Text.ElideRight
                }
              }

              // External Editor Button
              Rectangle {
                width: 34
                height: 34
                radius: 6
                color: edHover.containsMouse ? Util.alpha(Color.foreground, 0.15) : Util.alpha(Color.foreground, 0.08)
                Text {
                  anchors.centerIn: parent
                  text: "󰏫"
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 14
                  color: Color.foreground
                }
                ToolTip.visible: edHover.containsMouse
                ToolTip.text: "Open raw file in external editor"
                ToolTip.delay: 300
                MouseArea {
                  id: edHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (!root.currentReaderItem) return
                    var fp = root.activeReaderSubTab === 1 ? root.currentReaderItem.notes_file : root.currentReaderItem.transcript_file
                    root.openInEditor(fp || root.currentReaderItem.audio_file)
                  }
                }
              }

              // Folder Button
              Rectangle {
                width: 34
                height: 34
                radius: 6
                color: folHover.containsMouse ? Util.alpha(Color.foreground, 0.15) : Util.alpha(Color.foreground, 0.08)
                Text {
                  anchors.centerIn: parent
                  text: "󰉋"
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 14
                  color: Color.foreground
                }
                ToolTip.visible: folHover.containsMouse
                ToolTip.text: "Open folder in file manager"
                ToolTip.delay: 300
                MouseArea {
                  id: folHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (root.currentReaderItem) root.openFolder(root.currentReaderItem.folder)
                  }
                }
              }
            }

            // ==========================================
            // READER HEADER ROW 2: Library Back, Sub-Tabs & Action Toolbar
            // ==========================================
            RowLayout {
              Layout.fillWidth: true
              spacing: 8

              // Back to Library Button (On Row 2 with Sub-Tabs)
              Rectangle {
                width: 96
                height: 34
                radius: 6
                color: backHover.containsMouse ? Util.alpha(Color.foreground, 0.14) : Util.alpha(Color.foreground, 0.08)
                RowLayout {
                  anchors.centerIn: parent
                  spacing: 6
                  Text { text: "󰁍"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13; color: Color.foreground }
                  Text { text: "Library"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: Style.font.body; color: Color.foreground }
                }
                ToolTip.visible: backHover.containsMouse
                ToolTip.text: "Back to recordings list"
                ToolTip.delay: 300
                MouseArea {
                  id: backHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.isReaderOpen = false
                }
              }

              // Sub-Tabs: Transcript (0) first, then Structured Notes (1)
              Rectangle {
                Layout.preferredHeight: 34
                Layout.preferredWidth: 260
                radius: 6
                color: Util.alpha(Color.foreground, 0.08)

                RowLayout {
                  anchors.fill: parent
                  anchors.margins: 2
                  spacing: 2

                  // Sub-Tab 0: Transcript (Verbatim transcription first)
                  Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 5
                    color: root.activeReaderSubTab === 0 ? Color.accent : "transparent"
                    RowLayout {
                      anchors.centerIn: parent
                      spacing: 5
                      Text { text: "󰔊"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12; color: root.activeReaderSubTab === 0 ? Color.pick("background", "#1e1e2e") : Color.foreground }
                      Text { text: "Transcript"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: 11; color: root.activeReaderSubTab === 0 ? Color.pick("background", "#1e1e2e") : Color.foreground }
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.activeReaderSubTab = 0
                    }
                  }

                  // Sub-Tab 1: Structured Notes (Document with writing lines)
                  Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 5
                    color: root.activeReaderSubTab === 1 ? Color.accent : "transparent"
                    RowLayout {
                      anchors.centerIn: parent
                      spacing: 5
                      Text { text: "󰈙"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12; color: root.activeReaderSubTab === 1 ? Color.pick("background", "#1e1e2e") : Color.foreground }
                      Text { text: "Structured Notes"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: 11; color: root.activeReaderSubTab === 1 ? Color.pick("background", "#1e1e2e") : Color.foreground }
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.activeReaderSubTab = 1
                    }
                  }
                }
              }

              Item { Layout.fillWidth: true }

              // Copy Feedback Toast
              Text {
                visible: !!root.copyFeedbackText
                text: root.copyFeedbackText
                font.family: "JetBrainsMono Nerd Font"
                font.bold: true
                font.pixelSize: 10
                color: Color.accent
              }

              // Re-transcribe Button
              Rectangle {
                width: 120
                height: 34
                radius: 6
                color: retransHover.containsMouse ? Util.alpha(Color.foreground, 0.15) : Util.alpha(Color.foreground, 0.08)
                RowLayout {
                  anchors.centerIn: parent
                  spacing: 5
                  Text { text: "󱐋"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12; color: Color.foreground }
                  Text { text: "Re-transcribe"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: 11; color: Color.foreground }
                }
                ToolTip.visible: retransHover.containsMouse
                ToolTip.text: "Re-run Whisper transcription & AI note synthesis"
                ToolTip.delay: 300
                MouseArea {
                  id: retransHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (root.currentReaderItem) {
                      root.triggerTranscribe(root.currentReaderItem.audio_file, root.currentReaderItem.mode, root.currentReaderItem.title, "")
                    }
                  }
                }
              }

              // Copy Button
              Rectangle {
                width: 86
                height: 34
                radius: 6
                color: Util.alpha(Color.accent, 0.18)
                border.width: 1
                border.color: Color.accent
                RowLayout {
                  anchors.centerIn: parent
                  spacing: 5
                  Text { text: "󰆏"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 12; color: Color.accent }
                  Text { text: "Copy"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: 11; color: Color.accent }
                }
                ToolTip.visible: copyHover.containsMouse
                ToolTip.text: root.activeReaderSubTab === 0 ? "Copy verbatim transcript to clipboard" : "Copy structured notes to clipboard"
                ToolTip.delay: 300
                MouseArea {
                  id: copyHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    var txt = root.activeReaderSubTab === 0 ? root.activeReaderTransText : root.activeReaderNotesText
                    root.copyText(txt, root.activeReaderSubTab === 0 ? "Transcript copied" : "Notes copied")
                  }
                }
              }
            }

            // Text Reader View Box
            Rectangle {
              Layout.fillWidth: true
              Layout.fillHeight: true
              radius: 8
              color: Util.alpha(Color.foreground, 0.04)
              border.width: 1
              border.color: Util.alpha(Color.foreground, 0.10)

              ScrollView {
                anchors.fill: parent
                anchors.margins: 14
                clip: true

                TextArea {
                  readOnly: true
                  selectByMouse: true
                  wrapMode: Text.WordWrap
                  font.family: "JetBrainsMono Nerd Font"
                  font.pixelSize: 11
                  color: Color.foreground
                  text: root.activeReaderSubTab === 0 ? root.activeReaderTransText : root.activeReaderNotesText
                }
              }
            }
          }

          // ----------------------------------------------------
          // SUB-VIEW B: RECORDINGS LIST
          // ----------------------------------------------------
          ColumnLayout {
            visible: !root.isReaderOpen
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 8

            // Filter Bar & Search Box
            RowLayout {
              Layout.fillWidth: true
              spacing: 8

              // Filter Pills: All / Meetings / Memos
              Rectangle {
                Layout.preferredHeight: 32
                Layout.preferredWidth: 260
                radius: 6
                color: Util.alpha(Color.foreground, 0.06)

                RowLayout {
                  anchors.fill: parent
                  anchors.margins: 2
                  spacing: 2

                  Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 5
                    color: root.historyFilter === "all" ? Color.accent : "transparent"
                    Text {
                      anchors.centerIn: parent
                      text: "All (" + root.historyList.length + ")"
                      font.family: "JetBrainsMono Nerd Font"
                      font.bold: true
                      font.pixelSize: 10
                      color: root.historyFilter === "all" ? Color.pick("background", "#1e1e2e") : Color.foreground
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.historyFilter = "all"
                    }
                  }

                  Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 5
                    color: root.historyFilter === "meetings" ? Color.accent : "transparent"
                    Text {
                      anchors.centerIn: parent
                      text: "Meetings"
                      font.family: "JetBrainsMono Nerd Font"
                      font.bold: true
                      font.pixelSize: 10
                      color: root.historyFilter === "meetings" ? Color.pick("background", "#1e1e2e") : Color.foreground
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.historyFilter = "meetings"
                    }
                  }

                  Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: 5
                    color: root.historyFilter === "memos" ? Color.accent : "transparent"
                    Text {
                      anchors.centerIn: parent
                      text: "Memos"
                      font.family: "JetBrainsMono Nerd Font"
                      font.bold: true
                      font.pixelSize: 10
                      color: root.historyFilter === "memos" ? Color.pick("background", "#1e1e2e") : Color.foreground
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.historyFilter = "memos"
                    }
                  }
                }
              }

              // Search Bar
              Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 32
                radius: 6
                color: Util.alpha(Color.foreground, 0.06)
                border.width: 1
                border.color: searchInput.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.12)

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: 8
                  anchors.rightMargin: 8
                  spacing: 6
                  Text { text: "󰍉"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11; color: Color.muted }
                  TextInput {
                    id: searchInput
                    Layout.fillWidth: true
                    verticalAlignment: TextInput.AlignVCenter
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 11
                    color: Color.foreground
                    text: root.historySearchQuery
                    onTextChanged: root.historySearchQuery = text

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Search recordings..."
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: 11
                      color: Color.muted
                      visible: !searchInput.text && !searchInput.activeFocus
                    }
                  }
                }
              }

              // Storage Folder Button
              Rectangle {
                width: 86
                height: 32
                radius: 6
                color: Util.alpha(Color.foreground, 0.08)
                RowLayout {
                  anchors.centerIn: parent
                  spacing: 4
                  Text { text: "󰉋"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11; color: Color.foreground }
                  Text { text: "Folder"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: 11; color: Color.foreground }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openFolder()
                }
              }
            }

            // Scrollable List of Recordings
            Rectangle {
              Layout.fillWidth: true
              Layout.fillHeight: true
              radius: 8
              color: Util.alpha(Color.foreground, 0.02)
              border.width: 1
              border.color: Util.alpha(Color.foreground, 0.08)

              ScrollView {
                anchors.fill: parent
                anchors.margins: 8
                clip: true

                ListView {
                  id: historyView
                  spacing: 6
                  model: root.getFilteredHistory()

                  delegate: Rectangle {
                    id: cardDelegate
                    width: historyView.width - 4
                    height: 54
                    radius: 6
                    color: cardMouse.containsMouse ? Util.alpha(Color.foreground, 0.06) : Util.alpha(Color.foreground, 0.03)
                    border.width: 1
                    border.color: isTranscribingThis ? Color.accent : Util.alpha(Color.foreground, 0.08)

                    readonly property bool isTranscribingThis: root.stateObj.is_processing && root.stateObj.current_audio_file === modelData.audio_file

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: 10
                      anchors.rightMargin: 10
                      spacing: 8

                      // Mode Icon
                      Rectangle {
                        Layout.preferredWidth: 32
                        Layout.preferredHeight: 32
                        Layout.alignment: Qt.AlignVCenter
                        radius: 6
                        color: modelData.mode === "meeting" ? Util.alpha(Color.accent, 0.15) : Util.alpha(Color.foreground, 0.10)
                        Text {
                          anchors.centerIn: parent
                          text: modelData.mode === "meeting" ? "󰋋" : "\ued03"
                          font.family: "JetBrainsMono Nerd Font"
                          font.pixelSize: 13
                          color: modelData.mode === "meeting" ? Color.accent : Color.foreground
                        }
                      }

                      // Title & Metadata
                      ColumnLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 1
                        Text {
                          Layout.fillWidth: true
                          text: modelData.title || modelData.filename
                          font.family: "JetBrainsMono Nerd Font"
                          font.bold: true
                          font.pixelSize: Style.font.body
                          color: Color.foreground
                          elide: Text.ElideRight
                        }
                        Text {
                          Layout.fillWidth: true
                          text: modelData.date + " • " + modelData.size_kb + " KB" + (modelData.has_notes ? " • Notes Ready" : " • Audio Only")
                          font.family: "JetBrainsMono Nerd Font"
                          font.pixelSize: 10
                          color: modelData.has_notes ? Color.accent : Color.muted
                        }
                      }

                      // Perfectly Aligned 4-Button Toolbar: Transcript -> Notes -> Transcribe -> Bin
                      RowLayout {
                        Layout.preferredHeight: 32
                        Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
                        spacing: 6

                        // 1. Transcript Icon Button (32x32)
                        Rectangle {
                          Layout.preferredWidth: 32
                          Layout.preferredHeight: 32
                          Layout.alignment: Qt.AlignVCenter
                          radius: 5
                          color: modelData.has_transcript ? (transBtnArea.containsMouse ? Util.alpha(Color.foreground, 0.16) : Util.alpha(Color.foreground, 0.08)) : Util.alpha(Color.foreground, 0.04)
                          opacity: modelData.has_transcript ? 1.0 : 0.25
                          Text {
                            anchors.centerIn: parent
                            text: "󰔊"
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 13
                            color: modelData.has_transcript ? Color.foreground : Color.muted
                          }
                          ToolTip.visible: transBtnArea.containsMouse
                          ToolTip.text: modelData.has_transcript ? "View Verbatim Transcript" : "No transcript generated yet"
                          ToolTip.delay: 250
                          MouseArea {
                            id: transBtnArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: modelData.has_transcript
                            cursorShape: modelData.has_transcript ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: root.openReader(modelData, 0)
                          }
                        }

                        // 2. Structured Notes Icon Button (32x32, Page with writing lines)
                        Rectangle {
                          Layout.preferredWidth: 32
                          Layout.preferredHeight: 32
                          Layout.alignment: Qt.AlignVCenter
                          radius: 5
                          color: modelData.has_notes ? (notesBtnArea.containsMouse ? Util.alpha(Color.accent, 0.28) : Util.alpha(Color.accent, 0.16)) : Util.alpha(Color.foreground, 0.04)
                          opacity: modelData.has_notes ? 1.0 : 0.25
                          Text {
                            anchors.centerIn: parent
                            text: "󰈙"
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 13
                            color: modelData.has_notes ? Color.accent : Color.muted
                          }
                          ToolTip.visible: notesBtnArea.containsMouse
                          ToolTip.text: modelData.has_notes ? "View Structured Notes" : "No notes generated yet"
                          ToolTip.delay: 250
                          MouseArea {
                            id: notesBtnArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: modelData.has_notes
                            cursorShape: modelData.has_notes ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: root.openReader(modelData, 1)
                          }
                        }

                        // 3. Transcribe / Re-Transcribe Icon Button (32x32)
                        Rectangle {
                          Layout.preferredWidth: 32
                          Layout.preferredHeight: 32
                          Layout.alignment: Qt.AlignVCenter
                          radius: 5
                          color: isTranscribingThis
                            ? Util.alpha(Color.accent, 0.35)
                            : (!modelData.has_notes
                              ? (runTransArea.containsMouse ? Color.accent : Util.alpha(Color.accent, 0.85))
                              : (runTransArea.containsMouse ? Util.alpha(Color.foreground, 0.16) : Util.alpha(Color.foreground, 0.08)))
                          Text {
                            anchors.centerIn: parent
                            text: isTranscribingThis ? "󰑮" : "󱐋"
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 13
                            color: isTranscribingThis
                              ? Color.accent
                              : (!modelData.has_notes ? Color.pick("background", "#1e1e2e") : Color.foreground)
                          }
                          ToolTip.visible: runTransArea.containsMouse
                          ToolTip.text: isTranscribingThis ? "Transcribing in progress..." : (modelData.has_notes ? "Re-transcribe audio with Groq AI" : "Transcribe audio with Groq AI")
                          ToolTip.delay: 250
                          MouseArea {
                            id: runTransArea
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !isTranscribingThis
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.triggerTranscribe(modelData.audio_file, modelData.mode, modelData.title, "")
                          }
                        }

                        // 4. Delete Icon Button (32x32, Bin Icon)
                        Rectangle {
                          Layout.preferredWidth: 32
                          Layout.preferredHeight: 32
                          Layout.alignment: Qt.AlignVCenter
                          radius: 5
                          color: delArea.containsMouse ? Util.alpha(Color.urgent, 0.22) : Util.alpha(Color.foreground, 0.04)
                          Text {
                            anchors.centerIn: parent
                            text: "󰆴"
                            font.family: "JetBrainsMono Nerd Font"
                            font.pixelSize: 13
                            color: delArea.containsMouse ? Color.urgent : Color.muted
                          }
                          ToolTip.visible: delArea.containsMouse
                          ToolTip.text: "Delete recording and notes"
                          ToolTip.delay: 250
                          MouseArea {
                            id: delArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.deleteItem(modelData.audio_file)
                          }
                        }
                      }
                    }

                    MouseArea {
                      id: cardMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      z: -1
                      onClicked: {
                        if (modelData.has_notes || modelData.has_transcript) {
                          root.openReader(modelData)
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ==========================================
        // TAB 2: SETTINGS VIEW
        // ==========================================
        ScrollView {
          visible: root.activeTabIndex === 2
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true

          ColumnLayout {
            width: mainContainer.width - 28
            spacing: 14

            // Groq LPU Banner
            Rectangle {
              Layout.fillWidth: true
              implicitHeight: lpuBannerRow.implicitHeight + 20
              radius: 8
              color: Util.alpha(Color.accent, 0.12)
              border.width: 1
              border.color: Color.accent

              RowLayout {
                id: lpuBannerRow
                anchors.fill: parent
                anchors.margins: 12
                spacing: 10
                Text { text: "󱐋"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 20; color: Color.accent }
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 2
                  Text { text: "Groq Cloud LPU Pipeline (Free Tier)"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: Style.font.body; color: Color.foreground }
                  Text { text: "Whisper Large v3 (Audio) + Llama 3.1 70B (Synthesis) • 3-second processing"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 10; color: Color.muted; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                }
              }
            }

            // Groq API Key Input
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 6

              Text {
                text: "Groq API Key:"
                font.family: "JetBrainsMono Nerd Font"
                font.bold: true
                font.pixelSize: Style.font.body
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
                  color: Util.alpha(Color.foreground, 0.06)
                  border.width: 1
                  border.color: apiKeyInput.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.12)

                  TextInput {
                    id: apiKeyInput
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    echoMode: root.showApiKey ? TextInput.Normal : TextInput.Password
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: Style.font.body
                    color: Color.foreground
                    text: root.settingsObj.groq_api_key || ""
                    onTextChanged: root.settingsObj.groq_api_key = text

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Paste your Groq API key (gsk_...)"
                      font.family: "JetBrainsMono Nerd Font"
                      font.pixelSize: Style.font.body
                      color: Color.muted
                      visible: !apiKeyInput.text && !apiKeyInput.activeFocus
                    }
                  }
                }

                // Show/Hide Toggle
                Rectangle {
                  width: 36
                  height: 36
                  radius: 6
                  color: eyeMouse.containsMouse ? Util.alpha(Color.foreground, 0.15) : Util.alpha(Color.foreground, 0.08)
                  Text {
                    anchors.centerIn: parent
                    text: root.showApiKey ? "󰈉" : "󰈈"
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: 14
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

                // Paste Button
                Rectangle {
                  width: 80
                  height: 36
                  radius: 6
                  color: Util.alpha(Color.accent, 0.18)
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

            // Storage Folder Location
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 6

              Text {
                text: "Storage Location (Notes & Audio):"
                font.family: "JetBrainsMono Nerd Font"
                font.bold: true
                font.pixelSize: Style.font.body
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
                  color: Util.alpha(Color.foreground, 0.06)
                  border.width: 1
                  border.color: storagePathInput.activeFocus ? Color.accent : Util.alpha(Color.foreground, 0.12)

                  TextInput {
                    id: storagePathInput
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    font.family: "JetBrainsMono Nerd Font"
                    font.pixelSize: Style.font.body
                    color: Color.foreground
                    text: root.settingsObj.storage_path || (Quickshell.env("HOME") + "/Documents/AudioNotes")
                    onTextChanged: root.settingsObj.storage_path = text
                  }
                }

                Rectangle {
                  width: 96
                  height: 36
                  radius: 6
                  color: Util.alpha(Color.accent, 0.18)
                  RowLayout {
                    anchors.centerIn: parent
                    spacing: 4
                    Text { text: "󰉋"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 11; color: Color.accent }
                    Text { text: "Browse"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: 11; color: Color.accent }
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.pickDirectory()
                  }
                }
              }
            }

            // Document & Audio Format Selectors (Non-Crushed Pill Grids)
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 12

              // Document Format
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                Text { text: "Document Format:"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: Style.font.body; color: Color.foreground }
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 8
                  Repeater {
                    model: [
                      { id: "md", name: "Markdown (.md)" },
                      { id: "txt", name: "Plain (.txt)" },
                      { id: "html", name: "HTML (.html)" }
                    ]
                    Rectangle {
                      Layout.fillWidth: true
                      height: 36
                      radius: 6
                      color: root.selectedNotesFormat === modelData.id ? Util.alpha(Color.accent, 0.2) : Util.alpha(Color.foreground, 0.05)
                      border.width: 1
                      border.color: root.selectedNotesFormat === modelData.id ? Color.accent : "transparent"
                      Text {
                        anchors.centerIn: parent
                        text: modelData.name
                        font.family: "JetBrainsMono Nerd Font"
                        font.bold: root.selectedNotesFormat === modelData.id
                        font.pixelSize: 11
                        color: root.selectedNotesFormat === modelData.id ? Color.accent : Color.foreground
                      }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectedNotesFormat = modelData.id
                      }
                    }
                  }
                }
              }

              // Audio Format
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                Text { text: "Audio Codec:"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: Style.font.body; color: Color.foreground }
                RowLayout {
                  Layout.fillWidth: true
                  spacing: 8
                  Repeater {
                    model: [
                      { id: "opus", name: "Opus (Voice)" },
                      { id: "m4a", name: "AAC (.m4a)" },
                      { id: "mp3", name: "MP3 (.mp3)" }
                    ]
                    Rectangle {
                      Layout.fillWidth: true
                      height: 36
                      radius: 6
                      color: root.selectedAudioFormat === modelData.id ? Util.alpha(Color.accent, 0.2) : Util.alpha(Color.foreground, 0.05)
                      border.width: 1
                      border.color: root.selectedAudioFormat === modelData.id ? Color.accent : "transparent"
                      Text {
                        anchors.centerIn: parent
                        text: modelData.name
                        font.family: "JetBrainsMono Nerd Font"
                        font.bold: root.selectedAudioFormat === modelData.id
                        font.pixelSize: 11
                        color: root.selectedAudioFormat === modelData.id ? Color.accent : Color.foreground
                      }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectedAudioFormat = modelData.id
                      }
                    }
                  }
                }
              }
            }

            Item { Layout.preferredHeight: 6 }

            // Save Button
            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: 40
              radius: 6
              color: Color.accent
              RowLayout {
                anchors.centerIn: parent
                spacing: 6
                Text { text: "󰆓"; font.family: "JetBrainsMono Nerd Font"; font.pixelSize: 13; color: Color.pick("background", "#1e1e2e") }
                Text { text: "Save Settings"; font.family: "JetBrainsMono Nerd Font"; font.bold: true; font.pixelSize: Style.font.body; color: Color.pick("background", "#1e1e2e") }
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.settingsObj.groq_model = root.selectedGroqModel
                  root.settingsObj.storage_path = storagePathInput.text.trim()
                  root.settingsObj.notes_format = root.selectedNotesFormat
                  root.settingsObj.audio_format = root.selectedAudioFormat
                  root.settingsObj.groq_api_key = apiKeyInput.text.trim()

                  var settingsJson = JSON.stringify(root.settingsObj)
                  actionProc.command = ["python3", root.enginePath, "save-settings", settingsJson]
                  actionProc.running = true
                  root.saveFeedbackText = "✓ Settings saved"
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
              font.pixelSize: Style.font.body
              color: Color.accent
            }
          }
        }
      }
    }
  }
}
