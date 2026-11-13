package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"git.subcult.tv/subculture-collective/subarchy/internal/setup"
)

// managedObjects is what `busctl --json=short call net.connman.iwd /
// org.freedesktop.DBus.ObjectManager GetManagedObjects` prints on a laptop
// with one Wi-Fi card that is not connected (trimmed to the properties
// the installer reads).
const managedObjects = `{"type":"a{oa{sa{sv}}}","data":[{` +
	`"/net/connman/iwd":{"net.connman.iwd.AgentManager":{}},` +
	`"/net/connman/iwd/0":{"net.connman.iwd.Adapter":{"Powered":{"type":"b","data":true},"Name":{"type":"s","data":"phy0"}}},` +
	`"/net/connman/iwd/0/4":{"net.connman.iwd.Device":{"Name":{"type":"s","data":"wlan0"},"Powered":{"type":"b","data":true},"Mode":{"type":"s","data":"station"}},` +
	`"net.connman.iwd.Station":{"State":{"type":"s","data":"disconnected"},"Scanning":{"type":"b","data":false}}},` +
	`"/net/connman/iwd/0/4/486f6d65204e6574_psk":{"net.connman.iwd.Network":{"Name":{"type":"s","data":"Home Net"},"Connected":{"type":"b","data":false},"Device":{"type":"o","data":"/net/connman/iwd/0/4"},"Type":{"type":"s","data":"psk"}}},` +
	`"/net/connman/iwd/0/4/43616665_open":{"net.connman.iwd.Network":{"Name":{"type":"s","data":"Cafe"},"Connected":{"type":"b","data":false},"Device":{"type":"o","data":"/net/connman/iwd/0/4"},"Type":{"type":"s","data":"open"}}},` +
	`"/net/connman/iwd/0/4/556e69_8021x":{"net.connman.iwd.Network":{"Name":{"type":"s","data":"Uni"},"Connected":{"type":"b","data":false},"Device":{"type":"o","data":"/net/connman/iwd/0/4"},"Type":{"type":"s","data":"8021x"}}}` +
	`}]}`

// orderedNetworks is Station.GetOrderedNetworks for the same card.
const orderedNetworks = `{"type":"a(on)","data":[[["/net/connman/iwd/0/4/486f6d65204e6574_psk",-5400],` +
	`["/net/connman/iwd/0/4/556e69_8021x",-6500],["/net/connman/iwd/0/4/43616665_open",-8100]]]}`

// fakeIwd answers the installer's busctl and iwctl calls. Connecting
// marks the network connected and the link online.
type fakeIwd struct {
	t         *testing.T
	objects   map[string]map[string]map[string]variant
	online    bool
	failJoins int      // joins to refuse before one succeeds
	joins     []string // "device name security passphrase"
	scans     int
}

func newFakeIwd(t *testing.T) *fakeIwd {
	var reply struct {
		Data []iwdObjects `json:"data"`
	}
	if err := json.Unmarshal([]byte(managedObjects), &reply); err != nil {
		t.Fatal(err)
	}
	return &fakeIwd{t: t, objects: reply.Data[0]}
}

func (f *fakeIwd) busctl(args ...string) ([]byte, error) {
	switch args[len(args)-1] {
	case "GetManagedObjects":
		data, _ := json.Marshal(map[string]any{"type": "a{oa{sa{sv}}}", "data": []any{f.objects}})
		return data, nil
	case "Scan":
		f.scans++
		return nil, nil
	case "GetOrderedNetworks":
		return []byte(orderedNetworks), nil
	}
	f.t.Fatalf("unexpected busctl call %v", args)
	return nil, nil
}

func (f *fakeIwd) join(device, name, security, passphrase string) error {
	f.joins = append(f.joins, strings.Join([]string{device, name, security, passphrase}, " "))
	if f.failJoins > 0 {
		f.failJoins--
		return errors.New("exit status 1")
	}
	for path, ifaces := range f.objects {
		if n, ok := ifaces[iwdService+".Network"]; ok && str(n, "Name") == name {
			f.connect(path)
		}
	}
	f.online = true
	return nil
}

// connect puts the card on the network at path, as a join by hand would.
func (f *fakeIwd) connect(path string) {
	f.objects["/net/connman/iwd/0/4"][iwdService+".Station"]["ConnectedNetwork"] = variant{Type: "o", Data: json.RawMessage(`"` + path + `"`)}
	f.objects[path][iwdService+".Network"]["Connected"] = variant{Type: "b", Data: json.RawMessage("true")}
}

func (f *fakeIwd) wifi(dir string) *wifi {
	return &wifi{busctl: f.busctl, join: f.join, online: func() bool { return f.online }, dir: dir,
		sleep: func(time.Duration) {}, typed: map[string]string{}}
}

func TestWiFiScanAndNeeded(t *testing.T) {
	f := newFakeIwd(t)
	w := f.wifi(t.TempDir())
	if !w.needed() {
		t.Fatal("no network page with no link up and a Wi-Fi card")
	}
	nets, err := w.scan()
	if err != nil || f.scans != 1 {
		t.Fatalf("scan: %v, %d scans", err, f.scans)
	}
	var rows []string
	for _, n := range nets {
		rows = append(rows, strings.Join(strings.Fields(n.row()), " "))
	}
	if want := "Home Net password strong|Uni 802.1X good|Cafe open weak"; strings.Join(rows, "|") != want {
		t.Errorf("rows %q, want %q", strings.Join(rows, "|"), want)
	}
	// A link that is up, a card without a station (switched off) and no
	// iwd at all each mean no page.
	f.online = true
	if w.needed() {
		t.Error("network page with a link up")
	}
	f.online = false
	delete(f.objects["/net/connman/iwd/0/4"], iwdService+".Station")
	if w.needed() {
		t.Error("network page with no station")
	}
	w.busctl = func(...string) ([]byte, error) { return nil, errors.New("not running") }
	if w.needed() {
		t.Error("network page without iwd")
	}
	var nilWiFi *wifi
	if nilWiFi.needed() {
		t.Error("network page without Wi-Fi")
	}
}

// pickRows lets a scripted gum answer "<row:prefix>" with the first list
// entry that starts with prefix.
func pickRows(t *testing.T, s *screens) {
	real := s.gum
	s.gum = func(args ...string) (string, int) {
		out, code := real(args...)
		if p, ok := strings.CutPrefix(out, "<row:"); ok {
			for i, a := range args {
				if strings.HasPrefix(a, strings.TrimSuffix(p, ">")) && (i == 0 || args[i-1] != "--selected") {
					return a, code
				}
			}
			t.Fatalf("no row for %s in %v", out, args)
		}
		return out, code
	}
}

func TestScreensNetwork(t *testing.T) {
	e := testEnv(t)
	f := newFakeIwd(t)
	f.failJoins = 1
	e.wifi = f.wifi(t.TempDir())
	s, g, out := testScreens(t,
		"English (US)", "English (US)", // language, keyboard
		"<row:Uni>",               // 802.1X: refused
		"<row:Home Net>", "short", // passphrase too short
		"wrong-pass-1",            // refused by the network
		"<row:Home Net>", "<esc>", // Escape at the passphrase: back to the list
		"<row:Home Net>", "home-secret-42", // joins
		"UTC", "pat", "secret-one", "secret-one", "box", "", // account and machine
		"<row:/dev/vda>", "Install here", "", "", // disk, summary, erase
	)
	pickRows(t, s)
	e.screens = s
	dir := filepath.Join(t.TempDir(), "conf")
	var stdout bytes.Buffer
	if code := run([]string{"--dir", dir, "--dry-run"}, strings.NewReader(""), &stdout, e, nil, nil); code != 0 {
		t.Fatalf("exit %d:\n%s\n%s", code, stdout.String(), out.String())
	}
	if len(g.answers) != 0 {
		t.Errorf("unused answers: %v", g.answers)
	}
	if want := "wlan0 Home Net psk wrong-pass-1|wlan0 Home Net psk home-secret-42"; strings.Join(f.joins, "|") != want {
		t.Errorf("joins %q", f.joins)
	}
	conf, _ := os.ReadFile(filepath.Join(dir, "install.conf"))
	psk, _ := os.ReadFile(filepath.Join(dir, "wifi-psk"))
	if !strings.Contains(string(conf), "WIFI_SSID=Home Net\n") || string(psk) != "home-secret-42\n" {
		t.Errorf("config:\n%s\npsk %q", conf, psk)
	}
	screen := ansi.ReplaceAllString(out.String(), "")
	for _, want := range []string{networkTitle, "Uni needs an 802.1X sign-in", "A Wi-Fi passphrase has 8 to 63 characters",
		"Could not join Home Net. Check the passphrase", "Wi-Fi network    Home Net (joined at first boot)", networkSkip} {
		if !strings.Contains(screen+callText(g), want) {
			t.Errorf("screens lack %q", want)
		}
	}
	if strings.Contains(screen, "home-secret-42") || strings.Contains(screen, "wrong-pass-1") {
		t.Error("a Wi-Fi passphrase is on the screen")
	}
	if !strings.Contains(callText(g), "input --prompt Passphrase>  --placeholder The network's password") ||
		!strings.Contains(callText(g), "--password") {
		t.Error("the passphrase is not asked as a hidden input")
	}
}

func TestScreensNetworkSkip(t *testing.T) {
	e := testEnv(t)
	f := newFakeIwd(t)
	e.wifi = f.wifi(t.TempDir())
	s, g, _ := testScreens(t, "English (US)", "English (US)", networkSkip,
		"UTC", "pat", "secret-one", "secret-one", "box", "", "<row:/dev/vda>", "Install here", "", "")
	pickRows(t, s)
	e.screens = s
	dir := filepath.Join(t.TempDir(), "conf")
	var stdout bytes.Buffer
	if code := run([]string{"--dir", dir, "--dry-run"}, strings.NewReader(""), &stdout, e, nil, nil); code != 0 {
		t.Fatalf("exit %d:\n%s", code, stdout.String())
	}
	conf, _ := os.ReadFile(filepath.Join(dir, "install.conf"))
	if strings.Contains(string(conf), "WIFI_") || len(f.joins) != 0 || len(g.answers) != 0 {
		t.Errorf("skipped, yet joined %v or wrote:\n%s", f.joins, conf)
	}
}

// With a link up the page is not shown, and Escape from the step after it
// goes on back to the keyboard rather than stopping at the skipped page.
func TestScreensNetworkSkippedBothWays(t *testing.T) {
	e := testEnv(t)
	f := newFakeIwd(t)
	f.online = true
	e.wifi = f.wifi(t.TempDir())
	s, g, out := testScreens(t, "English (US)", "English (US)", "<esc>", "<esc>", "<esc>")
	keys := []bool{true, false}
	s.key = func() bool { k := keys[0]; keys = keys[1:]; return k }
	e.screens = s
	var stdout bytes.Buffer
	if code := run([]string{"--dir", t.TempDir()}, strings.NewReader(""), &stdout, e, nil, nil); code != 1 {
		t.Fatalf("exit %d", code)
	}
	var headers []string
	for _, c := range g.calls {
		for i, a := range c {
			if a == "--header" {
				headers = append(headers, c[i+1])
			}
		}
	}
	if want := "Language|Keyboard layout|Time zone|Keyboard layout|Language"; strings.Join(headers, "|") != want {
		t.Errorf("screens %q, want %q", strings.Join(headers, "|"), want)
	}
	if strings.Contains(out.String(), networkTitle) || f.scans != 0 {
		t.Error("the network page showed with a link up")
	}
}

func TestPlainNetwork(t *testing.T) {
	e := testEnv(t)
	f := newFakeIwd(t)
	e.wifi = f.wifi(t.TempDir())
	// After the keyboard: network 1, a short passphrase, network 1 again
	// with a good one; then the usual answers.
	rest := strings.TrimPrefix(goodInput, "de-latin1\n")
	input := "de-latin1\n9\n1\nshort\n1\nhome-secret-42\n" + rest + "y\n"
	dir := filepath.Join(t.TempDir(), "conf")
	var out bytes.Buffer
	if code := run([]string{"--dir", dir, "--dry-run"}, strings.NewReader(input), &out, e, nil, nil); code != 0 {
		t.Fatalf("exit %d:\n%s", code, out.String())
	}
	conf, _ := os.ReadFile(filepath.Join(dir, "install.conf"))
	if !strings.Contains(string(conf), "WIFI_SSID=Home Net\n") {
		t.Errorf("config:\n%s", conf)
	}
	for _, want := range []string{"1) Home Net", "enter a network number, r or s", "8 to 63 characters", "Joining Home Net...",
		"Wi-Fi     Home Net (joined at first boot)"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("output lacks %q", want)
		}
	}
	// --batch never asks.
	f = newFakeIwd(t)
	e.wifi = f.wifi(t.TempDir())
	out.Reset()
	if code := run([]string{"--dir", t.TempDir(), "--dry-run", "--batch"}, strings.NewReader(goodInput+"y\n"), &out, e, nil, nil); code != 0 || f.scans != 0 {
		t.Errorf("batch: exit %d, %d scans:\n%s", code, f.scans, out.String())
	}
}

// A network joined by hand before the installer started is carried over
// with the key iwd saved for it.
func TestCarryWiFi(t *testing.T) {
	dir := t.TempDir()
	f := newFakeIwd(t)
	w := f.wifi(dir)
	var a setup.Answers
	if note := carryWiFi(&a, w); note != "" || a.WiFiSSID != "" {
		t.Errorf("not connected, yet carried %q (%s)", a.WiFiSSID, note)
	}
	f.connect("/net/connman/iwd/0/4/486f6d65204e6574_psk")
	if note := carryWiFi(&a, w); a.WiFiSSID != "" || !strings.Contains(note, "key for Home Net was not found") {
		t.Errorf("no key file, yet carried %q (%s)", a.WiFiSSID, note)
	}
	os.WriteFile(filepath.Join(dir, "Home Net.psk"), []byte("[Security]\nPreSharedKey="+strings.Repeat("ab", 32)+"\nPassphrase=home-secret-42\n"), 0o600)
	if note := carryWiFi(&a, w); note != "" || a.WiFiSSID != "Home Net" || a.WiFiPSK != "home-secret-42" {
		t.Errorf("carried %q %q (%s)", a.WiFiSSID, a.WiFiPSK, note)
	}
	// iwd keeps only the derived key when it was given that.
	os.WriteFile(filepath.Join(dir, "Home Net.psk"), []byte("[Security]\nPreSharedKey="+strings.Repeat("ab", 32)+"\n"), 0o600)
	if carryWiFi(&a, w); a.WiFiPSK != strings.Repeat("ab", 32) {
		t.Errorf("psk %q", a.WiFiPSK)
	}
	// A passphrase typed in the installer wins over the file.
	w.typed["Home Net"] = "typed-secret-1"
	if carryWiFi(&a, w); a.WiFiPSK != "typed-secret-1" {
		t.Errorf("psk %q", a.WiFiPSK)
	}
	f = newFakeIwd(t)
	w = f.wifi(dir)
	f.connect("/net/connman/iwd/0/4/43616665_open")
	if note := carryWiFi(&a, w); note != "" || a.WiFiSSID != "Cafe" || a.WiFiPSK != "" {
		t.Errorf("open network: %q %q (%s)", a.WiFiSSID, a.WiFiPSK, note)
	}
	f.connect("/net/connman/iwd/0/4/556e69_8021x")
	delete(f.objects["/net/connman/iwd/0/4/43616665_open"], iwdService+".Network")
	if note := carryWiFi(&a, w); a.WiFiSSID != "" || !strings.Contains(note, "will not join Uni") {
		t.Errorf("802.1X: %q (%s)", a.WiFiSSID, note)
	}
}

func TestIwdFile(t *testing.T) {
	for ssid, want := range map[string]string{"Home Net": "Home Net.psk", "my_net-5G": "my_net-5G.psk",
		"Café": "=436166c3a9.psk", "a.b": "=612e62.psk"} {
		if got := iwdFile(ssid, "psk"); got != want {
			t.Errorf("iwdFile(%q) = %q, want %q", ssid, got, want)
		}
	}
}

func TestHasDefaultRoute(t *testing.T) {
	dir := t.TempDir()
	write := func(name, text string) string {
		p := filepath.Join(dir, name)
		os.WriteFile(p, []byte(text), 0o644)
		return p
	}
	const head = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n"
	v4 := write("route", head+"wlan0\t00000000\t0100000A\t0003\t0\t0\t600\t00000000\t0\t0\t0\n")
	v4local := write("route-local", head+"wlan0\t0000000A\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0\n")
	// The kernel's reject route on lo is no way out.
	v6none := write("ipv6-none", "00000000000000000000000000000000 00 00000000000000000000000000000000 00 00000000000000000000000000000000 ffffffff 00000001 00000000 00200200       lo\n")
	v6 := write("ipv6", "00000000000000000000000000000000 00 00000000000000000000000000000000 00 fe800000000000000000000000000001 00000400 00000001 00000000 00450003    wlan0\n")
	missing := filepath.Join(dir, "missing")
	for _, c := range []struct {
		v4, v6 string
		want   bool
	}{{v4, missing, true}, {v4local, v6none, false}, {missing, v6, true}, {missing, missing, false}} {
		if got := hasDefaultRoute(c.v4, c.v6); got != c.want {
			t.Errorf("hasDefaultRoute(%s, %s) = %v", filepath.Base(c.v4), filepath.Base(c.v6), got)
		}
	}
}
