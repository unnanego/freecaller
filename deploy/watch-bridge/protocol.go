package main

// The wire protocol between the Apple Watch and this bridge.
//
// One WebSocket per call, over the same TLS 443 as everything else. Two kinds
// of frames share it:
//
//   TEXT frames carry JSON control messages (controlMsg below).
//
//   BINARY frames carry audio, one Opus packet per frame, in both directions:
//
//       byte 0      kind     (frameOpus = 0x01; anything else is ignored)
//       bytes 1-2   seq      uint16 big-endian, +1 per packet, wraps
//       bytes 3-6   ts       uint32 big-endian, 48 kHz sample clock
//       bytes 7..   payload  one Opus packet, as RTP would carry it
//
// Downlink (bridge -> watch) copies seq and ts straight out of the RTP header
// LiveKit sent, so the watch can tell a lost packet (seq gap) from a silent
// stretch (DTX: seq continues, ts jumps). Uplink (watch -> bridge) only needs
// the payload — the bridge re-times what it publishes from the packet's own
// duration — but the watch fills seq/ts anyway so the format is symmetric and
// a capture of either direction can be replayed.
//
// The Opus payload is never decoded here. That is the whole point of this
// design: a call costs the server a memcpy, not a transcode.

import (
	"encoding/binary"
	"errors"
	"time"
)

const (
	protocolVersion = 1

	frameOpus      byte = 0x01
	audioHeaderLen      = 7
	// A 120 ms stereo Opus packet at the highest bitrate is ~1.3 KB; anything
	// near this size is not audio.
	maxOpusPayload = 4000
)

// Control message, both directions. Only the fields that apply are set.
//
// watch -> bridge
//
//	{"type":"hello","v":1,"token":"<PocketBase auth token>","callId":"<uuid>"}
//	    First frame on every connection. Reconnecting with the same account and
//	    call within the grace window re-attaches to the room seat that is still
//	    held, instead of rejoining.
//	{"type":"mute","muted":true}
//	{"type":"bye"}   the watch is done; leave the room now, no grace window.
//
// bridge -> watch
//
//	{"type":"ready","resumed":false}     in the room; audio may flow
//	{"type":"state","state":"accepted","endedBy":""}   call record changed
//	{"type":"peer","present":true}      the other side is (not) in the room
//	{"type":"error","code":"forbidden","message":"..."}   then the bridge closes
type controlMsg struct {
	Type    string `json:"type"`
	V       int    `json:"v,omitempty"`
	Token   string `json:"token,omitempty"`
	CallID  string `json:"callId,omitempty"`
	Muted   *bool  `json:"muted,omitempty"`
	Resumed *bool  `json:"resumed,omitempty"`
	State   string `json:"state,omitempty"`
	EndedBy string `json:"endedBy,omitempty"`
	Present *bool  `json:"present,omitempty"`
	Code    string `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

// Error codes the watch acts on. Anything it does not recognise it treats as
// `internal`.
const (
	errBadRequest   = "bad_request"  // malformed hello; a bug, do not retry
	errUnauthorized = "unauthorized" // token rejected; the watch must re-sign-in
	errNotFound     = "not_found"    // no such call, or not ours to see
	errConflict     = "conflict"     // call is over (or too old); do not retry
	errBusy         = "busy"         // bridge at capacity; retry shortly
	errInternal     = "internal"     // retry
)

func boolPtr(b bool) *bool { return &b }

type audioFrame struct {
	Seq     uint16
	TS      uint32
	Payload []byte
}

var errNotAudio = errors.New("not an audio frame")

func encodeAudio(f audioFrame) []byte {
	buf := make([]byte, audioHeaderLen+len(f.Payload))
	buf[0] = frameOpus
	binary.BigEndian.PutUint16(buf[1:3], f.Seq)
	binary.BigEndian.PutUint32(buf[3:7], f.TS)
	copy(buf[audioHeaderLen:], f.Payload)
	return buf
}

// decodeAudio parses a binary frame. The payload aliases buf.
func decodeAudio(buf []byte) (audioFrame, error) {
	if len(buf) <= audioHeaderLen || buf[0] != frameOpus {
		return audioFrame{}, errNotAudio
	}
	if len(buf)-audioHeaderLen > maxOpusPayload {
		return audioFrame{}, errNotAudio
	}
	return audioFrame{
		Seq:     binary.BigEndian.Uint16(buf[1:3]),
		TS:      binary.BigEndian.Uint32(buf[3:7]),
		Payload: buf[audioHeaderLen:],
	}, nil
}

// opusDuration reads how much audio an Opus packet holds from its TOC byte
// (RFC 6716 §3.1), so whatever frame size the watch's encoder settles on is
// published with the right timing. Returns 0 for a packet it cannot parse.
func opusDuration(pkt []byte) time.Duration {
	if len(pkt) < 1 {
		return 0
	}
	toc := pkt[0]
	config := toc >> 3

	// Per-frame duration, in units of 2.5 ms (so 10 ms = 4).
	var unit int
	switch {
	case config < 12: // SILK: 10, 20, 40, 60 ms
		unit = []int{4, 8, 16, 24}[config%4]
	case config < 16: // Hybrid: 10, 20 ms
		unit = []int{4, 8}[config%2]
	default: // CELT: 2.5, 5, 10, 20 ms
		unit = []int{1, 2, 4, 8}[config%4]
	}

	var frames int
	switch toc & 0x3 {
	case 0:
		frames = 1
	case 1, 2:
		frames = 2
	case 3:
		if len(pkt) < 2 {
			return 0
		}
		frames = int(pkt[1] & 0x3f)
	}

	d := time.Duration(unit*frames) * 2500 * time.Microsecond
	// RFC 6716: a packet never holds more than 120 ms.
	if d <= 0 || d > 120*time.Millisecond {
		return 0
	}
	return d
}
