import QtQuick
import QtTest
import "../Model.js" as Model

TestCase {
  name: "Tailscale"

  // Trimmed from `tailscale status --json` (1.104).
  readonly property string signedIn: JSON.stringify({
    Version: "1.104.7",
    BackendState: "Running",
    AuthURL: "",
    TailscaleIPs: ["100.64.0.1", "fd7a:115c:a1e0::1"],
    Self: { ID: "n1", HostName: "sputnik", DNSName: "sputnik.tail1234.ts.net.", OS: "linux", TailscaleIPs: ["100.64.0.1", "fd7a:115c:a1e0::1"], Online: true },
    CurrentTailnet: { Name: "subcult.example", MagicDNSSuffix: "tail1234.ts.net" },
    Peer: {
      "nodekey:a": { ID: "n2", HostName: "kvant", DNSName: "kvant.tail1234.ts.net.", OS: "linux", TailscaleIPs: ["100.64.0.2"], Online: true, ExitNodeOption: true, ExitNode: true, TaildropTarget: 1 },
      "nodekey:b": { ID: "n3", HostName: "Phone", DNSName: "", OS: "iOS", TailscaleIPs: ["fd7a:115c:a1e0::3", "100.64.0.3"], Online: false, TaildropTarget: 5 },
      "nodekey:c": { ID: "n4", HostName: "almaz", DNSName: "almaz.tail1234.ts.net.", OS: "linux", TailscaleIPs: ["100.64.0.4"], Online: true, TaildropTarget: 9 }
    }
  })

  readonly property string signedOut: JSON.stringify({
    BackendState: "NeedsLogin", AuthURL: "", TailscaleIPs: null,
    Self: { ID: "", HostName: "fresh", DNSName: "", TailscaleIPs: null, TaildropTarget: 0 }, Health: ["Tailscale is stopped."]
  })

  function test_parse() {
    compare(Model.parse("nope"), null)
    compare(Model.parse("{}"), null)
    const s = Model.parse(signedIn)
    verify(s.running)
    verify(!s.needsLogin)
    compare(s.tailnet, "subcult.example")
    compare(s.self.name, "sputnik")
    compare(s.self.ip, "100.64.0.1")
    compare(s.self.ipv6, "fd7a:115c:a1e0::1")
    compare(s.self.dnsName, "sputnik.tail1234.ts.net")
    compare(s.exitNode.name, "kvant")
  }

  function test_peersOnlineFirstThenByName() {
    const s = Model.parse(signedIn)
    compare(s.peers.map(p => p.name), ["almaz", "kvant", "Phone"])
    compare(Model.online(s).length, 2)
    compare(Model.online(null), [])
  }

  function test_peerFields() {
    const s = Model.parse(signedIn)
    const phone = s.peers[2]
    compare(phone.ip, "100.64.0.3", "the IPv4 address, whatever the order")
    compare(phone.name, "Phone", "the host name without a MagicDNS name")
    verify(!phone.taildrop)
    verify(s.peers[1].taildrop)
    verify(!s.peers[0].taildrop, "another user's machine takes no files")
    verify(s.peers[1].exitNodeOption)
  }

  function test_signedOut() {
    const s = Model.parse(signedOut)
    verify(s.needsLogin)
    verify(!s.running)
    compare(s.peers, [])
    compare(s.self.ip, "")
    compare(s.exitNode, null)
    compare(Model.stateText(s, false), "Signed out")
    compare(Model.tooltip(s, false), "Tailscale: Signed out")
    const withUrl = Model.parse(JSON.stringify({ BackendState: "NeedsLogin", AuthURL: "https://login.tailscale.com/a/abc" }))
    compare(withUrl.authUrl, "https://login.tailscale.com/a/abc")
  }

  function test_text() {
    const s = Model.parse(signedIn)
    compare(Model.stateText(s, false), "Connected")
    compare(Model.stateText(null, true), "The Tailscale service is not running")
    compare(Model.stateText(Model.parse('{"BackendState": "Stopped"}'), false), "Off")
    compare(Model.tooltip(s, false), "Tailscale: Connected\nsputnik 100.64.0.1\n2 machines online\nExit node: kvant")
    compare(Model.tooltip(null, false), "Tailscale: unknown")
  }

  function test_commandOutput() {
    compare(Model.loginUrl("\thttps://login.tailscale.com/a/gd13d0bed525528e"), "https://login.tailscale.com/a/gd13d0bed525528e")
    compare(Model.loginUrl("To authenticate, visit:"), "")
    verify(Model.accessDenied("Access denied: checkprefs access denied"))
    verify(!Model.accessDenied("timeout waiting"))
    verify(Model.daemonDown("failed to connect to local tailscaled; it doesn't appear to be running"))
    compare(Model.errorText("Access denied: prefs write access denied\n\nUse 'sudo tailscale down'.\nTo not require root, use 'sudo tailscale set --operator=$USER' once.\n"),
      "Access denied: prefs write access denied")
    compare(Model.errorText(""), "")
  }

  function test_commands() {
    const s = Model.parse(signedIn)
    compare(Model.exitNodeCommand(s.peers[1]), ["tailscale", "set", "--exit-node=100.64.0.2"])
    compare(Model.exitNodeCommand(null), ["tailscale", "set", "--exit-node="])
    compare(Model.sendTarget(s.peers[0]), "almaz")
    compare(Model.sendTarget({ name: "", ip: "100.64.0.9" }), "100.64.0.9")
  }
}
