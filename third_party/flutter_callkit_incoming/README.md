# flutter_callkit_incoming (vendored + patched 3.1.3)

Vendored copy of `flutter_callkit_incoming` 3.1.3, wired in via
`dependency_overrides` in the app's `pubspec.yaml`.

**Only change vs. upstream 3.1.3:** a one-line fix in
`android/.../CallkitNotificationManager.kt` `VolumeKeyBroadcastReceiver` so it
ignores the spurious `VOLUME_CHANGED_ACTION` broadcasts that the self-managed
Telecom audio setup emits on Android 14/15/16 — which otherwise silence the
incoming ringtone ~1s in. See upstream issue #827. Only stop the ring on a real
RING-stream volume change.

To re-derive: `diff` against pub.dev 3.1.3; the sole edit is in that receiver.
