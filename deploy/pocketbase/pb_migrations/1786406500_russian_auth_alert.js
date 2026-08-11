/// <reference path="../pb_data/types.d.ts" />

// Russian "login from a new location" email, and advice that is actually true.
//
// PocketBase sends this by default in English, and it ends with "change your
// {APP_NAME} account password to revoke access" — which nobody here can do: this
// collection has passwordAuth DISABLED (see 1784932900), sign-in is an emailed
// one-time code and there is no password to change. A security email whose
// instruction cannot be followed is worse than none: the reader is alarmed and
// has nowhere to go. For a family member the actionable step is to tell whoever
// set the app up, who can sign that device out (tools/admin.mjs, devices).
//
// `{APP_NAME}` is "Freecaller", the ASCII name the stores show. The Russian text
// hardcodes «Звонилка» so it can be declined properly — same reason the OTP
// template in configure-mail.sh does.
//
// The superuser gets its own wording: that account is a real password login, so
// there the English advice does apply.
migrate(
  (app) => {
    const users = app.findCollectionByNameOrId("users")
    users.authAlert.emailTemplate.subject = "Вход в «Звонилку» с нового устройства"
    users.authAlert.emailTemplate.body = [
      "<p>Здравствуйте!</p>",
      "<p>В ваш аккаунт в «Звонилке» только что вошли с нового устройства:</p>",
      "<p><em>{ALERT_INFO}</em></p>",
      "<p>Если это были вы — просто удалите это письмо.</p>",
      "<p><strong>Если это были не вы — скажите тому, кто настраивал вам «Звонилку»:",
      " он отключит это устройство.</strong></p>",
      "<p>Команда «Звонилки»</p>",
    ].join("\n")
    app.save(users)

    const superusers = app.findCollectionByNameOrId("_superusers")
    superusers.authAlert.emailTemplate.subject = "Вход в панель «Звонилки» с нового устройства"
    superusers.authAlert.emailTemplate.body = [
      "<p>Вход в панель управления «Звонилки»:</p>",
      "<p><em>{ALERT_INFO}</em></p>",
      "<p>Если это были не вы — немедленно смените пароль администратора:",
      " это закроет доступ со всех остальных устройств.</p>",
    ].join("\n")
    app.save(superusers)
  },
  (app) => {
    // Back to PocketBase's own English defaults, verbatim.
    const english = {
      subject: "Login from a new location",
      body:
        "<p>Hello,</p>\n" +
        "<p>We noticed a login to your {APP_NAME} account from a new location:</p>\n" +
        "<p><em>{ALERT_INFO}</em></p>\n" +
        "<p><strong>If this wasn't you, you should immediately change your {APP_NAME} " +
        "account password to revoke access from all other locations.</strong></p>\n" +
        "<p>If this was you, you may disregard this email.</p>\n" +
        "<p>\n  Thanks,<br/>\n  {APP_NAME} team\n</p>",
    }
    for (const name of ["users", "_superusers"]) {
      const collection = app.findCollectionByNameOrId(name)
      collection.authAlert.emailTemplate.subject = english.subject
      collection.authAlert.emailTemplate.body = english.body
      app.save(collection)
    }
  },
)
