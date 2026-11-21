import Foundation

/// JavaScript injected into every page, and into the embedded player frames
/// of the services CouchSync knows (Crunchyroll's player is in one). It finds
/// the playing <video>, reports play / pause / seek to the app, and applies
/// the party's state when told to. Which title is playing is up to the app,
/// which reads it from the page address.
///
/// On Netflix, seeking must go through Netflix's own player object: writing
/// `video.currentTime` directly crashes their player. YouTube is driven
/// through its player too, so its controls stay in step.
enum SyncScript {
    static var source: String {
        let domains = (try? JSONSerialization.data(withJSONObject: Services.allDomains))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return template.replacingOccurrences(of: "__FRAME_DOMAINS__", with: domains)
    }

    private static let template = #"""
    (() => {
      if (window.__couchsync) return;
      const isTop = window.top === window;
      const host = location.hostname;
      const onDomain = (list) => list.some((d) => host === d || host.endsWith('.' + d));
      // In frames, only the services' own player frames.
      if (!isTop && !onDomain(__FRAME_DOMAINS__)) return;
      const initialFullscreen = isTop && !!window.__couchsyncFullscreen;

      // Tells the app which frame a message came from.
      const token = Math.random().toString(36).slice(2) + Date.now().toString(36);
      const post = (m) => {
        m.token = token;
        try { window.webkit.messageHandlers.couchsync.postMessage(m); } catch (e) {}
      };
      const now = () => performance.now();
      const isNetflix = onDomain(['netflix.com']);
      const isYouTube = onDomain(['youtube.com']);

      let video = null;      // element we are attached to
      let attachedAt = 0;
      let announced = false; // told the app this video exists
      let ready = false;     // app has answered; events may flow
      let shared = null;     // { paused, pos, at }: what the party agreed on
      let quietUntil = 0;    // events before this are echoes of a remote change
      let lastFix = 0;
      let resetAt = -1e9;        // when the page last moved on to another title
      let awaitingMedia = false; // the player hasn't loaded the new title yet
      let warned = false;

      // Players often keep their <video> in a shadow root, closed ones too,
      // where querySelectorAll can't see it. Remember every root made.
      const shadowRoots = [];
      try {
        const attachShadow = Element.prototype.attachShadow;
        Element.prototype.attachShadow = function (...args) {
          const root = attachShadow.apply(this, args);
          shadowRoots.push(root);
          return root;
        };
      } catch (e) {}

      const nf = () => {
        if (!isNetflix) return null;
        try {
          const vp = window.netflix.appContext.state.playerApp.getAPI().videoPlayer;
          const ids = vp.getAllPlayerSessionIds();
          const id = ids.find((s) => String(s).startsWith('watch-')) || ids[0];
          return id ? vp.getVideoPlayerBySessionId(id) : null;
        } catch (e) {
          return null;
        }
      };

      // YouTube's player object, when it's ready to be driven.
      const yt = () => {
        if (!isYouTube) return null;
        const p = document.getElementById('movie_player');
        return p && typeof p.seekTo === 'function' ? p : null;
      };
      // During an ad the video isn't the title, so it mustn't be synced.
      const inAd = () => isYouTube && !!document.querySelector('.html5-video-player.ad-showing');

      const pos = () => {
        const p = nf();
        if (p) {
          try {
            const t = p.getCurrentTime();
            if (Number.isFinite(t)) return t;
          } catch (e) {}
        }
        return video.currentTime * 1000;
      };

      const seek = (ms) => {
        ms = Math.max(0, ms);
        const p = nf();
        if (p) {
          try { p.seek(ms); return; } catch (e) {}
        }
        const y = yt();
        if (y) {
          try { y.seekTo(ms / 1000, true); return; } catch (e) {}
        }
        if (isNetflix) {
          if (!warned) {
            warned = true;
            post({ type: 'warn', message: "Can't reach the Netflix player, so seeking won't sync." });
          }
          return;
        }
        video.currentTime = ms / 1000;
      };

      const setPaused = (paused) => {
        const p = nf();
        const y = yt();
        if (paused) {
          if (p) { try { p.pause(); return; } catch (e) {} }
          if (y) { try { y.pauseVideo(); return; } catch (e) {} }
          video.pause();
          return;
        }
        if (p) { try { p.play(); return; } catch (e) {} }
        if (y) { try { y.playVideo(); return; } catch (e) {} }
        const r = video.play();
        if (r && r.catch) {
          r.catch(() => post({ type: 'warn', message: 'Playback was blocked. Click the video once.' }));
        }
      };

      const local = () => ({ paused: video.paused, pos: pos() });
      const expected = () => (shared.paused ? shared.pos : shared.pos + (now() - shared.at));

      const announce = (reason) => {
        const s = local();
        shared = { paused: s.paused, pos: s.pos, at: now() };
        post({ type: 'state', paused: s.paused, pos: s.pos, reason });
      };

      const onEvent = (e) => {
        if (!ready || e.target !== video || now() < quietUntil || inAd()) return;
        if (e.type === 'pause' && video.ended) return;
        const s = local();
        // Nothing the party doesn't already know.
        if (shared && s.paused === shared.paused && Math.abs(s.pos - expected()) < 1200) return;
        announce(e.type);
      };

      const apply = (s, force) => {
        shared = { paused: s.paused, pos: s.pos, at: now() };
        // After the ad, the heartbeat brings this back in line.
        if (inAd()) return;
        const drift = Math.abs(pos() - s.pos);
        const tolerance = force ? (s.paused ? 300 : 800) : 2500;
        const settled = !video.seeking && video.readyState >= 3;
        const needsSeek = drift > tolerance && (force || (settled && now() - lastFix > 5000));
        const needsToggle = video.paused !== s.paused;
        // Only go quiet when we touch the player. Heartbeats that change
        // nothing must not swallow the viewer's own clicks.
        if (needsSeek || needsToggle) quietUntil = now() + 1500;
        if (needsSeek) {
          lastFix = now();
          seek(s.pos);
        }
        if (needsToggle) setPaused(s.paused);
      };

      const EVENTS = ['play', 'pause', 'seeked'];

      const detach = () => {
        if (!video) return;
        EVENTS.forEach((n) => video.removeEventListener(n, onEvent, true));
        video = null; announced = false; ready = false; shared = null;
        post({ type: 'gone' });
      };

      const attach = (v) => {
        detach();
        video = v; attachedAt = now();
        EVENTS.forEach((n) => v.addEventListener(n, onEvent, true));
      };

      const area = (el) => {
        const r = el.getBoundingClientRect();
        return r.width * r.height;
      };

      const pick = () => {
        let best = null, bestArea = -1;
        const consider = (v) => {
          const a = area(v);
          if (a > bestArea) { best = v; bestArea = a; }
        };
        document.querySelectorAll('video').forEach(consider);
        for (const root of shadowRoots) {
          if (root.host && root.host.isConnected) root.querySelectorAll('video').forEach(consider);
        }
        return best;
      };

      const scan = () => {
        const v = pick();
        if (v !== video) {
          if (v) attach(v); else detach();
        }
        // After a title change the player may still hold the old one for a
        // while, and an ad isn't the title either.
        const settled = !awaitingMedia || now() - resetAt > 5000;
        if (video && !announced && video.readyState >= 1 && settled && !inAd()) {
          // On Netflix, wait for their player object so the first seek lands.
          if (!isNetflix || nf() || now() - attachedAt > 10000) {
            announced = true;
            post({ type: 'ready', area: area(video), top: isTop });
          }
        }
      };

      // ---- Fullscreen ----------------------------------------------------
      // Real element fullscreen would move the video into a window of its own,
      // leaving the chat and reactions behind. Instead the page is told it is
      // fullscreen while the app window goes fullscreen around it, so the
      // player's button, its "f" key and the green traffic light are one switch.
      let fsElement = null;
      const FS_ATTR = 'data-couchsync-fullscreen';
      const fsStyle = document.createElement('style');
      fsStyle.textContent = '[' + FS_ATTR + '="page"]{position:fixed!important;inset:0!important;' +
        'width:100%!important;height:100%!important;max-width:none!important;max-height:none!important;' +
        'margin:0!important;z-index:2147483647!important;background:#000;}' +
        // While something is pinned, hide everything that isn't it, inside it
        // or around it: some of the page may be stacked above it (YouTube's
        // header, for one). As a selector, it follows the player if the page
        // moves it.
        'html:has([' + FS_ATTR + '="page"]){overflow:hidden!important;}' +
        'html:has([' + FS_ATTR + '="page"]) body *:not(:has([' + FS_ATTR + '="page"])):not([' + FS_ATTR + '="page"])' +
        ':not([' + FS_ATTR + '="page"] *){visibility:hidden!important;}';
      const addStyle = () => (document.head || document.documentElement).appendChild(fsStyle);
      if (document.documentElement) addStyle(); else document.addEventListener('DOMContentLoaded', addStyle);

      const fsFire = (target) => {
        const el = target && target.isConnected ? target : document;
        ['fullscreenchange', 'webkitfullscreenchange'].forEach((type) =>
          el.dispatchEvent(new Event(type, { bubbles: true, composed: true })));
      };

      const fsSet = (el, fromPage) => {
        if (fsElement === el) return;
        const old = fsElement;
        if (old) old.removeAttribute(FS_ATTR);
        fsElement = el;
        if (el) el.setAttribute(FS_ATTR, fromPage ? 'page' : 'window');
        fsFire(el || old);
        // Players size their video on resize; the window may not have resized.
        setTimeout(() => window.dispatchEvent(new Event('resize')), 50);
      };

      // Some players (YouTube) don't take the page's word for fullscreen, so
      // their player element is pinned over the whole window instead.
      const pinnedPlayer = () => (isYouTube ? document.getElementById('movie_player') : null);

      // The element the player would have asked for, when the window goes
      // fullscreen on its own (green traffic light).
      const fsGuess = () => {
        const v = video || pick();
        let el = v;
        while (el && el.parentElement && el.parentElement !== document.body) {
          const r = el.parentElement.getBoundingClientRect();
          if (r.width < innerWidth - 2 || r.height < innerHeight - 2) break;
          el = el.parentElement;
        }
        return el || document.documentElement;
      };

      function requestFs() {
        fsSet(pinnedPlayer() || this, true);
        post({ type: 'fullscreen', on: true });
        return Promise.resolve();
      }
      function exitFs() {
        if (fsElement) {
          fsSet(null);
          post({ type: 'fullscreen', on: false });
        }
        return Promise.resolve();
      }

      const define = (proto, name, value) => {
        try { Object.defineProperty(proto, name, { configurable: true, writable: true, value }); } catch (e) {}
      };
      const getter = (proto, name, get) => {
        try { Object.defineProperty(proto, name, { configurable: true, get }); } catch (e) {}
      };

      define(Element.prototype, 'requestFullscreen', requestFs);
      define(Element.prototype, 'webkitRequestFullscreen', requestFs);
      define(Element.prototype, 'webkitRequestFullScreen', requestFs);
      define(HTMLVideoElement.prototype, 'webkitEnterFullscreen', requestFs);
      define(HTMLVideoElement.prototype, 'webkitEnterFullScreen', requestFs);
      define(Document.prototype, 'exitFullscreen', exitFs);
      define(Document.prototype, 'webkitExitFullscreen', exitFs);
      define(Document.prototype, 'webkitCancelFullScreen', exitFs);
      define(HTMLVideoElement.prototype, 'webkitExitFullscreen', exitFs);
      getter(Document.prototype, 'fullscreenElement', () => fsElement);
      getter(Document.prototype, 'webkitFullscreenElement', () => fsElement);
      getter(Document.prototype, 'webkitCurrentFullScreenElement', () => fsElement);
      getter(Document.prototype, 'fullscreen', () => !!fsElement);
      getter(Document.prototype, 'webkitIsFullScreen', () => !!fsElement);
      getter(Document.prototype, 'fullscreenEnabled', () => true);
      getter(Document.prototype, 'webkitFullscreenEnabled', () => true);
      getter(HTMLVideoElement.prototype, 'webkitSupportsFullscreen', () => true);
      getter(HTMLVideoElement.prototype, 'webkitDisplayingFullscreen', () => !!fsElement);

      // Real fullscreen leaves on Escape; so should this.
      window.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && fsElement) {
          e.stopImmediatePropagation();
          e.preventDefault();
          exitFs();
        }
      }, true);

      window.__couchsync = {
        // The app window entered or left fullscreen.
        setFullscreen(on) {
          if (on && !fsElement) {
            const player = pinnedPlayer();
            if (player) fsSet(player, true); else fsSet(fsGuess(), false);
          }
          if (!on && fsElement) fsSet(null);
        },
        // The video is in a frame: make the frame fill the window.
        frameFullscreen(on) {
          if (!on) { if (fsElement) fsSet(null); return; }
          let best = null, bestArea = 0;
          for (const f of document.querySelectorAll('iframe')) {
            const a = area(f);
            if (a > bestArea) { best = f; bestArea = a; }
          }
          if (best && fsElement !== best) { fsSet(null); fsSet(best, true); }
        },
        // The page moved on to another title: start over with this video.
        reset() {
          resetAt = now();
          const old = video;
          detach();
          if (old) {
            // Same element, new title: wait for it to start loading.
            awaitingMedia = true;
            const loaded = () => { awaitingMedia = false; old.removeEventListener('loadstart', loaded); };
            old.addEventListener('loadstart', loaded);
          }
          scan();
        },
        // Answer to 'ready': the party's state for this title, or null if we
        // are the first one here and should tell everyone else.
        init(s) {
          if (!video) return;
          ready = true;
          if (s) apply(s, true); else announce('init');
        },
        apply(s, force) { if (video && ready) apply(s, force); },
        announce() { if (video && ready) announce('announce'); },
      };

      // A page loaded while the window is already fullscreen starts out fullscreen.
      if (initialFullscreen) {
        const settle = () => { if (!fsElement) window.__couchsync.setFullscreen(true); };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', settle);
        else settle();
      }

      // Tell the app when a sign-in field has focus, so it can offer to fill it.
      if (isTop) {
        const signIn = (el) => el && el.tagName === 'INPUT' &&
          (el.type === 'password' || el.type === 'email' || /username|email/.test(el.autocomplete || ''));
        let blurTimer = null;
        document.addEventListener('focusin', (e) => {
          if (!signIn(e.target)) return;
          clearTimeout(blurTimer);
          post({ type: 'login', on: true });
        }, true);
        document.addEventListener('focusout', (e) => {
          if (!signIn(e.target)) return;
          blurTimer = setTimeout(() => post({ type: 'login', on: false }), 600);
        }, true);
      }

      setInterval(scan, 500);
      setInterval(() => {
        if (!video || !ready || inAd()) return;
        const s = local();
        post({ type: 'tick', paused: s.paused, pos: s.pos });
      }, 2000);
      scan();
    })();
    """#
}
