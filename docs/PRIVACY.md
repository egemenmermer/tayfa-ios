# Privacy inventory

This inventory describes source-observed behavior. It is not a published privacy policy or a claim about uninspected server retention. Whoever distributes a build (for example through TestFlight) must confirm the App Store privacy answers against their own server's retention and logging.

## App manifest

`Apps/ROOMS/PrivacyInfo.xcprivacy` is copied into the app root by Xcode. Tracking is false and there are no tracking domains. Required-reason declarations:

- **UserDefaults / CA92.1**: account/origin-scoped last community/channel selection and personal playback/noise-reduction preferences in the app's own defaults only; no other app/group/system defaults are read.
- **SystemBootTime / 35F9.1**: monotonic time for join/reconnect deadlines. No raw boot time/uptime leaves the app. The user-shareable connection report contains categorical events and states, not those times.

The checked-out LiveKit 2.17.0, WebRTC and UniFFI manifests remain intact. The archive verifier checks their bundled presence and plist validity, not Apple's complete privacy validation.

## Data and disclosures to confirm

| Data | Source-observed use | Proposed purpose / linkage | Confirmation needed |
|---|---|---|---|
| Email address | Existing Stoat login/account | App functionality; linked to account | Account-server retention/privacy policy |
| Name and user ID | Account/profile, participants, message authors | App functionality; linked to account | Retention/deletion and community visibility |
| Messages, profile content, other files | Existing Stoat chat/Autumn upload service | Other user content; functionality; linked to account | Storage, deletion and upload retention |
| Photos/videos | User-selected attachments, optional profile avatars | App functionality; linked to account | Server retention; no broad photo-library permission; live camera is a separate explicit action |
| Audio files | User-selected generic attachments can include audio | App functionality; linked to account | Attachment retention; this declaration is not a claim that calls are recorded |
| Real-time microphone/camera/screen media | LiveKit sends microphone/camera only after explicit enable; selected remote screen and visible room cameras are received | Transport for live room functionality | Server operator decides SFU/relay recording, logging and retention; do not assume recording exists or is impossible |
| Password/session/grant | Password used transiently at login; session in device-only Keychain; short-lived grant in memory | Authentication | Server logging rules; credentials excluded from diagnostics and repository |
| Diagnostics | Last twenty categorical media events, counts and state kept in memory; user-triggered share only | No automatic telemetry SDK or automatic collection | Any future feedback collection process/disclosure |
| Network metadata | Network type observed locally; normal API/SFU connections transmit transport metadata | Connectivity | Server access logs, IP retention, hosting/subprocessors |

The manifest conservatively declares email, name, user ID, other user content, photos/videos and audio data for account-linked app functionality. Audio files and photos/videos are optional user-provided content. Confirm these against actual backend policy before submitting; SDK empty collection arrays do not mean the whole service collects no data. No advertising identifier, location, contacts, analytics SDK or automatic diagnostics uploader is introduced.

This repository does not ship a hosted privacy policy, App Store privacy answers, age rating, export-compliance answers or beta review contacts; each distributor supplies their own. `ITSAppUsesNonExemptEncryption=false` is the existing declaration for standard transport encryption; confirm that it applies to your build and jurisdiction before distributing it.

## Official references

- [Apple required-reason API declarations](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [API categories and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [Privacy manifest placement](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [Apple TestFlight distribution](https://help.apple.com/xcode/mac/current/en.lproj/dev2539d985f.html)

## Camera and navigation

The camera usage string explains optional room-camera publishing. Camera permission is requested only by the camera control; it is separate from microphone permission and is never requested during login/join. Camera denial retains listening and screen viewing. Backgrounding, permission revocation, room teardown and reconnect stop camera publication; returning does not automatically restart it. No local camera recording is implemented. SFU/relay retention depends on the server operator. Camera media falls under the existing photos/videos app-functionality disclosure pending that review.

The bounded community-icon cache uses the canonical authenticated server response and trusted Autumn endpoint. It is cleared on session/authority changes. In-memory conversation scroll anchors are bounded to eight conversations, scoped to the active session and purged when access is lost. No offline message store was added.

## Network destinations added later

New network destinations, all reached only after a user action:

- **Community cinema** (`/rooms-cinema` on the configured origin): the session token authorizes catalog, artwork and relay-ticket requests; relay playlists and segments carry only a short-lived ticket. Provider URLs and credentials never reach the phone.
- **GIFs:** search goes through Access `/v1/gifs` on the configured origin; the chosen and previewed images load directly from `static.klipy.com`, which sees the device's IP address.
- **Lyrics:** opening lyrics sends the current track's title, artist and duration to `lrclib.net`.
- **YouTube:** pasting a link in the hall asks `www.youtube.com/oembed` for the video title; thumbnails load from `i.ytimg.com` as before.
- **DM calls:** Access `/v1/calls/*` is polled every 3 s while the app is open (and during a call in the background); call media uses a short-lived LiveKit grant like voice rooms.

The microphone on/off choice is kept in the app's own defaults per server and account (covered by the existing CA92.1 declaration). No tracking, analytics or new required-reason API is introduced.

