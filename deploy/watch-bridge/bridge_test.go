package main

// End-to-end tests of the session lifecycle against a fake PocketBase (httptest)
// and a fake LiveKit room. Everything but the LiveKit transport is real: the
// HTTP handler, the WebSocket, the registry, the poller.

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

const testCallID = "0b6a0b8e-5d0c-4c39-9a51-2b0b4f7d9c11"

// ---- fake PocketBase ------------------------------------------------------------

type fakePB struct {
	mu       sync.Mutex
	state    string
	endedBy  string
	members  map[string]bool // uids allowed to see the call
	mints    int
	mintCode int // non-zero: the token endpoint fails with this status
}

func (f *fakePB) setState(state, endedBy string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.state, f.endedBy = state, endedBy
}

func (f *fakePB) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	uid, err := tokenUserID(r.Header.Get("Authorization"))
	if err != nil {
		http.Error(w, `{"message":"bad token"}`, http.StatusUnauthorized)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.members[uid] {
		http.Error(w, `{"message":"not found"}`, http.StatusNotFound)
		return
	}
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/api/collections/calls/records/"+testCallID:
		_ = json.NewEncoder(w).Encode(callRecord{
			ID: testCallID, CallerID: "caller", CalleeID: "watch",
			State: f.state, EndedBy: f.endedBy,
		})
	case r.Method == http.MethodPost && r.URL.Path == "/api/freecaller/livekit-token":
		f.mints++
		if f.mintCode != 0 {
			http.Error(w, `{"message":"nope"}`, f.mintCode)
			return
		}
		_ = json.NewEncoder(w).Encode(roomGrant{Token: "lk-token", URL: "wss://lk.example"})
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/api/collections/users/records/"):
		_, _ = w.Write([]byte(`{"id":"` + uid + `"}`))
	default:
		http.NotFound(w, r)
	}
}

// ---- fake room ------------------------------------------------------------------

type fakeRoom struct {
	ev     roomEvents
	mu     sync.Mutex
	writes [][]byte
	muted  bool
	closed bool
}

func (r *fakeRoom) WriteOpus(p []byte, _ time.Duration) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.writes = append(r.writes, append([]byte(nil), p...))
	return nil
}
func (r *fakeRoom) SetMuted(m bool) { r.mu.Lock(); r.muted = m; r.mu.Unlock() }
func (r *fakeRoom) Close()          { r.mu.Lock(); r.closed = true; r.mu.Unlock() }

func (r *fakeRoom) snapshot() (writes int, muted, closed bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.writes), r.muted, r.closed
}

type harness struct {
	t     *testing.T
	pb    *fakePB
	b     *bridge
	srv   *httptest.Server
	mu    sync.Mutex
	rooms []*fakeRoom
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	h := &harness{t: t, pb: &fakePB{state: "ringing", members: map[string]bool{"watch": true}}}
	pbSrv := httptest.NewServer(h.pb)
	t.Cleanup(pbSrv.Close)

	cfg := config{maxSessions: 2, detachGrace: 300 * time.Millisecond, pollEvery: 50 * time.Millisecond, echo: true}
	h.b = newBridge(cfg, newPBClient(pbSrv.URL), func(_ context.Context, _ roomGrant, ev roomEvents) (roomConn, error) {
		r := &fakeRoom{ev: ev}
		h.mu.Lock()
		h.rooms = append(h.rooms, r)
		h.mu.Unlock()
		return r, nil
	})
	h.srv = httptest.NewServer(h.b.routes())
	t.Cleanup(func() { h.b.closeAll(); h.srv.Close() })
	return h
}

func (h *harness) room(i int) *fakeRoom {
	h.mu.Lock()
	defer h.mu.Unlock()
	if i >= len(h.rooms) {
		h.t.Fatalf("room %d was never dialled (have %d)", i, len(h.rooms))
	}
	return h.rooms[i]
}

func (h *harness) sessions() int {
	h.b.mu.Lock()
	defer h.b.mu.Unlock()
	return len(h.b.sessions)
}

// ---- client helpers ---------------------------------------------------------------

type client struct {
	t  *testing.T
	ws *websocket.Conn
}

func (h *harness) dial(path string, hello controlMsg) *client {
	h.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(h.srv.URL, "http") + path
	ws, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		h.t.Fatal(err)
	}
	c := &client{t: h.t, ws: ws}
	raw, _ := json.Marshal(hello)
	if err := ws.Write(ctx, websocket.MessageText, raw); err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { _ = ws.CloseNow() })
	return c
}

func hello(uid string) controlMsg {
	return controlMsg{Type: "hello", V: protocolVersion, Token: fakeToken(uid), CallID: testCallID}
}

// next reads frames until a control message arrives (audio frames are skipped).
func (c *client) next() controlMsg {
	c.t.Helper()
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		typ, data, err := c.ws.Read(ctx)
		cancel()
		if err != nil {
			c.t.Fatalf("read: %v", err)
		}
		if typ == websocket.MessageText {
			var m controlMsg
			if err := json.Unmarshal(data, &m); err != nil {
				c.t.Fatal(err)
			}
			return m
		}
	}
}

func (c *client) expect(typ string) controlMsg {
	c.t.Helper()
	m := c.next()
	if m.Type != typ {
		c.t.Fatalf("got %+v, want type %q", m, typ)
	}
	return m
}

func (c *client) send(msg controlMsg) {
	raw, _ := json.Marshal(msg)
	if err := c.ws.Write(context.Background(), websocket.MessageText, raw); err != nil {
		c.t.Fatal(err)
	}
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

// ---- tests --------------------------------------------------------------------------

func TestJoinRelaysAudioBothWays(t *testing.T) {
	h := newHarness(t)
	c := h.dial("/bridge/ws", hello("watch"))

	if m := c.expect("ready"); m.Resumed == nil || *m.Resumed {
		t.Fatalf("first attach should not be a resume: %+v", m)
	}
	if m := c.expect("state"); m.State != "ringing" {
		t.Fatalf("state %+v", m)
	}
	c.expect("peer")

	// Uplink: a 20 ms CELT packet reaches the room.
	up := encodeAudio(audioFrame{Seq: 1, TS: 960, Payload: []byte{31 << 3, 9, 9}})
	if err := c.ws.Write(context.Background(), websocket.MessageBinary, up); err != nil {
		t.Fatal(err)
	}
	// A frame that is not audio is ignored, not fatal.
	_ = c.ws.Write(context.Background(), websocket.MessageBinary, []byte{0x09})
	eventually(t, "uplink write", func() bool { n, _, _ := h.room(0).snapshot(); return n == 1 })

	// Downlink: room audio reaches the watch with seq/ts intact.
	h.room(0).ev.onAudio(audioFrame{Seq: 77, TS: 4242, Payload: []byte{31 << 3, 1}})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	typ, data, err := c.ws.Read(ctx)
	if err != nil || typ != websocket.MessageBinary {
		t.Fatalf("downlink: %v %v", typ, err)
	}
	f, err := decodeAudio(data)
	if err != nil || f.Seq != 77 || f.TS != 4242 {
		t.Fatalf("downlink frame %+v %v", f, err)
	}

	// Peer presence is forwarded.
	h.room(0).ev.onPeer(true)
	if m := c.expect("peer"); m.Present == nil || !*m.Present {
		t.Fatalf("peer %+v", m)
	}

	// Mute goes to the room.
	c.send(controlMsg{Type: "mute", Muted: boolPtr(true)})
	eventually(t, "mute", func() bool { _, m, _ := h.room(0).snapshot(); return m })
}

func TestStateChangesAreForwardedAndTerminalEndsTheSeat(t *testing.T) {
	h := newHarness(t)
	c := h.dial("/bridge/ws", hello("watch"))
	c.expect("ready")
	c.expect("state")
	c.expect("peer")

	h.pb.setState("accepted", "")
	if m := c.expect("state"); m.State != "accepted" {
		t.Fatalf("%+v", m)
	}
	h.pb.setState("ended", "caller")
	if m := c.expect("state"); m.State != "ended" || m.EndedBy != "caller" {
		t.Fatalf("%+v", m)
	}
	eventually(t, "room closed", func() bool { _, _, closed := h.room(0).snapshot(); return closed })
	eventually(t, "session forgotten", func() bool { return h.sessions() == 0 })
}

func TestReconnectWithinGraceResumesTheSameSeat(t *testing.T) {
	h := newHarness(t)
	c := h.dial("/bridge/ws", hello("watch"))
	c.expect("ready")
	_ = c.ws.CloseNow() // the LTE handover

	c2 := h.dial("/bridge/ws", hello("watch"))
	if m := c2.expect("ready"); m.Resumed == nil || !*m.Resumed {
		t.Fatalf("expected a resume: %+v", m)
	}
	h.mu.Lock()
	dials := len(h.rooms)
	h.mu.Unlock()
	if dials != 1 {
		t.Fatalf("rejoined the room instead of resuming (%d dials)", dials)
	}
	if _, _, closed := h.room(0).snapshot(); closed {
		t.Fatal("room closed across a reconnect")
	}
}

func TestGraceExpiryLeavesTheRoom(t *testing.T) {
	h := newHarness(t)
	c := h.dial("/bridge/ws", hello("watch"))
	c.expect("ready")
	_ = c.ws.CloseNow()

	eventually(t, "room closed after grace", func() bool { _, _, closed := h.room(0).snapshot(); return closed })
	eventually(t, "session forgotten", func() bool { return h.sessions() == 0 })
}

func TestByeLeavesImmediately(t *testing.T) {
	h := newHarness(t)
	h.b.cfg.detachGrace = time.Hour
	c := h.dial("/bridge/ws", hello("watch"))
	c.expect("ready")
	c.send(controlMsg{Type: "bye"})
	eventually(t, "room closed on bye", func() bool { _, _, closed := h.room(0).snapshot(); return closed })
}

func TestRejections(t *testing.T) {
	cases := []struct {
		name  string
		setup func(*harness)
		hello controlMsg
		code  string
	}{
		{"outsider", nil, hello("stranger"), errNotFound},
		{"garbage token", nil, controlMsg{Type: "hello", V: 1, Token: "x", CallID: testCallID}, errUnauthorized},
		{"bad call id", nil, controlMsg{Type: "hello", V: 1, Token: fakeToken("watch"), CallID: "../../etc"}, errBadRequest},
		{"wrong version", nil, controlMsg{Type: "hello", V: 99, Token: fakeToken("watch"), CallID: testCallID}, errBadRequest},
		{"not a hello", nil, controlMsg{Type: "mute"}, errBadRequest},
		{"call already over", func(h *harness) { h.pb.setState("declined", "watch") }, hello("watch"), errConflict},
		{"token endpoint refuses", func(h *harness) { h.pb.mintCode = http.StatusConflict }, hello("watch"), errConflict},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t)
			if tc.setup != nil {
				tc.setup(h)
			}
			c := h.dial("/bridge/ws", tc.hello)
			if m := c.expect("error"); m.Code != tc.code {
				t.Fatalf("code %q, want %q (%s)", m.Code, tc.code, m.Message)
			}
			eventually(t, "no session left", func() bool { return h.sessions() == 0 })
		})
	}
}

func TestCapacity(t *testing.T) {
	h := newHarness(t)
	h.b.cfg.maxSessions = 1
	h.pb.members["other"] = true

	c := h.dial("/bridge/ws", hello("watch"))
	c.expect("ready")
	c2 := h.dial("/bridge/ws", hello("other"))
	if m := c2.expect("error"); m.Code != errBusy {
		t.Fatalf("%+v", m)
	}
}

func TestEcho(t *testing.T) {
	h := newHarness(t)
	c := h.dial("/bridge/echo", controlMsg{Type: "hello", Token: fakeToken("watch")})
	c.expect("ready")
	frame := encodeAudio(audioFrame{Seq: 5, TS: 10, Payload: []byte{31 << 3, 4}})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := c.ws.Write(ctx, websocket.MessageBinary, frame); err != nil {
		t.Fatal(err)
	}
	_, data, err := c.ws.Read(ctx)
	if err != nil || string(data) != string(frame) {
		t.Fatalf("echo: %x %v", data, err)
	}
}
