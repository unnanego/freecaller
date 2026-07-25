// Family roster admin tool — the PocketBase replacement for the old
// Firestore-based tools/admin.ts.
//
// Accounts are never self-registered (the users collection has no create rule),
// so this is how someone joins: an admin provisions them, and they sign in with
// an emailed one-time code. There are no activation or login codes any more.
//
//   ssh -N -L 8090:127.0.0.1:8090 root@<server>     # PocketBase is loopback-only
//   export PB_SUPERUSER_EMAIL=… PB_SUPERUSER_PASSWORD=…
//
//   node tools/admin.mjs list
//   node tools/admin.mjs add-user "Аида" +79150000000 aida@example.com
//   node tools/admin.mjs link <who> <who>        # mutual contacts, both ways
//   node tools/admin.mjs unlink <who> <who>
//   node tools/admin.mjs devices <who>           # what would ring for them
//   node tools/admin.mjs apply roster.json       # provision a whole roster
//
// <who> is an email, phone, display name or record id.
import { readFileSync } from 'node:fs';

import { authenticate, findUser, listUsers, pb } from './pb.mjs';

const [command, ...args] = process.argv.slice(2);

const usage = () => {
  console.log(
    'usage: admin.mjs list | add-user <name> <phone> <email> | ' +
      'link <who> <who> | unlink <who> <who> | devices <who> | apply <roster.json>',
  );
  process.exit(1);
};

/**
 * Provision one account. Password auth is disabled collection-wide, but an auth
 * record still carries a hash — so give it one nobody will ever hold. Sign-in
 * is the emailed one-time code.
 */
async function createUser({ name, phone, email }) {
  const password = crypto.randomUUID() + crypto.randomUUID();
  return pb('/api/collections/users/records', {
    method: 'POST',
    body: {
      displayName: name,
      phone,
      email: email.toLowerCase(),
      contacts: [],
      password,
      passwordConfirm: password,
      verified: true,
    },
  });
}

/** Both directions, idempotently — a roster edge is meaningless one-way. */
async function setLink(a, b, linked) {
  for (const [self, other] of [
    [a, b],
    [b, a],
  ]) {
    const contacts = new Set(self.contacts || []);
    if (linked) contacts.add(other.id);
    else contacts.delete(other.id);
    await pb(`/api/collections/users/records/${self.id}`, {
      method: 'PATCH',
      body: { contacts: [...contacts] },
    });
  }
}

await authenticate();

switch (command) {
  case 'list': {
    const users = await listUsers();
    for (const u of users) {
      console.log(
        `${(u.displayName || '?').padEnd(18)} | ${(u.phone || '—').padEnd(15)} | ` +
          `${(u.email || '—').padEnd(28)} | contacts=${(u.contacts || []).length} | ${u.id}`,
      );
    }
    console.log(`\n${users.length} user(s)`);
    break;
  }

  case 'add-user': {
    const [name, phone, email] = args;
    if (!name || !phone || !email) usage();
    const created = await createUser({ name, phone, email });
    console.log(`created ${created.displayName} <${created.email}> ${created.id}`);
    console.log('They sign in with that email — the code is emailed to them.');
    break;
  }

  case 'link':
  case 'unlink': {
    const [a, b] = args;
    if (!a || !b) usage();
    const [ua, ub] = await Promise.all([findUser(a), findUser(b)]);
    await setLink(ua, ub, command === 'link');
    console.log(
      `${command === 'link' ? 'linked' : 'unlinked'} ${ua.displayName} <-> ${ub.displayName}`,
    );
    break;
  }

  case 'devices': {
    const [who] = args;
    if (!who) usage();
    const user = await findUser(who);
    const page = await pb('/api/collections/devices/records', {
      query: { filter: `user = '${user.id}'`, perPage: '50' },
    });
    if (page.items.length === 0) {
      console.log(`${user.displayName} has NO registered devices — they cannot be rung.`);
    }
    for (const d of page.items) {
      const token = d.voipToken || d.fcmToken || '—';
      console.log(
        `${d.platform.padEnd(8)} | ${d.deviceId} | ${token.slice(0, 16)}… | ${d.updated}`,
      );
    }
    break;
  }


  // Declarative roster: the family is ~10 people who all know each other, and
  // re-typing add-user/link by hand is how someone ends up half-linked. Safe to
  // re-run — existing accounts are matched by email and only their missing
  // links are added.
  case 'apply': {
    const [file] = args;
    if (!file) usage();
    const roster = JSON.parse(readFileSync(file, 'utf8'));

    const byEmail = new Map();
    for (const person of roster.people || []) {
      const email = person.email.toLowerCase();
      let record = null;
      try {
        record = await findUser(email);
        console.log(`exists  ${person.name} <${email}>`);
      } catch {
        record = await createUser(person);
        console.log(`created ${person.name} <${email}> ${record.id}`);
      }
      byEmail.set(email, record);
    }

    // "everyone" is the common case for a family; explicit pairs are for the
    // review accounts, which must NOT see the real roster.
    const pairs = [];
    if (roster.linkEveryone) {
      const all = [...byEmail.values()].filter(
        (u) => !(roster.excludeFromEveryone || [])
          .map((e) => e.toLowerCase())
          .includes(String(u.email).toLowerCase()),
      );
      for (let i = 0; i < all.length; i++) {
        for (let j = i + 1; j < all.length; j++) pairs.push([all[i], all[j]]);
      }
    }
    for (const [a, b] of roster.links || []) {
      pairs.push([byEmail.get(a.toLowerCase()) || (await findUser(a)),
                  byEmail.get(b.toLowerCase()) || (await findUser(b))]);
    }

    for (const [a, b] of pairs) {
      // Re-read: setLink writes the whole contacts array, so it must start from
      // what the previous pair just wrote, not from a stale copy.
      const [fresh_a, fresh_b] = await Promise.all([
        findUser(a.email || a.id),
        findUser(b.email || b.id),
      ]);
      await setLink(fresh_a, fresh_b, true);
    }
    console.log(`\n${byEmail.size} account(s), ${pairs.length} link(s) applied`);
    break;
  }

  default:
    usage();
}

process.exit(0);
