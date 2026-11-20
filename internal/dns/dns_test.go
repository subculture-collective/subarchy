package dns

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
)

// fake stands in for the system. Output answers read-only queries from
// answers (keyed by the joined argv); Run records every change and fails the
// ones whose line starts with a key of fail, once each, and every one that
// starts with a key of stuck. Nothing here touches the host.
type fake struct {
	answers map[string]string
	fail    map[string]error
	stuck   map[string]error
	runs    []string
}

func (f *fake) Run(_ context.Context, argv ...string) error {
	line := strings.Join(argv, " ")
	f.runs = append(f.runs, line)
	for prefix, err := range f.fail {
		if strings.HasPrefix(line, prefix) {
			delete(f.fail, prefix)
			return err
		}
	}
	for prefix, err := range f.stuck {
		if strings.HasPrefix(line, prefix) {
			return err
		}
	}
	return nil
}

func (f *fake) Output(_ context.Context, argv ...string) (string, error) {
	line := strings.Join(argv, " ")
	if out, ok := f.answers[line]; ok {
		return out, nil
	}
	return "", errors.New("unexpected query: " + line)
}

func (f *fake) Has(string) bool { return true }

const readHome = "nmcli -e no -g ipv4.ignore-auto-dns,ipv6.ignore-auto-dns,ipv4.dns,ipv6.dns,connection.dns-over-tls connection show Home"

// homeProfile is a profile that uses the network's DNS, as NetworkManager
// creates it.
const homeProfile = "no\nno\n\n\n-1\n"

func TestParseMode(t *testing.T) {
	tests := []struct {
		in      string
		want    Mode
		invalid bool
	}{
		{"untrusted", Untrusted, false},
		{"trusted", Trusted, false},
		{"Trusted", "", true},
		{"", "", true},
		{"quad9", "", true},
		{"off", "", true},
	}
	for _, tt := range tests {
		t.Run(tt.in, func(t *testing.T) {
			got, err := ParseMode(tt.in)
			if tt.invalid {
				if !errors.Is(err, ErrInvalid) {
					t.Fatalf("ParseMode(%q) error = %v, want ErrInvalid", tt.in, err)
				}
				return
			}
			if err != nil || got != tt.want {
				t.Errorf("ParseMode(%q) = %q, %v; want %q", tt.in, got, err, tt.want)
			}
		})
	}
}

func TestParseServers(t *testing.T) {
	tests := []struct {
		name        string
		in          []string
		v4, v6      string
		tls         string
		wantInvalid bool
	}{
		{"none", nil, "", "", "0", false},
		{"plain LAN", []string{"10.0.0.200", "10.0.0.57"}, "10.0.0.200,10.0.0.57", "", "0", false},
		{"named", []string{"10.0.0.200#dns.home.example"}, "10.0.0.200#dns.home.example", "", "2", false},
		{"named v6", []string{"2620:fe::9#dns.quad9.net"}, "", "2620:fe::9#dns.quad9.net", "2", false},
		{"mixed names stay plaintext", []string{"10.0.0.200#dns.home.example", "10.0.0.57"}, "10.0.0.200#dns.home.example,10.0.0.57", "", "0", false},
		{"both families", []string{"10.0.0.200", "fd00::1"}, "10.0.0.200", "fd00::1", "0", false},
		{"not an address", []string{"dns.example"}, "", "", "", true},
		{"empty TLS name", []string{"10.0.0.200#"}, "", "", "", true},
		{"empty entry", []string{""}, "", "", "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v4, v6, tls, err := ParseServers(tt.in)
			if tt.wantInvalid {
				if !errors.Is(err, ErrInvalid) {
					t.Fatalf("error = %v, want ErrInvalid", err)
				}
				return
			}
			if err != nil || v4 != tt.v4 || v6 != tt.v6 || tls != tt.tls {
				t.Errorf("got %q, %q, %q, %v; want %q, %q, %q", v4, v6, tls, err, tt.v4, tt.v6, tt.tls)
			}
		})
	}
}

func TestModeOf(t *testing.T) {
	tests := []struct {
		name   string
		values string
		want   Mode
	}{
		{"untrusted", "yes\nyes\n\n\n-1\n", Untrusted},
		{"network DNS", homeProfile, Trusted},
		{"own servers", "yes\nyes\n10.0.0.200\n\n0\n", Trusted},
		{"only IPv4 ignored", "yes\nno\n\n\n-1\n", Trusted},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p, err := parseProfile("Home", tt.values)
			if err != nil {
				t.Fatal(err)
			}
			if got := ModeOf(p); got != tt.want {
				t.Errorf("ModeOf = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestParseProfileRejectsShortOutput(t *testing.T) {
	if _, err := parseProfile("Home", "yes\nyes\n"); err == nil {
		t.Error("want an error when nmcli prints fewer values than were asked for")
	}
}

func TestSwitchUntrusted(t *testing.T) {
	f := &fake{answers: map[string]string{readHome: homeProfile}}
	err := Switch(context.Background(), f, []string{"Home"}, Untrusted, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"nmcli connection modify Home ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes ipv4.dns  ipv6.dns  connection.dns-over-tls -1",
		"nmcli connection up Home",
		"resolvectl query --cache=no dns.quad9.net",
	}
	if !slices.Equal(f.runs, want) {
		t.Errorf("calls =\n%s\nwant\n%s", strings.Join(f.runs, "\n"), strings.Join(want, "\n"))
	}
}

func TestSwitchTrustedWithServers(t *testing.T) {
	f := &fake{answers: map[string]string{readHome: "yes\nyes\n\n\n-1\n"}}
	err := Switch(context.Background(), f, []string{"Home"}, Trusted, []string{"10.0.0.200", "10.0.0.57"}, false)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"nmcli connection modify Home ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes ipv4.dns 10.0.0.200,10.0.0.57 ipv6.dns  connection.dns-over-tls 0",
		"nmcli connection up Home",
	}
	if !slices.Equal(f.runs, want) {
		t.Errorf("calls =\n%s\nwant\n%s", strings.Join(f.runs, "\n"), strings.Join(want, "\n"))
	}
}

func TestSwitchTrustedNetworkDNS(t *testing.T) {
	// Without servers the network's own DNS is used, in plaintext: strict
	// DNS-over-TLS would fail against a router that does not listen on 853.
	f := &fake{answers: map[string]string{readHome: "yes\nyes\n\n\n-1\n"}}
	if err := Switch(context.Background(), f, []string{"Home"}, Trusted, nil, false); err != nil {
		t.Fatal(err)
	}
	want := "nmcli connection modify Home ipv4.ignore-auto-dns no ipv6.ignore-auto-dns no ipv4.dns  ipv6.dns  connection.dns-over-tls 0"
	if f.runs[0] != want {
		t.Errorf("first call = %q, want %q", f.runs[0], want)
	}
}

func TestSwitchRejectsBadInputBeforeAnyCall(t *testing.T) {
	tests := []struct {
		name    string
		names   []string
		mode    Mode
		servers []string
	}{
		{"unknown mode", []string{"Home"}, Mode("opportunistic"), nil},
		{"empty mode", []string{"Home"}, Mode(""), nil},
		{"servers on untrusted", []string{"Home"}, Untrusted, []string{"10.0.0.200"}},
		{"bad server", []string{"Home"}, Trusted, []string{"nope"}},
		{"no connections", nil, Untrusted, nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := &fake{}
			err := Switch(context.Background(), f, tt.names, tt.mode, tt.servers, true)
			if !errors.Is(err, ErrInvalid) {
				t.Fatalf("error = %v, want ErrInvalid", err)
			}
			if len(f.runs) != 0 {
				t.Errorf("changed the system before refusing: %v", f.runs)
			}
		})
	}
}

func TestSwitchLeavesNothingChangedWhenReadFails(t *testing.T) {
	f := &fake{} // no answer for the read
	err := Switch(context.Background(), f, []string{"Home"}, Untrusted, nil, true)
	if err == nil {
		t.Fatal("want an error")
	}
	if len(f.runs) != 0 {
		t.Errorf("changed the system without a saved copy of the old settings: %v", f.runs)
	}
}

func TestSwitchRestoresOnFailure(t *testing.T) {
	restore := "nmcli connection modify Home ipv4.ignore-auto-dns no ipv6.ignore-auto-dns no ipv4.dns  ipv6.dns  connection.dns-over-tls -1"
	tests := []struct {
		name string
		fail map[string]error
		want []string
	}{
		{
			"lookup fails after the switch",
			map[string]error{"resolvectl query": errors.New("no answer")},
			[]string{"nmcli connection modify Home ipv4.ignore-auto-dns yes", "nmcli connection up Home", "resolvectl query", restore, "nmcli connection up Home"},
		},
		{
			"reactivation fails",
			map[string]error{"nmcli connection up Home": errors.New("activation failed")},
			[]string{"nmcli connection modify Home ipv4.ignore-auto-dns yes", "nmcli connection up Home", restore, "nmcli connection up Home"},
		},
		{
			"modify fails",
			map[string]error{"nmcli connection modify Home ipv4.ignore-auto-dns yes": errors.New("denied")},
			[]string{"nmcli connection modify Home ipv4.ignore-auto-dns yes", restore, "nmcli connection up Home"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			f := &fake{answers: map[string]string{readHome: homeProfile}, fail: tt.fail}
			err := Switch(context.Background(), f, []string{"Home"}, Untrusted, nil, true)
			if err == nil || !strings.Contains(err.Error(), "restored") {
				t.Fatalf("error = %v, want one that says the old settings were restored", err)
			}
			if len(f.runs) != len(tt.want) {
				t.Fatalf("calls =\n%s\nwant %d calls starting\n%s", strings.Join(f.runs, "\n"), len(tt.want), strings.Join(tt.want, "\n"))
			}
			for i, w := range tt.want {
				if !strings.HasPrefix(f.runs[i], w) {
					t.Errorf("call %d = %q, want prefix %q", i, f.runs[i], w)
				}
			}
		})
	}
}

func TestSwitchReportsWhenRestoreFailsToo(t *testing.T) {
	f := &fake{
		answers: map[string]string{readHome: homeProfile},
		fail:    map[string]error{"resolvectl query": errors.New("no answer")},
		stuck:   map[string]error{"nmcli connection up Home": errors.New("link down")},
	}
	err := Switch(context.Background(), f, []string{"Home"}, Untrusted, nil, true)
	if err == nil || !strings.Contains(err.Error(), "could not restore") {
		t.Fatalf("error = %v, want one that says the restore failed", err)
	}
}

func TestSwitchRestoresEveryConnection(t *testing.T) {
	readWork := strings.Replace(readHome, "Home", "Work", 1)
	f := &fake{
		answers: map[string]string{readHome: homeProfile, readWork: "no\nno\n10.1.0.1\n\n0\n"},
		fail:    map[string]error{"nmcli connection up Work": errors.New("activation failed")},
	}
	err := Switch(context.Background(), f, []string{"Home", "Work"}, Untrusted, nil, false)
	if err == nil {
		t.Fatal("want an error")
	}
	var restoredHome, restoredWork bool
	for _, r := range f.runs {
		restoredHome = restoredHome || strings.HasPrefix(r, "nmcli connection modify Home ipv4.ignore-auto-dns no")
		restoredWork = restoredWork || strings.HasPrefix(r, "nmcli connection modify Work ipv4.ignore-auto-dns no ipv6.ignore-auto-dns no ipv4.dns 10.1.0.1")
	}
	if !restoredHome || !restoredWork {
		t.Errorf("both connections should be restored; calls:\n%s", strings.Join(f.runs, "\n"))
	}
}

func TestActiveConnections(t *testing.T) {
	out := "Debian: LAN:802-3-ethernet\ntailscale0:tun\nCafe WiFi:802-11-wireless\nbr0:bridge\nlo:loopback\nVPN:wireguard\n"
	f := &fake{answers: map[string]string{"nmcli -t -e no -f NAME,TYPE connection show --active": out}}
	got, err := Active(context.Background(), f)
	if err != nil {
		t.Fatal(err)
	}
	// Escaping is off, so a colon in a name stays; only the last one splits.
	want := []string{"Debian: LAN", "Cafe WiFi"}
	if !slices.Equal(got, want) {
		t.Errorf("Active = %q, want %q", got, want)
	}
}

func TestStatusNamesTheModeOfEachConnection(t *testing.T) {
	f := &fake{answers: map[string]string{
		"nmcli -t -e no -f NAME,TYPE connection show --active": "Home:802-3-ethernet\nCafe:802-11-wireless\n",
		readHome: homeProfile,
		strings.Replace(readHome, "Home", "Cafe", 1): "yes\nyes\n\n\n-1\n",
		"resolvectl dns": "Global: 9.9.9.9#dns.quad9.net\n",
	}}
	got, err := Status(context.Background(), f)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Home: trusted", "Cafe: untrusted", "9.9.9.9#dns.quad9.net"} {
		if !strings.Contains(got, want) {
			t.Errorf("status lacks %q:\n%s", want, got)
		}
	}
}
