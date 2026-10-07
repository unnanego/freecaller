package main

// One bridged call: a seat in a LiveKit room held on behalf of one Apple Watch.
//
// The seat and the WebSocket have separate lives. A watch on LTE drops its
// socket every time it hands over between Wi-Fi and cellular, and a phone app
// that saw its peer leave the room on every handover would announce a broken
// call each time. So when the socket goes, the seat stays for a grace window
// (BRIDGE_DETACH_GRACE); the watch reconnects with the same account and call,
// re-attaches, and the other side never notices more than a short gap in the
// audio. Only an explicit "bye", the grace window running out, the call record
// going terminal or the room itself going away end the seat.
//
// Lock order: bridge.mu before session.mu, never the other way round.

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// roomConn is the bridge's view of a LiveKit room — narrow so tests can fake it.
type roomConn interface {
	// WriteOpus publishes one Opus packet holding dur of audio.
	WriteOpus(payload []byte, dur time.Duration) error
	SetMuted(muted bool)
	Close()
}

// roomEvents is what a room reports back to its session.
type roomEvents interface {
	onAudio(f audioFrame)
	onPeer(present bool)
	onRoomGone(reason string)
}

type roomDialer func(ctx context.Context, grant roomGrant, ev roomEvents) (roomConn, error)

type session struct {
	b      *bridge
	key    string
	uid    string
	callID string

	// Closed once the room is joined (or failed to be); joinErr says which.
	ready   chan struct{}
	joinErr error
	room    roomConn

	mu        sync.Mutex
	token     string // the newest token any attachment presented; used to poll
	att       *attachment
	grace     *time.Timer
	call      callRecord
	peer      bool
	closed    bool
	closeOnce sync.Once
	done      chan struct{}
}

// attachment is one WebSocket bound to a session.
type attachment struct {
	ws     *websocket.Conn
	ctx    context.Context
	cancel context.CancelFunc
	ctrl   chan controlMsg
	audio  chan []byte
}

const (
	// About half a second of downlink audio. Past that the watch is not keeping
	// up and older audio is dropped: late audio is worse than lost audio.
	audioQueue = 25
	ctrlQueue  = 32
	writeLimit = 5 * time.Second
)

func newAttachment(parent context.Context, ws *websocket.Conn) *attachment {
	ctx, cancel := context.WithCancel(parent)
	return &attachment{
		ws:     ws,
		ctx:    ctx,
		cancel: cancel,
		ctrl:   make(chan controlMsg, ctrlQueue),
		audio:  make(chan []byte, audioQueue),
	}
}

func (s *session) logf(format string, args ...any) {
	log.Printf("[%s] "+format, append([]any{s.key}, args...)...)
}

// join takes the room seat. Runs once, outside every lock — minting a token and
// connecting to LiveKit take a second or two.
func (s *session) join(ctx context.Context, token string) {
	defer close(s.ready)

	grant, err := s.b.pb.mintRoomToken(ctx, token, s.callID)
	if err != nil {
		s.joinErr = err
		return
	}
	room, err := s.b.dial(ctx, grant, s)
	if err != nil {
		s.joinErr = err
		return
	}

	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		room.Close()
		s.joinErr = errors.New("session closed while joining")
		return
	}
	s.room = room
	s.mu.Unlock()

	s.logf("joined room")
	go s.poll()
}

// attach binds ws to this session and serves it until it goes away. Returns
// when the socket is done; the caller only has to return from the handler.
func (s *session) attach(ws *websocket.Conn, token string, resumed bool) {
	att := newAttachment(context.Background(), ws)

	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		sendErrorAndClose(ws, errConflict, "call is over")
		return
	}
	if old := s.att; old != nil {
		// Same watch, new socket (the old one is usually already dead and only
		// the server has not noticed yet). Newest wins.
		// Close waits for the peer's close handshake (up to 5s) — never under
		// the lock.
		old.cancel()
		go func() { _ = old.ws.Close(websocket.StatusPolicyViolation, "replaced by a newer connection") }()
	}
	if s.grace != nil {
		s.grace.Stop()
		s.grace = nil
	}
	s.att = att
	s.token = token
	call, peer := s.call, s.peer
	s.mu.Unlock()

	go s.writer(att)

	att.ctrl <- controlMsg{Type: "ready", Resumed: boolPtr(resumed)}
	if call.State != "" {
		att.ctrl <- controlMsg{Type: "state", State: call.State, EndedBy: call.EndedBy}
	}
	att.ctrl <- controlMsg{Type: "peer", Present: boolPtr(peer)}

	s.logf("watch attached (resumed=%v)", resumed)
	bye := s.reader(att)
	s.detach(att, bye)
}

// reader serves frames from the watch until the socket fails. Reports whether
// the watch said goodbye.
func (s *session) reader(att *attachment) (bye bool) {
	for {
		typ, data, err := att.ws.Read(att.ctx)
		if err != nil {
			return false
		}
		switch typ {
		case websocket.MessageBinary:
			f, err := decodeAudio(data)
			if err != nil {
				continue
			}
			dur := opusDuration(f.Payload)
			if dur == 0 {
				continue
			}
			if room := s.currentRoom(); room != nil {
				if err := room.WriteOpus(f.Payload, dur); err != nil {
					s.logf("uplink write: %v", err)
				}
			}
		case websocket.MessageText:
			var msg controlMsg
			if json.Unmarshal(data, &msg) != nil {
				continue
			}
			switch msg.Type {
			case "mute":
				if room := s.currentRoom(); room != nil && msg.Muted != nil {
					room.SetMuted(*msg.Muted)
				}
			case "bye":
				return true
			}
		}
	}
}

// writer is the only goroutine that writes to att.ws. Control messages go
// first: a state change must never wait behind a queue of audio.
func (s *session) writer(att *attachment) {
	defer att.cancel()
	for {
		select {
		case <-att.ctx.Done():
			return
		case msg := <-att.ctrl:
			if err := writeJSON(att.ctx, att.ws, msg); err != nil {
				return
			}
			continue
		default:
		}
		select {
		case <-att.ctx.Done():
			return
		case msg := <-att.ctrl:
			if err := writeJSON(att.ctx, att.ws, msg); err != nil {
				return
			}
		case frame := <-att.audio:
			ctx, cancel := context.WithTimeout(att.ctx, writeLimit)
			err := att.ws.Write(ctx, websocket.MessageBinary, frame)
			cancel()
			if err != nil {
				return
			}
		}
	}
}

func (s *session) detach(att *attachment, bye bool) {
	att.cancel()

	s.mu.Lock()
	if s.att != att {
		// Already replaced by a newer socket; nothing about the seat changes.
		s.mu.Unlock()
		return
	}
	s.att = nil
	if bye || s.closed {
		s.mu.Unlock()
		go func() { _ = att.ws.Close(websocket.StatusNormalClosure, "") }()
		s.close("watch said bye")
		return
	}
	s.grace = time.AfterFunc(s.b.cfg.detachGrace, func() { s.close("watch did not come back") })
	s.mu.Unlock()

	s.logf("watch detached; holding the seat for %s", s.b.cfg.detachGrace)
}

// close ends the seat for good. Safe to call from anywhere, any number of times.
func (s *session) close(reason string) {
	s.closeOnce.Do(func() {
		s.b.forget(s)

		s.mu.Lock()
		s.closed = true
		if s.grace != nil {
			s.grace.Stop()
			s.grace = nil
		}
		att, room := s.att, s.room
		s.att = nil
		s.mu.Unlock()

		if att != nil {
			// Let the writer flush what is queued (the final state message,
			// typically) before the socket goes.
			go func() {
				time.Sleep(500 * time.Millisecond)
				att.cancel()
				_ = att.ws.Close(websocket.StatusNormalClosure, reason)
			}()
		}
		if room != nil {
			room.Close()
		}
		close(s.done)
		s.logf("closed: %s", reason)
	})
}

func (s *session) currentRoom() roomConn {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.room
}

func (s *session) sendCtrl(msg controlMsg) {
	s.mu.Lock()
	att := s.att
	s.mu.Unlock()
	if att == nil {
		return
	}
	select {
	case att.ctrl <- msg:
	default:
		s.logf("control queue full; dropped %q", msg.Type)
	}
}

// poll follows the call record, because the watch's socket is the only line it
// has to the server during a call: watchOS gives an app sockets while a call is
// up, but no PocketBase realtime in the background. A one-second GET against a
// PocketBase on the same machine costs nothing.
func (s *session) poll() {
	t := time.NewTicker(s.b.cfg.pollEvery)
	defer t.Stop()
	for {
		select {
		case <-s.done:
			return
		case <-t.C:
		}

		s.mu.Lock()
		token := s.token
		s.mu.Unlock()

		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		call, err := s.b.pb.getCall(ctx, token, s.callID)
		cancel()
		if err != nil {
			code := protocolCode(err)
			if code == errUnauthorized || code == errNotFound {
				s.sendCtrl(controlMsg{Type: "error", Code: code, Message: err.Error()})
				s.close("call record unreadable: " + err.Error())
				return
			}
			continue // transient; the next tick tries again
		}

		s.mu.Lock()
		changed := call.State != s.call.State || call.EndedBy != s.call.EndedBy
		s.call = call
		s.mu.Unlock()

		if changed {
			s.sendCtrl(controlMsg{Type: "state", State: call.State, EndedBy: call.EndedBy})
		}
		if call.terminal() {
			s.close("call " + call.State)
			return
		}
	}
}

// ---- roomEvents ---------------------------------------------------------------

func (s *session) onAudio(f audioFrame) {
	s.mu.Lock()
	att := s.att
	s.mu.Unlock()
	if att == nil {
		return // detached: nobody to play it to
	}
	frame := encodeAudio(f)
	select {
	case att.audio <- frame:
		return
	default:
	}
	// Full: drop the oldest frame, keep the newest.
	select {
	case <-att.audio:
	default:
	}
	select {
	case att.audio <- frame:
	default:
	}
}

func (s *session) onPeer(present bool) {
	s.mu.Lock()
	changed := s.peer != present
	s.peer = present
	s.mu.Unlock()
	if changed {
		s.sendCtrl(controlMsg{Type: "peer", Present: boolPtr(present)})
	}
}

func (s *session) onRoomGone(reason string) {
	s.sendCtrl(controlMsg{Type: "error", Code: errConflict, Message: "room closed: " + reason})
	s.close("room gone: " + reason)
}

// ---- helpers --------------------------------------------------------------------

func writeJSON(ctx context.Context, ws *websocket.Conn, msg controlMsg) error {
	raw, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	wctx, cancel := context.WithTimeout(ctx, writeLimit)
	defer cancel()
	return ws.Write(wctx, websocket.MessageText, raw)
}

func sendErrorAndClose(ws *websocket.Conn, code, message string) {
	_ = writeJSON(context.Background(), ws, controlMsg{Type: "error", Code: code, Message: message})
	_ = ws.Close(websocket.StatusNormalClosure, code)
}
