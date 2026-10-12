package httpapi

import (
	"net"
	"net/http"
	"net/netip"
)

// IPv6 privacy addresses in one /64 share a quota; mapped IPv4 uses IPv4 rules.
func sourceNetwork(raw string) string {
	addr, e := netip.ParseAddr(raw)
	if e != nil {
		return "unknown"
	}
	addr = addr.Unmap()
	if addr.Is6() {
		return netip.PrefixFrom(addr, 64).Masked().String()
	}
	return addr.String()
}

// Only the directly connected, configured proxy may supply a client address.
// The ingress must overwrite X-Real-IP; X-Forwarded-For is never trusted here.
func (s *Server) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return "unknown"
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return "unknown"
	}
	addr = addr.Unmap()
	for _, network := range s.trustedProxies {
		if network.Contains(addr) {
			if forwarded, err := netip.ParseAddr(r.Header.Get("X-Real-IP")); err == nil {
				return forwarded.Unmap().String()
			}
			break
		}
	}
	return addr.String()
}
