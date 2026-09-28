/// <reference path="../pb_data/types.d.ts" />

// Stop handing the whole roster to anyone who can sign in.
//
// 1784932900 set users.listRule / viewRule to `@request.auth.id != ""`, on the
// reasoning that "the roster is readable by the whole signed-in family". But
// "signed in" is not "family": the App Review accounts are signed in, and so is
// every stranger somebody invites by typing an email. Each of them could page
// through /api/collections/users/records and read every member's name, phone
// number and — through `contacts` — who knows whom.
//
// A record is now visible to:
//
//   id = @request.auth.id                 yourself
//   @request.auth.contacts.id ?= id       people in YOUR contacts
//   contacts.id ?= @request.auth.id       people who list YOU
//
// which is every read the app actually makes (checked against lib/data and
// lib/services at the time of writing):
//
//   - UserRepo._watchRecord: getOne(<own id>, expand: 'contacts') plus a
//     realtime subscription to the own record. The expanded records are checked
//     against this same view rule, and they are by definition "in my contacts".
//   - AuthService.authRefresh(): not governed by list/view rules at all.
//   - Nothing reads another user's record directly. A caller's name and number
//     travel on the call record; people found through the address book come
//     from /api/freecaller/match-contacts, which runs with hook (admin) rights
//     and returns only uid, name, phone and avatar filename; avatars are served
//     by /api/files, and the field is not `protected`, so no rule applies.
//
// The third clause is not used by the client today. It is there so that a
// one-way roster edge (the admin linked A -> B but not B -> A) does not make A
// invisible to the very person who is about to be rung by them.
//
// The leading `@request.auth.id != ""` is NOT redundant. PocketBase treats
// `x = ""` as "empty or NULL", so for a guest the third clause alone would read
// `contacts.id ?= ""` and match every account that has no contacts yet.
//
// Hooks ($app.find…) and superusers bypass API rules, so discovery, invites,
// the push fan-out, tools/admin.mjs and the dashboard are all unaffected.
migrate(
  (app) => {
    const users = app.findCollectionByNameOrId("users")
    const rule =
      '@request.auth.id != "" && (id = @request.auth.id || @request.auth.contacts.id ?= id || contacts.id ?= @request.auth.id)'
    users.listRule = rule
    users.viewRule = rule
    app.save(users)
  },
  (app) => {
    // Back to what 1784932900 set.
    const users = app.findCollectionByNameOrId("users")
    users.listRule = '@request.auth.id != ""'
    users.viewRule = '@request.auth.id != ""'
    app.save(users)
  },
)
