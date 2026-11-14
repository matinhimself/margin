package zlibrary

import (
	"context"
	"crypto/sha1"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const proofSeed = "0123456789ABCDEF0123456789ABCDEF01234567"

func proofPage() string {
	sum := sha1.Sum([]byte(proofSeed + "0"))
	return fmt.Sprintf(`<title>Checking your browser ...</title><script>const c='%s';let n1=parseInt('0x'+c[0x0]);if((s[n1]===0x%x)&&(s[n1+0x1]===0x%x)){document.cookie='c_token=';document.cookie='c_time=';}</script>`, proofSeed, sum[0], sum[1])
}
func TestMirrorProof(t *testing.T) {
	token, elapsed, ok := mirrorProof(context.Background(), []byte(proofPage()))
	if !ok || token != proofSeed+"0" || elapsed == "" {
		t.Fatal("valid proof was not solved")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, ok := mirrorProof(ctx, []byte(proofPage())); ok {
		t.Fatal("ignored cancellation")
	}
	if _, _, ok := mirrorProof(context.Background(), []byte(`<script>arbitrary code</script>`)); ok {
		t.Fatal("accepted an unknown challenge")
	}
}
func TestVerificationCookiesAndPOSTReplay(t *testing.T) {
	attempts := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/" {
			w.Write([]byte("Library"))
			return
		}
		attempts++
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), "email=reader") {
			t.Error("login body was lost")
		}
		token, err := r.Cookie("c_token")
		if err != nil {
			w.Header().Set("Content-Type", "text/html")
			http.SetCookie(w, &http.Cookie{Name: "bsrv", Value: "session", Path: "/"})
			w.WriteHeader(503)
			w.Write([]byte(proofPage()))
			return
		}
		if token.Value != proofSeed+"0" {
			t.Error("incorrect proof cookie")
		}
		for _, name := range []string{"bsrv", "c_time"} {
			if _, err := r.Cookie(name); err != nil {
				t.Errorf("missing %s cookie", name)
			}
		}
		w.Write([]byte(`{"errors":[],"response":{"user_id":42,"user_key":"session-key"}}`))
	}))
	defer server.Close()
	c := New(WithMirror(server.URL))
	if err := c.Login(context.Background(), "reader", "password"); err != nil {
		t.Fatal(err)
	}
	if !c.LoggedIn() || attempts != 2 {
		t.Fatal(c.LoggedIn(), attempts)
	}
}
func TestVerificationRetriesAreBounded(t *testing.T) {
	attempts := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts++
		w.Header().Set("Content-Type", "text/html")
		w.WriteHeader(503)
		w.Write([]byte(proofPage()))
	}))
	defer server.Close()
	c := New(WithMirror(server.URL))
	if err := c.Login(context.Background(), "reader", "password"); err == nil || attempts != 3 {
		t.Fatal(err, attempts)
	}
}
func TestLoginRejectsMissingOrFailedConfirmation(t *testing.T) {
	for _, body := range []string{`{}`, `{"response":{}}`, `{"response":{"validationError":true}}`, `{"errors":["invalid password"],"response":{"user_id":42,"user_key":"key"}}`} {
		t.Run(body, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/" {
					w.Write([]byte("Library"))
					return
				}
				w.Write([]byte(body))
			}))
			defer server.Close()
			c := New(WithMirror(server.URL))
			if err := c.Login(context.Background(), "reader", "password"); err == nil || c.LoggedIn() {
				t.Fatal("accepted failed login")
			}
		})
	}
}
func TestLiteralMirrorCookie(t *testing.T) {
	body := []byte(`<title>Access Denied | DiamWall</title><script>document.cookie="dwid=0123456789abcdef0123456789abcdef; path=/";</script>`)
	if literalMirrorCookie(body) != "0123456789abcdef0123456789abcdef" {
		t.Fatal("literal cookie not recognized")
	}
	if literalMirrorCookie([]byte(`<script>document.cookie="dwid=0123456789abcdef0123456789abcdef;"</script>`)) != "" {
		t.Fatal("accepted unrelated script")
	}
}
