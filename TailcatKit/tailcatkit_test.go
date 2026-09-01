package tailcatkit

import (
	"bytes"
	"io"
	"net"
	"strconv"
	"testing"
	"time"

	"github.com/tailscale/tailcat"
	"tailscale.com/tstest/integration"
	"tailscale.com/types/logger"
)

// newEchoPair starts an in-process echo server and a client connected
// to it, rendezvousing over an in-process DERP+STUN on 127.0.0.1
// (an in-process pair cannot meet over the public relays, which see
// both sides behind one socket).
func newEchoPair(t *testing.T) (*EchoServer, *Client) {
	t.Helper()
	dm := integration.RunDERPAndSTUN(t, logger.Discard, "127.0.0.1")
	srv, err := startEchoServer(&tailcat.Server{Logf: logger.Discard, Region: dm.Regions[1]})
	if err != nil {
		t.Fatalf("startEchoServer: %v", err)
	}
	t.Cleanup(func() { srv.Close() })
	cl := NewClient(srv.Token())
	t.Cleanup(func() { cl.Close() })
	// Warm up with retried pings: the registration ping is a single
	// DERP packet with no retransmit, so it can race the server's DERP
	// registration and get dropped. Once one ping succeeds the client
	// is registered and later dials don't ping again.
	for i := 0; i < 5; i++ {
		if err = cl.Ping(2_000); err == nil {
			return srv, cl
		}
	}
	t.Fatalf("warm-up Ping: %v", err)
	return nil, nil
}

func TestDialEcho(t *testing.T) {
	_, cl := newEchoPair(t)

	conn, err := cl.Dial(4711, 60_000)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	defer conn.Close()

	msg := []byte("hello tailcatkit")
	if err := conn.Write(msg); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if err := conn.SetDeadlineMs(60_000); err != nil {
		t.Fatalf("SetDeadlineMs: %v", err)
	}
	var got []byte
	for len(got) < len(msg) {
		chunk, err := conn.Read(len(msg) - len(got))
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		if len(chunk) == 0 {
			break
		}
		got = append(got, chunk...)
	}
	if !bytes.Equal(got, msg) {
		t.Fatalf("echo = %q, want %q", got, msg)
	}
}

func TestPing(t *testing.T) {
	_, cl := newEchoPair(t)

	if err := cl.Ping(60_000); err != nil {
		t.Fatalf("Ping: %v", err)
	}
}

func TestForwarder(t *testing.T) {
	_, cl := newEchoPair(t)

	fwd, err := cl.Forward(4712)
	if err != nil {
		t.Fatalf("Forward: %v", err)
	}
	defer fwd.Close()
	if fwd.Port() <= 0 {
		t.Fatalf("Port = %d, want > 0", fwd.Port())
	}

	nc, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(fwd.Port())), 10*time.Second)
	if err != nil {
		t.Fatalf("dial forwarder: %v", err)
	}
	defer nc.Close()
	nc.SetDeadline(time.Now().Add(60 * time.Second))

	msg := []byte("via forwarder")
	if _, err := nc.Write(msg); err != nil {
		t.Fatalf("Write: %v", err)
	}
	got := make([]byte, len(msg))
	if _, err := io.ReadFull(nc, got); err != nil {
		t.Fatalf("Read: %v", err)
	}
	if !bytes.Equal(got, msg) {
		t.Fatalf("echo = %q, want %q", got, msg)
	}
}

// TestForwarderHalfClose covers the request/response pattern where the
// client sends its request, half-closes its write side, and still expects
// the full response: the forwarder must not tear down the reverse
// direction when the client→remote copy finishes.
func TestForwarderHalfClose(t *testing.T) {
	_, cl := newEchoPair(t)

	fwd, err := cl.Forward(4713)
	if err != nil {
		t.Fatalf("Forward: %v", err)
	}
	defer fwd.Close()

	nc, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(fwd.Port())), 10*time.Second)
	if err != nil {
		t.Fatalf("dial forwarder: %v", err)
	}
	defer nc.Close()
	nc.SetDeadline(time.Now().Add(60 * time.Second))

	msg := []byte("request then half-close")
	if _, err := nc.Write(msg); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if err := nc.(*net.TCPConn).CloseWrite(); err != nil {
		t.Fatalf("CloseWrite: %v", err)
	}
	got, err := io.ReadAll(nc)
	if err != nil {
		t.Fatalf("ReadAll: %v", err)
	}
	if !bytes.Equal(got, msg) {
		t.Fatalf("echo = %q, want %q", got, msg)
	}
}

func TestInvalidPort(t *testing.T) {
	cl := NewClient("tc-invalid-token")
	defer cl.Close()
	if _, err := cl.Dial(0, 1000); err == nil {
		t.Fatal("Dial(0) succeeded, want error")
	}
	if _, err := cl.Forward(70000); err == nil {
		t.Fatal("Forward(70000) succeeded, want error")
	}
}
