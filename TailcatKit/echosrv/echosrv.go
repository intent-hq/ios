// Package echosrv is an in-process tailcat echo server used by the
// TailcatKit tests and cmd/tcecho. It lives outside the root package
// on purpose: gomobile bind exports the whole bound package, so
// keeping the server side here keeps it out of the shipped
// xcframework's API surface and binary.
package echosrv

import (
	"net"

	"github.com/tailscale/tailcat"
	"tailscale.com/types/logger"
)

// Server is an in-process tailcat listener that echoes bytes back on
// every TCP port. It exists to support the iOS smoke test, which
// dials it through a Client and exchanges bytes over a real tunnel
// (relayed via DERP) without needing an external daemon.
type Server struct {
	s *tailcat.Server
}

// Start starts an in-process echo server with a fresh ephemeral key
// and returns it. Requires network access to a DERP relay. Note that
// a tailcat client in the same process cannot reach it through the
// public DERP relays; dial it from another process (or device), as
// the iOS smoke test does via cmd/tcecho.
func Start() (*Server, error) {
	return StartWith(&tailcat.Server{Logf: logger.Discard})
}

// StartWith starts an echo server on a caller-configured
// tailcat.Server (e.g. one pointed at an in-process test DERP
// region). The server's OnTCP handler is replaced.
func StartWith(s *tailcat.Server) (*Server, error) {
	s.OnTCP = func(port uint16) func(net.Conn) {
		return func(c net.Conn) {
			defer c.Close()
			buf := make([]byte, 32*1024)
			for {
				n, err := c.Read(buf)
				if n > 0 {
					if _, werr := c.Write(buf[:n]); werr != nil {
						return
					}
				}
				if err != nil {
					return
				}
			}
		}
	}
	if err := s.Start(); err != nil {
		return nil, err
	}
	return &Server{s: s}, nil
}

// Token returns the connection token clients dial to reach this server.
func (e *Server) Token() string { return string(e.s.ConnBlob()) }

// Close shuts the server down.
func (e *Server) Close() error { return e.s.Close() }
