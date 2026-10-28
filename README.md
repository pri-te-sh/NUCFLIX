# NucFlix

A Netflix-style player for **Xtream Codes** IPTV providers, on iPhone and Fire TV, with one shared account.

- **One household account** (Firebase). Sign in on the iPhone with Google or email.
- **Profiles are people** (you, the kids, …). Each has its own My List, Continue Watching and recommendations. Kids profiles never show adult content.
- **IPTV lines are shared.** The Xtream login is saved in the account (Firestore), never on a device. Apps hold it in memory only while they play.
- **TVs pair with a code.** The Fire TV shows an 8-character code; enter it on the iPhone under **Settings → Pair a TV**.
- **Watch on one, continue on the other.** Favorites and playback positions sync live between the iPhone and the TVs.

```
NucFlix/                 iOS app (SwiftUI)
NucFlix.xcodeproj
NucFlixFireTV/           Fire TV app (WebView UI + native ExoPlayer, no Gradle)
firebase/                Firestore security rules, emulator tests, deploy scripts
scripts/fetch-vlckit.sh  downloads the iOS player engine
```

## iOS app

SwiftUI, iOS 17+. Live TV with EPG, movies, series, downloads for offline viewing, AirPlay and Picture-in-Picture. Playback uses MobileVLCKit, so MKV/TS and other containers AVPlayer can't open still play.

### Build

1. Fetch MobileVLCKit (about 1 GB unpacked, not in git):
   ```bash
   ./scripts/fetch-vlckit.sh
   ```
2. Open `NucFlix.xcodeproj`. Swift packages (Firebase, GoogleSignIn) resolve on first open.
3. Under **Signing & Capabilities**, choose your team. If you change the bundle ID (`com.priteshbhavsar.NucFlix`), register it as an iOS app in the Firebase project and replace `NucFlix/GoogleService-Info.plist`. Also update the `com.googleusercontent.apps…` URL scheme in `NucFlix/Info.plist` with the new `REVERSED_CLIENT_ID`.
4. Run on your iPhone. With a free Apple ID, trust the developer profile under **Settings → General → VPN & Device Management**.

### Testing against the local emulators

Debug builds launched with `-useFirebaseEmulator` use the Auth (9099) and Firestore (8181) emulators started from `firebase/` (see below) instead of the live project.

## Fire TV app

A 1920×1080 web UI (`NucFlixFireTV/web/`) built for the remote, running in a WebView over a native Media3 ExoPlayer surface. The TV signs in anonymously, pairs with the account through the code screen, then shows **Who's watching?**.

```bash
cd NucFlixFireTV
./build.sh                    # build/NucFlix.apk (aapt2 → javac → R8 → zipalign → apksigner)
./build.sh --install          # also installs and launches it on the Fire TV
./build.sh --debug --install  # debuggable build: the WebView UI can be inspected from chrome://inspect
```

- Needs the Android SDK (`ANDROID_SDK`, default `~/Library/Developer/Xamarin/android-sdk-macosx`) and ADB debugging on the TV.
- The first build runs `fetch-libs.sh`, which downloads the Media3 ExoPlayer jars and R8 into `libs/` and `tools/`.
- Local settings go in `NucFlixFireTV/local.properties`, which is not committed:
  - `firetv=<ip>:5555` is the TV used by `--install`. You can also set it with the `FIRETV` variable.
  - `storePass=…` is the password for `keystore.jks`.
- The first build creates the signing key with a random password. Back up `keystore.jks` and `local.properties` together. A build signed with a different key won't install over the existing app; you would have to uninstall it first, which unpairs the TV.

While developing in a desktop browser, serve `NucFlixFireTV/web/` from `localhost`. On localhost the app talks to the local Firebase emulators.

## Firebase

`firebase/` holds the Firestore rules and their emulator tests.

```bash
cd firebase
npm install
npm test               # starts the emulators and runs the rules tests
npm run deploy:rules   # deploys firestore.rules once the tests pass
```

Data model: `users/{uid}` holds `lines`, `profiles/{id}` (with `favorites` and `progress`), `members` (paired TVs) and `devices`; `pairing/{code}` holds short-lived TV pairing codes. Content keys are `<lineId>:<kind>:<id>`.
