package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"sync"
	"time"

	"github.com/coder/websocket"
)

type config struct {
	listen      string
	pbURL       string
	livekitURL  string // overrides the URL the token endpoint hands out; "" = use it
	maxSessions int
	detachGrace time.Duration
	pollEvery   time.Duration
	echo        bool
}

type bridge struct {
	cfg  config
	pb   *pbClient
	dial roomDialer

	mu       sync.Mutex
	sessions map[string]*session
}

func newBridge(cfg config, pb *pbClient, dial roomDialer) *bridge {
	return &bridge{cfg: cfg, pb: pb, dial: dial, sessions: map[string]*session{}}
}

func (b *bridge) routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /bridge/ws", b.handleWS)
	mux.HandleFunc("GET /bridge/healthz", b.handleHealth)
	if b.cfg.echo {
		mux.HandleFunc("GET /bridge/echo", b.handleEcho)
	}
	return mux
}

func (b *bridge) handleHealth(w http.ResponseWriter, _ *http.Request) {
	b.mu.Lock()
	n := len(b.sessions)
	b.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "sessions": n})
}

// A call id is the CallKit UUID, and the server refuses anything else at
// creation (pb_hooks/calls.pb.js); refusing it here too keeps junk out of URLs.
var uuidRE = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func (b *bridge) handleWS(w http.ResponseWriter, r *http.Request) {
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	ws.SetReadLimit(16 << 10)

	hello, err := readHello(r.Context(), ws)
	if err != nil {
		sendErrorAndClose(ws, errBadRequest, err.Error())
		return
	}
	if !uuidRE.MatchString(hello.CallID) {
		sendErrorAndClose(ws, errBadRequest, "callId must be a UUID")
		return
	}
	uid, err := tokenUserID(hello.Token)
	if err != nil {
		sendErrorAndClose(ws, errUnauthorized, err.Error())
		return
	}

	// The token is checked by PocketBase BEFORE it may touch any session: this
	// one read is what proves the account is real and a participant.
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	call, err := b.pb.getCall(ctx, hello.Token, hello.CallID)
	cancel()
	if err != nil {
		sendErrorAndClose(ws, protocolCode(err), "call lookup failed")
		return
	}
	if call.terminal() {
		sendErrorAndClose(ws, errConflict, "call is "+call.State)
		return
	}

	s, created, err := b.sessionFor(uid, hello.CallID, call)
	if err != nil {
		sendErrorAndClose(ws, errBusy, err.Error())
		return
	}
	if created {
		go s.join(context.Background(), hello.Token)
	}

	select {
	case <-s.ready:
	case <-r.Context().Done():
		return
	}
	if s.joinErr != nil {
		s.close("join failed: " + s.joinErr.Error())
		sendErrorAndClose(ws, protocolCode(s.joinErr), "could not join the call")
		return
	}

	s.attach(ws, hello.Token, !created)
}

func readHello(ctx context.Context, ws *websocket.Conn) (controlMsg, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	typ, data, err := ws.Read(ctx)
	if err != nil {
		return controlMsg{}, errors.New("no hello")
	}
	var msg controlMsg
	if typ != websocket.MessageText || json.Unmarshal(data, &msg) != nil || msg.Type != "hello" {
		return controlMsg{}, errors.New("first frame must be a hello")
	}
	if msg.V != protocolVersion {
		return controlMsg{}, errors.New("unsupported protocol version")
	}
	if msg.Token == "" || msg.CallID == "" {
		return controlMsg{}, errors.New("hello needs token and callId")
	}
	return msg, nil
}

// sessionFor returns the live session for this account and call, or registers
// a new one (not yet joined) if there is none.
func (b *bridge) sessionFor(uid, callID string, call callRecord) (*session, bool, error) {
	key := uid + "/" + callID

	b.mu.Lock()
	defer b.mu.Unlock()
	if s, ok := b.sessions[key]; ok {
		return s, false, nil
	}
	if len(b.sessions) >= b.cfg.maxSessions {
		return nil, false, errors.New("bridge is full")
	}
	s := &session{
		b:      b,
		key:    key,
		uid:    uid,
		callID: callID,
		ready:  make(chan struct{}),
		done:   make(chan struct{}),
		call:   call,
	}
	b.sessions[key] = s
	return s, true, nil
}

func (b *bridge) forget(s *session) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.sessions[s.key] == s {
		delete(b.sessions, s.key)
	}
}

// closeAll ends every seat (shutdown).
func (b *bridge) closeAll() {
	b.mu.Lock()
	all := make([]*session, 0, len(b.sessions))
	for _, s := range b.sessions {
		all = append(all, s)
	}
	b.mu.Unlock()
	for _, s := range all {
		s.sendCtrl(controlMsg{Type: "error", Code: errInternal, Message: "bridge restarting"})
		s.close("shutdown")
	}
}

// handleEcho bounces every audio frame straight back — the first on-device test
// (docs/watch-plan.md, spike 1): mic -> Opus -> LTE -> here -> back -> speaker,
// to measure round-trip latency and hear the echo canceller, with no call and
// no second person. Off unless BRIDGE_ECHO=1, and still needs a live account.
func (b *bridge) handleEcho(w http.ResponseWriter, r *http.Request) {
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	ws.SetReadLimit(16 << 10)

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	typ, data, err := ws.Read(ctx)
	cancel()
	var hello controlMsg
	if err != nil || typ != websocket.MessageText || json.Unmarshal(data, &hello) != nil || hello.Type != "hello" {
		sendErrorAndClose(ws, errBadRequest, "first frame must be a hello")
		return
	}
	ctx, cancel = context.WithTimeout(r.Context(), 8*time.Second)
	err = b.pb.getSelf(ctx, hello.Token)
	cancel()
	if err != nil {
		sendErrorAndClose(ws, protocolCode(err), "token rejected")
		return
	}

	ctx, cancel = context.WithTimeout(r.Context(), 5*time.Minute)
	defer cancel()
	if err := writeJSON(ctx, ws, controlMsg{Type: "ready", Resumed: boolPtr(false)}); err != nil {
		return
	}
	for {
		typ, data, err := ws.Read(ctx)
		if err != nil {
			_ = ws.Close(websocket.StatusNormalClosure, "")
			return
		}
		if typ == websocket.MessageBinary {
			if err := ws.Write(ctx, websocket.MessageBinary, data); err != nil {
				return
			}
		}
	}
}
