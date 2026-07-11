# Handoff: DIALR — 1:1 Caller App

## Overview
DIALR is a personal 1:1 calling app (voice + video) styled in a flat, architectural "Modernist" system: near-mono red on off-white, Archivo throughout, zero corner radius, strong 2px rules, black-and-white imagery. This package documents every screen, interaction, and design token needed to rebuild it in a real codebase.

Scope covered: registration (phone → SMS code), Recents (with missed-call emphasis), Contacts (auto-matched from the OS address book), a system contact-access permission sheet, Incoming call, Voice call, Video call, and Settings (profile). Phase 2 (group video) is intentionally out of scope — space is reserved on the video-call grid.

## About the Design Files
The files in this bundle are **design references created in HTML** — prototypes that show the intended look and behavior, **not production code to copy directly**. The `.dc.html` files use an internal streaming/React-ish component runtime (`support.js`) that is *not* part of your codebase and should not be shipped.

Your task is to **recreate these designs in the target codebase's existing environment** (React, SwiftUI, Kotlin/Compose, Flutter, etc.), using its established components, navigation, and libraries. If no environment exists yet, choose the most appropriate framework for a mobile calling app and implement there. Treat the HTML as the spec for layout, spacing, color, type, and interaction — re-express it idiomatically.

## Fidelity
**High-fidelity (hifi).** Colors, typography, spacing, and interactions are final. Recreate the UI pixel-accurately using your codebase's patterns. Exact values are in **Design Tokens** below.

## Platform note
Designed mobile-first at a **390×844** logical viewport (iOS reference). The side "index rail" and the desktop framing in the prototype are a **prototype navigator only** — do NOT build it. Ship only the phone screens. The on-device **bottom tab bar (Recents · Contacts · Settings)** is real navigation.

## Screens / Views

Reference device frame: 390 wide, 2px `--color-text` border, 0 radius, `--color-bg` fill. A 44px status bar sits at top of every screen (left: time `9:41` @ 14px/800; right: `5G · 100%` @ 11px/800).

### 1. Register — Phone (`reg-phone`)
- **Purpose**: Enter phone number to receive an SMS code.
- **Layout**: Single column, padding 34/24/28. Top-aligned content, primary button pinned to bottom via a flex spacer.
- **Components**:
  - Wordmark `DIALR` — Archivo 800, 26px.
  - Kicker `STEP 1 OF 2` — 11px/800, `--color-accent`, uppercase, letter-spacing 0.14em.
  - H1 `Your number` — Archivo 800, 40px, line-height 1.
  - Body paragraph — 14px/400, `--color-neutral-700`, line-height 1.55.
  - Country-code field: fixed box, `--color-surface` fill, 2px `--color-divider` border, min-height 50px. Leading `+` glyph (16px/800) then a numeric input **accepting up to 5 digits** (default `1`).
  - Phone-number input: flex-1, same field styling, `inputmode=tel`, placeholder `(555) 000-0000`.
  - Primary button `Send code` — full-width, `--color-accent` bg, `--color-bg` text, 15px/800 uppercase, left-aligned label + send icon; padding 17/18. Enabled only when the national number has ≥10 digits.

### 2. Register — Code (`reg-code`)
- **Purpose**: Enter the 6-digit SMS code.
- **Components**:
  - `‹ Back` link (top-left) → returns to reg-phone.
  - Kicker `STEP 2 OF 2`, H1 `Enter code`.
  - Body: `Sent by SMS to +<cc> <number>` (the entered value; the country code is preserved).
  - Code input: full-width, min-height 64px, Archivo 800, 34px, centered, letter-spacing 0.42em, placeholder `000000`; strips non-digits, max 6.
  - `Resend code` — 13px/800 accent, uppercase.
  - Primary button `Verify` (checkmark icon) — enabled at 6 digits → lands on Settings and sets the profile phone number.

### 3. Recents (`recents`)
- **Purpose**: Call history; open a call by tapping a row.
- **Layout**: Header → filter tabs → scrolling list → bottom tab bar.
- **Components**:
  - Header: H2 `Recents` (32px/800) + subtitle `<n> calls · tap to open` (12px/400 neutral-600). *(No action button in the header.)*
  - Filter segmented control: two equal cells `ALL` / `MISSED`, 13px/800 uppercase, top+bottom 2px rules and a 2px divider between; the active cell is `--color-accent` fill with `--color-bg` text.
  - Call rows (each): 46×46 initials tile (2px divider border, 15px/800 centered), name (17px/800), meta line (12px/400) `<Direction> · <Voice|Video>`, right-aligned time (11px/400 neutral-600). **Missed calls render the name AND meta in `--color-accent` (red)**; incoming/outgoing render name in `--color-text`, meta in neutral-600. Row divider: 1px `--color-divider` at ~18% opacity. Tapping a row starts a call of that row's mode.
  - Seed data: Mara Vance (missed·video·9:41 AM), Theo Grant (incoming·voice·Yesterday), Nadia Reyes (outgoing·voice·Yesterday), Owen Park (missed·video·Tuesday), Lena Fisk (outgoing·video·Monday), Sam Ives (incoming·voice·Monday). MISSED filter shows only missed.

### 4. Contacts (`contacts`)
- **Purpose**: People from the OS address book **who also use DIALR**, auto-matched. There is NO manual add-contact flow.
- **Components**:
  - Header: H2 `Contacts` + subtitle `<n> on DIALR`; top-right 44×44 outlined shield button → opens the system permission sheet.
  - Info strip: `--color-surface` bg, 11px/400 neutral-700: "Matched automatically from your phone's contacts — only people who use DIALR appear here."
  - Contact rows: 46×46 initials tile, name (17px/800), a small `■ ON DIALR` marker (6px accent square + 11px/800 accent uppercase), and two trailing action buttons — a 40×40 outlined **voice** (phone icon) and a 40×40 `--color-accent` **video** (video icon) button.
  - Only contacts where `onApp === true && access[name] === true` are listed.
  - Bottom tab bar.

### 5. System permission sheet (`picker`, overlay)
- **Purpose**: OS-style granular permission — choose which OS contacts DIALR may access. This REPLACES an in-app "add contact" screen.
- **Presentation**: Bottom sheet over a scrim (`--color-neutral-900` @ 45%), 82% height, 2px top border, slides up over any screen. Opened from the Contacts shield button and from Settings → "Contact access".
- **Components**:
  - Header: kicker `SYSTEM · PERMISSION`, title `Contacts DIALR can see`, close (✕) button.
  - Shield info strip explaining granular access.
  - Rows (all OS contacts): initials tile, name, status line `On DIALR` (accent) or `Not on DIALR` (neutral-500), and a 26×26 checkbox — checked = `--color-accent` fill with a white check; unchecked = 2px divider outline. Tapping the row toggles access.
  - Footer: full-width accent `Done · <n> allowed` button.
  - Toggling a row updates which people appear on the Contacts screen (only `onApp && granted`).

### 6. Incoming call (`incoming`)
- **Purpose**: Accept or decline an inbound call.
- **Components**:
  - Kicker `INCOMING · <VIDEO|VOICE> CALL` (accent).
  - 132×132 avatar tile: 2px `--color-text` border, initials 46px/800, diagonal-stripe grayscale placeholder fill.
  - H1 caller name (44px/800), sub `mobile · calling…` (14px neutral-600).
  - Bottom actions, full-width, left-aligned labels: `Decline` (2px divider outline, ✕ icon) then `Accept` (`--color-accent` fill, phone icon). Decline → Recents; Accept → live call.

### 7. Voice call (`call` + mode `voice`)
- **Components**:
  - Centered block: kicker `VOICE CALL`, 132×132 avatar tile, H1 name (40px), running timer `mm:ss` (18px/800 neutral-700, increments each second while in a call).
  - Control tray (top 2px rule, padding 24/26/30): a row of three controls, each = a 62×62 square button + a 10px/800 uppercase caption. **Mute** (mic / mic-off icon, caption `Mute`/`Muted`), **Speaker** (caption `Speaker`/`On`), **Video** (switches to video mode). Active/on state = `--color-accent` fill, `--color-bg` icon; idle = `--color-surface` fill + 2px divider border.
  - **End** button: compact, centered (not full-width), `--color-accent`, phone icon rotated 135°, `End` label.

### 8. Video call (`call` + mode `video`)
- **Components**:
  - Remote video area (flex-1): dark diagonal-stripe placeholder (`#242120` base, `#2f2c2b` 12px stripes), centered monospace label `REMOTE VIDEO` @ 28–32% white.
  - Top-left overlay: caller name (21px/800, `#f3f2f2`) + timer (12px, 82% white).
  - Self-view PIP **bottom-right**: 96×128, 2px `#f3f2f2` border, darker stripe fill, monospace label `YOU · <FRONT|BACK>`. (Toggle via `showSelfView` flag.)
  - Control tray (same structure as voice): **Mute**, **Flip · Front/Back** (switch-camera icon, active/accent — toggles the PIP label), **Voice** (switches to voice mode). Compact centered **End** below.

### 9. Settings (`settings`)
- **Components**:
  - H2 `Settings`.
  - Profile block: 88×88 avatar tile (initials, or the user's uploaded photo rendered grayscale, `object-fit:cover`); name (22px/800) + phone (12px neutral-600); a `Change photo` label-button wrapping a hidden `<input type=file accept=image/*>` (sets the avatar).
  - `PROFILE` section: `Display name` text input (min-height 46px, surface fill, 2px divider border) — edits the user name live; `Phone number` shown read-only in a field with an accent `Change` button → re-enters the registration phone step.
  - `ACCOUNT` section: `Contact access` row (chevron) → opens the system permission sheet; `Sign out` row (accent text) → returns to registration.
  - Bottom tab bar.

## Interactions & Behavior
- **Navigation**: bottom tab bar switches Recents / Contacts / Settings. Call, incoming, register, and the permission sheet are full-screen/overlay states without the tab bar.
- **Start call**: tapping a Recents row or a Contacts action button sets `screen='call'`, the chosen `mode`, resets timer/mute/speaker/camera, and closes the sheet.
- **Mute / Speaker / Camera flip**: toggle booleans; the button's fill flips to accent when active; camera flip swaps `front`/`back` and updates the PIP label.
- **Mode switch**: Video↔Voice changes `mode` in place (same call/timer).
- **Incoming**: Accept → live call; Decline / End → Recents.
- **Registration gating**: Send code enabled at ≥10 national digits; Verify enabled at 6 code digits; country code accepts up to 5 digits.
- **Timer**: 1s interval, only counts while `screen==='call'`, formatted `mm:ss`.
- No real telephony/SMS — this is a UI prototype.

## State Management
Single component state:
- `screen`: `'recents' | 'contacts' | 'incoming' | 'call' | 'settings' | 'reg-phone' | 'reg-code'`
- `mode`: `'voice' | 'video'`
- `filter`: `'all' | 'missed'`
- `muted`, `speaker`: booleans; `camera`: `'front' | 'back'`
- `elapsed`: number (seconds); `contact`: the active call's `{name}` (falls back to first recent)
- `picker`: boolean (permission sheet open)
- `access`: `{ [contactName]: boolean }` — which OS contacts are permitted
- `userName`, `userPhone`, `avatarUrl`
- `regCC` (country code, ≤5 digits, default `1`), `regPhone`, `regCode`
Contacts source: array of `{ name, onApp, granted }`; Contacts list = `onApp && access[name]`; permission sheet lists all.

## Design Tokens (Modernist system — see `modernist.css`)
- **Colors**: bg `#f3f2f2`; surface `#eae9e9`; text `#201e1d`; accent `#ec3013`; divider `rgba(32,30,29,0.4)`. Accent ramp: 600 `#dd2b0f`, 700 `#ae1800` (pressed / accent text on light). Neutral ramp: 500 `#9b9797`, 600 `#7d7979`, 700 `#605d5d`, 900 `#2d2b2b`.
- **Typography**: Archivo (Google Fonts), weights 400 / 600 / 800. Headings 800. Scale used: H1 40–44, H2 32, control captions 10–11 (uppercase, letter-spacing ~0.06–0.14em), body 12–16, code input 34.
- **Radius**: 0 everywhere (do not round corners).
- **Rules/borders**: major dividers 2px `--color-divider`; row dividers 1px at ~18% opacity; device border 2px `--color-text`.
- **Spacing**: 4 / 8 / 12 / 16 / 24 / 32.
- **Shadows** (only for elevated surfaces like the sheet): `--shadow-lg: 0 12px 32px rgba(45,43,43,0.22)`.
- **Interaction states**: hover = accent tint; pressed = one accent ramp step past base (`--color-accent-600`); focus-visible = 2px accent outline, 2px offset.

## Assets
- **Icons**: [Lucide](https://lucide.dev) — phone, phone-off (phone rotated 135°), mic, mic-off, video, volume-2, switch-camera, users, clock, settings/gear, shield, camera, send, check, chevrons, plus, x. Use Lucide (or your codebase's equivalent) at 2px stroke on `currentColor`.
- **Font**: Archivo via Google Fonts (`@import` in `modernist.css`).
- **Imagery**: avatars/video use grayscale diagonal-stripe placeholders — replace with real camera feeds / contact photos, always rendered grayscale per the system.
- **App icon & store screenshots**: in the project `store/` folder (icon is a white Lucide phone on `#ec3013`).

## Files
- `Caller App.dc.html` — the interactive prototype (all screens + logic). Primary reference.
- `Store Assets.dc.html` — app-icon and store-screenshot compositions.
- `modernist.css` — the design system: all tokens (`:root` variables), type scale, and component classes. Source of truth for values.
