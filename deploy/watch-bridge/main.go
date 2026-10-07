// watch-bridge seats an Apple Watch in a LiveKit call.
//
// watchOS has no WebRTC, so the watch cannot join a LiveKit room itself. This
// process joins on its behalf — as the watch's own account, with a room token
// minted by PocketBase for that account — and relays Opus packets between the
// room and a WebSocket from the watch. See protocol.go for the wire format and
// docs/watch-plan.md for why it exists.
//
// Configuration (environment):
//
//	BRIDGE_LISTEN         127.0.0.1:8095   behind Caddy at /bridge/*
//	PB_URL                http://127.0.0.1:8090
//	LIVEKIT_URL           ""  (override the URL the token endpoint returns,
//	                           e.g. ws://127.0.0.1:7880 to skip the public hop)
//	BRIDGE_MAX_SESSIONS   6
//	BRIDGE_DETACH_GRACE   15s
//	BRIDGE_POLL           1s
//	BRIDGE_ECHO           0   (1 enables /bridge/echo for on-device tests)
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	cfg := config{
		listen:      env("BRIDGE_LISTEN", "127.0.0.1:8095"),
		pbURL:       env("PB_URL", "http://127.0.0.1:8090"),
		livekitURL:  env("LIVEKIT_URL", ""),
		maxSessions: envInt("BRIDGE_MAX_SESSIONS", 6),
		detachGrace: envDuration("BRIDGE_DETACH_GRACE", 15*time.Second),
		pollEvery:   envDuration("BRIDGE_POLL", time.Second),
		echo:        env("BRIDGE_ECHO", "0") == "1",
	}

	b := newBridge(cfg, newPBClient(cfg.pbURL), liveKitDialer(cfg.livekitURL))
	srv := &http.Server{
		Addr:              cfg.listen,
		Handler:           b.routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		log.Printf("watch-bridge listening on %s (pb=%s, echo=%v)", cfg.listen, cfg.pbURL, cfg.echo)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop

	log.Print("shutting down")
	b.closeAll()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil && v > 0 {
		return v
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if v, err := time.ParseDuration(os.Getenv(key)); err == nil && v > 0 {
		return v
	}
	return def
}
