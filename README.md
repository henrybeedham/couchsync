<p align="center">
  <img src="docs/icon.png" width="160" height="160" alt="CouchSync icon">
</p>

<h1 align="center">CouchSync</h1>

<p align="center"><b>Watch Netflix, Disney+, Prime Video and more together on every Mac.</b></p>

<p align="center">
  <a href="https://henrybeedham.github.io/couchsync/"><img src="https://img.shields.io/github/v/release/henrybeedham/couchsync?label=Download&logo=apple&logoColor=white&color=7c63e6" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20silicon-arm64-111" alt="Apple silicon">
  <img src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift and SwiftUI">
  <img src="https://img.shields.io/badge/Tailscale-ready-242424?logo=tailscale&logoColor=white" alt="Works over Tailscale">
</p>

<p align="center">
  <a href="https://henrybeedham.github.io/couchsync/"><b>Download</b></a> ·
  <a href="https://github.com/henrybeedham/couchsync/releases">Release notes</a>
</p>

A Mac app (Apple silicon) for watching streaming services together across
Macs, like Teleparty but yours. Each Mac runs the app, signs in to the service
inside it, and joins the same party. Play, pause, seek and choosing a title on
one Mac happen on all of them, with a chat, GIFs and reactions alongside.

Works with **Netflix, Disney+, Prime Video, HBO Max, Apple TV+, YouTube, BBC
iPlayer, Crunchyroll, Paramount+ and Hulu**. Switch with the service menu in the
toolbar. Everyone needs their own subscription to whatever you're watching, and
some services are only available in some countries.

## Build

    ./build.sh

Needs only the Xcode Command Line Tools. Produces `build/CouchSync.app`.

To turn on GIFs for everyone who gets this build, include a free GIPHY API key
(create an app at https://developers.giphy.com and choose API):

    GIPHY_API_KEY=yourkey ./build.sh      # or put the key in giphy-key.txt

Without one, the GIF browser asks for a key the first time it's opened.

## Releases

To share CouchSync, send https://henrybeedham.github.io/couchsync/. It's a
download page (in `docs/`, served by GitHub Pages) whose link preview shows the
CouchSync card, and its button always fetches the newest release. GitHub's own
release links always show GitHub's generic card instead.

Releases are on the [Releases](https://github.com/henrybeedham/couchsync/releases)
page. They're made automatically: every push to `main` that changes the app
builds it on GitHub and publishes the next patch version (1.0.1, 1.0.2, …).
Pushes that only change Markdown files or `docs/` don't make a release.

To choose the version yourself (say 1.1 or 2.0), open **Actions → Release →
Run workflow** on GitHub, or run `./release.sh 1.1` on your Mac.

For GIFs to work out of the box, add your GIPHY key as a repository secret
named `GIPHY_API_KEY` (Settings → Secrets and variables → Actions). Anyone who
downloads a release can extract the key from the app.

## Use

1. Open CouchSync on every Mac, pick the service from the toolbar and sign in.
2. On one Mac: **Party → Host a party**.
3. On the others: **Party**, then pick the host. Parties you've joined before
   are under **Recent**, and Macs on your tailnet are listed below them (marked
   *Hosting* when a party is running). Or type a Tailscale name or IP.
4. Start a title on any Mac. Everyone else's CouchSync opens the same title,
   on the same service, and keeps it in step. If a service opens the title's
   page without starting it, CouchSync asks you to press play.

### How well each service works

- **Tested end to end** with two copies: **Netflix**, **YouTube** and **BBC
  iPlayer**. Play, pause, seeking, joining late, following the party to a title
  and fullscreen all work. On YouTube, moving on to the next video takes the
  party with it, and ads are waited out (each viewer catches up when their ad
  ends).
- **Not yet tested with a subscription**: Disney+, Prime Video, HBO Max,
  Apple TV+, Crunchyroll, Paramount+ and Hulu. Their sites load in CouchSync,
  and they're followed through the page's video the same way, but one may need
  adjusting if it handles its player differently. Ads on their ad-supported
  plans aren't detected, so they can put viewers out of step until the next
  correction. Outside the US, hulu.com sends you to Disney+.

### Chat

The sidebar on the right (⇧⌘C to show or hide) has the party's chat:

- messages, with a **GIF** button that opens a GIPHY search;
- hover a message to react to it, and click a reaction to add or remove yours;
- the emoji row above the message box sends a reaction floating up over
  everyone's video;
- play, pause, seek, joins and leaves are noted in the chat, as in Teleparty.

Someone who joins late gets the chat so far.

### Fullscreen

The player's fullscreen button, its `f` key and the green traffic light all do
the same thing: the window goes fullscreen with the chat still beside the video.
Esc leaves. The toolbar shows when the mouse reaches the top of the screen.

### Remembered parties

- Parties you join are remembered under **Recent**. Hover one and click × to
  forget it.
- If the connection drops, CouchSync keeps trying to get back in for about
  a minute, so a host restarting their app doesn't end the party.
- Quit while in a party and CouchSync picks up again on the next launch, either
  rejoining or hosting again. Leaving or ending the party stops that.

### Updates

CouchSync checks GitHub for a new release when it opens and every six hours.
New versions download in the background and install when you quit, or straight
away with **Restart to Update** in the toolbar. You never get restarted in the
middle of a film, and if you were in a party you rejoin it when CouchSync
reopens. **CouchSync → Check for Updates…** checks now; turn automatic installs
off in **CouchSync → Settings**, and you'll be asked instead.

Updates are checked against the SHA-256 that GitHub publishes for the download,
must have the same bundle ID and a valid signature, and are swapped in only once
CouchSync has quit. If the swap fails, the old app is put back.

The party uses TCP port 47800, directly between the Macs. There is no server.

## Installing on another Mac

The app is signed ad hoc, so a copy that arrives by AirDrop or a download is
blocked by Gatekeeper. Either build it on that Mac, or clear the flag once:

    xattr -dr com.apple.quarantine CouchSync.app

## How it works

- `Services.swift`: the streaming services: how to find the title in a page
  address and how to open a title. A peer can only ever send you to a watch
  page built here from a checked title ID.
- `SyncScript.swift`: JavaScript injected into the page and the services'
  player frames. Watches the `<video>`, reports changes, applies the party's
  state. On Netflix and YouTube it drives their own player objects (writing
  `video.currentTime` crashes Netflix's). It also stands in for the page's
  fullscreen API so fullscreen means the window.
- `PartySession.swift`: the party. One Mac hosts and relays; every change
  carries a sequence number; the host sends its position every 2 s so the
  others can correct drift over 2.5 s. Also reconnection and remembered parties.
- `Chat.swift`, `ChatPanel.swift`, `ReactionOverlay.swift`: chat, reactions.
- `Giphy.swift`: GIF search, and a GIF view that animates.
- `WebController.swift`: the web view, the bridge to the script, fullscreen.
- `Updater.swift`, `UpdatePanel.swift`: update checks, download and install.
- `WebCryptoKey.swift`: gives WebKit its own key for data the page encrypts, so
  it doesn't use the keychain (which would ask for your password after every
  update, since each build has a new ad-hoc signature).
- `Tailscale.swift`: reads the tailnet from the Tailscale CLI for the join list.

Set `COUCHSYNC_VERBOSE=1` to log sync activity to stderr. `App.swift` lists the
other environment overrides used for testing.
