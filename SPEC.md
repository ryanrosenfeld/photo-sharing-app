# PhotoShare App — Product Specification v3

## Overview

PhotoShare is an iOS app that automatically shares photos to friends who appear in them. When a photo in your library contains a friend's face, the photo is instantly and privately delivered to them — no manual sharing required. All face matching happens on-device; all photos and face reference data are end-to-end encrypted.

---

## Core Concept

- Users form mutual friendships (opt-in, bilateral) via invite link
- Each friendship has two independent toggles: Send (am I auto-sharing photos of them?) and Receive (am I accepting photos from them?)
- When a new photo is added to your camera roll containing a friend's face, it is automatically encrypted on-device and delivered to that friend
- Recipients see photos they appear in delivered to their Photos tab in-app
- Every user uploads encrypted reference photos of themselves during setup — this is how friends enroll your face, automatically and privately

---

## User Accounts

- Sign up via phone number (SMS verification)
- Profile: display name, profile photo, phone number
- No contacts sync or in-app discovery for v1 — friends are added via invite link only

---

## Friend Model

### What it is

A **friendship** is a mutual, opt-in connection between two users. Both must accept before any photos can flow. Once established, each user independently controls two toggles per friendship: whether they are sending photos to that friend, and whether they are receiving photos from that friend.

### Send & Receive Toggles

- **Send toggle (per friend):** When ON, the app auto-shares photos of this friend with them when their face is detected. When OFF, no photos are sent to this friend regardless of face detection.
- **Receive toggle (per friend):** When ON, you accept incoming auto-shared photos from this friend. When OFF, photos from this friend are not delivered to you.
- A photo flows from A → B only if A's Send toggle for B is ON **and** B's Receive toggle for A is ON
- Either user can stop photo flow unilaterally by flipping their own toggle — no coordination required
- Both toggles **default to ON** when a friendship is first established
- Toggle state changes are not communicated to the other user (muting is silent)

### Visibility of toggle state

- On the Friends list, a friend row shows a paused/muted indicator if your Send is ON but their Receive is OFF — meaning your photos are not reaching them even though you intend them to
- The reverse (their Send ON, your Receive OFF) is not surfaced — you control your own receive state, no pressure indicator needed

### Friend Request Flow

1. User A taps "Add Friend" and generates an invite link
2. A shares the link via iMessage, WhatsApp, or any channel they choose
3. B taps the link, which opens the app with a pre-filled friend request
4. B sees an acceptance screen: "[Name] wants to be friends on PhotoShare. You'll automatically share photos of each other when you appear in them."
5. B accepts or declines
6. On acceptance, the friendship is established; both Send and Receive toggles default to ON for both users
7. Both devices immediately begin syncing each other's encrypted reference photos and generating local embeddings (see Face Enrollment)
8. A is notified: "[Name] accepted your friend request"

### Rules

- Either user can unfriend at any time; removal is immediate and unilateral
- Unfriending does not delete previously shared photos
- Local face embeddings for the unfriended person are deleted from both devices on unfriend
- No blocking feature in v1 — unfriend is sufficient given invite-only friend discovery
- A user must have a PhotoShare account (and completed face profile setup) to receive a friend request

---

## Face Profile & Enrollment

### Overview

Every user is required to upload reference photos of themselves as part of account setup. These photos are end-to-end encrypted — the server cannot see or analyze them. When two users become friends, their devices exchange access to each other's encrypted reference photos, generate face embeddings locally, and enrollment is complete automatically. No manual photo selection is ever required.

### Face Profile Setup (required)

- During onboarding (hard gate — cannot proceed without completing this step)
- User selects 3–5 photos of themselves from their photo library using the standard iOS photo picker
- Guidance: "Choose clear photos of your face, from different angles if possible"
- Quality nudge: 3 photos = Good, 4 = Better, 5 = Best — minimum 3 required
- On-device processing: MobileFaceNet pipeline runs on selected photos to validate a face is detectable in each; photos without a detectable face are rejected with guidance
- The reference photos themselves (not embeddings) are encrypted and uploaded to server (see Encryption section)
- This step can be deferred until first friend request is sent, but is required before any friend request can be sent or accepted

### Enrollment flow (automatic, on friendship acceptance)

1. A and B become friends
2. A's device fetches B's encrypted reference photos + A's copy of B's symmetric key (encrypted to A's public key)
3. A's device decrypts symmetric key using A's private key, decrypts reference photos locally
4. A's device runs MobileFaceNet pipeline on B's reference photos, generates 512-D embeddings
5. Embeddings stored locally on A's device; reference photos discarded immediately after embedding generation
6. Same process runs in parallel on B's device for A's reference photos
7. Both devices are now enrolled and ready to detect each other's faces — auto-sharing begins immediately

### Updating reference photos

- User can update their reference photos at any time from Profile tab
- On update: new photos are encrypted with a new symmetric key; server re-encrypts new symmetric key to all existing friends' public keys (B's device must be online to initiate; propagates to friends on their next app foreground)
- Friends' devices automatically regenerate embeddings from updated reference photos on next sync — silent background task
- Update propagation does not require any action from friends

### Encryption of reference photos

- User's device generates a random symmetric key at face profile setup
- Reference photos encrypted with symmetric key on-device before upload
- Symmetric key is itself encrypted to the user's own public key and stored on server (for multi-device access)
- When a new friendship is formed: user's device encrypts the symmetric key to the new friend's public key; server stores this additional encrypted copy alongside the friend record
- Server stores: encrypted photo blobs + symmetric key encrypted to each authorized friend's public key
- Server cannot decrypt photos or symmetric keys
- On unfriend: server deletes the friend's copy of the encrypted symmetric key; friend loses access to reference photos on next sync

### What the server stores (face profile)

- Encrypted reference photo blobs (cannot decrypt)
- Symmetric key encrypted to owner's public key (cannot decrypt)
- Symmetric key encrypted to each friend's public key (cannot decrypt)
- Metadata: user ID, upload timestamp, friend access list (who has a key copy)

---

## Face Detection & Matching

### Pipeline

- When new photos are added to the user's camera roll, the app processes them on next app foreground
- Pipeline: Vision detects faces (image pyramid of 1024px tiles so small faces in wide shots are found) → landmarks aligned to the ArcFace 112×112 template (padded box crop only as a penalised fallback) → MobileFaceNet CoreML inference → 512-D float embedding
- Images normalized to `.up` orientation and capped at 4096px before processing
- Detected face embeddings compared against locally stored enrolled embeddings for all friends with Send toggle ON
- A match above the confidence threshold triggers a share to that friend

### Matching

- MobileFaceNet (ArcFace-trained, `w600k_mbf`) bundled as CoreML model (~4MB, ~25ms on A-series)
- Confidence threshold tunable server-side (pushed to devices without app update); cosine distance (0 = identical, ~1 = unrelated), default 0.55
- Conservative threshold: prefer missed shares over false positives
- Users can report a missed share to improve future matching
- If a friend updates their reference photos and embeddings are regenerated, matching accuracy improves automatically

---

## Auto-Share Behavior

### Trigger

A share is triggered when:

1. A new photo is detected in the user's camera roll (processed on next app foreground)
2. At least one friend's face is detected above the confidence threshold
3. The sending user's Send toggle for that friend is ON
4. The receiving user's Receive toggle for the sender is ON
5. The photo passes manual review (if manual review mode is enabled for that friend)

### Manual Review Mode

- Global setting, default OFF (auto-send)
- Can be overridden per friend (e.g. auto-send to some friends, review before sending to others)
- When ON: matched photos are queued locally on device for review before any upload occurs
- Review queue lives in a dedicated section of the Friends tab (badged)
- Queue shows: the photo, which friend(s) it matched, approve/reject controls
- Bulk approve/reject supported
- Approved → photo is encrypted and uploaded; rejected → photo is discarded, never leaves device
- No expiry on queued photos — stored locally, no server involvement until approved
- If a photo matches multiple friends with different review settings (e.g. auto-send to Ryan, review before Sarah): Ryan's copy sends immediately, Sarah's copy queues independently

### What is shared

- Full-resolution photo, encrypted on-device before upload
- Timestamp and location metadata (if location permission granted and user has location sharing enabled)
- Photos shared only with friends whose faces were detected above threshold — not broadcast to all friends

### End-to-End Encryption (photos)

- Each user has a public/private keypair generated during onboarding (non-negotiable, non-skippable)
- Private key stored in device Keychain, synced via iCloud Keychain for device continuity
- Public key uploaded to server (public by definition)
- At send time: sender's device fetches recipient's public key, encrypts photo locally, uploads encrypted blob
- Server stores encrypted blob + unencrypted metadata (sender ID, recipient ID, timestamp, expiry)
- Server cannot decrypt photo content
- Recipient downloads encrypted blob, decrypts locally
- Privacy policy is honest: server cannot see photo content but can see metadata (who sent to whom, when)
- Rejected photos (manual review) never touch the server

### Delivery

- Push notification: "[Name] shared a photo with you"
- Recipient opens app to view in Photos tab
- Encrypted blobs retained on server for 30 days, then permanently deleted
- Users warned 3 days before a photo expires
- Users can save photos to camera roll before expiry

### Retry

- If upload fails (network error), app retries for up to 24 hours before dropping
- If delivery fails on recipient side, encrypted blob remains available for 30 days

### Opt-out controls

- **Sending user:** disable Send toggle globally or per friend
- **Sending user:** enable manual review globally or per friend
- **Receiving user:** disable Receive toggle globally or per friend (silent to sender)

---

## Photos Tab

- Chronological feed of all photos received from friends
- Each photo card shows: sender name + avatar, timestamp, location (if shared), photo, badge if saved to camera roll
- Tap to view full screen
- Long-press for options: save to camera roll, react with emoji, report
- Unread indicator per sender
- **Bulk save UX** — users frequently receive bursts of photos from events; saving should be effortless (exact interaction left to designer)
- Empty state: warm, encouraging — "When friends share photos with you, they'll appear here"
- Expiry warning on photos within 3 days of deletion ("Expires in 2 days — save it")
- Photos retained for 30 days then deleted from server

---

## Friends Tab

- Full friends list with per-friend toggle state visible
- Friend row shows paused indicator if your Send is ON but their Receive is OFF
- Tap a friend → Friend Detail screen:
  - Send toggle: "Auto-share photos of [Name] with them"
  - Receive toggle: "Receive photos from [Name]"
  - Manual review toggle: "Review before sending to [Name]"
  - Face enrollment status: when B last updated their reference photos; option to refresh embeddings manually
  - Unfriend (destructive, bottom of screen)
- Pending incoming friend requests surface as card/banner at top with badge count on tab
- Manual review queue lives here (badged separately from friend requests)

---

## Profile Tab

- Account info: name, profile photo, phone number
- Plan status with upgrade CTA if on free tier
- **My Reference Photos** — manage your uploaded face profile photos; add/replace; shows current photo count and last updated date; clear explanation: "Friends' devices use these to recognize you in their photos. They're encrypted — we can't see them."
- **Manual Review** global toggle
- Permissions: current state of each with deep link to iOS Settings
- Privacy summary: honest, plain-language description of what is and isn't stored
- Delete account (destructive)

---

## Freemium Plan

### Free Tier

- Maximum 3 active friends with Send toggle ON at any time
- Receiving is unlimited and free
- All core features available within the 3-friend send limit
- When at the limit: disable Send for an existing friend to free a slot, or upgrade
- Attempting to enable Send for a 4th friend shows an upgrade prompt

### Paid Tier (Pro)

- Unlimited friends with Send toggle ON — the only differentiator from free

### Pricing

- Monthly and annual subscription options (prices TBD)
- Free trial: 7 days of Pro on new account creation
- Subscription managed via Apple In-App Purchase (StoreKit 2)
- Downgrade behavior: Send is paused for all friends beyond 3; user is prompted to choose which 3 to keep active; if dismissed, 3 most recently activated are kept, rest paused

---

## Permissions

| Permission               | Why                                                              | When requested                        |
| ------------------------ | ---------------------------------------------------------------- | ------------------------------------- |
| Photo Library (read)     | Detect faces in new photos; select reference photos during setup | Onboarding (face profile setup)       |
| Photo Library (add only) | Save received photos to camera roll                              | When user first taps "Save"           |
| Face ID / On-device ML   | Face matching and embedding generation (on-device only)          | During face profile setup             |
| Push Notifications       | Deliver photo alerts                                             | After completing onboarding           |
| Location (when in use)   | Attach location to shared photos                                 | Only if user enables location sharing |

All permissions requested contextually, each preceded by an in-app explanation before the iOS system prompt.

---

## Privacy & Data

- Face embeddings stored locally on device only — never uploaded
- Reference photos encrypted on-device before upload; server cannot decrypt or analyze them
- Photos end-to-end encrypted; server stores encrypted blobs it cannot decrypt
- Server metadata (sender ID, recipient ID, timestamps) is not encrypted — disclosed honestly in privacy policy
- Rejected photos (manual review) never leave the sender's device
- Photos encrypted in transit (TLS) and at rest
- Users can delete account; all sent/received photo blobs and reference photo blobs purged from server within 24 hours
- On unfriend: friend's access to encrypted reference photos revoked server-side; local embeddings deleted from both devices
- Compliance: GDPR, CCPA, App Store privacy guidelines, BIPA (Illinois biometric law)

---

## Notifications

| Event                   | Notification                                                     |
| ----------------------- | ---------------------------------------------------------------- |
| Incoming friend request | "[Name] wants to be friends on PhotoShare" — card in Friends tab |
| Friend request accepted | "[Name] accepted your friend request"                            |
| Photo received          | "[Name] shared a photo with you" (badge count increments)        |
| Photo expiring soon     | "A photo from [Name] expires in 3 days"                          |
| Pro trial ending        | "Your free trial ends in 2 days"                                 |
| Manual review queued    | "[Name] appeared in a new photo — review before sending"         |

- Notification preferences configurable per-type in settings
- Receive toggle OFF suppresses photo-received notifications from that friend

---

## Onboarding

1. **Welcome screen** — value prop: "Photos with your friends, automatically delivered"
2. **Phone number entry** → SMS verification
3. **Keypair generation** — silent, runs immediately after verification; stored in Keychain with iCloud Keychain sync; non-skippable
4. **Profile setup** — display name, profile photo
5. **Face profile setup (required)** — "Choose 3–5 photos of yourself so friends can recognize you in their photos." Standard iOS photo picker. Quality nudge shown. Minimum 3 photos with detectable face required. Cannot proceed without completing. Brief privacy reassurance: "These are encrypted — only your friends' devices can use them, and only to recognize you."
6. **Photo Library permission** — in-app explanation before iOS system prompt
7. **First friend** — guided flow to share an invite link; skip option equally visible
8. **Notifications permission** — contextual prompt
9. **Home screen** (Photos tab, empty state with call to action)

Note: face enrollment of friends is now fully automatic on friendship acceptance — no manual enrollment step needed in onboarding.

---

## App Structure

- **Photos** — chronological feed of received photos; bulk save UX; expiry warnings (default tab)
- **Friends** — full friends list with toggle state; pending friend requests card; manual review queue
- **Profile** — account settings, plan status, permissions, reference photo management, manual review global setting

---

## Edge Cases & Rules

- If a photo contains multiple friends' faces, it is encrypted and sent to each independently
- A photo is never shared with the person who took it, even if their own face appears in it
- If upload fails, app retries for up to 24 hours before dropping
- Duplicate sends prevented by perceptual hash / asset identifier deduplication
- A user under 13 cannot create an account (age gate at sign-up; parental consent flow TBD)
- Photos processed on next app foreground if app was not running when photo was taken
- Manual review: per-friend settings override global setting; each recipient's copy handled independently
- If a friend's reference photo update is in progress when a photo is being processed, matching uses the previous embeddings; re-matching does not occur retroactively
- If face profile setup is abandoned mid-onboarding, account is not created; user must restart

---

## Out of Scope (v1)

- Android
- Group chats or threads
- Video sharing
- Reactions beyond emoji (comments, replies)
- Photo editing before share
- Web app
- Third-party sign-in (Apple ID, Google)
- Background photo processing
- Contacts sync
- In-app friend discovery / search
- Camera roll face clustering for friend suggestions (noted as v2 cold-start/discovery mechanic)
- Blocking (unfriend is sufficient given invite-only discovery)
- E2E encryption key rotation / recovery phrase (iCloud Keychain sync covers v1 device continuity)
- Manual face enrollment (sender picking photos of friend) — removed entirely; all enrollment is automatic via encrypted face profiles

---

## Technical Notes

### Face Recognition Stack

- Detection: `VNDetectFaceRectanglesRequest` (Apple Vision)
- Embedding: MobileFaceNet CoreML model (`w600k_mbf`, ArcFace-trained, ~4MB, ~25ms on A-series)
- Pipeline: detect (pyramid) → align to ArcFace template → 112×112 → CoreML → 512-D float embedding
- Threshold: cosine distance 0.55, chosen from real-photo (LFW) same/different-person distributions; tunable server-side
- Debug: Face Match Sandbox screen available in debug/TestFlight builds only (Profile → Debug); must not ship in production

### Photo Encryption

- Per-user asymmetric keypair; private key in Keychain + iCloud Keychain sync
- At send time: encrypt photo to recipient's public key on-device; upload encrypted blob
- Server stores encrypted blobs + unencrypted metadata; 30-day retention then hard-delete

### Face Profile Encryption

- Per-user symmetric key generated at face profile setup
- Reference photos encrypted with symmetric key on-device before upload
- Symmetric key stored on server encrypted to: owner's public key + each friend's public key
- On new friendship: owner's device encrypts symmetric key to new friend's public key; server stores new copy
- On unfriend: server deletes friend's copy of encrypted symmetric key
- Friend's device discards reference photos after embedding generation; only embeddings persist locally
