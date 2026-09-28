/// <reference path="../pb_data/types.d.ts" />

// A trail of invitation attempts, so that /api/freecaller/invite can have a
// daily quota.
//
// An invite provisions a real account and sends a real email from the family's
// own mailbox, and nothing recorded WHO had asked for either — so there was
// nothing to count, and one signed-in account could mint accounts and mail
// strangers in a loop (and get the sending domain blacklisted, which for an app
// whose only sign-in is an emailed code is a total outage).
//
// One row per attempt that got past input validation, successful or refused:
//
//   inviter   the uid that asked. Plain text, not a relation — same reasoning
//             as `reports`: the trail should not vanish (and the quota reset)
//             because the account was deleted and re-invited.
//   outcome   "created" | "refused". Refusals are counted too, more loosely:
//             the 409 is an oracle for "does this phone/email have an account".
//
// Deliberately NOT stored: the invitee's name, phone or email. The quota needs
// none of them, and a table of everyone anybody ever tried to invite is exactly
// the kind of thing this backend should not be keeping.
//
// Entirely hook-owned, like email_changes: every rule is null, and the route
// reads and writes it through $app. Old rows are purged by a cron in
// pb_hooks/contacts.pb.js.
migrate(
  (app) => {
    const invites = new Collection({
      type: "base",
      name: "invites",
      fields: [
        { type: "text", name: "inviter", required: true, max: 255 },
        {
          type: "select",
          name: "outcome",
          required: true,
          maxSelect: 1,
          values: ["created", "refused"],
        },
        { type: "autodate", name: "created", onCreate: true },
      ],
      listRule: null,
      viewRule: null,
      createRule: null,
      updateRule: null,
      deleteRule: null,
    })
    app.save(invites)

    // The only query there is: "this inviter, since yesterday".
    invites.addIndex("idx_invites_inviter_created", false, "inviter, created", "")
    app.save(invites)
  },
  (app) => {
    try {
      app.delete(app.findCollectionByNameOrId("invites"))
    } catch (err) {
      // already gone
    }
  },
)
