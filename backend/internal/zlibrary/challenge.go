package zlibrary

import (
	"bytes"
	"context"
	"crypto/sha1" // The mirror specifies SHA-1 for its proof-of-work, not for authentication.
	"encoding/hex"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	challengeSeed   = regexp.MustCompile(`["']([A-Fa-f0-9]{40})["']`)
	challengeFirst  = regexp.MustCompile(`s\[n1\]\s*===\s*0x([A-Fa-f0-9]{1,2})\b`)
	challengeSecond = regexp.MustCompile(`s\[n1\+0x1\]\s*===\s*0x([A-Fa-f0-9]{1,2})\b`)
)

// mirrorProof recognizes the mirror’s bounded SHA-1 cookie challenge.
// It never evaluates downloaded JavaScript or loads scripts from other origins.
func mirrorProof(ctx context.Context, body []byte) (string, string, bool) {
	if !bytes.Contains(body, []byte("Checking your browser")) || !bytes.Contains(body, []byte("c_token=")) || !bytes.Contains(body, []byte("c_time=")) || !bytes.Contains(body, []byte("parseInt('0x'+c[0x0])")) {
		return "", "", false
	}
	seed := challengeSeed.FindSubmatch(body)
	first, second := challengeFirst.FindSubmatch(body), challengeSecond.FindSubmatch(body)
	if len(seed) != 2 || len(first) != 2 || len(second) != 2 {
		return "", "", false
	}
	offset, err := strconv.ParseUint(string(seed[1][:1]), 16, 8)
	if err != nil {
		return "", "", false
	}
	a, _ := strconv.ParseUint(string(first[1]), 16, 8)
	b, _ := strconv.ParseUint(string(second[1]), 16, 8)
	started := time.Now()
	for nonce := 0; nonce < 1<<24; nonce++ {
		if nonce%4096 == 0 {
			if ctx.Err() != nil || time.Since(started) > 10*time.Second {
				return "", "", false
			}
		}
		token := strconv.AppendInt(append([]byte{}, seed[1]...), int64(nonce), 10)
		digest := sha1.Sum(token)
		if digest[offset] == byte(a) && digest[offset+1] == byte(b) {
			return string(token), strconv.FormatFloat(time.Since(started).Seconds(), 'f', 6, 64), true
		}
	}
	return "", "", false
}

// do retains the same TLS profile, proxy and cookie jar throughout verification.
// Only a recognized cookie challenge is retried; ordinary failures return once.
func (c *Client) do(req *http.Request) (*http.Response, error) {
	for attempt := 0; attempt < 3; attempt++ {
		current := req.Clone(req.Context())
		if attempt > 0 && req.Body != nil {
			if req.GetBody == nil {
				return nil, ErrAccessChallenge
			}
			body, err := req.GetBody()
			if err != nil {
				return nil, err
			}
			current.Body = body
		}
		resp, err := c.http.Do(current)
		if err != nil {
			return nil, err
		}
		if resp.StatusCode != 503 && resp.StatusCode != 517 {
			return resp, nil
		}
		if !strings.Contains(strings.ToLower(resp.Header.Get("Content-Type")), "text/html") {
			return resp, nil
		}
		body, err := io.ReadAll(io.LimitReader(resp.Body, (1<<20)+1))
		resp.Body.Close()
		if err != nil {
			return nil, err
		}
		if len(body) > 1<<20 {
			return nil, ErrAccessChallenge
		}
		target := resp.Request.URL
		token, elapsed, ok := mirrorProof(req.Context(), body)
		if ok && attempt < 2 {
			c.http.Jar.SetCookies(target, []*http.Cookie{
				{Name: "c_token", Value: token, Path: "/", Secure: target.Scheme == "https"},
				{Name: "c_time", Value: elapsed, Path: "/", Secure: target.Scheme == "https"},
			})
			continue
		}
		// Some gateway responses use a literal JavaScript cookie before the proof.
		if match := literalMirrorCookie(body); match != "" && attempt < 2 {
			c.http.Jar.SetCookies(target, []*http.Cookie{{Name: "dwid", Value: match, Path: "/", Secure: target.Scheme == "https"}})
			continue
		}
		if bytes.Contains(body, []byte("Checking your browser")) || bytes.Contains(body, []byte("DiamWall")) {
			return nil, ErrAccessChallenge
		}
		resp.Body = io.NopCloser(bytes.NewReader(body))
		return resp, nil
	}
	return nil, ErrAccessChallenge
}

var mirrorCookie = regexp.MustCompile(`document\.cookie\s*=\s*["']dwid=([a-fA-F0-9]{32});`)

func literalMirrorCookie(body []byte) string {
	if !bytes.Contains(body, []byte("DiamWall")) {
		return ""
	}
	match := mirrorCookie.FindSubmatch(body)
	if len(match) != 2 {
		return ""
	}
	// Reject malformed values rather than accepting arbitrary script assignments.
	if _, err := hex.DecodeString(string(match[1])); err != nil {
		return ""
	}
	return string(match[1])
}
