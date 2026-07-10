/**
 * Family roster admin tool. Runs locally with a service-account key
 * (Admin SDK bypasses Firestore rules — this is the only writer of the
 * roster and activation codes).
 *
 * Usage:
 *   export GOOGLE_APPLICATION_CREDENTIALS=path/to/service-account.json
 *   npx tsx tools/admin.ts add-user "Аида" +79150000000
 *   npx tsx tools/admin.ts link <uidA> <uidB>          # mutual contacts
 *   npx tsx tools/admin.ts code <uid>                  # new activation code
 *   npx tsx tools/admin.ts list
 */
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { randomInt } from "node:crypto";

initializeApp();
const db = getFirestore();

async function addUser(displayName: string, phone: string): Promise<void> {
  if (!/^\+\d{7,15}$/.test(phone)) throw new Error(`Not E.164: ${phone}`);
  const clash = await db.collection("users").where("phone", "==", phone).get();
  if (!clash.empty) throw new Error(`Phone ${phone} already belongs to ${clash.docs[0].id}`);

  const user = await getAuth().createUser({ displayName });
  await db.collection("users").doc(user.uid).set({
    phone,
    displayName,
    contacts: [],
    isAdmin: false,
    createdAt: Timestamp.now(),
  });
  console.log(`Created ${displayName} (${phone}): uid=${user.uid}`);
  await makeCode(user.uid);
}

async function link(uidA: string, uidB: string): Promise<void> {
  await db.collection("users").doc(uidA).update({ contacts: FieldValue.arrayUnion(uidB) });
  await db.collection("users").doc(uidB).update({ contacts: FieldValue.arrayUnion(uidA) });
  console.log(`Linked ${uidA} <-> ${uidB}`);
}

async function makeCode(uid: string): Promise<void> {
  const user = await db.collection("users").doc(uid).get();
  if (!user.exists) throw new Error(`No such user: ${uid}`);

  // Retry on the unlikely collision with an existing unexpired code.
  for (let i = 0; i < 5; i++) {
    const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
    const ref = db.collection("activationCodes").doc(code);
    if ((await ref.get()).exists) continue;
    await ref.set({
      uid,
      expiresAt: Timestamp.fromMillis(Date.now() + 72 * 3600 * 1000),
      usedAt: null,
      createdAt: Timestamp.now(),
    });
    console.log(`Activation code for ${user.data()!.displayName}: ${code} (valid 72h)`);
    return;
  }
  throw new Error("Could not mint a unique code");
}

async function list(): Promise<void> {
  const users = await db.collection("users").get();
  for (const doc of users.docs) {
    const u = doc.data();
    console.log(`${doc.id}  ${u.displayName}  ${u.phone}  contacts=[${u.contacts.join(", ")}]`);
  }
}

const [cmd, ...args] = process.argv.slice(2);
const commands: Record<string, () => Promise<void>> = {
  "add-user": () => addUser(args[0], args[1]),
  link: () => link(args[0], args[1]),
  code: () => makeCode(args[0]),
  list,
};

const run = commands[cmd];
if (!run) {
  console.error("Usage: admin.ts <add-user|link|code|list> ...");
  process.exit(1);
}
run().catch((err) => {
  console.error(err.message ?? err);
  process.exit(1);
});
