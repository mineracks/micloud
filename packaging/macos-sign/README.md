# macOS code-signing + notarization (Developer ID)

Produces a **Developer-ID-signed + notarized + stapled** `micloud.app` and deploys it to the demo Mac.
This is the macOS lane — Developer ID direct distribution (not the Mac App Store).

## Why it matters (beyond Gatekeeper)

The demo app used to be **ad-hoc signed**. An ad-hoc signature's designated requirement pins the `cdhash`,
which changes on every build, so macOS **TCC treats each rebuild as a different app and wipes all Privacy
grants** (Calendar / Reminders / Contacts / Photos) — forcing a painful re-grant after every rebuild.

A **Developer ID** signature gives a stable, **team-based** requirement:

```
identifier "com.mineracks.micloud.dashboard" and anchor apple generic
  and certificate leaf[subject.OU] = NB859QPG78
```

That requirement is identical across rebuilds (and survives cert renewal), so tccd recognises a rebuilt app
as the same app and **keeps the grants**. You only re-grant **once**, the first time you switch from ad-hoc
to Developer ID; after that, rebuilds are silent.

## One-command pipeline

`./sign-notarize-deploy.sh` runs the whole thing on **one trusted host** (the Mac Studio, or any Mac with
the Swift toolchain + Xcode CLT). It:

1. builds `app/micloud` with `swiftc`
2. imports the vaulted Developer ID identity into a **throwaway keychain** (destroyed on exit — no standing
   cert on the host), plus the `DeveloperIDG2CA.cer` intermediate so the chain resolves
3. Developer-ID signs with hardened runtime + the sandbox entitlements + a secure timestamp
4. notarizes via `notarytool` (App Store Connect API key from the vault)
5. staples + verifies (`stapler`, `spctl`)
6. deploys the signed app to the demo Mac and restarts the LaunchAgent

No secrets are printed; the p12 / p8 live only in a `mktemp` dir that is shredded on exit.

### Host prerequisites (Mac Studio setup — the "no MacBook needed" path)

- this repo checked out (`~/micloud`)
- `~/mineracks-infrastructure` with a **current** `vault.yml` + `ansible/vault-password.txt`
  (`git pull` to refresh — the vault holds the Developer ID p12 + password, the notary `.p8` + key-id +
  issuer, and the signing-identity string, all added 2026-07-12)
- `swiftc`, `xcrun notarytool` (Xcode CLT), `sshpass`, `rsync`, `ansible-vault`
- network to Apple + reachability to the demo Mac (`LAN_HOST`)

Run it:

```sh
cd ~/micloud/packaging/macos-sign && ./sign-notarize-deploy.sh
```

Env overrides: `MICLOUD_INFRA`, `DEMO_HOST` / `DEMO_USER` / `DEMO_PW`, `MICLOUD_APP_DEST`, `NOTARY_TIMEOUT`,
`MICLOUD_SIGNING_IDENTITY`.

## Notarization timing

The **first** submission under a brand-new Apple Team ID goes through Apple's slow "in-depth analysis"
queue (that's the multi-day wait wifi2qr hit once). After the Team ID (`NB859QPG78`) is warm — which it is —
notarization is an automated malware scan that returns in **minutes**, including for a brand-new bundle ID.

## Vault variables used

`vault_wifi2qr_developer_id_p12_b64`, `vault_wifi2qr_developer_id_p12_password`,
`vault_wifi2qr_signing_identity`, `vault_wifi2qr_notary_key_p8_b64`, `vault_wifi2qr_notary_key_id`,
`vault_wifi2qr_notary_issuer` (shared with the wifi2qr signing setup — same Apple account/Team ID).
