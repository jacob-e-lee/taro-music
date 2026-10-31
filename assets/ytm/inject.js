// Injected into every music.youtube.com page by YtmWebView.kt (at document start, and
// again from onPageStarted as a fallback). Edit this file to change the UX.
(function () {
  if (window.__taroYtm) return;
  window.__taroYtm = true;

  // At document start there may be no <html> yet; wait for it instead of throwing.
  function addStyle(css) {
    var style = document.createElement('style');
    style.textContent = css;
    if (document.documentElement) return (document.head || document.documentElement).appendChild(style);
    new MutationObserver(function (_, obs) {
      if (!document.documentElement) return;
      obs.disconnect();
      document.documentElement.appendChild(style);
    }).observe(document, { childList: true });
  }

  // ---- CSS: prefer element names (stable) over hashed class names. ----------
  addStyle([
    // "Get the app" / upsell banners.
    'ytmusic-mealbar-promo-renderer, ytmusic-statement-banner-renderer { display: none !important; }',
    // "Open app" button (mobile web).
    '.app-install-link, a[href^="https://app.music.youtube.com"], .open-app-button,ytmusic-open-app-button, a[href*="app.adjust"], a[href^="intent://"], a[href*="play.google.com/store/apps/details?id=com.google.android.apps.youtube.music"] { display: none !important; }',
  ].join('\n'));
  // The same buttons inside shadow roots are hidden by HIDE_OPEN_APP in YtmWebView.kt.

  // ---- Ads: rewrite YouTube's JSON (the approach NouTube uses). -------------
  var AD_KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams'];
  // List entries that are an ad/promo instead of content.
  var AD_RENDERERS = ['adSlotRenderer', 'adsEngagementPanelRenderer', 'bannerPromoRenderer',
    'brandVideoShelfRenderer', 'brandVideoSingletonRenderer', 'carouselAdRenderer',
    'compactPromotedItemRenderer', 'compactPromotedVideoRenderer', 'displayAdRenderer',
    'inFeedAdLayoutRenderer', 'mealbarPromoRenderer', 'primetimePromoRenderer',
    'promotedSparklesTextSearchRenderer', 'promotedSparklesWebRenderer',
    'promotedVideoRenderer', 'searchPyvRenderer', 'statementBannerRenderer'];
  function isAd(item) {
    return item && typeof item === 'object' && AD_RENDERERS.some(function (k) {
      return item[k] || (item.richItemRenderer && item.richItemRenderer.content &&
        item.richItemRenderer.content[k]);
    });
  }
  function strip(o) {
    if (!o || typeof o !== 'object') return o;
    AD_KEYS.forEach(function (k) { delete o[k]; });
    if (o.playerResponse) strip(o.playerResponse);
    Object.keys(o).forEach(function (k) {
      var v = o[k];
      if (Array.isArray(v)) o[k] = v.filter(function (i) { return !isAd(i); });
      if (o[k] && typeof o[k] === 'object') strip(o[k]);
    });
    return o;
  }

  var parse = JSON.parse;
  JSON.parse = function () { return strip(parse.apply(this, arguments)); };

  // Server-rendered first page: the page assigns these globals itself.
  ['ytInitialData', 'ytInitialPlayerResponse'].forEach(function (name) {
    var value = window[name];
    Object.defineProperty(window, name, {
      configurable: true,
      get: function () { return value; },
      set: function (v) { value = strip(v); },
    });
  });

  var RE = /^\/youtubei\/v1\/(browse|get_watch|next|player|reel|search)/;
  function rewrite(url, text) {
    try {
      if (!RE.test(new URL(url, location.origin).pathname)) return text;
      return JSON.stringify(strip(parse(text)));
    } catch (e) { return text; }
  }

  var origFetch = window.fetch;
  window.fetch = function (input) {
    var url = input instanceof Request ? input.url : String(input);
    return origFetch.apply(this, arguments).then(function (res) {
      if (res.status !== 200) return res;
      return res.clone().text().then(function (text) {
        var out = rewrite(url, text);
        return out === text ? res : new Response(out, {
          status: res.status, statusText: res.statusText, headers: res.headers,
        });
      });
    });
  };

  var xhrOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    var xhr = this;
    xhr.addEventListener('readystatechange', function () {
      if (xhr.readyState !== 4 || xhr.responseType) return;
      var text = rewrite(String(url), xhr.responseText);
      Object.defineProperty(xhr, 'response', { writable: true, value: text });
      Object.defineProperty(xhr, 'responseText', { writable: true, value: text });
    });
    return xhrOpen.apply(this, arguments);
  };

  // ---- Ads: fallback if one slips through. Selectors are unverified. --------
  // Video ads play in the same <video>: mute, speed through, seek to the end.
  addStyle('.video-ads, .ytp-ad-module, .ytp-ad-overlay-container, ' +
    'ytmusic-player-ad-renderer { display: none !important; }');

  // YouTube marks an ad on its player element; checking that one element's classes is cheap,
  // where searching the whole page (~13k elements) for the marker 10 times a second was not.
  setInterval(function () {
    var p = document.getElementById('movie_player'), v = p && p.querySelector('video');
    if (!v || !(p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting'))) return;
    v.muted = true;
    v.playbackRate = 16;
    if (isFinite(v.duration) && v.duration > 0) v.currentTime = v.duration;
    var skip = document.querySelector('.ytp-ad-skip-button, .ytp-skip-ad-button, .ytp-ad-skip-button-modern');
    if (skip) skip.click();
  }, 250);

  // ---- Mobile UX: no tap flash, bottom tabs, swipe gestures. ----------------
  var NAV_H = 48;
  // The page runs under the phone's status bar (main.dart); this is that bar's height.
  var TOP = 'env(safe-area-inset-top, 0px)';
  // ...and under its navigation bar: the tabs (and the player's black) extend behind it. The keyboard
  // zeroes this inset while it's up; --taro-bot keeps the keyboard-down value (see keepBottomInset)
  // so the tabs and mini player don't jump when it opens.
  var BOT = 'var(--taro-bot, env(safe-area-inset-bottom, 0px))';
  var NAVB = 'calc(' + NAV_H + 'px + ' + BOT + ')';  // tabs plus the navigation bar below them
  // Full-player parts that fade in as it opens (the artwork morphs instead).
  var FADE = '.background-image, .background-gradient, #side-panel, #main-panel > :not(#music-player-wrapper)';
  addStyle([
    // Inherited, so this also reaches into shadow roots.
    'html, * { -webkit-tap-highlight-color: transparent !important; }',
    // Like a native app: no text selection or long-press callout (except in text fields), nothing draggable.
    'html { -webkit-user-select: none; user-select: none; -webkit-touch-callout: none; }',
    'input, textarea, [contenteditable] { -webkit-user-select: text; user-select: text; }',
    'a, img { -webkit-user-drag: none; }',
    // A slimmer top bar (YouTube's is 64px), below the status bar: the page below follows this
    // variable, and the bar's background extends up behind the status bar.
    'html { --ytmusic-nav-bar-height: calc(48px + ' + TOP + ') !important; }',
    'ytmusic-nav-bar { top: ' + TOP + ' !important; height: 48px !important; }',
    // The full player keeps its content below the status bar too. Its layout is sized from
    // --ytmusic-player-page-inner-height (YouTube sets it to the window height); in the queue view
    // YouTube's own art placement already allows for the shift, so leave it there.
    '#player-page #main-panel { top: ' + TOP + ' !important; height: calc(100% - ' + TOP + ' - ' + BOT + ') !important; }',
    '#player-page #side-panel { top: calc(64px + ' + TOP + ') !important; }',
    '#player-page > .content { padding-top: ' + TOP + ' !important; }',
    // ...while its blurred background and darkening gradient start at the very top, under the status bar.
    '#player-page :is(.background-image, .background-gradient) { top: 0 !important; }',
    'ytmusic-app-layout[player-page-open] ytmusic-player-page:not([player-page-ui-state=TABS_VIEW]),' +
      ' html.taro-sheet ytmusic-player-page { --ytmusic-player-page-inner-height: calc(100dvh - ' + TOP + ' - ' + BOT + ') !important; }',
    // Pull the chip rows (Home's moods, Library's filters) up under the top bar.
    'ytmusic-browse-response ytmusic-chip-cloud-chip-renderer { padding-top: 8px !important; }',
    'ytmusic-browse-response #header > ytmusic-side-aligned-item-renderer { margin-top: 0 !important; }',
    '#taro-nav { position: fixed; left: 0; right: 0; bottom: 0; height: ' + NAVB + '; padding-bottom: ' + BOT + ';' +
      ' box-sizing: border-box; z-index: 4; display: flex; background: rgb(33,33,33); }',  // the mini player's grey
    '#taro-nav button { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center;' +
      ' gap: 1px; background: none; border: 0; color: #aaa; font: 500 11px Roboto, sans-serif; }',
    '#taro-nav button[active] { color: #fff; }',
    // A key press (e.g. Escape) would otherwise leave a blue focus ring on the tapped tab.
    '#taro-nav button, #taro-new { outline: none; }',
    '#taro-nav svg, #taro-new svg { width: 24px; height: 24px; fill: currentColor; }',
    '#taro-nav svg { width: 22px; height: 22px; }',
    'html.taro-open #taro-nav { display: none; }',
    // The tabs replace the drawer; its one extra, "New playlist", moves to the Library tab.
    'ytmusic-nav-bar #guide-button { display: none !important; }',
    '#taro-new { position: fixed; right: 16px; bottom: calc(' + (NAV_H + 16) + 'px + ' + BOT + '); z-index: 4; display: none; align-items: center;' +
      ' gap: 8px; height: 48px; padding: 0 20px 0 16px; border: 0; border-radius: 24px; background: #fff; color: #030303;' +
      ' font: 500 14px Roboto, sans-serif; box-shadow: 0 2px 8px rgba(0,0,0,.4); }',
    '#taro-new[shown] { display: flex; }',
    // Touch feedback (see the press handler): whatever is under a finger dims while it's held.
    '[taro-pressed] { opacity: .55 !important; transition: opacity .2s; }',
    'ytmusic-two-row-item-renderer[taro-pressed] { opacity: 1 !important; transform: scale(.96); transition: transform .2s; }',
    ':is(ytmusic-responsive-list-item-renderer, ytmusic-player-queue-item, ytmusic-menu-navigation-item-renderer,' +
      ' ytmusic-menu-service-item-renderer, ytmusic-toggle-menu-service-item-renderer)[taro-pressed] {' +
      ' opacity: 1 !important; background: rgba(255,255,255,.12); animation: taro-fade .25s; }',
    '@keyframes taro-fade { from { background-color: transparent; } }',
    // A list row's highlight reaches halfway to the rows above and below (--taro-t and --taro-b, set when pressed), with rounded corners.
    'ytmusic-responsive-list-item-renderer[taro-pressed] { background: none; isolation: isolate; }',
    'ytmusic-responsive-list-item-renderer[taro-pressed]::before { content: ""; position: absolute; z-index: -1;' +
      ' inset: calc(-1 * var(--taro-t, 8px)) var(--taro-r, -8px) calc(-1 * var(--taro-b, 8px)) var(--taro-l, -8px);' +
      ' border-radius: 12px; background: rgba(255,255,255,.12); animation: taro-fade-in .3s; }',
    '@keyframes taro-fade-in { from { opacity: 0; } }',
    // Song menus (3-dots, long press): a bottom sheet over a darkened page. See watchMenu.
    '#taro-scrim { position: fixed; inset: 0; z-index: 102; background: rgba(0,0,0,.6); opacity: 0; pointer-events: none;' +
      ' transition: opacity .25s; }',
    '#taro-scrim.on { opacity: 1; pointer-events: auto; }',
    'tp-yt-iron-dropdown.taro-menu { position: fixed !important; left: 0 !important; right: 0 !important; top: auto !important;' +
      ' bottom: 0 !important; width: auto !important; max-width: none !important; max-height: none !important;' +
      ' animation: taro-menu-up .25s cubic-bezier(.2,.8,.2,1); }',
    '@keyframes taro-menu-up { from { transform: translateY(100%); } }',
    'tp-yt-iron-dropdown.taro-menu #contentWrapper { background: rgb(33,33,33); border-radius: 16px 16px 0 0;' +
      ' overflow-y: auto; overscroll-behavior: contain; max-height: 75vh; padding-bottom: ' + BOT + '; box-sizing: border-box; }',
    // Swiping up on a sheet that has more to show first grows it to the top of the screen (see dragSheet).
    'tp-yt-iron-dropdown.taro-menu #contentWrapper { transition: max-height .25s; }',
    'tp-yt-iron-dropdown.taro-menu.taro-tall #contentWrapper { max-height: calc(100vh - ' + TOP + '); }',
    'tp-yt-iron-dropdown.taro-menu ytmusic-menu-popup-renderer { display: block; overflow: visible !important; max-height: none !important;' +
      ' width: auto !important; max-width: none !important; background: none; box-shadow: none; }',
    'tp-yt-iron-dropdown.taro-menu #items { border: 0 !important; outline: none; width: auto; }',
    '.taro-liked-item { display: none !important; }',
    '#taro-mh { display: flex; align-items: center; gap: 4px; padding: 20px 4px 8px 16px; position: relative;' +
      ' border-bottom: 1px solid rgba(255,255,255,.1); }',
    '#taro-mh::before { content: ""; position: absolute; top: 8px; left: 50%; width: 36px; height: 4px; margin-left: -18px;' +
      ' border-radius: 2px; background: rgba(255,255,255,.3); }',
    '#taro-mh div { flex: 1; min-width: 0; color: #fff; font: 500 16px Roboto, sans-serif; }',
    '#taro-mh div span { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }',
    '#taro-mh div span + span { color: #aaa; font-size: 14px; font-weight: 400; margin-top: 2px; }',
    '#taro-mh button { flex: none; width: 48px; height: 48px; display: flex; align-items: center; justify-content: center;' +
      ' background: none; border: 0; outline: none; color: #fff; }',
    '#taro-mh svg { width: 24px; height: 24px; fill: currentColor; }',
    '#taro-fit { position: fixed; left: 0; right: 0; top: ' + TOP + '; bottom: ' + BOT + '; visibility: hidden; pointer-events: none; }',
    'html.taro-playing #taro-new { bottom: calc(' + (NAV_H + 64 + 16) + 'px + ' + BOT + '); }',
    'html.taro-open #taro-new, html.taro-sheet #taro-new { display: none !important; }',
    // Lift the mini player above the tabs, and leave room to scroll past both.
    'ytmusic-app-layout:not([player-page-open]) > ytmusic-player-bar, #player-bar-background { bottom: ' + NAVB + ' !important; }',
    // The mini player's artwork is the real #player, pinned 8px from the bottom.
    // (Measured from the player's main panel, which already stops above the navigation bar.)
    'ytmusic-app-layout:not([player-page-open]) #player-page #player { bottom: ' + (NAV_H + 8) + 'px !important; }',
    'ytmusic-app-layout > #content { margin-bottom: ' + NAVB + '; }',
    // The mini player's progress line moves to its bottom edge, as the divider above the tabs.
    // It's display-only there (disabled), so its 31px slider box mustn't take taps from the tabs.
    'ytmusic-app-layout > ytmusic-player-bar #progress-bar { top: auto !important; bottom: -15px !important;' +
      ' transform: none !important; pointer-events: none; }',
    // Search: the open box covers the whole top bar, flush and borderless. [is-mobile-view] and the
    // nav-bar ancestor outrank YouTube's own `margin-left: 16px !important`.
    'ytmusic-nav-bar ytmusic-search-box[is-mobile-view]:is([opened], [has-query]) { position: fixed !important;' +
      ' inset: ' + TOP + ' 0 auto 0 !important; margin: 0 !important; width: auto !important; height: 48px !important;' +
      ' border: 0 !important; border-radius: 0 !important; }',
    'ytmusic-search-box:is([opened], [has-query]) :is(.search-container, .search-box) { height: 48px !important;' +
      ' border: 0 !important; border-radius: 0 !important; box-shadow: none !important; }',
    // YouTube hides the back arrow once a search has run and the box loses focus; keep it (see onSearchBack).
    'ytmusic-search-box[has-query]:not([opened]) .search-button { display: inline-block !important; }',
    'ytmusic-search-box:is([opened], [has-query]) #suggestion-list { left: 0 !important; right: 0 !important;' +
      ' width: auto !important; top: 48px !important; border: 0 !important; border-radius: 0 !important; }',
    // Our swipes own these areas; otherwise the browser pans the page underneath.
    '#player-page #main-panel, #player-page #player, ytmusic-app-layout > ytmusic-player-bar { touch-action: none; }',
    // Sheet mode (see setP): the player drawn part-way between mini and full, with the page behind visible.
    'html.taro-sheet #content, html.taro-sheet ytmusic-nav-bar, html.taro-sheet ytmusic-player-page { visibility: visible !important; }',
    'html.taro-sheet #taro-nav { display: flex !important; z-index: 7; }',
    // The mini bar fades out above the rising page, over its own grey (#taro-shade).
    // #layout (YouTube's id for ytmusic-app-layout) outranks YouTube's open-state rule that pins the bar to the bottom.
    'html.taro-sheet #layout > ytmusic-player-bar { visibility: visible !important; bottom: ' + NAVB + ' !important;' +
      ' z-index: 7 !important; background: transparent !important; transition: none !important; }',
    // YouTube hides the bar's contents while its player is open; keep them for the sheet's mini end.
    'html.taro-sheet #layout > ytmusic-player-bar > * { visibility: inherit !important; }',
    // YouTube hides the closed player a moment after closing; don't let it show once the sheet is gone.
    '@media (orientation: portrait) { html:not(.taro-sheet) ytmusic-app-layout:not([player-page-open]) ytmusic-player-page { visibility: hidden !important; } }',
    // YouTube clears the full player's side margins a frame late, which would nudge the mini art right.
    'ytmusic-app-layout:not([player-page-open]) #player-page #player { margin: 0 !important; }',
    // Own GPU layers, so each frame is only a compositor update (no layout or repaint).
    'html.taro-sheet ytmusic-player-page { will-change: transform; transition: none !important; }',
    'html.taro-sheet #taro-nav, html.taro-sheet ytmusic-app-layout > ytmusic-player-bar, html.taro-sheet #taro-shade,' +
      ' html.taro-sheet #player-page :is(' + FADE + ') { will-change: transform, opacity; }',
    // A full-size copy of the cover (or video) morphs instead of YouTube's #player, whose size and
    // place change with YouTube's open/closed layout (and a small one would blur when scaled up).
    '#taro-art, #taro-vid { position: fixed; left: 0; top: 0; z-index: 8; pointer-events: none; transform-origin: 0 0;' +
      ' will-change: transform; }',
    '#taro-vid { object-fit: contain; background: #000; }',  // letterboxed in black, like YouTube's
    'html:not(.taro-sheet) :is(#taro-art, #taro-vid), html.taro-slide :is(#taro-art, #taro-vid) { display: none; }',
    // YouTube squares off a music video's box; round it like a cover's, which the copy also is.
    'ytmusic-player-page[video-mode] #player { border-radius: 4px !important; }',
    // Sliding (a picked song): the page comes up whole, YouTube's own art and all.
    'html.taro-slide #player-page #player { opacity: 1 !important; }',
    'html.taro-slide #taro-shade { display: none; }',
    'html.taro-slide #player-page :is(' + FADE + ') { opacity: 1 !important; }',
    'html.taro-sheet #player-page #player { opacity: 0 !important; }',
    // Mini-bar grey over the player's black, faded out as it opens.
    '#taro-shade { position: absolute; inset: 0; background: rgb(33,33,33); pointer-events: none; }',
    'html:not(.taro-sheet) #taro-shade { display: none; }',
  ].join('\n'));

  var TABS = [
    ['Home', '/', 'FEmusic_home', 'M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z'],
    ['Explore', '/explore', 'FEmusic_explore', 'M12 10.9c-.61 0-1.1.49-1.1 1.1s.49 1.1 1.1 1.1c.61 0 1.1-.49 1.1-1.1s-.49-1.1-1.1-1.1zM12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm2.19 12.19L6 18l3.81-8.19L18 6l-3.81 8.19z'],
    ['Library', '/library', 'FEmusic_library_landing', 'M20 2H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-2 5h-3v5.5c0 1.38-1.12 2.5-2.5 2.5S10 13.88 10 12.5s1.12-2.5 2.5-2.5c.57 0 1.08.19 1.5.51V5h4v2zM4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6z'],
  ];
  // YouTube's own in-app navigation (no reload, playback continues). Forwarding a
  // click to the drawer entry doesn't work: Polymer drops it as a ghost click after a touch.
  function go(browseId) {
    document.querySelector('ytmusic-app').dispatchEvent(new CustomEvent('yt-navigate', {
      bubbles: true, composed: true, detail: { endpoint: { browseEndpoint: { browseId: browseId } } },
    }));
  }
  // A button with an icon and a label. DOM calls, not innerHTML: YouTube enforces Trusted Types.
  function iconButton(label, d, onClick) {
    var b = document.createElement('button');
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    var p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    p.setAttribute('d', d);
    svg.appendChild(p);
    b.appendChild(svg);
    b.appendChild(document.createTextNode(label));
    b.addEventListener('click', onClick);
    return b;
  }
  function buildNav() {
    var nav = document.createElement('nav');
    nav.id = 'taro-nav';
    TABS.forEach(function (t) {
      var b = iconButton(t[0], t[3], function () { go(t[2]); });
      b.dataset.path = t[1];
      nav.appendChild(b);
    });
    document.body.appendChild(nav);
    // Opens YouTube's own dialog via the (hidden) drawer's "New playlist" button.
    var add = iconButton('New playlist', 'M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z', function () {
      press('#guide-wrapper ytmusic-guide-section-renderer #buttons yt-button-renderer button');
    });
    add.id = 'taro-new';
    document.body.appendChild(add);
    // YouTube's menus (Polymer dropdowns) fit themselves into the window, which now runs under
    // the system bars; fit them into this box between the bars instead.
    var fit = document.createElement('div');
    fit.id = 'taro-fit';
    document.body.appendChild(fit);
    var fitMenus = function (root) {
      root.querySelectorAll('tp-yt-iron-dropdown').forEach(function (d) {
        d.fitInto = fit;
        watchMenu(d);
      });
    };
    var menus = null;
    setInterval(function () {
      nav.querySelectorAll('button').forEach(function (b) {
        b.toggleAttribute('active', b.dataset.path === location.pathname);
      });
      add.toggleAttribute('shown', location.pathname === '/library');
      // YouTube adds its dropdowns to this container as menus are first opened.
      if (!menus && (menus = document.querySelector('ytmusic-popup-container'))) {
        fitMenus(menus);
        new MutationObserver(function () { fitMenus(menus); }).observe(menus, { childList: true });
      }
    }, 300);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', buildNav);
  else buildNav();

  // ---- Song menus as a bottom sheet -----------------------------------------------------
  // YouTube opens these as a dropdown at the tapped spot. Here the dropdown is restyled (see the CSS)
  // into a sheet under a bar with the song, its artist, a like button and a close button. Dragging
  // the sheet down, tapping the dimmed page or the close button slides it away.
  var ROW = 'ytmusic-responsive-list-item-renderer, ytmusic-two-row-item-renderer, ytmusic-player-queue-item, ytmusic-player-bar';
  var menuRow = null, scrim = null, sheet = null;  // the row that opened the menu; the dimmer; the open dropdown
  // The menu doesn't say which song it is for; remember the last row touched (3-dots or long press).
  document.addEventListener('pointerdown', function (e) {
    var r = e.target.closest && e.target.closest(ROW);
    if (r) menuRow = r;
  }, true);
  // Touch feedback. A finger that lands on something marks it pressed until it lifts, moves off or the
  // browser takes the touch over to scroll (pointercancel), so a press that turns into a drag still shows.
  var BUTTON = 'button, tp-yt-paper-icon-button, yt-icon-button, ytmusic-menu-renderer';
  var CARD = 'ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer, ytmusic-chip-cloud-chip-renderer,' +
    ' ytmusic-player-queue-item, ytmusic-menu-navigation-item-renderer, ytmusic-menu-service-item-renderer,' +
    ' ytmusic-toggle-menu-service-item-renderer, tp-yt-paper-item, ytmusic-guide-entry-renderer';
  var pressed = null, pressTimer = 0, px = 0, py = 0;
  function unpress() {
    clearTimeout(pressTimer);
    if (pressed) pressed.removeAttribute('taro-pressed');
    pressed = null;
  }
  // Native taps are forgiving of neither a wandering finger nor a long hold: such a touch isn't a tap.
  var downX = 0, downY = 0, downAt = 0;
  window.addEventListener('click', function (e) {
    if (e.isTrusted && e.pointerType === 'touch' && (e.timeStamp - downAt > 500 ||
        Math.abs(e.clientX - downX) + Math.abs(e.clientY - downY) > 16)) {
      e.stopImmediatePropagation();
      e.preventDefault();
    }
  }, true);
  // YouTube's own taps (rows, cards) fire from touchend, not click: a still finger held too long is no tap
  // there either. (A moving finger is left alone: sliders and drags need their touchend.)
  window.addEventListener('touchend', function (e) {
    var t = e.changedTouches[0];
    if (e.timeStamp - downAt > 500 && Math.abs(t.clientX - downX) + Math.abs(t.clientY - downY) <= 16) {
      e.stopImmediatePropagation();
      e.preventDefault();
    }
  }, true);
  document.addEventListener('dragstart', function (e) { e.preventDefault(); }, true);
  document.addEventListener('pointerdown', function (e) {
    downX = e.clientX; downY = e.clientY; downAt = e.timeStamp;
    unpress();
    var t = e.target.closest && (e.target.closest(BUTTON) || e.target.closest(CARD) || e.target.closest('a[href]'));
    if (!t) return;
    px = e.clientX; py = e.clientY;
    // A beat of delay, so a flick that scrolls at once doesn't flash.
    pressTimer = setTimeout(function () {
      pressed = t;
      // Half the gap to the row above or below (in its own column: a carousel lists its columns one
      // after another), but no further than the box that clips it.
      var a = t.getBoundingClientRect(), pr = t.parentElement.getBoundingClientRect(), half = 8;
      [t.previousElementSibling, t.nextElementSibling].some(function (o) {
        var b = o && o.localName === t.localName && o.getBoundingClientRect();
        if (b && Math.abs(b.left - a.left) < 2) return (half = Math.max(0, (Math.abs(b.top - a.top) - a.height) / 2)), true;
      });
      t.style.setProperty('--taro-t', Math.min(half, Math.max(0, a.top - pr.top)) + 'px');
      t.style.setProperty('--taro-b', Math.min(half, Math.max(0, pr.bottom - a.bottom)) + 'px');
      // Reach 8px past the row's content (its padding), which differs from page to page.
      var cs = getComputedStyle(t);
      t.style.setProperty('--taro-l', (parseFloat(cs.paddingLeft) - 8) + 'px');
      t.style.setProperty('--taro-r', (parseFloat(cs.paddingRight) - 8) + 'px');
      t.setAttribute('taro-pressed', '');
    }, 100);
    pressed = null;
  }, true);
  document.addEventListener('pointermove', function (e) {
    if (Math.abs(e.clientX - px) + Math.abs(e.clientY - py) > 24) unpress();
  }, true);
  ['pointerup', 'pointercancel'].forEach(function (n) { document.addEventListener(n, unpress, true); });
  var HEART = 'M16.5 3c-1.74 0-3.41.81-4.5 2.09C10.91 3.81 9.24 3 7.5 3 4.42 3 2 5.42 2 8.5c0 3.78 3.4 6.86 8.55 11.54L12 21.35l1.45-1.32C18.6 15.36 22 12.28 22 8.5 22 5.42 19.58 3 16.5 3zm-4.4 15.55l-.1.1-.1-.1C7.14 14.24 4 11.39 4 8.5 4 6.5 5.5 5 7.5 5c1.54 0 3.04.99 3.57 2.36h1.87C13.46 5.99 14.96 5 16.5 5c2 0 3.5 1.5 3.5 3.5 0 2.89-3.14 5.74-7.9 10.05z';
  var HEART_ON = 'M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z';
  var CLOSE = 'M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z';
  function svgButton(d, onClick) {
    var b = document.createElement('button');
    var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    svg.appendChild(document.createElementNS('http://www.w3.org/2000/svg', 'path')).setAttribute('d', d);
    b.appendChild(svg);
    b.addEventListener('click', onClick);
    return b;
  }
  var likeItem = function (m) {
    return Array.prototype.find.call(m.querySelectorAll('ytmusic-toggle-menu-service-item-renderer'),
      function (t) { return /liked songs/i.test(t.textContent); });
  };
  function menuHead(m) {
    var h = document.createElement('div');
    h.id = 'taro-mh';
    var t = document.createElement('div');
    t.appendChild(document.createElement('span'));
    t.appendChild(document.createElement('span'));
    var like = svgButton(HEART, function () {
      var item = likeItem(m);
      if (item) { item.__taroOn = !item.__taroOn; press(item); setLike(like, item.__taroOn); }
    });
    h.appendChild(t);
    h.appendChild(like);
    h.appendChild(svgButton(CLOSE, function () { closeSheet(); }));
    m.insertBefore(h, m.firstChild);
    return h;
  }
  function setLike(b, on) { b.firstChild.firstChild.setAttribute('d', on ? HEART_ON : HEART); }
  function fillHead(m) {
    var h = m.querySelector('#taro-mh') || menuHead(m);
    var r = menuRow, q = function (s) { var e = r && r.querySelector(s); return e ? e.textContent.trim().replace(/\s+/g, ' ') : ''; };
    var spans = h.querySelectorAll('span');
    spans[0].textContent = q('.title');
    spans[1].textContent = q('.secondary-flex-columns > *').split(' • ')[0] || q('.subtitle') || q('.byline');
    var item = likeItem(m), like = h.querySelector('button');
    if (item) {
      item.classList.add('taro-liked-item');
      item.__taroOn = !!(item.data && item.data.isToggled);
      setLike(like, item.__taroOn);
    }
    like.style.display = item ? '' : 'none';
  }
  function closeSheet() {
    var dd = sheet;
    if (!dd) return;
    sheet = null;
    scrim.classList.remove('on');
    scrim.style.opacity = '';
    dd.style.transition = 'transform .2s ease-in';
    dd.style.transform = 'translateY(100%)';
    setTimeout(function () { dd.close(); dd.style.transition = dd.style.transform = ''; }, 200);
  }
  // Dragging down anywhere on the sheet closes it, unless the sheet is scrolled (then it scrolls back first).
  // Touch events, not pointer events: only a cancelable touchmove can stop the list from scrolling.
  function dragSheet(dd) {
    var list = dd.querySelector('#contentWrapper'), y0 = 0, dy = 0, t0 = 0, drag = false;
    dd.addEventListener('touchstart', function (e) {
      y0 = e.touches[0].clientY; t0 = e.timeStamp; dy = 0; drag = false;
    }, { passive: true });
    dd.addEventListener('touchmove', function (e) {
      var y = e.touches[0].clientY;
      if (!drag) {
        if (list.scrollTop > 0) { y0 = y; t0 = e.timeStamp; return; }  // scrolling: start over from here
        if (y - y0 < -6 && !dd.classList.contains('taro-tall') && list.scrollHeight > list.clientHeight) {
          dd.classList.add('taro-tall');
          e.preventDefault();  // this swipe grows the sheet; the next one scrolls it
        }
        if (y - y0 < 6) return;
        drag = true;
        dd.style.transition = scrim.style.transition = 'none';
      }
      e.preventDefault();
      dy = Math.max(0, y - y0);
      dd.style.transform = 'translateY(' + dy + 'px)';
      scrim.style.opacity = 1 - dy / dd.offsetHeight;
    }, { passive: false });
    var up = function (e) {
      if (!drag) return;
      drag = false;
      dd.style.transition = scrim.style.transition = '';
      // Far enough or a quick flick closes; otherwise it springs back.
      if (dy > dd.offsetHeight / 3 || dy / (e.timeStamp - t0) > 0.5) return closeSheet();
      dd.style.transition = 'transform .2s';
      dd.style.transform = '';
      scrim.style.opacity = '';
    };
    dd.addEventListener('touchend', up);
    dd.addEventListener('touchcancel', up);
  }
  // Called for each dropdown YouTube adds. `opened` isn't an attribute; Polymer flips aria-hidden with it.
  function watchMenu(dd) {
    if (dd.__taroWatched) return;
    dd.__taroWatched = true;
    new MutationObserver(function () {
      var m = dd.querySelector('ytmusic-menu-popup-renderer');
      if (!m) return;
      if (dd.opened) {
        if (!scrim) {
          scrim = document.createElement('div');
          scrim.id = 'taro-scrim';
          scrim.addEventListener('click', closeSheet);
          document.body.appendChild(scrim);
        }
        fillHead(m);
        if (!dd.__taroDrag) { dd.__taroDrag = true; dragSheet(dd); }
        dd.noCancelOnOutsideClick = true;  // the scrim's tap closes it, with the slide
        sheet = dd;
        dd.classList.remove('taro-tall');
        dd.classList.add('taro-menu');
        scrim.classList.add('on');
      } else {
        if (sheet === dd) sheet = null;
        dd.classList.remove('taro-menu', 'taro-tall');
        if (scrim) scrim.classList.remove('on');
      }
    }).observe(dd, { attributes: true, attributeFilter: ['aria-hidden'] });
  }

  function keepBottomInset() {
    var probe = document.createElement('div');
    probe.style.cssText = 'position: fixed; visibility: hidden; padding-bottom: env(safe-area-inset-bottom, 0px);';
    document.body.appendChild(probe);
    var update = function () {
      // Only while the keyboard is down (it shrinks the visual viewport, not the window).
      if (visualViewport.height < innerHeight - 50) return;
      document.documentElement.style.setProperty('--taro-bot', getComputedStyle(probe).paddingBottom);
    };
    update();
    visualViewport.addEventListener('resize', update);
  }
  if (window.visualViewport) {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', keepBottomInset);
    else keepBottomInset();
  }

  // Search's back arrow: with text in the box it clears it and reopens the keyboard. With the box
  // empty, YouTube's own arrow runs, which just closes the search.
  function onSearchBack(e) {
    var arrow = e.target.closest && e.target.closest(
      'ytmusic-nav-bar ytmusic-search-box:is([opened], [has-query]) .search-button');  // closed, it's the search icon
    var box = arrow && arrow.closest('ytmusic-search-box'), input = box && box.querySelector('#input');
    if (!input) return;
    if (!input.value) {
      // On search results YouTube's close puts the query back in the bar ([has-query]). Show the plain
      // bar (logo, search icon, profile) instead; the query stays in the box for when search reopens.
      if (location.pathname === '/search') {
        var frames = 20;
        (function closed() {
          if (!box.hasAttribute('opened') && box.hasQuery) return void (box.hasQuery = false);
          if (--frames) requestAnimationFrame(closed);
        })();
      }
      return;
    }
    e.stopImmediatePropagation();
    e.preventDefault();
    press('ytmusic-nav-bar ytmusic-search-box #clear-button');
    input.focus();
  }
  document.addEventListener('click', onSearchBack, true);

  // Not el.click(): right after a touch, Polymer drops clicks outside the touched element
  // as ghost clicks, unless the click says it came from a non-touch device.
  function press(sel) {
    var el = typeof sel === 'string' ? document.querySelector(sel) : sel;
    if (el) el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, composed: true,
      sourceCapabilities: new InputDeviceCapabilities({ firesTouchEvents: false }) }));
    return !!el;
  }
  var MINI = 'ytmusic-app-layout > ytmusic-player-bar';
  var next = function () { press(MINI + ' .next-button'); };
  var prev = function () { press(MINI + ' .previous-button'); };
  var isOpen = function () { return !!document.querySelector('ytmusic-app-layout[player-page-open]'); };

  // ---- Player sheet: the player drawn at progress p (0 = mini player, 1 = full). -----
  // Drags and every open/close (tap, chevron, back) go through it, so the page follows
  // the finger and the artwork morphs between the mini player's thumbnail and full size.
  // YouTube's player does ~100 ms of work when it opens or closes. The sheet works in either of
  // its layouts, so we flip YouTube's state only while the sheet rests at an end, where a frozen
  // frame looks the same as a live one.
  var coverBox = null;  // YouTube's full-size art box, read with the player at rest (see endSheet)
  var slideNext = false, miniTapAt = -1e9, flippedAt = -1e9;  // see the observer
  // Remember taps on the mini player. On press, not click: after a touch YouTube cancels the click
  // and handles the tap itself.
  document.addEventListener('pointerdown', function (e) {
    if (e.target.closest && e.target.closest(MINI)) miniTapAt = performance.now();
  }, true);
  var BAR_H = 64, sheetP = 1, animating = false, ours = false, geo = null;
  // Elements and resting geometry, read once per sheet, so frames only write transforms and opacities.
  function measure() {
    var pg = document.querySelector('ytmusic-player-page'), img = document.querySelector('#player-page #player img'),
      wrap = document.querySelector('#player-page #music-player-wrapper');
    if (!pg || !img || !wrap) return null;
    var shade = document.getElementById('taro-shade'), art = document.getElementById('taro-art');
    if (!shade) {
      shade = document.createElement('div');
      shade.id = 'taro-shade';
      pg.insertBefore(shade, pg.firstChild);
    }
    if (!art) {
      art = document.createElement('canvas');
      art.id = 'taro-art';
      document.body.appendChild(art);
    }
    // Sheet mode first: it sets the full player's size, which the wrapper below is measured at.
    document.documentElement.classList.add('taro-sheet');
    pg.style.transform = '';
    // In video mode (music videos) the cover is a placeholder and the picture is the <video>,
    // drawn live each frame. A cross-origin video can still be drawn; only reading pixels is blocked.
    var video = pg.hasAttribute('video-mode') && pg.querySelector('#song-video video');
    if (video && !video.videoWidth) video = null;
    // The live copy if it's ready, else the canvas (redrawn from the video each frame, below).
    var live = video && videoCopy();
    art.style.display = live ? 'none' : '';
    if (vcopy) vcopy.style.display = live ? '' : 'none';
    // YouTube's #player box, which needn't be square: for a video, the whole wrapper (the picture
    // letterboxed in black); for a cover, the last reading at rest (see endSheet), else YouTube's layout
    // (32px margins). The copy is a square showing the picture as YouTube does (a cover cropped to fill,
    // a video letterboxed), trimmed to the box at the full end; in the mini player the box is 48px square.
    var w = wrap.getBoundingClientRect();
    var b = video ? { x: w.x, y: w.y, w: w.width, h: w.height }
      : coverBox || { x: w.x + 32, y: w.y, w: w.width - 64, h: Math.min(w.width - 64, w.height) };
    var side = Math.max(b.w, b.h);
    var full = { x: b.x + (b.w - side) / 2, y: b.y + (b.h - side) / 2, w: side, h: side };
    var clip = { y: (side - b.h) / 2, x: (side - b.w) / 2 };  // trimmed at the full end, in the copy's own px
    var mini = { x: 16, dy: 8, w: 48 };
    if (live) live.style.width = live.style.height = full.w + 'px';
    art.style.width = full.w + 'px';
    art.style.height = full.h + 'px';
    art.width = Math.round(full.w * devicePixelRatio);
    art.height = Math.round(full.h * devicePixelRatio);
    var ctx = art.getContext('2d');
    if (!video) ctx.drawImage(img, 0, 0, art.width, art.height);
    var g = {
      pg: pg, art: live || art, ctx: ctx, video: video, shade: shade, bar: document.querySelector(MINI),
      nav: document.getElementById('taro-nav'), fades: [].slice.call(pg.querySelectorAll(FADE)),
      top: sheetTop(), navH: navSpace(), full: full, mini: mini, clip: clip,
    };
    // A video keeps playing while the copy is up, also at rest (touch held, YouTube settling):
    // redraw it every frame until the sheet ends, or the picture freezes.
    // Fitted inside the square, wide or tall, with black around it.
    var fit = video && Math.min(art.width / video.videoWidth, art.height / video.videoHeight);
    var vw = video && video.videoWidth * fit, vh = video && video.videoHeight * fit;
    if (video && !live) (function draw() {
      if (geo !== g && geo !== null) return;
      ctx.fillStyle = '#000';
      ctx.fillRect(0, 0, art.width, art.height);
      ctx.drawImage(video, (art.width - vw) / 2, (art.height - vh) / 2, vw, vh);
      if (document.documentElement.classList.contains('taro-sheet')) requestAnimationFrame(draw);
    })();
    return g;
  }
  // A muted live copy of YouTube's <video> (captureStream), kept running while a music video plays so
  // it's ready before a drag starts (a new one takes ~60 ms to show a frame). Unlike the canvas it's
  // drawn by the browser's media pipeline, so it keeps moving while YouTube's code blocks the page.
  var vcopy = null;
  function videoCopy() {
    var pg = document.querySelector('ytmusic-player-page');
    var v = pg && pg.hasAttribute('video-mode') && pg.querySelector('#song-video video');
    var stream = vcopy && vcopy.srcObject;
    var live = stream && vcopy.source === v &&
      stream.getVideoTracks().some(function (t) { return t.readyState === 'live'; });
    if (stream && !live) stream.getTracks().forEach(function (t) { t.stop(); });
    if (!v || !v.captureStream) return vcopy && (vcopy.srcObject = null);
    if (!vcopy) {
      vcopy = document.createElement('video');
      vcopy.id = 'taro-vid';
      vcopy.muted = vcopy.playsInline = true;
      document.body.appendChild(vcopy);
    }
    if (!live) {
      vcopy.source = v;
      vcopy.srcObject = v.captureStream();
      vcopy.play().catch(function () {});
    }
    return vcopy.readyState >= 2 ? vcopy : null;
  }
  setInterval(videoCopy, 1000);
  // Height of the tabs plus the phone's navigation bar under them (the tabs' bottom padding).
  var navSpace = function () {
    var nav = document.getElementById('taro-nav');
    return !nav ? 0 : NAV_H + (parseFloat(getComputedStyle(nav).paddingBottom) || 0);
  };
  // The mini bar's top. innerHeight is rounded (693 for a 693.67px viewport), which would
  // leave the art a device pixel or two off YouTube's.
  var sheetTop = function () {
    return (window.visualViewport ? visualViewport.height : innerHeight) - navSpace() - BAR_H;
  };
  // To whole device pixels, where YouTube's own art is painted; a GPU-moved layer isn't snapped.
  var snap = function (v) { return Math.round(v * devicePixelRatio) / devicePixelRatio; };
  var clamp = function (v) { return Math.min(1, Math.max(0, v)); };
  function setP(p) {
    var g = geo || (geo = measure());
    if (!g) return;
    sheetP = p;
    if (g.slide === undefined) {
      g.slide = slideNext;
      slideNext = false;
      document.documentElement.classList.toggle('taro-slide', g.slide);
    }
    g.pg.style.transform = 'translate3d(0,' + snap((1 - p) * g.top) + 'px,0)';
    // Sliding (see the observer below), the page comes up whole: no copy, no fade-in.
    if (!g.slide) morph(g, p);
    if (g.bar) {
      // !important: YouTube's finished slide-up animation still holds the bar's opacity, and animations beat inline styles.
      g.bar.style.setProperty('opacity', clamp(1 - p * 3), 'important');
      // Touchable while the sheet shows the mini end, so it can be dragged again right away.
      g.bar.style.pointerEvents = p < 0.5 ? '' : 'none';
    }
    if (g.nav) g.nav.style.transform = 'translate3d(0,' + p * g.navH + 'px,0)';
  }
  // The art copy, the grey shade and the fading player parts, at progress p.
  function morph(g, p) {
    var f = g.full, m = g.mini, size = m.w + (f.w - m.w) * p, x = m.x + (f.x - m.x) * p,
      y = g.top + m.dy + (f.y - g.top - m.dy) * p;
    // Crop to YouTube's art box, growing from none (the square thumbnail) to the full trim, with its 4px
    // corners; both are in the copy's own pixels, so divide out the scale.
    var c = g.clip, k = f.w / size, cx = c.x * p / k, cy = c.y * p / k;  // the trim on screen
    // Snap the visible (cropped) edges, not the square's, so they land on device pixels like YouTube's.
    g.art.style.transform = 'translate3d(' + (snap(x + cx) - cx) + 'px,' + (snap(y + cy) - cy) + 'px,0) scale(' + 1 / k + ')';
    g.art.style.clipPath = 'inset(' + c.y * p + 'px ' + c.x * p + 'px round ' + 4 * k + 'px)';
    g.shade.style.opacity = 1 - p;
    g.fades.forEach(function (el) { el.style.setProperty('opacity', clamp(p * 2 - 1), 'important'); });
  }
  function endSheet() {
    geo = null;
    document.documentElement.classList.remove('taro-sheet', 'taro-slide');
    // The full player at rest: remember its art box. (Mid-open, YouTube briefly makes it full width.)
    var pg = document.querySelector('ytmusic-player-page');
    if (isOpen() && pg && !pg.hasAttribute('video-mode')) {
      var pr = document.querySelector('#player-page #player').getBoundingClientRect();
      if (pr.x > 0 && pr.width > 100) coverBox = { x: pr.x, y: pr.y, w: pr.width, h: pr.height };
    }
    document.querySelectorAll('ytmusic-player-page, #taro-nav, ' + MINI + ', #player-page :is(' + FADE + ')')
      .forEach(function (el) { el.style.transform = el.style.opacity = el.style.pointerEvents = ''; });
  }
  // calm: wait for frames to arrive on time before starting. After YouTube itself opens or
  // closes the player it stays busy for a frame or two, which would skip the animation's start.
  var animToken = 0;  // bumping it cancels the running animation (a touch caught the sheet)
  function animateTo(target, done, calm) {
    var from = sheetP, t0 = 0, ms = 120 + 200 * Math.abs(target - from), last = 0, ok = 0, start = performance.now();
    var token = ++animToken;
    animating = true;
    setP(from);
    requestAnimationFrame(function frame(now) {
      if (token !== animToken) return;
      if (!t0) {
        ok = last && now - last < 20 ? ok + 1 : 0;
        last = now;
        if (calm && ok < 2 && now - start < 300) return requestAnimationFrame(frame);
        t0 = now;
      }
      var k = Math.min(1, (now - t0) / ms);
      setP(from + (target - from) * (1 - Math.pow(1 - k, 3)));  // ease-out cubic
      if (k < 1) return requestAnimationFrame(frame);
      animating = false;
      done();
    });
  }
  // Finish the sheet at target, then make YouTube's state match it.
  function settle(target) {
    animateTo(target, function () {
      if ((target === 1) === isOpen()) return endSheet();
      if (!ours) ours = press(target ? MINI + ' .middle-controls' : '#player-page #collapse-button');
      // Failsafe: never leave the sheet up if YouTube didn't react.
      setTimeout(function () { if (!drag && !animating) endSheet(); }, 1000);
    });
  }
  // YouTube's own open/close keyframes would play over ours (and replay if merely paused); end them on the spot.
  function quench(frames) {
    document.getAnimations().forEach(function (a) {
      try {
        if (/player-page|player-bar-slide-up/.test(a.animationName) || a.transitionProperty === 'bottom' ||
            a.effect.target.id === 'player') a.finish();
      } catch (e) {}
    });
    if (frames) requestAnimationFrame(function () { quench(frames - 1); });
  }
  // Landscape uses a different player layout; leave YouTube's own animations there.
  var portrait = function () { return innerHeight > innerWidth; };
  // The player's state, mirrored onto <html> for the rules above (taro-open, taro-playing): a
  // body:has(...) rule would make the browser re-check styles after every change anywhere in the page.
  new MutationObserver(function () {
    var L = document.querySelector('ytmusic-app-layout'), h = document.documentElement;
    h.classList.toggle('taro-open', !!L && L.hasAttribute('player-page-open'));
    h.classList.toggle('taro-playing', !!L && L.hasAttribute('player-visible'));
  }).observe(document, { subtree: true, attributes: true, attributeFilter: ['player-page-open', 'player-visible'] });
  new MutationObserver(function (recs) {
    if (!portrait() || !recs.some(function (r) { return r.target.tagName === 'YTMUSIC-APP-LAYOUT'; })) return;
    quench(10);
    flippedAt = performance.now();
    if (ours) {
      ours = false;
      // The sheet rests at the end it animated to, so keeping it up costs nothing; give YouTube
      // a moment to finish re-laying out its player (it paints a stray frame otherwise).
      setTimeout(function () { if (!drag && !animating) endSheet(); }, 250);
      return;
    }
    // Opened or closed by YouTube itself (tap, chevron, back): animate the change. Picking a song
    // opens it too, but YouTube swaps in the new cover only after opening, so a morph would start
    // from the old one: slide the whole player up instead, its real art changing in place.
    var open = isOpen();
    slideNext = open && performance.now() - miniTapAt > 1000;
    setP(open ? 0 : 1);
    animateTo(open ? 1 : 0, endSheet, true);
  }).observe(document, { subtree: true, attributes: true, attributeFilter: ['player-page-open'] });

  // Animate el to transform tf.
  function slide(el, tf, ms) {
    el.style.transition = 'transform ' + ms + 'ms ease-out';
    el.style.transform = tf;
    setTimeout(function () { el.style.transition = ''; }, ms);
  }
  // Swipes: mini player ←/→ skip, ↑ drags the player open; full player artwork ←/→ skip, ↓ drags it closed.
  var drag = null;
  document.addEventListener('touchstart', function (e) {
    drag = null;
    if (e.touches.length !== 1) return;
    var t = e.target;
    if (t.closest('tp-yt-paper-slider, #side-panel')) return;
    // While the sheet rests at an end (just after a drag), go by what it shows: YouTube's own
    // state may not have caught up yet. The mini player's art is YouTube's #player, not part of the bar.
    var open = geo ? sheetP > 0.5 : isOpen();
    var zone = open ? (t.closest('#player-page #player') ? 'art' : t.closest('#player-page #main-panel') ? 'page' : null)
      : t.closest(MINI) || t.closest('#player-page #player') ? 'mini' : null;
    var x = e.touches[0].clientX, y = e.touches[0].clientY;
    // Catch the sheet mid-animation, like a native one, instead of ignoring the touch.
    var grab = animating && geo && !!(t.closest('ytmusic-player-page') || t.closest(MINI));
    if (grab) {
      animToken++;
      animating = false;
      zone = sheetP > 0.5 ? 'page' : 'mini';
    }
    if (!zone || animating) return;
    drag = { zone: zone, grab: grab, x: x, y: y, dx: 0, dy: 0, t: Date.now(), ly: y, lt: Date.now(), vy: 0, axis: null };
    // Set the sheet up now, at its resting end (looks identical), so its one-off cost
    // lands before the finger moves instead of on the drag's first frame.
    if (!grab && portrait()) setP(zone === 'mini' ? 0 : 1);
    drag.p0 = sheetP;
  }, { capture: true, passive: true });
  document.addEventListener('touchmove', function (e) {
    if (!drag) return;
    var d = drag, y = e.touches[0].clientY, now = Date.now();
    d.dx = e.touches[0].clientX - d.x;
    d.dy = y - d.y;
    if (now > d.lt) d.vy = (y - d.ly) / (now - d.lt);  // px/ms, for flings
    d.ly = y;
    d.lt = now;
    if (!d.axis && Math.hypot(d.dx, d.dy) > 16) {
      d.axis = Math.abs(d.dx) > Math.abs(d.dy) ? 'x' : 'y';
      // A caught sheet stays the drag's whatever the direction; it can't be left mid-way.
      d.sheet = d.grab || (d.axis === 'y' && portrait() && (d.zone !== 'mini' || d.dy < 0));
      if (!d.sheet) endSheet();
    }
    // Follow the finger so the gesture feels physical.
    if (d.axis === 'x' && d.zone === 'art') document.querySelector('#player-page #player').style.transform = 'translateX(' + d.dx + 'px)';
    var top = geo ? geo.top : sheetTop();
    if (d.sheet) {
      // Touch events can outpace the display; draw once per frame.
      d.p = clamp(d.p0 - d.dy / top);
      if (!d.raf) d.raf = requestAnimationFrame(function () { d.raf = 0; if (drag === d) setP(d.p); });
    }
  }, { capture: true, passive: true });
  // touchcancel too: Android can cancel a long drag, and that must not strand the page mid-way.
  function release() {
    if (!drag) return;
    var d = drag;
    drag = null;
    if (d.sheet) {
      setP(d.p);  // catch up with the finger before animating from there
      // A fling decides by direction; otherwise moving a quarter of the way is enough.
      // Speed is the faster of the last move and the whole drag (short flicks have few moves).
      var avg = d.dy / Math.max(1, Date.now() - d.t), v = Math.abs(d.vy) > Math.abs(avg) ? d.vy : avg;
      var fling = Math.abs(v) > 0.4 && Date.now() - d.lt < 100;
      settle(fling ? (v < 0 ? 1 : 0) : d.p0 < 0.5 ? (sheetP > d.p0 + 0.25 ? 1 : 0) : (sheetP < d.p0 - 0.25 ? 0 : 1));
    } else if (d.axis === 'x') {
      if (d.zone === 'art') slide(document.querySelector('#player-page #player'), '', 150);
      if (d.zone !== 'page' && Math.abs(d.dx) > 60) (d.dx < 0 ? next : prev)();
    } else if (d.grab) settle(1);  // a tap on a moving sheet (e.g. the mini player while it closes) opens it
    // Just after YouTube closes its player it ignores taps on the mini player; open it ourselves.
    else if (d.zone === 'mini' && performance.now() - flippedAt < 600) settle(1);
    else endSheet();  // a tap: drop the sheet set up on touchstart
  }
  document.addEventListener('touchend', release, { capture: true, passive: true });
  document.addEventListener('touchcancel', release, { capture: true, passive: true });

  // ---- Android media controls (MediaControls.kt): report what's playing, run its commands. ----
  // TaroMedia exists only in the YouTube Music page (YtmWebView.kt).
  if (window.TaroMedia) {
    var lastKey = '';
    var report = function (force) {
      var v = document.querySelector('video'), bar = document.querySelector(MINI);
      var title = bar && bar.querySelector('.title');
      if (!v || !title || !title.textContent.trim()) return;
      var img = bar.querySelector('img.image'), byline = bar.querySelector('.byline');
      var s = {
        title: title.textContent.trim(),
        artist: byline ? byline.textContent.trim().split(' • ')[0] : '',
        // The bar's 60px thumbnail; ask Google's image server for a sharper one.
        art: img && /^https:/.test(img.currentSrc) ? img.currentSrc.replace(/=w\d+-h\d+/, '=w544-h544') : '',
        playing: !v.paused,
        position: Math.round(v.currentTime * 1000),
        duration: isFinite(v.duration) ? Math.round(v.duration * 1000) : 0,
      };
      var key = [s.title, s.artist, s.art, s.playing, s.duration].join('|');
      if (!force && key === lastKey) return;  // Android extrapolates the position while playing
      lastKey = key;
      TaroMedia.postMessage(JSON.stringify(s));
    };
    // Media events don't bubble, but a capturing listener on the document still sees them.
    ['play', 'pause', 'seeked', 'durationchange'].forEach(function (type) {
      document.addEventListener(type, function () { report(true); }, true);
    });
    setInterval(function () { report(false); }, 1000);
    window.__taroMedia = function (command, arg) {
      var v = document.querySelector('video');
      if (command === 'next') next();
      else if (command === 'prev') prev();
      else if (v && command === 'play') v.play();
      else if (v && command === 'pause') v.pause();
      else if (v && command === 'seek') v.currentTime = arg / 1000;
    };
  }
})();
