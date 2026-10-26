# FeeqdKit for AI assistants

You are adding FeeqdKit (in-app feedback, backed by Feeqd) to an iOS app, or changing how it behaves. This file is the exact public API and the recipes that use it. Do not use any symbol that is not listed here: everything else in `Sources/` is internal (`package` access) and does not compile from an app.

## First rule: the dashboard decides most things

Most of what the feedback screen shows is set by the team in the Feeqd dashboard (**App & SDK → Your app**) and read at launch, with no App Store release. **Do not write code for these.** If the user asks for one, tell them where it is in the dashboard:

| The user wants to change… | Where |
|---|---|
| Which sections show (requests, bugs, roadmap, chat), their order and labels | Dashboard |
| The layout (tabs, chips, menu, front page) | Dashboard |
| Which statuses are visible in the app | Dashboard |
| Default sort, vote counts, comment counts, undoing a vote, the status badge | Dashboard |
| Asking for an email on new requests, allowing new requests at all | Dashboard |
| Turning the chat on | Dashboard (and the key must carry chat) |
| Colours and copy for every build at once | Dashboard (code can override, see below) |

Code is only for: integrating, where the screen is opened, who the user is, signing out, and colours or copy that must be fixed in the build.

## Requirements

- iOS 16+ (`fontDesign` needs iOS 16.1). SwiftUI. No dependencies.
- The **publishable key** (`feeqd_pk_…`) from the dashboard. It ships in the binary and is public by design.
- Never put the **signing secret** in the app. It belongs on the developer's server.

## Install

Swift Package Manager, product `FeeqdKit`:

```swift
.package(url: "https://github.com/adriamatz/FeeqdKit", from: "0.3.0")
```

In an Xcode project: File → Add Package Dependencies… → `https://github.com/adriamatz/FeeqdKit`, and add `FeeqdKit` to the app target.

## Public API, complete

```swift
// Configure once, at launch, before any Feeqd view is shown.
Feeqd.configure(with: "feeqd_pk_…")
Feeqd.configure(FeeqdConfiguration(
    apiKey: "feeqd_pk_…",
    boardID: String? = nil,              // optional, saves a round trip at launch
    theme: FeeqdTheme = FeeqdTheme(),    // wins over the dashboard's colours
    strings: [String: String] = [:],     // wins over the dashboard's copy, by key
    appVersion: String? = nil,           // defaults to CFBundleShortVersionString
    showsChatButton: Bool = true,        // the chat button on the feedback screen
    collectPurchases: Bool = false,      // read App Store purchases (StoreKit), read-only
    translation: FeeqdTranslation = .automatic  // "See translation" on requests and comments
))
// readerURL / gathererURL also exist: leave them alone, the defaults are production.

// Views. Presented (sheet, cover), each brings its own navigation and a close button.
// Pushed onto your NavigationStack, pass pushed: true and it uses your back button.
Feeqd.FeedbackView(pushed: Bool = false) // requests, votes, comments, new request, chat button
Feeqd.ChatView(pushed: Bool = false)     // the private chat on its own

// Who the user is.
Feeqd.setIdentityToken(_ token: String?) // a JWT your server signed: verified
Feeqd.updateUser(id: String?, name: String? = nil, email: String? = nil,
                 payment: FeeqdPayment? = nil)   // unsigned: shown as unverified
Feeqd.reset()                            // on sign-out

// Chat entry point of your own.
let status = await Feeqd.chatStatus()    // FeeqdChatStatus(isAvailable:, hasUnread:)

// Types
FeeqdTheme(primary:, background:, surface:, textPrimary:, textSecondary:,
           voteActive:, cornerRadius:, statusColors:, fontDesign:)   // all optional
FeeqdStatusColors(open:, inProgress:, done:, byStatus: [String: Color])
FeeqdFontDesign: .standard, .rounded, .serif, .monospaced
FeeqdPayment: .weekly(Decimal, currency:), .monthly(...), .yearly(...), .lifetime(...)
FeeqdTranslation: .automatic, .hidden    // on-device, iOS 18+; never shown before
Feeqd.version                            // the SDK version string
```

## Recipes

### Integrate

```swift
import FeeqdKit

@main struct MyApp: App {
    init() { Feeqd.configure(with: "feeqd_pk_…") }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

With an `AppDelegate`, call it in `application(_:didFinishLaunchingWithOptions:)` instead. Not in a view's `onAppear`, not lazily: it also tells Feeqd the app launched, which is how the dashboard sees it connected, and a Feeqd view shown before it stays empty.

Then add an entry point where users look for help or settings. Fit the app: a row in the settings screen, an item in an existing menu, or a toolbar button. Don't add a floating button unless asked.

In a settings screen that already sits in a `NavigationStack`, push it like the other rows:

```swift
NavigationLink("Send feedback") { Feeqd.FeedbackView(pushed: true) }
```

Anywhere else, present it. Don't wrap it in a `NavigationStack`: it brings its own.

```swift
@State private var showFeedback = false

Button("Send feedback") { showFeedback = true }
    .sheet(isPresented: $showFeedback) { Feeqd.FeedbackView() }
```

Build and run once. The Feeqd dashboard shows the app as connected on its own.

### Identify signed-in users

If the app has accounts, call this after sign-in and whenever the app starts with a user already signed in:

```swift
Feeqd.updateUser(id: user.id, name: user.displayName, email: user.email)
```

To have the user verified (recommended when the app has a backend), the server signs an HS256 JWT with the key's signing secret and the app passes it:

```swift
Feeqd.setIdentityToken(tokenFromYourServer)
```

Claims: `sub` (your user id, required), `name` (required), `exp` (required), and optional `email` and `avatar` (a URL). Sign it on the server only. Example in Node:

```js
jwt.sign({ sub: user.id, name: user.name, email: user.email }, process.env.FEEQD_SIGNING_SECRET, { expiresIn: '1h' })
```

### Sign out

```swift
Feeqd.reset()
```

Call it wherever the app signs the user out. It forgets the user and takes a new device id, so the next person on the same phone doesn't see the previous one's chat or requests.

### Offer the chat from somewhere else

```swift
@State private var chat = FeeqdChatStatus(isAvailable: false, hasUnread: false)
@State private var showChat = false

Group {
    if chat.isAvailable {
        Button { showChat = true } label: {
            Label("Message us", systemImage: chat.hasUnread ? "message.badge" : "message")
        }
    }
}
.task { chat = await Feeqd.chatStatus() }
.sheet(isPresented: $showChat) { Feeqd.ChatView() }
```

Only show it when `isAvailable` is true: it fails closed (no network, a key without chat, chat off in the dashboard). To keep the chat button off the feedback screen and offer it only this way, set `showsChatButton: false`.

### Match the app's look

Prefer the app's own colour assets so dark mode keeps working. Leave out what the app doesn't define: it falls back to the dashboard, then to the system.

```swift
Feeqd.configure(FeeqdConfiguration(
    apiKey: "feeqd_pk_…",
    theme: FeeqdTheme(
        primary: Color("AccentColor"),
        cornerRadius: 12,
        statusColors: FeeqdStatusColors(inProgress: .blue, done: .green),
        fontDesign: .rounded
    )
))
```

`byStatus` takes a status slug (`"planned"`, `"in_progress"`, `"declined"`…) and wins over its stage.

### Change copy in the build

Keys you can override (anything else is ignored):

`board.title`, `submit.cta`, `submit.title`, `submit.send`, `submit.sent.title`, `submit.sent.message`, `empty.title`, `empty.message`, `search.prompt`, `tab.open`, `tab.done`, `tab.mine`, `chat.button`, `chat.title`, `chat.empty.title`, `chat.empty.message`, `home.title`, `home.subtitle`, `hub.requests`, `hub.bugs`, `hub.roadmap`, `roadmap.empty`, `translate.see`, `translate.original`.

```swift
strings: ["board.title": "Ideas", "submit.cta": "Suggest something"]
```

Overrides apply in every language. For copy that should change without a release, or per language, use the dashboard instead.

### Revenue behind each request

Only if the user asks:

- For App Store subscriptions, set `collectPurchases: true`. The developer must then declare **Purchase History** in the app's privacy details.
- For billing outside the App Store, pass it in `updateUser(id:…, payment: .monthly(9.99, currency: "EUR"))`.

## Don'ts

- Don't call `configure` more than once, or after showing a Feeqd view.
- Don't wrap `FeedbackView` or `ChatView` in another `NavigationStack`. They bring their own.
- Don't change `readerURL` / `gathererURL` in an app.
- Don't put the signing secret, or code that signs the JWT, in the app.
- Don't build a custom feedback form against Feeqd's HTTP API. Use the views.

## Privacy

In App Store Connect, declare what the app sends:
- **Name** and **Email Address**, only if passed to `updateUser` or the token.
- **Customer Support**, only if the chat is used.
- **Purchase History**, only with `collectPurchases` or `payment`.

The SDK's own `PrivacyInfo.xcprivacy` is already included.
