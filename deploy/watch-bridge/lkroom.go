package main

// The real roomConn: a LiveKit participant that publishes one Opus track (the
// watch's mic) and subscribes to every audio track in the room (the peer).
//
// It subscribes to AUDIO ONLY. A video call's camera track would otherwise be
// pulled across and decrypted here just to be thrown away, and on a one-vCPU
// box that is the most expensive thing this process could do.

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/livekit/protocol/livekit"
	lksdk "github.com/livekit/server-sdk-go/v2"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
)

type lkRoom struct {
	ev roomEvents

	mu    sync.Mutex
	room  *lksdk.Room
	track *lksdk.LocalTrack
	pub   *lksdk.LocalTrackPublication

	closing   bool
	closeOnce sync.Once
}

func liveKitDialer(urlOverride string) roomDialer {
	return func(_ context.Context, grant roomGrant, ev roomEvents) (roomConn, error) {
		url := grant.URL
		if urlOverride != "" {
			url = urlOverride
		}
		r := &lkRoom{ev: ev}

		cb := lksdk.NewRoomCallback()
		cb.OnParticipantConnected = func(*lksdk.RemoteParticipant) { r.peersChanged() }
		cb.OnParticipantDisconnected = func(*lksdk.RemoteParticipant) { r.peersChanged() }
		cb.OnDisconnectedWithReason = func(reason lksdk.DisconnectionReason) {
			r.mu.Lock()
			closing := r.closing
			r.mu.Unlock()
			if !closing {
				ev.onRoomGone(string(reason))
			}
		}
		cb.ParticipantCallback.OnTrackPublished = func(pub *lksdk.RemoteTrackPublication, _ *lksdk.RemoteParticipant) {
			if pub.Kind() == lksdk.TrackKindAudio {
				_ = pub.SetSubscribed(true)
			}
		}
		cb.ParticipantCallback.OnTrackSubscribed = func(track *webrtc.TrackRemote, _ *lksdk.RemoteTrackPublication, _ *lksdk.RemoteParticipant) {
			if track.Kind() == webrtc.RTPCodecTypeAudio {
				go r.pump(track)
			}
		}

		room, err := lksdk.ConnectToRoomWithToken(url, grant.Token, cb, lksdk.WithAutoSubscribe(false))
		if err != nil {
			return nil, err
		}

		track, err := lksdk.NewLocalSampleTrack(webrtc.RTPCodecCapability{
			MimeType:    webrtc.MimeTypeOpus,
			ClockRate:   48000,
			Channels:    2,
			SDPFmtpLine: "minptime=10;useinbandfec=1",
		})
		if err != nil {
			room.Disconnect()
			return nil, err
		}
		pub, err := room.LocalParticipant.PublishTrack(track, &lksdk.TrackPublicationOptions{
			Name:   "microphone",
			Source: livekit.TrackSource_MICROPHONE,
		})
		if err != nil {
			room.Disconnect()
			return nil, err
		}

		r.mu.Lock()
		r.room, r.track, r.pub = room, track, pub
		r.mu.Unlock()

		// Tracks that were already published when we arrived (the caller joins
		// before the callee answers) never fire OnTrackPublished for us.
		for _, rp := range room.GetRemoteParticipants() {
			for _, p := range rp.TrackPublications() {
				if rpub, ok := p.(*lksdk.RemoteTrackPublication); ok && rpub.Kind() == lksdk.TrackKindAudio {
					_ = rpub.SetSubscribed(true)
				}
			}
		}
		r.peersChanged()
		return r, nil
	}
}

func (r *lkRoom) peersChanged() {
	r.mu.Lock()
	room := r.room
	r.mu.Unlock()
	if room == nil {
		return // still connecting; the dialer reports once it is done
	}
	r.ev.onPeer(len(room.GetRemoteParticipants()) > 0)
}

// pump forwards one remote audio track to the watch, packet for packet.
func (r *lkRoom) pump(track *webrtc.TrackRemote) {
	red := track.Codec().MimeType == "audio/red"
	for {
		pkt, _, err := track.ReadRTP()
		if err != nil {
			return
		}
		payload := pkt.Payload
		if red {
			if payload, err = redPrimary(payload); err != nil {
				continue
			}
		}
		if len(payload) == 0 {
			continue
		}
		// The RTP buffer is reused by the next ReadRTP.
		out := make([]byte, len(payload))
		copy(out, payload)
		r.ev.onAudio(audioFrame{Seq: pkt.SequenceNumber, TS: pkt.Timestamp, Payload: out})
	}
}

func (r *lkRoom) WriteOpus(payload []byte, dur time.Duration) error {
	r.mu.Lock()
	track := r.track
	r.mu.Unlock()
	if track == nil {
		return errors.New("no local track")
	}
	return track.WriteSample(media.Sample{Data: payload, Duration: dur}, nil)
}

func (r *lkRoom) SetMuted(muted bool) {
	r.mu.Lock()
	pub := r.pub
	r.mu.Unlock()
	if pub != nil {
		pub.SetMuted(muted)
	}
}

func (r *lkRoom) Close() {
	r.closeOnce.Do(func() {
		r.mu.Lock()
		r.closing = true
		room := r.room
		r.mu.Unlock()
		if room != nil {
			room.Disconnect()
		}
	})
}

// redPrimary extracts the primary (newest) Opus packet from an RFC 2198 RED
// payload. LiveKit clients publish audio with RED redundancy; the SFU only
// strips it for subscribers that did not offer audio/red, and whether this SDK
// offers it depends on its version — so both shapes are handled.
//
//	block header (more follow):  F=1 | PT(7) | ts offset(14) | length(10)  4 bytes
//	last header:                 F=0 | PT(7)                               1 byte
//	then the blocks' data in header order; the primary is the last one.
func redPrimary(p []byte) ([]byte, error) {
	off, redundant := 0, 0
	for {
		if off >= len(p) {
			return nil, errors.New("red: truncated header")
		}
		if p[off]&0x80 == 0 {
			off++
			break
		}
		if off+4 > len(p) {
			return nil, errors.New("red: truncated header")
		}
		redundant += int(p[off+2]&0x03)<<8 | int(p[off+3])
		off += 4
	}
	start := off + redundant
	if start > len(p) {
		return nil, errors.New("red: block lengths exceed payload")
	}
	return p[start:], nil
}
