/// <reference path="../pb_data/types.d.ts" />

// Contact discovery and invitations — replaces the `matchContacts` and
// `inviteContact` callable Cloud Functions.
//
//   POST /api/freecaller/match-contacts  {"phones": ["+7…", …]}
//     -> {"matches": [{"uid": …, "displayName": …, "phone": "+7…",
//                      "avatar": "photo.jpg"|""}, …]}
//
//   POST /api/freecaller/invite  {"name": …, "phone": "+7…", "email": …}
//     -> {"uid": …, "email": …, "emailed": true|false}   409 if either the
//        phone or the address already belongs to an account
//                                                        429 past the daily
//        quota (10 accounts created / 30 attempts per inviter per 24h)
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
          // Just the stored filename; the app builds the /api/files URL from
          // the server it is already talking to, rather than depending on the
          // dashboard's appURL setting being right.
          avatar: users[i].get("avatar") || "",
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

    // Everything that reaches the email below is somebody's free text: the
    // inviter's displayName is owner-editable, and the address is whatever was
    // typed into the sheet. Unescaped, a displayName of `<a href="https://…">`
    // is a phishing link delivered from the family's own trusted sender, to a
    // person who has been told to expect exactly this email.
    const esc = (raw) =>
      String(raw === null || raw === undefined ? "" : raw)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;")

    // The quota. See pb_migrations/1789900200_create_invites.js for why the
    // trail exists and what it (deliberately) does not hold.
    const MAX_CREATED_PER_DAY = 10
    const MAX_ATTEMPTS_PER_DAY = 30

    // Both helpers fail OPEN. The quota is a guard rail, and the collection
    // behind it arrives by migration: if that migration has not run (or the
    // table is unreadable) the right outcome is that invitations keep working
    // and the log says why they are uncounted — not that nobody can be invited.
    const countInvites = (uid, outcome) => {
      try {
        const since = new Date(Date.now() - 86400 * 1000)
          .toISOString()
          .replace("T", " ")
        const filter =
          "inviter = {:uid} && created > {:since}" +
          (outcome ? " && outcome = {:outcome}" : "")
        return $app.findRecordsByFilter("invites", filter, "", 100, 0, {
          uid: uid,
          since: since,
          outcome: outcome || "",
        }).length
      } catch (err) {
        console.log("invite: quota unavailable (not enforced): " + err)
        return 0
      }
    }
    const noteInvite = (uid, outcome) => {
      try {
        const row = new Record($app.findCollectionByNameOrId("invites"))
        row.set("inviter", uid)
        row.set("outcome", outcome)
        $app.save(row)
      } catch (err) {
        console.log("invite: could not record attempt: " + err)
      }
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

    // The address has to look like one, and must not carry anything that
    // could mean something to an HTML renderer or a mail header. PocketBase
    // validates it again on save; this just turns a 500 into a 400 and keeps
    // obvious junk away from the mailer.
    const emailOk =
      email.length <= 255 && /^[^\s@<>",;]+@[^\s@<>",;]+\.[^\s@<>",;]+$/.test(email)

    if (!name || name.length > 100 || !phone || !emailOk) {
      return e.json(400, {
        message: "A name, a valid phone and an email are required",
      })
    }

    // Quota, checked before anything is looked up: the 409 below answers "does
    // an account hold this number / address", and an unmetered oracle is its
    // own problem even when it creates nothing.
    if (
      countInvites(auth.id, "created") >= MAX_CREATED_PER_DAY ||
      countInvites(auth.id, "") >= MAX_ATTEMPTS_PER_DAY
    ) {
      console.log("invite: " + auth.id + " is over the daily quota")
      return e.json(429, {
        message: "Слишком много приглашений за сегодня, попробуйте завтра",
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

    // Somebody already has this number or this address. Refuse, rather than
    // quietly linking to their account: the invitation would have to go to the
    // address on that account, not the one just typed, and reporting either the
    // address or even "it went elsewhere" turns this endpoint into "type a
    // phone number, learn whose email it is".
    //
    // The message names nothing. Which of the two fields matched, and what the
    // account is, stay on the server.
    if (invitee) {
      console.log(
        "invite: refused, " + (invitee.id === auth.id ? "self" : invitee.get("email")) +
          " already holds phone " + phone + " / typed address " + email,
      )
      noteInvite(auth.id, "refused")
      return e.json(409, { message: "Такой аккаунт уже есть" })
    }

    // Accounts are never self-registered (createRule is null); provisioning one
    // is precisely the privilege this hook exists to lend the inviter.
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
    noteInvite(auth.id, "created")

    // Link both directions. Hook writes go through $app, which bypasses the API
    // rules — so this does what the old Cloud Function's arrayUnion did without
    // handing clients the ability to edit anyone's roster.
    const inviter = $app.findRecordById("users", auth.id)
    link(inviter, invitee.id)
    link(invitee, auth.id)

    // Tell the invitee, from here rather than from the inviter's phone: the
    // address IS the credential, so the one thing they must be told is which
    // address to type — and having the app say it in the same mailbox the code
    // will later arrive in proves the address works.
    //
    // Deliberately NO code in this email. A sign-in code lives 15 minutes,
    // which is nothing next to "install an app you have not heard of"; a code
    // that is always expired on arrival teaches people to distrust the one that
    // isn't. They get a fresh one the moment they ask for it.
    let emailed = false
    try {
      const settings = $app.settings()
      const inviterName = String(inviter.get("displayName") || "").trim()

      $app.newMailClient().send(
        new MailerMessage({
          from: {
            address: settings.meta.senderAddress,
            name: settings.meta.senderName,
          },
          to: [{ address: email }],
          subject: "Вас пригласили в «Звонилку»",
          html:
            "<p>Здравствуйте!</p>" +
            "<p>" +
            (inviterName ? esc(inviterName) + " приглашает вас" : "Вас пригласили") +
            " в «Звонилку» — приложение для звонков близким.</p>" +
            "<p>Установите приложение и на первом экране введите этот адрес " +
            "почты:</p>" +
            '<p style="font-size:20px"><strong>' + esc(email) + "</strong></p>" +
            "<p>Мы сразу пришлём сюда код для входа — пароль не нужен.</p>",
        }),
      )
      emailed = true
    } catch (err) {
      // The account exists and the roster is linked; only the notification
      // failed. Saying so beats failing an invite that actually succeeded —
      // the inviter can pass the address along by hand.
      console.log("invite: could not email " + email + ": " + err)
    }

    return e.json(200, { uid: invitee.id, email: email, emailed: emailed })
  },
  $apis.requireAuth(),
)

// Housekeeping for the invite trail: the quota only ever looks back one day, so
// a month is already generous (and enough to answer "who invited all these
// people?" after the fact). Self-contained, like every cron callback.
cronAdd("purgeInvites", "29 4 * * *", () => {
  const cutoff = new Date(Date.now() - 30 * 86400 * 1000)
    .toISOString()
    .replace("T", " ")
  let old = []
  try {
    old = $app.findRecordsByFilter("invites", "created < {:cutoff}", "", 1000, 0, {
      cutoff: cutoff,
    })
  } catch (err) {
    return
  }
  for (let i = 0; i < old.length; i++) {
    try {
      $app.delete(old[i])
    } catch (err) {
      // best effort
    }
  }
  if (old.length) {
    console.log("invite: purged " + old.length + " old trail record(s)")
  }
})
