package zlibrary

import (
	"fmt"
	"net/http"

	fhttp "github.com/bogdanfinn/fhttp"
	tlsclient "github.com/bogdanfinn/tls-client"
	"github.com/bogdanfinn/tls-client/profiles"
)

// browserTransport supplies a consistent Chrome TLS and HTTP/2 profile. The
// outer net/http.Client owns cookies, redirects and request cancellation.
type browserTransport struct {
	client tlsclient.HttpClient
	err    error
}

func newBrowserTransport(proxyURL string) *browserTransport {
	options := []tlsclient.HttpClientOption{
		tlsclient.WithClientProfile(profiles.Chrome_131),
		tlsclient.WithRandomTLSExtensionOrder(),
		tlsclient.WithNotFollowRedirects(),
		tlsclient.WithTimeoutSeconds(60),
	}
	if proxyURL != "" {
		options = append(options, tlsclient.WithProxyUrl(proxyURL))
	}
	client, err := tlsclient.NewHttpClient(tlsclient.NewNoopLogger(), options...)
	return &browserTransport{client: client, err: err}
}
func (t *browserTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if t.err != nil {
		return nil, fmt.Errorf("zlibrary transport configuration: %w", t.err)
	}
	r, err := fhttp.NewRequestWithContext(req.Context(), req.Method, req.URL.String(), req.Body)
	if err != nil {
		return nil, err
	}
	r.Host = req.Host
	r.ContentLength = req.ContentLength
	r.GetBody = req.GetBody
	r.Header = fhttp.Header(req.Header.Clone())
	r.Header[fhttp.HeaderOrderKey] = []string{"content-length", "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform", "upgrade-insecure-requests", "user-agent", "accept", "content-type", "origin", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-user", "sec-fetch-dest", "referer", "accept-encoding", "accept-language", "cookie"}
	response, err := t.client.Do(r)
	if err != nil {
		return nil, err
	}
	return &http.Response{
		Status: response.Status, StatusCode: response.StatusCode, Proto: response.Proto,
		ProtoMajor: response.ProtoMajor, ProtoMinor: response.ProtoMinor,
		Header: http.Header(response.Header), Body: response.Body, ContentLength: response.ContentLength,
		TransferEncoding: response.TransferEncoding, Close: response.Close,
		Uncompressed: response.Uncompressed, Trailer: http.Header(response.Trailer), Request: req,
	}, nil
}
func (t *browserTransport) CloseIdleConnections() {
	if t.client != nil {
		t.client.CloseIdleConnections()
	}
}
