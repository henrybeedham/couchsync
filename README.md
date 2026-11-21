# CouchSync

A Mac app (Apple silicon) for watching Netflix together across Macs, like
Teleparty but yours. Each Mac runs the app, signs in to Netflix inside it, and
joins the same party. Play, pause, seek and choosing a title on one Mac happen
on all of them, with a chat, GIFs and reactions alongside.

## Build

    ./build.sh

Needs only the Xcode Command Line Tools. Produces `build/CouchSync.app`.

To turn on GIFs for everyone who gets this build, include a free GIPHY API key
(create an app at https://developers.giphy.com and choose API):

    GIPHY_API_KEY=yourkey ./build.sh      # or put the key in giphy-key.txt

Without one, the GIF browser asks for a key the first time it's opened.

## Releases

Downloads are on the [Releases](https://github.com/henrybeedham/couchsync/releases)
page. They're made automatically: every push to `main` that changes the app
builds it on GitHub and publishes the next patch version (1.0.1, 1.0.2, …).
Pushes that only change Markdown files don't make a release.

To choose the version yourself (say 1.1 or 2.0), open **Actions → Release →
Run workflow** on GitHub, or run `./release.sh 1.1` on your Mac.

For GIFs to work out of the box, add your GIPHY key as a repository secret
named `GIPHY_API_KEY` (Settings → Secrets and variables → Actions). Anyone who
downloads a release can extract the key from the app.

## Use

1. Open CouchSync on every Mac and sign in to Netflix.
2. On one Mac: **Party → Host a party**.
3. On the others: **Party**, then pick the host. Parties you've joined before
   are under **Recent**, and Macs on your tailnet are listed below them (marked
   *Hosting* when a party is running). Or type a Tailscale name or IP.
4. Start a title on any Mac.

### Chat

The sidebar on the right (⇧⌘C to show or hide) has the party's chat:

- messages, with a **GIF** button that opens a GIPHY search;
- hover a message to react to it, and click a reaction to add or remove yours;
- the emoji row above the message box sends a reaction floating up over
  everyone's video;
- play, pause, seek, joins and leaves are noted in the chat, as in Teleparty.

Someone who joins late gets the chat so far.

### Fullscreen

Netflix's fullscreen button, its `f` key and the green traffic light all do the
same thing: the window goes fullscreen with the chat still beside the video.
Esc leaves. The toolbar shows when the mouse reaches the top of the screen.

### Remembered parties

- Parties you join are remembered under **Recent**. Hover one and click × to
  forget it.
- If the connection drops, CouchSync keeps trying to get back in for about
  a minute, so a host restarting their app doesn't end the party.
- Quit while in a party and CouchSync picks up again on the next launch, either
  rejoining or hosting again. Leaving or ending the party stops that.

The party uses TCP port 47800, directly between the Macs. There is no server.

## Installing on another Mac

The app is signed ad hoc, so a copy that arrives by AirDrop or a download is
blocked by Gatekeeper. Either build it on that Mac, or clear the flag once:

    xattr -dr com.apple.quarantine CouchSync.app

## How it works

- `SyncScript.swift`: JavaScript injected into the page. Watches the `<video>`,
  reports changes, applies the party's state. Seeks go through Netflix's own
  player object, because writing `video.currentTime` crashes their player. It
  also stands in for the page's fullscreen API so fullscreen means the window.
- `PartySession.swift`: the party. One Mac hosts and relays; every change
  carries a sequence number; the host sends its position every 2 s so the
  others can correct drift over 2.5 s. Also reconnection and remembered parties.
- `Chat.swift`, `ChatPanel.swift`, `ReactionOverlay.swift`: chat, reactions.
- `Giphy.swift`: GIF search, and a GIF view that animates.
- `WebController.swift`: the web view, the bridge to the script, fullscreen.
- `Tailscale.swift`: reads the tailnet from the Tailscale CLI for the join list.

Set `COUCHSYNC_VERBOSE=1` to log sync activity to stderr. `App.swift` lists the
other environment overrides used for testing.
