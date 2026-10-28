# Spike T07: Keychain access across self-signed rebuilds

**Result: passed for the question asked, with one open observation.** Builds signed with the same self-signed certificate keep reading their keychain items after a code change, with no prompt. An ad-hoc build also got in without a visible prompt, so the certificate may not be the only thing macOS goes by (see Open observation).
**Date:** 2026-10-19 · macOS 27.0.1 · Xcode 27 · certificate "Kairos Local Signing" (self-signed, login keychain)

## Question

Without a paid developer team ID, the app can't use the data protection keychain. It stores keys in the login keychain, where macOS ties access to the app's code identity. Does one stable self-signed certificate keep that access across updates without password prompts?

## Setup

- `Secrets.KeychainStore` writes generic-password items with `kSecUseDataProtectionKeychain: false` (service `com.keneepatel.kairos`).
- Debug-only routes: `kairos://debug/keychain-write` (build A) and `kairos://debug/keychain-read` (later builds). Results go to the unified log under category `debug`.
- The app reads its identity from `KAIROS_SIGNING_IDENTITY`, so only the app target is signed with the certificate.

## Evidence

| Build | Signing | Code identity (designated requirement) | CDHash | Result |
| --- | --- | --- | --- | --- |
| A, build 1 | Kairos Local Signing | `identifier "com.keneepatel.kairos" and certificate leaf = H"1473…2763"` | `e84a…a532` | Wrote the item |
| B, build 2, with a source change | Kairos Local Signing | same as A | `6e1d…565b` (different code) | Read "written by build 1" at once, no prompt |
| C, build 3 (control) | ad hoc | `cdhash H"8135…6441"` | `8135…6441` | Also read the item at once (expected a prompt) |

The item's access list afterwards (`security dump-keychain -a`, filtered to this item; no secret values involved):

- **Trusted applications:** `identifier "com.keneepatel.kairos" and certificate leaf = H"1473…2763"`, and `cdhash H"8135…6441"`
- **Partition IDs:** `cdhash:e84a…`, `cdhash:6e1d…`, `cdhash:8135…`

## Findings

1. **A stable certificate works.** Build B, with different code, kept access with no prompt. The question this spike asked is answered: yes.
2. **Debug builds signed with the certificate need `ENABLE_DEBUG_DYLIB=NO`.** With the hardened runtime on, macOS refused to load Xcode's separate debug library ("different Team IDs"), and a self-signed certificate has no team. Release builds don't use that library. `docs/signing.md` passes the setting.
3. **XcodeGen had hard-coded the version numbers** (`1.0` and build `1`) into Info.plist, ignoring `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`. Fixed in `App/project.yml`.

## Open observation

The ad-hoc control build C was also let in, and its code hash was added to both the trusted-application list and the partition list. A `SecurityAgent` process started during C's run, but the read finished in under half a second, too fast for someone to click a dialog.

Two explanations fit:

- macOS added C on its own because it has the same bundle ID and path as the item's creator.
- A dialog appeared and was answered before the read returned.

**Ask the owner** whether any keychain dialog appeared around 00:51 on 2026-10-19.

For the product this changes little. Signed releases keep access across updates (finding 1), and friends never run ad-hoc builds. But the login keychain may not keep a different app with the same bundle ID out without a prompt. That's acceptable for API keys a user can rotate, and is noted in SPEC §15.

## Cleanup

The test item stays in the login keychain under service `com.keneepatel.kairos`, account `debug.signing-spike`. Delete it in Keychain Access, or run `security delete-generic-password -s com.keneepatel.kairos -a debug.signing-spike`.
