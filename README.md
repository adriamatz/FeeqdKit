# FeeqdKit

In-app feedback for iOS: requests with votes, comments, a way to ask for something new, and a private chat with your team, backed by [Feeqd](https://feeqd.com). SwiftUI, iOS 16+, no dependencies.

> **0.2.0.** Talks to production out of the box. You need a Feeqd plan that includes the iOS SDK, and the publishable key from **App & SDK** in the dashboard.

## Installation

In Xcode: **File → Add Package Dependencies…** and paste `https://github.com/adriamatz/FeeqdKit`.

Or in `Package.swift`:

```swift
.package(url: "https://github.com/adriamatz/FeeqdKit", from: "0.2.0")
```

and add `FeeqdKit` to your target's dependencies.

## Integration

```swift
import FeeqdKit

@main struct MyApp: App {
    init() { Feeqd.configure(with: "feeqd_pk_…") }
    var body: some Scene { WindowGroup { ContentView() } }
}

// anywhere
.sheet(isPresented: $showFeedback) { Feeqd.FeedbackView() }

// or as a row of your settings, pushed onto your NavigationStack
NavigationLink("Send feedback") { Feeqd.FeedbackView(pushed: true) }
```

That is the whole integration. Theme, copy, tabs, sort order and the "Powered by" badge come from the dashboard, with no App Store release.

### With an AI assistant

[`AGENTS.md`](AGENTS.md) has the complete public API, what belongs in code and what in the dashboard, and a recipe for each change: integrating, identifying users, signing out, offering the chat, matching your app's look, changing copy. Point your assistant at it:

```text
Add FeeqdKit to this app following https://github.com/adriamatz/FeeqdKit/blob/main/AGENTS.md.
My key is feeqd_pk_…
```

The dashboard has these prompts ready to copy: in the onboarding (with your key already in them), in Getting started, and in **App & SDK**.

### What the screen shows

Decided in the dashboard, under **App & SDK → In-app experience**, and read at launch, no release needed:

- **Sections**: any of the key's boards (requests, bugs…), the roadmap and the chat, in the order and under the short labels the admin picked.
- **Layout**: tabs in the navigation bar, scrolling chips, a menu in the title, or a front page with a card per section. *Automatic* picks from how many sections are on: one has no switcher, two or three go in the bar, four or more become chips.
- **Roadmap**: columns fed by status, across every board.
- **Which statuses show**: a status can be kept out of the app (by default *Pending*, until the team looks at a request, and *Declined*). The person who sent a request still sees it, on top of the list and marked *Only you can see this*, so it never looks lost; it opens to votes and comments once the team moves it on.

With nothing saved, the screen is the key's first board, which is what FeeqdKit always was. A layout this version does not know falls back to *Automatic*, and an unknown section is left out, so an app already on the App Store never breaks on something the dashboard learns later.

### Chat

Once the team turns the chat on in the dashboard (App & SDK → What users see), and the key carries chat, the board shows a button to message the team, with a dot when the team replied. Users write privately; you answer from the dashboard's inbox, and the reply shows up in the app. Nothing to add to the integration above.

To offer it from somewhere else in your app:

```swift
let chat = await Feeqd.chatStatus()               // one request; fails closed
if chat.isAvailable {
    // a "Message us" row, dotted when chat.hasUnread
}

.sheet(isPresented: $showChat) { Feeqd.ChatView() }
```

The button (and `isAvailable`) only appear once the server confirmed the chat works for this key: no network, a key created without chat, or a plan without it all mean no button, never a chat that can't deliver. Set `showsChatButton: false` in the configuration to keep it off the board. The screen checks for replies every five seconds while it is open; there is no push yet.


### Options

```swift
Feeqd.configure(FeeqdConfiguration(
    apiKey: "feeqd_pk_…",
    boardID: "…",                                   // optional: saves a round trip at launch
    theme: FeeqdTheme(primary: .orange),            // wins over the dashboard's colours
    strings: ["board.title": "Ideas"],              // wins over the dashboard's copy
    showsChatButton: true                           // the chat button on the board (default)
))

Feeqd.setIdentityToken(jwt)                          // a user your server vouched for
Feeqd.updateUser(id: "42", name: "Marta", email: "marta@example.com")   // unsigned; shown as unverified
Feeqd.reset()                                        // on sign-out: forgets the user and takes a new device id
```

### Look and feel

Set the look in code. It uses your app's own colours and dark mode, and it is there from the first frame. Anything you leave out comes from the dashboard, and then from the system (your accent colour and grouped backgrounds), so an unconfigured SDK already looks like part of your app.

```swift
FeeqdTheme(
    primary: Color("Brand"),                         // buttons, links, the selected tab
    voteActive: .orange,                             // a vote the user cast (defaults to primary)
    cornerRadius: 16,
    statusColors: FeeqdStatusColors(
        open: .gray,                                 // pending, under review, planned
        inProgress: .blue,
        done: .green,                                // done, shipped, declined
        byStatus: ["declined": .red]                 // one status by slug, wins over its stage
    ),
    fontDesign: .rounded                             // .serif, .monospaced; iOS 16.1+
)
```

Statuses are named per board in the dashboard, but each belongs to one of three stages, so colouring the stages covers every board.

## Developing Feeqd itself

Leave the hosts alone in an app: the defaults are production. To run the SDK against a local Feeqd backend, which serves reads (go-reader) and writes (go-gatherer) on different ports:

```swift
Feeqd.configure(FeeqdConfiguration(
    apiKey: "feeqd_pk_…",                           // App & SDK in the dashboard, or the onboarding
    readerURL: URL(string: "http://localhost:8093")!,
    gathererURL: URL(string: "http://localhost:8092")!
))
```

From a device, use the Mac's LAN address instead of `localhost`, and allow local networking in the host app's `Info.plist` (`NSAllowsLocalNetworking`).

New requests go through the SDK's own submit route, which every board of the key accepts. Against a backend that does not have that route yet, FeeqdKit falls back to the public one, which only works on boards that accept anonymous submissions: the boards the dashboard's iOS onboarding creates already do, and for a board you add later, turn on **Allow anonymous widget feedback** in its settings.

## Layout

| Target | What | Public |
|---|---|---|
| `FeeqdCore` | Networking (`FeeqdClient` actor), device identity (Keychain), models, stores, strings | no |
| `FeeqdUI` | Board, detail with comments, new request, chat | no |
| `FeeqdKit` | `Feeqd`, `FeeqdConfiguration`, `FeeqdTheme` | **yes**, the only product |

Cross-target APIs use the `package` access level, so the app integrating the SDK only sees `FeeqdKit`. Every public type is a compatibility promise.

## Decisions worth knowing

- **Tolerant decoding.** Unknown keys are ignored, unknown enum values fall back to defaults, and one malformed row never takes a page down. A value the server adds tomorrow must not break a build already on the App Store.
- **Device identity** is a KSUID in the Keychain (`AfterFirstUnlockThisDeviceOnly`, not synced), read once per process. It survives reinstalls. Restoring to a new phone without iCloud Keychain starts a new identity: the accepted cost of never asking for an email.
- **Diagnostics** (`X-Feeqd-Device-Info`: model, OS, locale) ride only on something the user did: a vote, a comment, a request. The launch request carries only the app and SDK versions: the backend records a device once an hour from whichever request comes first, and without them the dashboard's version spread would stay empty.
- **Votes are optimistic** and replaced by the server's count when it answers; reverted on failure. Retrying is safe: the backend only moves the count when the vote ledger changed.
- **Launch registers the device.** `configure` sends one quiet request in the background (the config, then `my-votes` on the key's board), which is how the dashboard's onboarding learns the app is connected: running the app once is enough, no Feeqd screen has to open. A failure is silent; the first screen load registers it just the same.
- **"Sent", never "published".** Submissions are accepted with `202 queued` and no id; the board may hold them for moderation. The list reloads shortly after.
- **One conversation at a time.** The server keeps one open conversation per key and device; the chat shows it, or the latest closed one. Writing after the team closed it opens a new one. An unknown sender from the server reads as the team, never as the user.
- **Loaded-and-empty is not failed.** An empty board invites the first request; a failed load shows an error and a retry, never an inviting empty screen.
- **Strings**: code override → dashboard copy for the locale (`es-MX`) → for the base language (`es`) → bundled table → English. English and Spanish are bundled complete.

## Not in phase 1, and why

| Missing | Because |
|---|---|
| Email on new requests | the submit body has nowhere to put it |
| Status tabs from the server | the list can't filter by status; tabs filter what is loaded |
| Push, "what you voted is done", chat replies while the app is closed | the notification loop is wired but never fires |

All of these wait on the backend, not on the SDK: they arrive in later versions without changing the integration above.

## Tests

```bash
swift test
```

`FeeqdCore` has no SwiftUI, so its tests run on a Mac without a simulator. They decode responses captured from the local stack (`Tests/FeeqdCoreTests/Fixtures`): what the server really sends, not what we believe it sends, and drive the client and stores through a stubbed `URLProtocol`.

Two suites run against a local stack instead, and skip without it: `LocalStackTests` (`FEEQD_LOCAL_KEY`, `FEEQD_LOCAL_BOARD`) and `LocalChatTests` (`FEEQD_LOCAL_KEY` with the chat scope; add `FEEQD_LOCAL_TEAM_TOKEN`, a dashboard access token, to play the team's side too).

## Privacy

`PrivacyInfo.xcprivacy` declares what the SDK can send: a device ID, a user ID, user content, customer support messages, diagnostic data, email address, name and purchase history. All of it is for app functionality, linked to the user, with no tracking.

In App Store Connect, declare what your app actually sends: **Email Address** and **Name** only if you pass them in `Feeqd.updateUser`, and **Customer Support** only if you use the chat.
