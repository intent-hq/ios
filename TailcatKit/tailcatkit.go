// Package tailcatkit is a small gomobile-friendly wrapper around
// github.com/tailscale/tailcat for the Intent iOS app.
//
// It exposes only gomobile bind compatible types (int, string, []byte,
// error, and exported struct pointers): dial a tailcat token to get a
// connected byte stream, or start a local loopback forwarder that pipes
// a 127.0.0.1 TCP port to a remote port over the tunnel.
package tailcatkit

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/types/logger"
)

// Client connects to a tailcat server identified by its connection
// token (the "tc..." string). The underlying tunnel is established
// lazily by the first dial or ping.
type Client struct {
	c *tailcat.Client
}

// NewClient returns a client for the server identified by token.
func NewClient(token string) *Client {
	c := tailcat.NewClient(tailcat.ConnBlob(token))
	c.Logf = logger.Discard
	return &Client{c: c}
}

// Ping performs a relay round-trip to the server, verifying
// reachability. timeoutMs bounds the whole operation, including
// first-use tunnel establishment; <=0 means 30s.
//
// Single-value returns keep the gomobile Swift projection clean
// (multi-value returns surface as pointer out-parameters).
func (c *Client) Ping(timeoutMs int) error {
	ctx, cancel := timeoutCtx(timeoutMs)
	defer cancel()
	_, err := c.c.Ping(ctx)
	return err
}

// Dial opens a TCP connection to the given port on the server and
// returns the connected byte stream. timeoutMs bounds connection
// establishment (not later reads/writes); <=0 means 30s.
func (c *Client) Dial(port int, timeoutMs int) (*Conn, error) {
	if port <= 0 || port > 65535 {
		return nil, fmt.Errorf("tailcatkit: invalid port %d", port)
	}
	ctx, cancel := timeoutCtx(timeoutMs)
	defer cancel()
	nc, err := c.c.DialTCPPort(ctx, uint16(port))
	if err != nil {
		return nil, err
	}
	return &Conn{nc: nc}, nil
}

// Forward starts a loopback listener on an ephemeral 127.0.0.1 port and
// pipes each accepted connection to remotePort on the server over the
// tunnel. Use Forwarder.Port to find the local port to connect to.
func (c *Client) Forward(remotePort int) (*Forwarder, error) {
	if remotePort <= 0 || remotePort > 65535 {
		return nil, fmt.Errorf("tailcatkit: invalid port %d", remotePort)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	f := &Forwarder{ln: ln}
	go f.serve(c.c, uint16(remotePort))
	return f, nil
}

// Close shuts down the client and its tunnel.
func (c *Client) Close() error { return c.c.Close() }

// Conn is a connected byte stream over the tunnel.
type Conn struct {
	nc net.Conn
}

// Read reads up to maxLen bytes (<=0 means 32 KiB). It blocks until
// some data is available and returns an empty slice at end of stream.
func (c *Conn) Read(maxLen int) ([]byte, error) {
	if maxLen <= 0 {
		maxLen = 32 * 1024
	}
	buf := make([]byte, maxLen)
	n, err := c.nc.Read(buf)
	if err != nil {
		if errors.Is(err, io.EOF) {
			return []byte{}, nil
		}
		return nil, err
	}
	return buf[:n], nil
}

// Write writes all of data to the stream.
func (c *Conn) Write(data []byte) error {
	_, err := c.nc.Write(data)
	return err
}

// SetDeadlineMs sets a deadline for future reads and writes, in
// milliseconds from now. <=0 clears the deadline.
func (c *Conn) SetDeadlineMs(ms int) error {
	if ms <= 0 {
		return c.nc.SetDeadline(time.Time{})
	}
	return c.nc.SetDeadline(time.Now().Add(time.Duration(ms) * time.Millisecond))
}

// Close closes the stream.
func (c *Conn) Close() error { return c.nc.Close() }

// Forwarder is a local loopback listener piping connections to a
// remote port over the tunnel.
type Forwarder struct {
	ln net.Listener
}

// Port returns the local 127.0.0.1 port the forwarder listens on.
func (f *Forwarder) Port() int {
	return f.ln.Addr().(*net.TCPAddr).Port
}

// Close stops the forwarder. In-flight connections are not closed.
func (f *Forwarder) Close() error { return f.ln.Close() }

func (f *Forwarder) serve(c *tailcat.Client, remotePort uint16) {
	for {
		local, err := f.ln.Accept()
		if err != nil {
			return
		}
		go pipe(local, c, remotePort)
	}
}

func pipe(local net.Conn, c *tailcat.Client, remotePort uint16) {
	defer local.Close()
	ctx, cancel := timeoutCtx(0)
	defer cancel()
	remote, err := c.DialTCPPort(ctx, remotePort)
	if err != nil {
		return
	}
	defer remote.Close()
	done := make(chan struct{}, 2)
	go func() { io.Copy(remote, local); done <- struct{}{} }()
	go func() { io.Copy(local, remote); done <- struct{}{} }()
	<-done
}

func timeoutCtx(timeoutMs int) (context.Context, context.CancelFunc) {
	d := 30 * time.Second
	if timeoutMs > 0 {
		d = time.Duration(timeoutMs) * time.Millisecond
	}
	return context.WithTimeout(context.Background(), d)
}
