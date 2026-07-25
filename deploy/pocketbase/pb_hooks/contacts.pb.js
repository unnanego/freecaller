/// <reference path="../pb_data/types.d.ts" />

// Contact discovery and invitations — replaces the `matchContacts` and
// `inviteContact` callable Cloud Functions.
//
//   POST /api/freecaller/match-contacts  {"phones": ["+7…", …]}
//     -> {"matches": [{"uid": …, "displayName": …, "phone": "+7…"}, …]}
//
//   POST /api/freecaller/invite  {"name": …, "phone": "+7…", "email": …}
//     -> {"uid": …, "email": …}
//
// Both need to read or write records the caller has no rule-level access to
// (the whole roster; another user's contacts), which is exactly what a hook is
// for: $app calls bypass the API rules, so authorization is spelled out here.
//
// Everything each handler needs is declared INSIDE it — PocketBase runs hook
// callbacks in separate goja runtimes, where file-level consts are not in scope.

routerAdd(
  "POST",
  "/api/freecaller/match-contacts",
  (e) => {
    // Best-effort E.164. The client already normalizes with libphonenumber
    // before uploading, and the admin provisions `phone` in E.164, so this only
    // has to survive stray spaces and the Russian 8-prefix habit — it is not a
    // phone-number parser and must not pretend to be one.
    const toE164 = (raw) => {
      const trimmed = String(raw || "").trim()
      if (!trimmed) return ""
      const plus = trimmed.charAt(0) === "+"
      let digits = trimmed.replace(/\D/g, "")
      if (!plus && digits.length === 11 && digits.charAt(0) === "8") {
        digits = "7" + digits.slice(1)
      }
      if (digits.length < 8 || digits.length > 15) return ""
      return "+" + digits
    }

    const auth = e.auth
    if (!auth) {
      return e.json(401, { message: "Sign in required" })
    }

    let phones = []
    try {
      const body = e.requestInfo().body
      phones = body.phones || []
    } catch (err) {
      return e.json(400, { message: "Malformed request body" })
    }
    if (!Array.isArray(phones)) {
      return e.json(400, { message: "phones must be an array" })
    }

    // Cap the input so a huge address book can't turn into a huge scan.
    const wanted = {}
    let wantedCount = 0
    for (let i = 0; i < phones.length && i < 2000; i++) {
      const e164 = toE164(phones[i])
      if (e164 && !wanted[e164]) {
        wanted[e164] = true
        wantedCount++
      }
    }
    if (wantedCount === 0) {
      return e.json(200, { matches: [] })
    }

    // Scan the roster and normalize both sides, rather than filtering on an
    // exact string match: a family roster is a couple of dozen records, and the
    // stored format is whatever the admin typed.
    const users = $app.findRecordsByFilter("users", "id != {:me}", "", 500, 0, {
      me: auth.id,
    })

    const matches = []
    for (let i = 0; i < users.length; i++) {
      const e164 = toE164(users[i].get("phone"))
      if (e164 && wanted[e164]) {
        matches.push({
          uid: users[i].id,
          displayName: users[i].get("displayName"),
          phone: e164,
        })
      }
    }

    return e.json(200, { matches: matches })
  },
  $apis.requireAuth(),
)

routerAdd(
  "POST",
  "/api/freecaller/invite",
  (e) => {
    const toE164 = (raw) => {
      const trimmed = String(raw || "").trim()
      if (!trimmed) return ""
      const plus = trimmed.charAt(0) === "+"
      let digits = trimmed.replace(/\D/g, "")
      if (!plus && digits.length === 11 && digits.charAt(0) === "8") {
        digits = "7" + digits.slice(1)
      }
      if (digits.length < 8 || digits.length > 15) return ""
      return "+" + digits
    }

    const link = (record, otherId) => {
      const contacts = record.get("contacts") || []
      if (contacts.indexOf(otherId) === -1) {
        contacts.push(otherId)
        record.set("contacts", contacts)
        $app.save(record)
      }
    }

    const auth = e.auth
    if (!auth) {
      return e.json(401, { message: "Sign in required" })
    }

    let name = ""
    let phone = ""
    let email = ""
    try {
      const body = e.requestInfo().body
      name = String(body.name || "").trim()
      phone = toE164(body.phone)
      email = String(body.email || "").trim().toLowerCase()
    } catch (err) {
      return e.json(400, { message: "Malformed request body" })
    }

    if (!name || !phone || email.indexOf("@") < 1) {
      return e.json(400, {
        message: "A name, a valid phone and an email are required",
      })
    }

    // Reuse an account that already exists for this person — by email first
    // (it is the credential and is unique), then by phone. Inviting someone
    // twice must link, not duplicate.
    let invitee = null
    try {
      invitee = $app.findAuthRecordByEmail("users", email)
    } catch (err) {
      // no account with that email
    }

    if (!invitee) {
      const roster = $app.findRecordsByFilter("users", "", "", 500, 0)
      for (let i = 0; i < roster.length; i++) {
        if (toE164(roster[i].get("phone")) === phone) {
          invitee = roster[i]
          break
        }
      }
    }

    if (invitee && invitee.id === auth.id) {
      return e.json(400, { message: "That's your own account" })
    }

    if (!invitee) {
      // Accounts are never self-registered (createRule is null); provisioning
      // one is precisely the privilege this hook exists to lend the inviter.
      const collection = $app.findCollectionByNameOrId("users")
      invitee = new Record(collection)
      invitee.set("email", email)
      invitee.set("displayName", name)
      invitee.set("phone", phone)
      invitee.set("contacts", [])
      invitee.set("verified", true)
      // Password auth is disabled collection-wide; an auth record still needs a
      // hash, so give it one nobody will ever hold. Sign-in is email OTP.
      invitee.setPassword($security.randomString(40))
      $app.save(invitee)
      console.log("invite: provisioned " + email + " (" + invitee.id + ")")
    }

    // Link both directions. Hook writes go through $app, which bypasses the API
    // rules — so this does what the old Cloud Function's arrayUnion did without
    // handing clients the ability to edit anyone's roster.
    link($app.findRecordById("users", auth.id), invitee.id)
    link(invitee, auth.id)

    return e.json(200, { uid: invitee.id, email: email })
  },
  $apis.requireAuth(),
)
