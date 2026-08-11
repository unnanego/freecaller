// Shared PocketBase access for the admin/dev tools. No dependencies: Node's
// own fetch is enough, and these scripts are run by hand.
//
// PocketBase answers on https://pb.holographica.space, and also on 127.0.0.1 on
// the server itself, which is what the default here assumes:
//
//   ssh -N -L 8090:127.0.0.1:8090 root@<server>      # for the loopback default
//   PB_URL=https://pb.holographica.space node tools/admin.mjs list
//
// CREDENTIALS — two ways, in this order:
//
//   1. The macOS Keychain (preferred; nothing in a file, nothing in shell
//      history, and nothing for a stray `git add` to catch). Store them once:
//
//        security add-generic-password -s freecaller-pb -a <superuser-email> -w
//
//      That prompts for the password without echoing it. The first tool run
//      afterwards raises a Keychain dialog — "Always Allow" makes it the last.
//      Change it later by adding `-U` to the same command.
//
//   2. PB_SUPERUSER_EMAIL / PB_SUPERUSER_PASSWORD in the environment, which win
//      when set — for CI, or a one-off against another server.
//
// Everything here authenticates as a SUPERUSER, which bypasses the collection
// rules — that is the point (the roster is admin-provisioned, never
// self-registered), and also why these scripts live outside the app.
import { execFileSync } from 'node:child_process';

export const PB_URL = process.env.PB_URL || 'http://127.0.0.1:8090';

/** Keychain service name holding the superuser email (account) + password. */
const KEYCHAIN_SERVICE = process.env.PB_KEYCHAIN_SERVICE || 'freecaller-pb';

let token = null;

export async function pb(path, { method = 'GET', body, query } = {}) {
  const url = new URL(PB_URL + path);
  for (const [k, v] of Object.entries(query || {})) {
    if (v !== undefined) url.searchParams.set(k, v);
  }

  const res = await fetch(url, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: token } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await res.text();
  const data = text ? JSON.parse(text) : {};
  if (!res.ok) {
    throw new Error(`${method} ${path} -> ${res.status} ${JSON.stringify(data)}`);
  }
  return data;
}

/**
 * The superuser login from the macOS Keychain, or null if it isn't stored (or
 * access was refused at the dialog).
 *
 * Two lookups because `security` will either print the attributes or the
 * password, never both: the account attribute carries the email, `-w` the
 * secret. The secret goes straight into the request below — never logged, never
 * written anywhere, and it stays out of shell history and process arguments.
 */
function fromKeychain() {
  const read = (args) =>
    execFileSync('security', ['find-generic-password', '-s', KEYCHAIN_SERVICE, ...args], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  try {
    const identity = read([]).match(/"acct"<blob>="([^"]*)"/)?.[1];
    const password = read(['-w']).replace(/\n$/, '');
    return identity && password ? { identity, password } : null;
  } catch {
    // No such item, or the user declined the Keychain prompt.
    return null;
  }
}

export async function authenticate() {
  const stored = process.env.PB_SUPERUSER_PASSWORD ? null : fromKeychain();
  const identity = process.env.PB_SUPERUSER_EMAIL || stored?.identity;
  const password = process.env.PB_SUPERUSER_PASSWORD || stored?.password;
  if (!identity || !password) {
    throw new Error(
      'no superuser credentials: store them once with\n' +
        `  security add-generic-password -s ${KEYCHAIN_SERVICE} -a <superuser-email> -w\n` +
        'or set PB_SUPERUSER_EMAIL and PB_SUPERUSER_PASSWORD',
    );
  }
  const out = await pb('/api/collections/_superusers/auth-with-password', {
    method: 'POST',
    body: { identity, password },
  });
  token = out.token;
}

/**
 * The superuser token from [authenticate], for the few requests that cannot go
 * through [pb] — impersonating a roster member, say, whose response has to be
 * carried on a *different* Authorization header afterwards.
 */
export function authToken() {
  return token;
}

/** Find one roster member by email, phone, display name or id. */
export async function findUser(needle) {
  const escaped = String(needle).replace(/'/g, "\\'");
  const filter =
    `email = '${escaped}' || phone = '${escaped}' || ` +
    `displayName = '${escaped}' || id = '${escaped}'`;
  const page = await pb('/api/collections/users/records', {
    query: { filter, perPage: '2' },
  });
  if (page.items.length === 0) throw new Error(`no user matches "${needle}"`);
  if (page.items.length > 1) throw new Error(`"${needle}" matches more than one user`);
  return page.items[0];
}

export async function listUsers() {
  const page = await pb('/api/collections/users/records', {
    query: { perPage: '200', sort: 'created' },
  });
  return page.items;
}
