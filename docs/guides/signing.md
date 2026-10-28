# Signing Kairos without the paid developer program

Kairos is signed with one stable **self-signed** code-signing certificate instead of an Apple Developer ID (ADR-013). Every build signed with the same certificate has the same code identity, so the login keychain keeps letting the app read its saved keys after an update.

The certificate stays in your login keychain. Never commit it, export it into the repo, or paste its private key anywhere. CI gets an encrypted copy later (T57).

## 1. Create the certificate (once)

1. Open **Keychain Access** (search for it in Spotlight).
2. From the menu bar, choose **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Fill in:
   - **Name:** `Kairos Local Signing`
   - **Identity Type:** Self-Signed Root
   - **Certificate Type:** Code Signing
4. Click **Create**, then **Done**. It lands in the **login** keychain.
5. Check it from Terminal:
   ```bash
   security find-identity -p codesigning
   ```
   You should see `Kairos Local Signing`. A "not trusted" note next to it is expected for a self-signed certificate and doesn't stop signing.

## 2. Sign your everyday builds too

Builds from Xcode or `xcodebuild` are ad-hoc unless told otherwise, and an ad-hoc build gets a new code identity every time. The login keychain then treats each rebuild as a new app and asks for your password once for every saved key. To sign this Mac's builds with the certificate:

```bash
cp App/Config/Local.xcconfig.example App/Config/Local.xcconfig
(cd App && xcodegen generate)
```

`Local.xcconfig` is git-ignored, so CI and fresh clones stay ad-hoc. It also turns off Xcode's separate debug library, which macOS won't load into an app signed without a team ID (finding 2 of the spike below).

The first launch after switching asks once for each key saved by an earlier ad-hoc build. Choose **Always Allow**: that adds the certificate's identity to the key, and later builds are let in without asking. Keys saved from now on are the app's own and never ask.

Kairos also avoids reading keys it doesn't need. Opening the app reads none: the masked key shown in Settings is a hint stored beside the key, readable without unlocking it. Each key is then read at most once per launch, however many runs use it.

## 3. Spike T07: does the keychain stay quiet across updates?

Kairos debug builds have two terminal-only routes: `kairos://debug/keychain-write` saves a test item, and `kairos://debug/keychain-read` reads it back. The question is whether build B, with different code but the same certificate, can read build A's item **without a keychain password prompt**.

From the repo root:

```bash
build() {  # $1 = build number, $2 = signing identity
  (cd App && xcodegen generate >/dev/null)
  xcodebuild -project App/Kairos.xcodeproj -scheme Kairos -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData -quiet build \
    CURRENT_PROJECT_VERSION="$1" KAIROS_SIGNING_IDENTITY="$2" ENABLE_DEBUG_DYLIB=NO
}
APP=build/DerivedData/Build/Products/Debug/Kairos.app

# Build A writes the item
build 1 "Kairos Local Signing" && open "$APP" && sleep 3 && open "kairos://debug/keychain-write"
pkill -x Kairos

# Build B (new build number, so new code) reads it. Watch the screen for a keychain prompt.
build 2 "Kairos Local Signing" && open "$APP" && sleep 3 && open "kairos://debug/keychain-read"
pkill -x Kairos

# Control: an ad-hoc build should trigger the prompt, which shows the problem being solved
build 3 "-" && open "$APP" && sleep 3 && open "kairos://debug/keychain-read"
pkill -x Kairos
```

`ENABLE_DEBUG_DYLIB=NO` matters: with the hardened runtime on, macOS won't load Xcode's separate debug library into an app signed by a certificate with no team ID. Release builds don't have that library.

Results appear in the log:

```bash
/usr/bin/log show --last 10m --info --predicate 'subsystem == "com.keneepatel.kairos"' --style compact | grep keychain-spike
```

**Pass:** build B logs `read: written by build 1` with no prompt on screen.
**Fail:** a dialog asks to allow Kairos to use the keychain item. The fallback options are in `docs/archive/plan-v1.md` (Risks).

Clean up afterwards: in Keychain Access, search for `debug.signing-spike` and delete the item.
