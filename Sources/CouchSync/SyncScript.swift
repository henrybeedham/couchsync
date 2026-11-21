/// JavaScript injected into every page. It finds the playing <video>, reports
/// play / pause / seek to the app, and applies the party's state when told to.
///
/// On Netflix, seeking must go through Netflix's own player object: writing
/// `video.currentTime` directly crashes their player.
enum SyncScript {
    static let source = #"""
    (() => {
      if (window.__couchsync || window.top !== window) return;
      const initialFullscreen = !!window.__couchsyncFullscreen;

      const post = (m) => {
        try { window.webkit.messageHandlers.couchsync.postMessage(m); } catch (e) {}
      };
      const now = () => performance.now();
      const isNetflix = /(^|\.)netflix\.com$/.test(location.hostname);

      let video = null;      // element we are attached to
      let vid = null;        // id of the title it is playing
      let attachedAt = 0;
      let announced = false; // told the app this video exists
      let ready = false;     // app has answered; events may flow
      let shared = null;     // { paused, pos, at }: what the party agreed on
      let quietUntil = 0;    // events before this are echoes of a remote change
      let lastFix = 0;
      let warned = false;

      const currentId = () => {
        if (isNetflix) {
          const m = location.pathname.match(/\/watch\/(\d+)/);
          return m ? m[1] : null;
        }
        return 'page:' + location.host + location.pathname;
      };

      const nf = () => {
        try {
          const vp = window.netflix.appContext.state.playerApp.getAPI().videoPlayer;
          const ids = vp.getAllPlayerSessionIds();
          const id = ids.find((s) => String(s).startsWith('watch-')) || ids[0];
          return id ? vp.getVideoPlayerBySessionId(id) : null;
        } catch (e) {
          return null;
        }
      };

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
        if (paused) {
          if (p) { try { p.pause(); return; } catch (e) {} }
          video.pause();
          return;
        }
        if (p) { try { p.play(); return; } catch (e) {} }
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
        post({ type: 'state', videoId: vid, paused: s.paused, pos: s.pos, reason });
      };

      const onEvent = (e) => {
        if (!ready || e.target !== video || now() < quietUntil) return;
        if (e.type === 'pause' && video.ended) return;
        const s = local();
        // Nothing the party doesn't already know.
        if (shared && s.paused === shared.paused && Math.abs(s.pos - expected()) < 1200) return;
        announce(e.type);
      };

      const apply = (s, force) => {
        shared = { paused: s.paused, pos: s.pos, at: now() };
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
        video = null; vid = null; announced = false; ready = false; shared = null;
        post({ type: 'gone' });
      };

      const attach = (v, id) => {
        detach();
        video = v; vid = id; attachedAt = now();
        EVENTS.forEach((n) => v.addEventListener(n, onEvent, true));
      };

      const pick = () => {
        let best = null, bestArea = -1;
        for (const v of document.querySelectorAll('video')) {
          const r = v.getBoundingClientRect();
          const area = r.width * r.height;
          if (area > bestArea) { best = v; bestArea = area; }
        }
        return best;
      };

      const scan = () => {
        const id = currentId();
        const v = id ? pick() : null;
        if (v !== video || (video && id !== vid)) {
          if (v) attach(v, id); else detach();
        }
        if (video && !announced && video.readyState >= 1) {
          // On Netflix, wait for their player object so the first seek lands.
          if (!isNetflix || nf() || now() - attachedAt > 10000) {
            announced = true;
            post({ type: 'ready', videoId: vid });
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
        'margin:0!important;z-index:2147483647!important;background:#000;}';
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
      };

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
        fsSet(this, true);
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
          if (on && !fsElement) fsSet(fsGuess(), false);
          if (!on && fsElement) fsSet(null);
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
        const settle = () => { if (!fsElement) fsSet(fsGuess(), false); };
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', settle);
        else settle();
      }

      setInterval(scan, 500);
      setInterval(() => {
        if (!video || !ready) return;
        const s = local();
        post({ type: 'tick', videoId: vid, paused: s.paused, pos: s.pos });
      }, 2000);
      scan();
    })();
    """#
}
