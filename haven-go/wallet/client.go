package wallet

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/elnosh/gonuts/cashu"
	"github.com/elnosh/gonuts/cashu/nuts/nut01"
	"github.com/elnosh/gonuts/cashu/nuts/nut02"
	"github.com/elnosh/gonuts/cashu/nuts/nut03"
	"github.com/elnosh/gonuts/cashu/nuts/nut04"
	"github.com/elnosh/gonuts/cashu/nuts/nut05"
	"github.com/elnosh/gonuts/cashu/nuts/nut06"
	"github.com/elnosh/gonuts/cashu/nuts/nut07"
	"github.com/elnosh/gonuts/cashu/nuts/nut09"
)

// maxResponse caps a mint reply; a keyset is ~6 KB, a big swap a few hundred KB.
const maxResponse = 4 << 20

// MintError is a reply the mint gave on purpose (HTTP 400 with a Cashu error
// body). It means the mint did NOT carry out the request.
type MintError struct {
	Status int
	Code   cashu.CashuErrCode
	Detail string
}

func (e *MintError) Error() string {
	return fmt.Sprintf("mint refused (%d): %s", e.Code, e.Detail)
}

// IsDefinite reports whether err is a refusal the mint made on purpose. Any
// other error (network, timeout, 5xx, garbled reply) leaves the outcome
// unknown, and the journaled op must stay for Recover.
func IsDefinite(err error) bool {
	var me *MintError
	return errors.As(err, &me)
}

func isProofSpentErr(err error) bool {
	var me *MintError
	return errors.As(err, &me) && me.Code == cashu.ProofAlreadyUsedErrCode
}

// Client talks to one mint's HTTP API (NUT-01..09). All calls take a context
// and have a timeout; nothing uses http.DefaultClient.
type Client struct {
	URL  string
	HTTP *http.Client
}

// NewClient checks and normalizes the mint URL. Only https is accepted, except
// http to loopback (local test mints).
func NewClient(mintURL string) (*Client, error) {
	u, err := NormalizeMintURL(mintURL)
	if err != nil {
		return nil, err
	}
	return &Client{URL: u, HTTP: &http.Client{Timeout: 30 * time.Second}}, nil
}

// NormalizeMintURL lower-cases the host, drops a trailing slash, and refuses
// anything that is not https (or http on loopback).
func NormalizeMintURL(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Host == "" {
		return "", fmt.Errorf("not a mint URL: %q", raw)
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("mint URL must not have user, query or fragment: %q", raw)
	}
	host := strings.ToLower(u.Hostname())
	switch u.Scheme {
	case "https":
	case "http":
		if host != "127.0.0.1" && host != "localhost" && host != "::1" {
			return "", fmt.Errorf("mint URL must be https: %q", raw)
		}
	default:
		return "", fmt.Errorf("mint URL must be https: %q", raw)
	}
	u.Host = strings.ToLower(u.Host)
	return strings.TrimRight(u.String(), "/"), nil
}

func (c *Client) do(ctx context.Context, method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.URL+path, body)
	if err != nil {
		return err
	}
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxResponse+1))
	if err != nil {
		return err
	}
	if len(raw) > maxResponse {
		return fmt.Errorf("mint reply over %d bytes", maxResponse)
	}
	if resp.StatusCode == http.StatusBadRequest {
		var ce cashu.Error
		if json.Unmarshal(raw, &ce) == nil && (ce.Code != 0 || ce.Detail != "") {
			return &MintError{Status: resp.StatusCode, Code: ce.Code, Detail: ce.Detail}
		}
		// A 400 we can't read is still a refusal, but with no code.
		return &MintError{Status: resp.StatusCode, Detail: strings.TrimSpace(string(raw))}
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("mint %s %s: HTTP %d", method, path, resp.StatusCode)
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("mint %s %s: bad reply: %w", method, path, err)
	}
	return nil
}

func (c *Client) Info(ctx context.Context) (*nut06.MintInfo, error) {
	var r nut06.MintInfo
	return &r, c.do(ctx, http.MethodGet, "/v1/info", nil, &r)
}

func (c *Client) Keysets(ctx context.Context) (*nut02.GetKeysetsResponse, error) {
	var r nut02.GetKeysetsResponse
	return &r, c.do(ctx, http.MethodGet, "/v1/keysets", nil, &r)
}

func (c *Client) Keys(ctx context.Context, id string) (*nut01.GetKeysResponse, error) {
	var r nut01.GetKeysResponse
	return &r, c.do(ctx, http.MethodGet, "/v1/keys/"+url.PathEscape(id), nil, &r)
}

func (c *Client) MintQuote(ctx context.Context, amount uint64) (*nut04.PostMintQuoteBolt11Response, error) {
	var r nut04.PostMintQuoteBolt11Response
	req := nut04.PostMintQuoteBolt11Request{Amount: amount, Unit: cashu.Sat.String()}
	return &r, c.do(ctx, http.MethodPost, "/v1/mint/quote/bolt11", req, &r)
}

func (c *Client) MintQuoteState(ctx context.Context, quote string) (*nut04.PostMintQuoteBolt11Response, error) {
	var r nut04.PostMintQuoteBolt11Response
	return &r, c.do(ctx, http.MethodGet, "/v1/mint/quote/bolt11/"+url.PathEscape(quote), nil, &r)
}

func (c *Client) Mint(ctx context.Context, quote string, outputs cashu.BlindedMessages) (*nut04.PostMintBolt11Response, error) {
	var r nut04.PostMintBolt11Response
	req := nut04.PostMintBolt11Request{Quote: quote, Outputs: outputs}
	return &r, c.do(ctx, http.MethodPost, "/v1/mint/bolt11", req, &r)
}

func (c *Client) Swap(ctx context.Context, inputs cashu.Proofs, outputs cashu.BlindedMessages) (*nut03.PostSwapResponse, error) {
	var r nut03.PostSwapResponse
	req := nut03.PostSwapRequest{Inputs: inputs, Outputs: outputs}
	return &r, c.do(ctx, http.MethodPost, "/v1/swap", req, &r)
}

func (c *Client) MeltQuote(ctx context.Context, bolt11 string) (*nut05.PostMeltQuoteBolt11Response, error) {
	var r nut05.PostMeltQuoteBolt11Response
	req := nut05.PostMeltQuoteBolt11Request{Request: bolt11, Unit: cashu.Sat.String()}
	return &r, c.do(ctx, http.MethodPost, "/v1/melt/quote/bolt11", req, &r)
}

func (c *Client) MeltQuoteState(ctx context.Context, quote string) (*nut05.PostMeltQuoteBolt11Response, error) {
	var r nut05.PostMeltQuoteBolt11Response
	return &r, c.do(ctx, http.MethodGet, "/v1/melt/quote/bolt11/"+url.PathEscape(quote), nil, &r)
}

func (c *Client) Melt(ctx context.Context, quote string, inputs cashu.Proofs, outputs cashu.BlindedMessages) (*nut05.PostMeltQuoteBolt11Response, error) {
	var r nut05.PostMeltQuoteBolt11Response
	req := nut05.PostMeltBolt11Request{Quote: quote, Inputs: inputs, Outputs: outputs}
	return &r, c.do(ctx, http.MethodPost, "/v1/melt/bolt11", req, &r)
}

func (c *Client) CheckState(ctx context.Context, ys []string) (*nut07.PostCheckStateResponse, error) {
	var r nut07.PostCheckStateResponse
	return &r, c.do(ctx, http.MethodPost, "/v1/checkstate", nut07.PostCheckStateRequest{Ys: ys}, &r)
}

func (c *Client) Restore(ctx context.Context, outputs cashu.BlindedMessages) (*nut09.PostRestoreResponse, error) {
	var r nut09.PostRestoreResponse
	return &r, c.do(ctx, http.MethodPost, "/v1/restore", nut09.PostRestoreRequest{Outputs: outputs}, &r)
}
