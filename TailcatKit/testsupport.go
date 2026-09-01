package tailcatkit

import (
	"net"

	"github.com/tailscale/tailcat"
	"tailscale.com/types/logger"
)

// EchoServer is an in-process tailcat listener that echoes bytes back
// on every TCP port. It exists to support the iOS smoke test, which
// dials it through a Client and exchanges bytes over a real tunnel
// (relayed via DERP) without needing an external daemon.
type EchoServer struct {
	s *tailcat.Server
}

// StartEchoServer starts an in-process echo server with a fresh
// ephemeral key and returns it. Requires network access to a DERP
// relay. Note that a tailcat client in the same process cannot reach
// it through the public DERP relays; dial it from another process (or
// device), as the iOS smoke test does via cmd/tcecho.
func StartEchoServer() (*EchoServer, error) {
	return startEchoServer(&tailcat.Server{Logf: logger.Discard})
}

func startEchoServer(s *tailcat.Server) (*EchoServer, error) {
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
	return &EchoServer{s: s}, nil
}

// Token returns the connection token clients dial to reach this server.
func (e *EchoServer) Token() string { return string(e.s.ConnBlob()) }

// Close shuts the server down.
func (e *EchoServer) Close() error { return e.s.Close() }
