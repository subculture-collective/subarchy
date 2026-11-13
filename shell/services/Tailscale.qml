pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../widgets/tailscale/Model.js" as Model

// Tailscale (ADR 0058), shared by the bar widget and its panel. The status
// comes from `tailscale status --json` when the widget's timer fires, when
// the panel opens and after each action; nothing else polls. The user is
// tailscaled's operator (set at install), so up, down, sign-in and the exit
// node need no password.
Singleton {
  id: root

  property var status: null
  // false once the command is missing: the widget leaves the bar.
  property bool installed: true
  property bool daemonDown: false
  // The last action's error, for the panel.
  property string error: ""
  // tailscaled refused the last action: the user is not its operator.
  property bool needsOperator: false
  // The sign-in link while `tailscale up` waits for the browser.
  property string loginUrl: ""
  readonly property bool signingIn: login.running
  readonly property bool busy: action.running || login.running

  // A refresh asked for while a read is under way runs after it: that read
  // may have started before the change the caller wants to see.
  function refresh() {
    if (query.running)
      query.again = true
    else
      query.running = true
  }

  function run(argv) {
    if (action.running)
      return
    root.error = ""
    action.command = argv
    action.running = true
  }

  // Signed out, `tailscale up` prints a link and waits until the browser
  // finishes; signed in, it reconnects with the settings it had. No flags:
  // any flag would make it re-check every setting against its defaults.
  function up() {
    if (login.running)
      return
    root.error = ""
    root.needsOperator = false
    root.loginUrl = ""
    login.cancelled = false
    login.errText = ""
    login.running = true
  }

  function cancelSignIn() {
    login.cancelled = true
    login.running = false
  }

  function down() {
    root.run(["tailscale", "down"])
  }

  function setExitNode(peer) {
    root.run(Model.exitNodeCommand(peer))
  }

  // For a user added after the install: an administrator's password through
  // polkit, once. tailscaled has one operator, so this takes the role from
  // any other account that has it.
  function becomeOperator() {
    root.run(["pkexec", "tailscale", "set", "--operator=" + Quickshell.env("USER")])
  }

  function copy(text) {
    if (text !== "")
      Quickshell.clipboardText = text
  }

  // The file picker and the transfer belong to `subcult tailscale send`,
  // which reports the result as a notification.
  function send(peer) {
    Quickshell.execDetached(Model.sendCommand(peer))
  }

  function openLogin() {
    if (root.loginUrl !== "")
      Quickshell.execDetached(["uwsm-app", "--", "xdg-open", root.loginUrl])
  }

  onStatusChanged: {
    const running = root.status !== null && root.status.running
    // Signed in: the Taildrop receiver stops waiting and fetches now. The
    // shell's first read counts too: the receiver may have gone to sleep
    // while tailscaled was still connecting at login. A restart during a
    // copy loses nothing; the receiver drops the half-copied file and
    // tailscaled hands it over again.
    if (running && !query.wasRunning)
      Quickshell.execDetached(["systemctl", "--user", "try-restart", "subcult-tailscale-receive.service"])
    query.wasRunning = running
    if (running)
      root.loginUrl = ""
  }

  Process {
    id: query
    property bool wasRunning: false
    property bool again: false
    // Exit 127 without the command, so a missing package hides the widget.
    command: ["sh", "-c", "command -v tailscale >/dev/null || exit 127; exec tailscale status --json"]
    stdout: StdioCollector {
      id: queryOut
    }
    stderr: StdioCollector {
      id: queryErr
    }
    onExited: (code) => {
      root.installed = code !== 127
      const s = Model.parse(queryOut.text)
      root.daemonDown = s === null && Model.daemonDown(queryErr.text)
      root.status = s
      if (query.again) {
        query.again = false
        Qt.callLater(root.refresh)
      }
    }
  }

  Process {
    id: action
    stderr: StdioCollector {
      id: actionErr
    }
    onExited: (code) => {
      root.needsOperator = code !== 0 && Model.needsOperator(actionErr.text)
      root.error = code === 0 || root.needsOperator ? "" : Model.errorText(actionErr.text)
      root.refresh()
    }
  }

  Process {
    id: login
    property bool cancelled: false
    // What `tailscale up` printed besides the link, for the error.
    property string errText: ""
    command: ["tailscale", "up"]
    stderr: SplitParser {
      onRead: (line) => {
        const url = Model.loginUrl(line)
        if (url !== "" && root.loginUrl === "") {
          root.loginUrl = url
          root.openLogin()
        }
        if (Model.needsOperator(line))
          root.needsOperator = true
        login.errText += line + "\n"
      }
    }
    onExited: (code) => {
      if (code !== 0 && !login.cancelled && !root.needsOperator && root.loginUrl === "")
        root.error = Model.errorText(login.errText) || "tailscale up failed (exit " + code + ")"
      root.loginUrl = ""
      root.refresh()
    }
  }

  IpcHandler {
    target: "subcult.tailscale"
    function refresh(): void { root.refresh() }
    function signIn(): void { root.up() }
    function cancelSignIn(): void { root.cancelSignIn() }
    function state(): string {
      return JSON.stringify({ installed: root.installed, daemonDown: root.daemonDown,
        state: root.status ? root.status.state : "", loginUrl: root.loginUrl,
        self: root.status ? root.status.self : null, peers: root.status ? root.status.peers.length : 0 })
    }
  }
}
