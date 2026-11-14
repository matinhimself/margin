package zlibrary

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestBrowserTransportUsesChromeClientHello(t *testing.T) {
	listener, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	listener.SetDeadline(time.Now().Add(5 * time.Second))
	hellos := make(chan []byte, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			hellos <- nil
			return
		}
		defer conn.Close()
		conn.SetReadDeadline(time.Now().Add(5 * time.Second))
		header := make([]byte, 5)
		if _, err = io.ReadFull(conn, header); err != nil {
			hellos <- nil
			return
		}
		body := make([]byte, int(binary.BigEndian.Uint16(header[3:5])))
		if _, err = io.ReadFull(conn, body); err != nil {
			hellos <- nil
			return
		}
		hellos <- body
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	transport := newBrowserTransport("")
	defer transport.CloseIdleConnections()
	req, _ := http.NewRequestWithContext(ctx, "GET", "https://"+listener.Addr().String(), nil)
	if resp, err := transport.RoundTrip(req); err == nil {
		resp.Body.Close()
		t.Fatal("expected server to stop after ClientHello")
	}
	hello := <-hellos
	if len(hello) < 40 || hello[0] != 1 {
		t.Fatal("missing TLS ClientHello")
	}
	offset := 4 + 2 + 32
	offset += 1 + int(hello[offset])
	if offset+4 > len(hello) {
		t.Fatal("truncated cipher suites")
	}
	cipher := binary.BigEndian.Uint16(hello[offset+2 : offset+4])
	// Chrome places a GREASE value first; Go standard TLS does not.
	if byte(cipher>>8) != byte(cipher) || cipher&0x0f0f != 0x0a0a {
		t.Fatalf("missing Chrome GREASE cipher: %04x", cipher)
	}
}
func TestBrowserTransportUsesConfiguredProxy(t *testing.T) {
	connected := make(chan struct{}, 1)
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connected <- struct{}{}
		if r.Method != "CONNECT" || r.Host != "example.test:443" {
			t.Errorf("unexpected proxy request %s %s", r.Method, r.Host)
		}
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer proxy.Close()
	transport := newBrowserTransport(proxy.URL)
	defer transport.CloseIdleConnections()
	req, _ := http.NewRequest("GET", "https://example.test/", nil)
	if resp, err := transport.RoundTrip(req); err == nil {
		resp.Body.Close()
		t.Fatal("expected proxy rejection")
	}
	select {
	case <-connected:
	default:
		t.Fatal("proxy was not used")
	}
}
