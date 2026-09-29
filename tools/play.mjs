// Google Play upload — the Android half of `xcrun altool --upload-app`.
// No dependencies: the service-account JWT is signed with node:crypto and the
// Play Developer API is plain REST, so fetch is enough.
//
//   node tools/play.mjs tracks                       # what is live on each track
//   node tools/play.mjs upload                       # build/…/app-release.aab → internal
//   node tools/play.mjs upload --track production    # or alpha / beta / a custom track
//   node tools/play.mjs upload --draft               # stage it; roll out from the Console
//   node tools/play.mjs upload path/to/other.aab
//
// CREDENTIALS — a Google Cloud service account's JSON key, invited into the
// Play Console (Users and permissions) with release rights on this app. See
// "Google Play API" in docs/RUNBOOK.md for the one-time setup. The key is read
// from PLAY_SERVICE_ACCOUNT if set, else android/play-service-account.json —
// which `*-service-account*.json` in .gitignore keeps out of git.
//
// Every upload is one "edit": open it, attach the bundle, point the track at
// the new versionCode, commit. Nothing is visible on Play until the commit, and
// a failure part-way deletes the edit, so a half-done upload leaves no trace.
import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PACKAGE = 'com.unnanego.freecaller';
const API = `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${PACKAGE}`;
const UPLOAD_API = `https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/${PACKAGE}`;
const DEFAULT_AAB = join(ROOT, 'build/app/outputs/bundle/release/app-release.aab');
const KEY_FILE = process.env.PLAY_SERVICE_ACCOUNT || join(ROOT, 'android/play-service-account.json');

let token = null;

async function login() {
  let key;
  try {
    key = JSON.parse(readFileSync(KEY_FILE, 'utf8'));
  } catch (e) {
    throw new Error(`No service-account key at ${KEY_FILE} (${e.code || e.message}).\n` +
      'Set PLAY_SERVICE_ACCOUNT or put the key there — see "Google Play API" in docs/RUNBOOK.md.');
  }

  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const unsigned = b64({ alg: 'RS256', typ: 'JWT' }) + '.' + b64({
    iss: key.client_email,
    scope: 'https://www.googleapis.com/auth/androidpublisher',
    aud: key.token_uri,
    iat: now,
    exp: now + 3600,
  });
  const signature = createSign('RSA-SHA256').update(unsigned).sign(key.private_key, 'base64url');

  const res = await fetch(key.token_uri, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${signature}`,
    }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`token exchange -> ${res.status} ${JSON.stringify(data)}`);
  token = data.access_token;
  console.log(`Signed in as ${key.client_email}`);
}

async function play(path, { method = 'GET', body, upload } = {}) {
  const res = await fetch((upload ? UPLOAD_API : API) + path, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': upload ? 'application/octet-stream' : 'application/json',
    },
    body: upload ?? (body === undefined ? undefined : JSON.stringify(body)),
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : {};
  if (!res.ok) {
    throw new Error(`${method} ${path} -> ${res.status} ${data.error?.message || text}`);
  }
  return data;
}

async function withEdit(fn) {
  const { id } = await play('/edits', { method: 'POST' });
  try {
    return await fn(id);
  } catch (e) {
    await play(`/edits/${id}`, { method: 'DELETE' }).catch(() => {});
    throw e;
  }
}

async function tracks() {
  await withEdit(async (edit) => {
    const { tracks = [] } = await play(`/edits/${edit}/tracks`);
    for (const t of tracks) {
      console.log(`\n${t.track}`);
      for (const r of t.releases || []) {
        const codes = (r.versionCodes || []).join(', ') || '-';
        const fraction = r.userFraction ? ` @ ${r.userFraction * 100}%` : '';
        console.log(`  ${r.status}${fraction}  ${r.name || ''}  [versionCode ${codes}]`);
      }
    }
    // Read-only: drop the edit rather than commit an empty one.
    await play(`/edits/${edit}`, { method: 'DELETE' });
  });
}

async function upload({ aab, track, draft }) {
  let bytes;
  try {
    bytes = readFileSync(aab);
  } catch (e) {
    throw new Error(`No bundle at ${aab} (${e.code}). Run \`flutter build appbundle --release\` first.`);
  }

  await withEdit(async (edit) => {
    console.log(`Uploading ${aab} (${(bytes.length / 1e6).toFixed(1)} MB)…`);
    const bundle = await play(`/edits/${edit}/bundles`, { method: 'POST', upload: bytes });
    const code = bundle.versionCode;
    console.log(`Accepted as versionCode ${code}`);

    // The release name is the pubspec version, the same one that names the iOS
    // build — Play would otherwise show just "19".
    const pubspec = readFileSync(join(ROOT, 'pubspec.yaml'), 'utf8');
    const name = pubspec.match(/^version:\s*(\S+)/m)?.[1] ?? String(code);

    await play(`/edits/${edit}/tracks/${track}`, {
      method: 'PUT',
      body: {
        track,
        releases: [{ name, versionCodes: [String(code)], status: draft ? 'draft' : 'completed' }],
      },
    });

    try {
      await play(`/edits/${edit}:commit`, { method: 'POST' });
    } catch (e) {
      // An app that has never been published only accepts draft releases.
      if (!draft && /draft app/i.test(e.message)) {
        throw new Error(`${e.message}\nThe app is still a draft on Play — rerun with --draft.`);
      }
      throw e;
    }
    console.log(`${name} is on "${track}"${draft ? ' as a draft — roll it out from the Console' : ''}.`);
  });
}

function parseArgs(argv) {
  const opts = { aab: DEFAULT_AAB, track: 'internal', draft: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--track') opts.track = argv[++i];
    else if (a === '--draft') opts.draft = true;
    else if (a.startsWith('--')) throw new Error(`Unknown option ${a}`);
    else opts.aab = a;
  }
  return opts;
}

const [command, ...rest] = process.argv.slice(2);
try {
  if (command === 'tracks') {
    await login();
    await tracks();
  } else if (command === 'upload') {
    const opts = parseArgs(rest);
    await login();
    await upload(opts);
  } else {
    console.log('usage: node tools/play.mjs tracks | upload [--track internal] [--draft] [file.aab]');
    process.exitCode = command ? 1 : 0;
  }
} catch (e) {
  console.error(e.message);
  process.exitCode = 1;
}
