// Package dns implements `subcult dns` (ADR 0020): show and change the DNS
// trust of NetworkManager connections.
//
// A connection is untrusted (the default policy: the network's DNS is
// ignored and lookups go to the system resolver's Quad9 over strict
// DNS-over-TLS) or trusted (the network's DNS, or servers the user names).
// The package changes NetworkManager connection settings only. The resolved
// configuration under /usr/lib/systemd/resolved.conf.d is not touched, and
// nothing here makes a newly joined network untrusted or handles captive
// portals; those need the dispatcher the ADR describes.
package dns

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"strings"

	"git.subcult.tv/subculture-collective/subarchy/internal/update"
)

// ErrInvalid marks a request that was refused before anything changed.
var ErrInvalid = errors.New("invalid DNS request")

// Mode is a DNS trust setting from ADR 0020.
type Mode string

const (
	Untrusted Mode = "untrusted"
	Trusted   Mode = "trusted"
)

// Modes lists the modes the command accepts.
var Modes = []Mode{Untrusted, Trusted}

// checkHost is looked up after a switch to see that the resolver still
// answers. It is Quad9's own name, which every mode can resolve.
const checkHost = "dns.quad9.net"

// ParseMode accepts the exact mode names and refuses anything else.
func ParseMode(s string) (Mode, error) {
	for _, m := range Modes {
		if string(m) == s {
			return m, nil
		}
	}
	return "", fmt.Errorf("%w: unknown mode %q (use untrusted or trusted)", ErrInvalid, s)
}

// The NetworkManager properties that make up the trust setting, in the order
// they are read and written.
var props = []string{"ipv4.ignore-auto-dns", "ipv6.ignore-auto-dns", "ipv4.dns", "ipv6.dns", "connection.dns-over-tls"}

// Profile is the trust-related part of one NetworkManager connection, as
// nmcli prints it.
type Profile struct {
	Name   string
	Values []string // one per props entry
}

func parseProfile(name, out string) (Profile, error) {
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if len(lines) != len(props) {
		return Profile{}, fmt.Errorf("connection %q: nmcli printed %d values, want %d", name, len(lines), len(props))
	}
	return Profile{Name: name, Values: lines}, nil
}

// ModeOf reports whether the connection ignores the network's DNS and has no
// servers of its own (untrusted) or not (trusted).
func ModeOf(p Profile) Mode {
	if p.Values[0] == "yes" && p.Values[1] == "yes" && p.Values[2] == "" && p.Values[3] == "" {
		return Untrusted
	}
	return Trusted
}

// ParseServers splits addresses (each optionally "address#tls-name") into the
// IPv4 and IPv6 lists nmcli takes and chooses the DNS-over-TLS value: strict
// (2) when every server has a TLS name, off (0) otherwise, since strict TLS
// to a server that does not speak it would break lookups.
func ParseServers(servers []string) (v4, v6, tls string, err error) {
	var a4, a6 []string
	named := 0
	for _, s := range servers {
		addr, name, hasName := strings.Cut(s, "#")
		if _, perr := netip.ParseAddr(addr); perr != nil {
			return "", "", "", fmt.Errorf("%w: %q is not an IP address, optionally followed by #tls-name", ErrInvalid, s)
		}
		if hasName {
			if name == "" {
				return "", "", "", fmt.Errorf("%w: %q has an empty TLS name", ErrInvalid, s)
			}
			named++
		}
		if strings.Contains(addr, ":") {
			a6 = append(a6, s)
		} else {
			a4 = append(a4, s)
		}
	}
	tls = "0"
	if len(servers) > 0 && named == len(servers) {
		tls = "2"
	}
	return strings.Join(a4, ","), strings.Join(a6, ","), tls, nil
}

// Read returns the trust settings of one connection.
func Read(ctx context.Context, r update.Runner, name string) (Profile, error) {
	out, err := r.Output(ctx, "nmcli", "-e", "no", "-g", strings.Join(props, ","), "connection", "show", name)
	if err != nil {
		return Profile{}, fmt.Errorf("read connection %q: %w", name, err)
	}
	return parseProfile(name, out)
}

// Active lists the active Wi-Fi and Ethernet connections.
func Active(ctx context.Context, r update.Runner) ([]string, error) {
	out, err := r.Output(ctx, "nmcli", "-t", "-e", "no", "-f", "NAME,TYPE", "connection", "show", "--active")
	if err != nil {
		return nil, fmt.Errorf("list active connections: %w", err)
	}
	var names []string
	for _, line := range strings.Split(out, "\n") {
		i := strings.LastIndex(line, ":")
		if i < 0 {
			continue
		}
		switch line[i+1:] {
		case "802-11-wireless", "802-3-ethernet", "wifi", "ethernet":
			names = append(names, line[:i])
		}
	}
	return names, nil
}

func modifyArgs(name string, values []string) []string {
	argv := []string{"nmcli", "connection", "modify", name}
	for i, p := range props {
		argv = append(argv, p, values[i])
	}
	return argv
}

// Target validates a mode and its servers and returns the props values a
// connection gets in that mode. It makes no system call, so callers can
// refuse bad input before reading anything.
func Target(mode Mode, servers []string) ([]string, error) {
	if _, err := ParseMode(string(mode)); err != nil {
		return nil, err
	}
	if mode == Untrusted {
		if len(servers) > 0 {
			return nil, fmt.Errorf("%w: --dns applies to trusted connections only", ErrInvalid)
		}
		return []string{"yes", "yes", "", "", "-1"}, nil
	}
	v4, v6, tls, err := ParseServers(servers)
	if err != nil {
		return nil, err
	}
	ignore := "no"
	if len(servers) > 0 {
		ignore = "yes"
	}
	return []string{ignore, ignore, v4, v6, tls}, nil
}

// Switch puts the named connections in mode and checks that names still
// resolve. Input is validated before any change. If any step fails, every
// connection goes back to the settings read at the start and is reactivated,
// so a failed switch leaves the resolver as it was. check=false skips the
// lookup (for use without a network).
func Switch(ctx context.Context, r update.Runner, names []string, mode Mode, servers []string, check bool) error {
	target, err := Target(mode, servers)
	if err != nil {
		return err
	}
	if len(names) == 0 {
		return fmt.Errorf("%w: no connection to change", ErrInvalid)
	}

	old := make([]Profile, 0, len(names))
	for _, n := range names {
		p, err := Read(ctx, r, n)
		if err != nil {
			return err
		}
		old = append(old, p)
	}

	if err := apply(ctx, r, names, target, check); err != nil {
		var rerr error
		for _, p := range old {
			if e := r.Run(ctx, modifyArgs(p.Name, p.Values)...); e != nil {
				rerr = errors.Join(rerr, e)
				continue
			}
			if e := r.Run(ctx, "nmcli", "connection", "up", p.Name); e != nil {
				rerr = errors.Join(rerr, e)
			}
		}
		if rerr != nil {
			return fmt.Errorf("%w; could not restore the old settings: %w", err, rerr)
		}
		return fmt.Errorf("%w; the old DNS settings are restored", err)
	}
	return nil
}

func apply(ctx context.Context, r update.Runner, names, target []string, check bool) error {
	for _, n := range names {
		if err := r.Run(ctx, modifyArgs(n, target)...); err != nil {
			return err
		}
	}
	for _, n := range names {
		if err := r.Run(ctx, "nmcli", "connection", "up", n); err != nil {
			return err
		}
	}
	if check {
		if err := r.Run(ctx, "resolvectl", "query", "--cache=no", checkHost); err != nil {
			return fmt.Errorf("lookup after the switch failed: %w", err)
		}
	}
	return nil
}

var tlsNames = map[string]string{"-1": "default (resolved's setting)", "0": "off", "1": "opportunistic", "2": "strict"}

// Status describes the trust mode of each active connection and the DNS
// servers resolved is using.
func Status(ctx context.Context, r update.Runner) (string, error) {
	names, err := Active(ctx, r)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	if len(names) == 0 {
		b.WriteString("No active Wi-Fi or Ethernet connection.\n")
	}
	for _, n := range names {
		p, err := Read(ctx, r, n)
		if err != nil {
			return "", err
		}
		m := ModeOf(p)
		detail := "network DNS"
		switch {
		case m == Untrusted:
			detail = "network DNS ignored, system resolver"
		case p.Values[2] != "" || p.Values[3] != "":
			detail = "servers " + strings.Trim(p.Values[2]+","+p.Values[3], ",")
		}
		tls := tlsNames[p.Values[4]]
		if tls == "" {
			tls = p.Values[4]
		}
		fmt.Fprintf(&b, "%s: %s (%s), DNS-over-TLS %s\n", n, m, detail, tls)
	}
	if out, err := r.Output(ctx, "resolvectl", "dns"); err == nil {
		b.WriteString("\nresolved DNS servers:\n")
		for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
			b.WriteString("  " + l + "\n")
		}
	}
	return b.String(), nil
}
