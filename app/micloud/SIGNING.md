# micloud demo app — code signing & TCC persistence

## The problem
Ad-hoc signing (`codesign --sign -`) pins the **cdhash** in the app's designated requirement, and the cdhash
changes on every build. macOS TCC keys each Privacy grant to that requirement, so after a rebuild the app no
longer matches — tccd treats it as a **different app and drops every grant** (Calendar, Reminders, Contacts,
Photos). Re-granting headlessly on the demo tart VM is painful (real HID over VNC), so every rebuild cost a
full re-grant.

## The fix: Developer ID signing
Sign with the **`Developer ID Application: mineracks pty ltd (NB859QPG78)`** identity. The designated
requirement becomes stable and **team-based** (cdhash-free):

```
identifier "com.mineracks.micloud.dashboard" and anchor apple generic
  and certificate leaf[subject.OU] = NB859QPG78
```

Identical across rebuilds (and across cert renewal), so tccd keeps the grants. You re-grant **once** when
switching from ad-hoc → Developer ID; thereafter rebuilds are silent. It also enables notarization.

- `build.sh` auto-detects a `Developer ID Application` identity in the keychain and signs with it +
  hardened runtime; with no cert it falls back to ad-hoc (loudly warned).
- The full **build → sign → notarize → staple → deploy** pipeline lives in
  [`../../packaging/macos-sign/`](../../packaging/macos-sign/) and runs on one trusted host (the Mac
  Studio) using vaulted materials in a throwaway keychain — see that README for the "no MacBook needed"
  setup.

## PPPC profile (optional, needs MDM)
`make-pppc-profile.sh` generates `micloud-pppc.mobileconfig`, which would pre-grant the four services with
**no prompt at all** — but a PPPC profile only takes effect for Calendar/Contacts/Reminders/Photos when
delivered by an **MDM the Mac is enrolled in** (UAMDM/supervised); a double-clicked profile is ignored for
those services. With Developer ID signing + the one-time grant, you don't need it — it's the artifact to
hand an MDM if the demo Mac is ever enrolled. It keys on the same stable team-based requirement.
