// Shared PocketBase access for the admin/dev tools. No dependencies: Node's
// own fetch is enough, and these scripts are run by hand.
//
// PocketBase listens on 127.0.0.1 on the server, so from a laptop you tunnel:
//
//   ssh -N -L 8090:127.0.0.1:8090 root@<server>
//   PB_SUPERUSER_EMAIL=… PB_SUPERUSER_PASSWORD=… node tools/admin.mjs list
//
// Everything here authenticates as a SUPERUSER, which bypasses the collection
// rules — that is the point (the roster is admin-provisioned, never
// self-registered), and also why these scripts live outside the app.

export const PB_URL = process.env.PB_URL || 'http://127.0.0.1:8090';

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

export async function authenticate() {
  const identity = process.env.PB_SUPERUSER_EMAIL;
  const password = process.env.PB_SUPERUSER_PASSWORD;
  if (!identity || !password) {
    throw new Error('set PB_SUPERUSER_EMAIL and PB_SUPERUSER_PASSWORD');
  }
  const out = await pb('/api/collections/_superusers/auth-with-password', {
    method: 'POST',
    body: { identity, password },
  });
  token = out.token;
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
