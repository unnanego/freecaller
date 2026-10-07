package main

// The two PocketBase calls the bridge makes, both AS THE WATCH'S USER — the
// token the watch sent is forwarded as-is. The bridge holds no credentials of
// its own and decides nothing about who may join what: the calls collection's
// view rule and /api/freecaller/livekit-token already do, and asking them is
// what keeps the bridge from becoming a second, weaker copy of those rules.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type pbClient struct {
	base string
	http *http.Client
}

func newPBClient(base string) *pbClient {
	return &pbClient{
		base: strings.TrimRight(base, "/"),
		http: &http.Client{Timeout: 8 * time.Second},
	}
}

// pbError is a PocketBase answer the session maps onto a protocol error code.
type pbError struct {
	Status  int
	Message string
}

func (e *pbError) Error() string { return fmt.Sprintf("pocketbase %d: %s", e.Status, e.Message) }

// code is the protocol error this answer becomes on the watch.
func (e *pbError) code() string {
	switch e.Status {
	case http.StatusUnauthorized:
		return errUnauthorized
	case http.StatusForbidden, http.StatusNotFound:
		// The view rule answers a call that is not ours with 404, and so does a
		// call that does not exist; the watch handles both the same way.
		return errNotFound
	case http.StatusConflict:
		return errConflict
	case http.StatusBadRequest:
		return errBadRequest
	}
	return errInternal
}

func protocolCode(err error) string {
	var pe *pbError
	if errors.As(err, &pe) {
		return pe.code()
	}
	return errInternal
}

type callRecord struct {
	ID       string `json:"id"`
	CallerID string `json:"callerId"`
	CalleeID string `json:"calleeId"`
	State    string `json:"state"`
	EndedBy  string `json:"endedBy"`
}

func (c callRecord) terminal() bool {
	switch c.State {
	case "declined", "cancelled", "missed", "ended":
		return true
	}
	return false
}

func (p *pbClient) getCall(ctx context.Context, token, callID string) (callRecord, error) {
	var rec callRecord
	err := p.do(ctx, http.MethodGet,
		"/api/collections/calls/records/"+url.PathEscape(callID), token, nil, &rec)
	return rec, err
}

type roomGrant struct {
	Token string `json:"token"`
	URL   string `json:"url"`
}

func (p *pbClient) mintRoomToken(ctx context.Context, token, callID string) (roomGrant, error) {
	var g roomGrant
	err := p.do(ctx, http.MethodPost, "/api/freecaller/livekit-token", token,
		map[string]string{"callId": callID}, &g)
	if err == nil && (g.Token == "" || g.URL == "") {
		err = &pbError{Status: 500, Message: "token endpoint returned no token"}
	}
	return g, err
}

// getSelf proves a token is live without touching any call. Used by the echo
// endpoint, which has no call to authorize against.
func (p *pbClient) getSelf(ctx context.Context, token string) error {
	uid, err := tokenUserID(token)
	if err != nil {
		return &pbError{Status: http.StatusUnauthorized, Message: err.Error()}
	}
	var out map[string]any
	return p.do(ctx, http.MethodGet,
		"/api/collections/users/records/"+url.PathEscape(uid), token, nil, &out)
}

func (p *pbClient) do(ctx context.Context, method, path, token string, body, out any) error {
	var rd io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rd = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, p.base+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := p.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var msg struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(raw, &msg)
		return &pbError{Status: resp.StatusCode, Message: msg.Message}
	}
	if out != nil {
		if err := json.Unmarshal(raw, out); err != nil {
			return fmt.Errorf("decoding %s: %w", path, err)
		}
	}
	return nil
}

// tokenUserID reads the account id out of a PocketBase auth token WITHOUT
// verifying it. That is safe only because nothing is ever granted on the
// strength of it: it names the session a reconnect may re-attach to, and every
// attach first has the same token accepted by PocketBase (getCall). A forged
// token naming someone else's id fails there.
func tokenUserID(token string) (string, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", errors.New("token is not a JWT")
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", errors.New("token payload is not base64url")
	}
	var claims struct {
		ID   string `json:"id"`
		Type string `json:"type"`
	}
	if err := json.Unmarshal(raw, &claims); err != nil || claims.ID == "" {
		return "", errors.New("token carries no account id")
	}
	if claims.Type != "" && claims.Type != "auth" {
		return "", errors.New("not an auth token")
	}
	return claims.ID, nil
}
