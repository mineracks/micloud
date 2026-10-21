# Privacy & keys — the commitment behind "you hold the keys"

The site says **"You hold the keys. Private by design."** This doc pins what that means and what we build
to back it. **Rule: never claim more privacy than the architecture delivers — but the architecture below
delivers a lot.**

## The model: encrypt in transit + at rest, with keys only the customer holds

Done on the Nextcloud/Immich VMs themselves:

- **In transit:** TLS everywhere — agent → storage, and customer → their instance.
- **At rest:** the instance's storage volume is **encrypted with a key only the customer holds** (e.g.
  LUKS/volume encryption; the key is the customer's, escrow is *their* choice). So:
  - the **storage host** (Hetzner, or Mineracks metal) **cannot read the raw disk**,
  - **backups are encrypted** to the same customer key,
  - a stolen/decommissioned disk is ciphertext.
- **Per-customer isolation:** every customer gets their **own** Nextcloud + Immich instance — never a
  shared pool, never scanned, never mined, never Apple.

That is a real, strong "**keys only you hold**" claim for the data at rest, in transit, and in backups.

## The one honest scope note (and the option that closes it)
A *running* managed instance must hold the volume unlocked in memory to serve you — that's what lets Immich
do face/object search, thumbnails and previews (true of *any* hosted app). So the default managed claim is
"**encrypted at rest + in transit with your key, on your own isolated instance**" — not "we can't read it
while it's live." For customers who want zero-knowledge even at runtime:

- **Optional End-to-end mode:** the Mac agent encrypts client-side *before* upload; the instance stores
  blobs it can't decrypt. **True zero-knowledge, even at runtime** — at the cost of server-side features
  (you browse via a client that holds the key). This is what the site's "turn on end-to-end mode" commits to.
  Make it a labelled customer choice, not a silent default.

**Self-host** needs none of this nuance: the customer runs the whole thing, so they hold the keys, the
storage, and the code. Mineracks has zero access, full stop.

## What we build (to back the claims)
- **Customer-held volume-encryption key** per managed instance — generated/held by the customer; rotate,
  revoke, export at will; Mineracks operates but never *owns* the key.
- **Encrypted at-rest volumes + encrypted backups**, keyed to the customer.
- **TLS** in transit everywhere.
- **Per-customer isolation** — own instance/keys, never multi-tenant shared data. The load-bearing promise.
- **Optional client-side E2EE mode** in the agent (encrypt-before-upload) for runtime zero-knowledge.
- **One-way enforced** — the agent only reads iCloud; can never write/delete in the Apple account.
- **Open source** — agent (and ideally the deploy) auditable; "verify, don't trust" needs readable code.

## Claim boundaries (so copy never outruns reality)
- ✅ "Encrypted in transit and at rest, with keys only you hold." — the default (customer-held volume key).
- ✅ "You hold the keys" — self-host (literal) and managed (customer-held key + isolated instance).
- ✅ "Your own isolated instance — never a shared pool, never mined, never Apple."
- ✅ "The storage host can't read it; backups are encrypted to your key."
- ✅ "Private by design, not by promise" — isolation, one-way, encryption, open source.
- ✅ "Turn on end-to-end mode for true zero-knowledge, even while it's running (trades some managed features)."
- ⚠️ "We *literally cannot* read it, ever" — only accurate in End-to-end mode; don't say it for default managed.
