package main

import (
	"bytes"
	"encoding/base64"
	"testing"
	"time"
)

func TestAudioFrameRoundTrip(t *testing.T) {
	in := audioFrame{Seq: 65535, TS: 0xdeadbeef, Payload: []byte{0x78, 1, 2, 3}}
	out, err := decodeAudio(encodeAudio(in))
	if err != nil {
		t.Fatal(err)
	}
	if out.Seq != in.Seq || out.TS != in.TS || !bytes.Equal(out.Payload, in.Payload) {
		t.Fatalf("got %+v, want %+v", out, in)
	}
}

func TestDecodeAudioRejects(t *testing.T) {
	cases := map[string][]byte{
		"empty":       {},
		"header only": encodeAudio(audioFrame{})[:audioHeaderLen],
		"wrong kind":  append([]byte{0x02, 0, 0, 0, 0, 0, 0}, 0x78),
		"too large":   encodeAudio(audioFrame{Payload: make([]byte, maxOpusPayload+1)}),
	}
	for name, buf := range cases {
		if _, err := decodeAudio(buf); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestOpusDuration(t *testing.T) {
	cases := []struct {
		name string
		pkt  []byte
		want time.Duration
	}{
		// config 31 = CELT FB 20 ms, code 0 = one frame. What the watch sends.
		{"celt 20ms", []byte{31<<3 | 0}, 20 * time.Millisecond},
		{"celt 10ms", []byte{30<<3 | 0}, 10 * time.Millisecond},
		{"celt 2.5ms", []byte{28<<3 | 0}, 2500 * time.Microsecond},
		{"silk 60ms", []byte{3<<3 | 0}, 60 * time.Millisecond},
		{"hybrid 20ms", []byte{13<<3 | 0}, 20 * time.Millisecond},
		{"two 20ms frames", []byte{31<<3 | 1}, 40 * time.Millisecond},
		{"code 3, 3 frames", []byte{31<<3 | 3, 3}, 60 * time.Millisecond},
		{"code 3, too long", []byte{31<<3 | 3, 7}, 0},
		{"code 3, truncated", []byte{31<<3 | 3}, 0},
		{"empty", nil, 0},
	}
	for _, c := range cases {
		if got := opusDuration(c.pkt); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestRedPrimary(t *testing.T) {
	primary := []byte{0xf8, 0xaa, 0xbb}
	redundant := []byte{0xf8, 0x11}

	// One redundant block (4-byte header, length 2) + last header + data.
	p := []byte{0x80 | 111, 0x00, 0x00, byte(len(redundant)), 111}
	p = append(p, redundant...)
	p = append(p, primary...)
	got, err := redPrimary(p)
	if err != nil || !bytes.Equal(got, primary) {
		t.Fatalf("got %x, %v; want %x", got, err, primary)
	}

	// No redundancy at all: just the 1-byte header.
	got, err = redPrimary(append([]byte{111}, primary...))
	if err != nil || !bytes.Equal(got, primary) {
		t.Fatalf("plain: got %x, %v", got, err)
	}

	// Lengths that point past the end.
	if _, err := redPrimary([]byte{0x80 | 111, 0x00, 0x03, 0xff, 111}); err == nil {
		t.Fatal("accepted an overlong block")
	}
	if _, err := redPrimary([]byte{0x80 | 111, 0x00}); err == nil {
		t.Fatal("accepted a truncated header")
	}
}

func fakeToken(uid string) string {
	enc := base64.RawURLEncoding.EncodeToString
	return enc([]byte(`{"alg":"HS256"}`)) + "." +
		enc([]byte(`{"id":"`+uid+`","type":"auth","collectionId":"_pb_users_auth_"}`)) + ".sig"
}

func TestTokenUserID(t *testing.T) {
	if uid, err := tokenUserID(fakeToken("abc123")); err != nil || uid != "abc123" {
		t.Fatalf("got %q, %v", uid, err)
	}
	enc := base64.RawURLEncoding.EncodeToString
	bad := []string{
		"",
		"not-a-jwt",
		"a.!!!.c",
		"a." + enc([]byte(`{"type":"auth"}`)) + ".c",
		"a." + enc([]byte(`{"id":"x","type":"file"}`)) + ".c",
	}
	for _, tok := range bad {
		if _, err := tokenUserID(tok); err == nil {
			t.Errorf("accepted %q", tok)
		}
	}
}
