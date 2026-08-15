/// <reference path="../pb_data/types.d.ts" />

// Moving an account to a different mailbox.
//
//   POST /api/freecaller/email-change/request  {"email": "new@mail.ru"}
//     -> {"expiresIn": 900}        409 if the address belongs to someone
//                                  429 if one was just sent
//
//   POST /api/freecaller/email-change/confirm  {"code": "12345678"}
//     -> {"token": …, "record": …}  a fresh session on the new address;
//                                   400 on a wrong, expired or missing code
//
// Why not PocketBase's own request/confirm-email-change pair: confirming it
// requires the account's password, and this collection has password auth
// disabled — sign-in is an emailed one-time code and nothing else. So the same
// idea is rebuilt here on the same proof: possession of the new mailbox.
//
// The proof matters more than usual. The address IS the credential: get it
// wrong and every future sign-in code goes to a mailbox nobody owns, with no
// password, no recovery address and no support desk — only the family admin and
// the PocketBase dashboard. So the old address keeps working until the new one
// has answered.
//
// Everything each handler needs is declared INSIDE it — PocketBase runs hook
// callbacks in separate goja runtimes, where file-level consts are not in scope.

routerAdd(
  "POST",
  "/api/freecaller/email-change/request",
  (e) => {
    const auth = e.auth
    if (!auth) {
      return e.json(401, { message: "Sign in required" })
    }

    let email = ""
    try {
      email = String(e.requestInfo().body.email || "")
        .trim()
        .toLowerCase()
    } catch (err) {
      return e.json(400, { message: "Malformed request body" })
    }

    if (email.indexOf("@") < 1 || email.indexOf(".") < 0 || email.length > 255) {
      return e.json(400, { message: "Неверный адрес почты" })
    }

    const user = $app.findRecordById("users", auth.id)
    if (String(user.get("email") || "").toLowerCase() === email) {
      return e.json(400, { message: "Это уже ваш адрес" })
    }

    // Taken addresses are refused rather than merged: one person is one
    // account, and the invite route already guards the same invariant.
    let existing = null
    try {
      existing = $app.findAuthRecordByEmail("users", email)
    } catch (err) {
      // free
    }
    if (existing) {
      console.log(
        "email-change: refused, " + email + " already belongs to " + existing.id,
      )
      return e.json(409, { message: "Этот адрес уже занят" })
    }

    const now = Math.floor(Date.now() / 1000)

    // One code per minute per account. Mail is slow and people tap twice; the
    // limit is here so that a second tap cannot invalidate the code that is
    // already in flight to them.
    let pending = null
    try {
      const found = $app.findRecordsByFilter(
        "email_changes",
        "user = {:uid}",
        "-created",
        1,
        0,
        { uid: auth.id },
      )
      pending = found.length ? found[0] : null
    } catch (err) {
      pending = null
    }
    if (pending && now - Number(pending.get("sentAt") || 0) < 60) {
      return e.json(429, { message: "Код уже отправлен, подождите минуту" })
    }

    // Eight digits and fifteen minutes, matching the sign-in code: the person
    // reading this one aloud to the person typing it is the same pair.
    const code = $security.randomStringWithAlphabet(8, "0123456789")

    const collection = $app.findCollectionByNameOrId("email_changes")
    const record = pending || new Record(collection)
    record.set("user", auth.id)
    record.set("newEmail", email)
    record.set("codeHash", $security.sha256(auth.id + ":" + code))
    record.set("attempts", 0)
    record.set("sentAt", now)
    record.set("expiresAt", now + 900)
    $app.save(record)

    // Sent to the NEW address, deliberately: arriving there is the whole proof.
    try {
      const settings = $app.settings()
      $app.newMailClient().send(
        new MailerMessage({
          from: {
            address: settings.meta.senderAddress,
            name: settings.meta.senderName,
          },
          to: [{ address: email }],
          subject: "Код для смены почты в «Звонилке»",
          html:
            "<p>Здравствуйте!</p>" +
            "<p>Вы просили привязать «Звонилку» к этому адресу. Введите этот " +
            "код в приложении:</p>" +
            '<p style="font-size:28px;letter-spacing:3px"><strong>' +
            code +
            "</strong></p>" +
            "<p>Код действует 15 минут. Пока вы его не введёте, вход " +
            "остаётся на старом адресе.</p>" +
            "<p>Если вы этого не просили — просто удалите это письмо.</p>",
        }),
      )
    } catch (err) {
      // Nothing was changed yet, and a pending code nobody received would only
      // block the next attempt for a minute — so drop it and say so plainly.
      console.log("email-change: could not mail " + email + ": " + err)
      try {
        $app.delete(record)
      } catch (err2) {
        // best effort
      }
      return e.json(502, { message: "Не удалось отправить письмо" })
    }

    console.log("email-change: code sent to " + email + " for " + auth.id)
    return e.json(200, { expiresIn: 900 })
  },
  $apis.requireAuth(),
)

routerAdd(
  "POST",
  "/api/freecaller/email-change/confirm",
  (e) => {
    const auth = e.auth
    if (!auth) {
      return e.json(401, { message: "Sign in required" })
    }

    let code = ""
    try {
      code = String(e.requestInfo().body.code || "").replace(/\D/g, "")
    } catch (err) {
      return e.json(400, { message: "Malformed request body" })
    }
    if (!code) {
      return e.json(400, { message: "Введите код из письма" })
    }

    let pending = null
    try {
      const found = $app.findRecordsByFilter(
        "email_changes",
        "user = {:uid}",
        "-created",
        1,
        0,
        { uid: auth.id },
      )
      pending = found.length ? found[0] : null
    } catch (err) {
      pending = null
    }
    if (!pending) {
      return e.json(400, { message: "Сначала запросите код" })
    }

    const now = Math.floor(Date.now() / 1000)
    if (now > Number(pending.get("expiresAt") || 0)) {
      $app.delete(pending)
      return e.json(400, { message: "Код истёк, запросите новый" })
    }

    // Five guesses at eight digits, then the code is burned and a fresh one has
    // to be mailed — an online guessing budget, not a rate limit.
    const attempts = Number(pending.get("attempts") || 0)
    if (attempts >= 5) {
      $app.delete(pending)
      return e.json(400, { message: "Слишком много попыток, запросите новый код" })
    }

    if ($security.sha256(auth.id + ":" + code) !== String(pending.get("codeHash"))) {
      pending.set("attempts", attempts + 1)
      $app.save(pending)
      return e.json(400, { message: "Неверный код" })
    }

    const email = String(pending.get("newEmail") || "")

    // Someone may have been invited onto this address in the fifteen minutes
    // since the code went out.
    let existing = null
    try {
      existing = $app.findAuthRecordByEmail("users", email)
    } catch (err) {
      // free
    }
    if (existing && existing.id !== auth.id) {
      $app.delete(pending)
      return e.json(409, { message: "Этот адрес уже занят" })
    }

    // Written through $app, which bypasses both the API rules and the
    // owner-side field guard in users.pb.js — this route IS the sanctioned way
    // past it.
    //
    // Changing the email rotates the record's token key, which invalidates
    // every token ever issued for this account. That is PocketBase's own
    // behaviour and it cost the first person who tried this a sign-out on the
    // phone in their hand. Two things guard against it here:
    //
    //   1. The previous key is written back, so the other phones this family
    //      signed in on stay signed in. Being silently logged out is the worst
    //      failure this app has — worse than a stale session on a device the
    //      owner still holds — and the address is not a password: nobody is
    //      locked out by keeping it.
    //   2. The response is a full auth response, so the phone that made the
    //      change swaps in a fresh token either way, without a round trip that
    //      could fail in between.
    const user = $app.findRecordById("users", auth.id)
    const previous = String(user.get("email") || "")
    const previousTokenKey = user.get("tokenKey")
    user.set("email", email)
    user.set("verified", true)
    user.set("tokenKey", previousTokenKey)
    $app.save(user)
    $app.delete(pending)

    console.log("email-change: " + auth.id + " moved from " + previous + " to " + email)
    return $apis.recordAuthResponse(e, user, "email-change")
  },
  $apis.requireAuth(),
)

// Housekeeping: a code nobody used is rubbish after a day. Same hour as the
// diagnostics purge, and equally best-effort.
cronAdd("purgeEmailChanges", "17 4 * * *", () => {
  const cutoff = Math.floor(Date.now() / 1000) - 86400
  let stale = []
  try {
    stale = $app.findRecordsByFilter(
      "email_changes",
      "expiresAt < {:cutoff}",
      "",
      500,
      0,
      { cutoff: cutoff },
    )
  } catch (err) {
    return
  }
  for (let i = 0; i < stale.length; i++) {
    try {
      $app.delete(stale[i])
    } catch (err) {
      // best effort
    }
  }
  if (stale.length) {
    console.log("email-change: purged " + stale.length + " stale request(s)")
  }
})
