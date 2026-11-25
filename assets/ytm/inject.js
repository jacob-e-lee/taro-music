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
  function clean(url, res) {
    if (res.status !== 200) return res;
    return res.clone().text().then(function (text) {
      var out = rewrite(url, text);
      return out === text ? res : new Response(out, {
        status: res.status, statusText: res.statusText, headers: res.headers,
      });
    });
  }
  // YouTube can answer one account's home with 400 "invalid argument" (other pages and other
  // accounts work); the same request signed out still works, so show that home instead.
  function homeFallback(url, body) {
    if (body.indexOf('"browseId":"FEmusic_home"') < 0) return null;
    return origFetch(url, { method: 'POST', credentials: 'omit', headers: { 'content-type': 'application/json' }, body: body });
  }
  window.fetch = function (input) {
    var url = input instanceof Request ? input.url : String(input);
    // Read now: fetch consumes the request's body. YouTube gzips it.
    var body = input instanceof Request && input.method === 'POST' && url.indexOf('/youtubei/v1/browse') >= 0 &&
      new Response(input.headers.get('content-encoding') === 'gzip'
        ? input.clone().body.pipeThrough(new DecompressionStream('gzip')) : input.clone().body).text();
    return origFetch.apply(this, arguments).then(function (res) {
      if (res.status !== 400 || !body) return clean(url, res);
      return body.then(function (b) { return homeFallback(url, b) || res; })
        .then(function (r) { return clean(url, r); }, function () { return res; });
    });
  };
  // The first page's home comes inside the HTML, past the hook above: if it's the error,
  // navigate home again so it comes through fetch.
  var homeTries = 40;
  var homeCheck = setInterval(function () {
    var b = document.querySelector('ytmusic-browse-response');
    if (!b || !b.data) { if (--homeTries <= 0) clearInterval(homeCheck); return; }
    clearInterval(homeCheck);
    if (location.pathname === '/' && b.data.error) go('FEmusic_home');
  }, 250);

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
  var PL = 'ytmusic-playlist-shelf-renderer ytmusic-responsive-list-item-renderer';
  var AS = 'ytmusic-browse-response ytmusic-shelf-renderer ytmusic-responsive-list-item-renderer';
  var FADE ='.background-image, .background-gradient, #side-panel, #main-panel > :not(#music-player-wrapper)';
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
    // The header icons are 26-32px: a pseudo-element grows each hit area to 48px.
    'ytmusic-nav-bar .search-button { position: relative; overflow: visible !important; }',
    'ytmusic-nav-bar .search-button::after { content: ""; position: absolute; left: 50%; top: 50%; width: 48px; height: 48px; transform: translate(-50%, -50%); }',
    'ytmusic-nav-bar ytmusic-search-box yt-icon-button.search-button { transform: translateX(-2px); }',
    // Icon / text buttons YouTube draws at 36px: grow them to a 44px touch target.
    'button.ytSpecButtonShapeNextText { min-width: 44px !important; min-height: 44px !important; }',
    // Header logo link is 24px tall: pad it to 44 and cancel with negative margin so layout stays put.
    'a.yt-simple-endpoint.ytmusic-logo { display: inline-flex !important; align-items: center; box-sizing: content-box !important; padding: 10px 0 !important; margin: -10px 0 !important; }',
    // The full player keeps its content below the status bar too. Its layout is sized from
    // --ytmusic-player-page-inner-height (YouTube sets it to the window height). The tabs view keeps
    // the same size, so the art doesn't jump when the state flips (fitTabs corrects YouTube's math).
    '#player-page #main-panel { top: ' + TOP + ' !important; height: calc(100% - ' + TOP + ' - ' + BOT + ') !important; }',
    // YouTube sizes the up next / lyrics / related panel for a top without TOP, so it would hang off
    // the bottom: pin its bottom instead, and let its list scroll clear of the navigation bar.
    '#player-page #side-panel { top: calc(64px + ' + TOP + ') !important; bottom: 0 !important; height: auto !important; }',
    '#player-page #side-panel > ytmusic-tab-renderer { padding-bottom: ' + BOT + ' !important; box-sizing: border-box; }',
    // As the panel settles after a drag, its colour (blended with the drag in fitTabs) moves with it.
    'ytmusic-player-page[transition-mode] #side-panel { transition: transform var(--ytmusic-player-page-transition-ms) cubic-bezier(.2,0,.6,1),' +
      ' background-color var(--ytmusic-player-page-transition-ms) cubic-bezier(.2,0,.6,1) !important; }',
    // No empty band above the tabs when the panel is open...
    'ytmusic-player-page[player-page-ui-state=TABS_VIEW] tp-yt-paper-tabs.ytmusic-player-page { margin-top: 0 !important; }',
    // ...but a drag handle on top of them, inside the tabs bar, which is what YouTube's drag listens on.
    '#side-panel tp-yt-paper-tabs.ytmusic-player-page { position: relative; height: 64px !important; padding-top: 16px; box-sizing: border-box; }',
    '#side-panel tp-yt-paper-tabs.ytmusic-player-page::before { content: ""; position: absolute; top: 14px; left: 50%; width: 32px;' +
      ' height: 4px; margin-left: -16px; border-radius: 2px; background: rgba(255,255,255,.3); }',
    // Settling back to the full player, hide the list at once: fading, it shows in the strip below the tabs.
    'ytmusic-player-page[player-page-ui-state=FULL_PLAYER_VIEW] #side-panel > #tab-renderer { transition: none !important; }',
    // The full player's controls stay hidden in the tabs view. Not !important: YouTube fades them inline while dragging.
    'ytmusic-player-page[player-page-ui-state=TABS_VIEW] #main-panel > :not(#music-player-wrapper) { opacity: 0; }',
    // With the tabs panel open, the whole background behind it is the mini player's grey-black. fitTabs cross-fades
    // #taro-band over the full player's backdrop with the drag, evenly, so no edge or fade from the top shows.
    'ytmusic-player-bar#top-player-bar { background: none !important; }',
    '#taro-band { position: absolute; top: 0; left: 0; right: 0; bottom: 0; pointer-events: none; opacity: 0; background: rgb(3,3,3); will-change: opacity;' +
      ' transition: opacity var(--ytmusic-player-page-transition-ms, 300ms) cubic-bezier(.2,0,.6,1); }',
    '#player-page > .content { padding-top: ' + TOP + ' !important; }',
    // ...while its blurred background and darkening gradient start at the very top, under the status bar.
    '#player-page :is(.background-image, .background-gradient) { top: 0 !important; }',
    'ytmusic-app-layout[player-page-open] ytmusic-player-page, html.taro-sheet ytmusic-player-page { --ytmusic-player-page-inner-height: calc(100dvh - ' + TOP + ' - ' + BOT + ') !important; }',
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
    // A carousel clips its rows at their edges; give the press highlight 8px more room above and below
    // (padding that margin cancels, so nothing moves).
    'ytmusic-carousel#ytmusic-carousel { overflow: clip; overflow-clip-margin: 8px; }',
    'ytmusic-carousel#ytmusic-carousel > #items { padding-block: 8px; margin-block: -8px; }',
    // YouTube's tap ripple is a sharp-cornered rectangle; our press highlight replaces it (a quick tap shows that too).
    // Not display: none: a 0x0 ripple's waves never reach full size, so each tap left one animating every frame forever.
    ':is(ytmusic-responsive-list-item-renderer, ytmusic-two-row-item-renderer, ytmusic-player-queue-item, tp-yt-paper-tab,' +
      ' ytmusic-menu-navigation-item-renderer, ytmusic-menu-service-item-renderer, ytmusic-toggle-menu-service-item-renderer)' +
      ' tp-yt-paper-ripple { visibility: hidden !important; }',
    'ytmusic-responsive-list-item-renderer[taro-leaving]::before { opacity: 0; transition: opacity .2s; }',
    // Playlist-style song lists (artist's Top songs): like YouTube Music's app, a row is thumbnail, title, "artist • plays", menu.
    // The multi-select checkbox only shows in select mode (#taro-select), as a check over the thumbnail.
    PL + ' .fixed-columns { display: none !important; }',
    'html.taro-select ' + PL + ' .fixed-columns { display: flex !important; position: absolute; left: 8px; top: 50%; width: 40px; height: 40px;' +
      ' margin: -20px 0 0; align-items: center; justify-content: center; background: rgba(0,0,0,.55); border-radius: 6px; }',
    // The same rows in the artist page's own Top songs shelf (no checkboxes there).
    PL + ' .left-items, ' + PL + ' .left-items ytmusic-thumbnail-renderer, ' + AS + ' .left-items, ' + AS + ' .left-items ytmusic-thumbnail-renderer { width: 40px !important; height: 40px !important; min-width: 40px !important; }',
    PL + ' .flex-columns, ' + AS + ' .flex-columns { flex: 1; min-width: 0; }',
    PL + ' .secondary-flex-columns > .flex-column, ' + AS + ' .secondary-flex-columns > .flex-column { flex: 0 1 auto !important; width: auto !important; min-width: 0; max-width: none; }',
    PL + ' .secondary-flex-columns > .flex-column:nth-child(n+3), ' + AS + ' .secondary-flex-columns > .flex-column:nth-child(n+3) { display: none !important; }',
    '#taro-select { display: inline-block; vertical-align: top; height: 27px; margin: 0; padding: 0 12px; position: relative; background: none; border: 0;' +
      ' outline: none; color: #fff; font: 500 14px/27px Roboto, sans-serif; }',
    '#taro-select::after { content: ""; position: absolute; left: 0; right: 0; top: 50%; height: 44px; transform: translateY(-50%); }',
    // Song menus (3-dots, long press): a bottom sheet over a darkened page. See watchMenu.
    '#taro-scrim { position: fixed; inset: 0; z-index: 102; background: rgba(0,0,0,.6); opacity: 0; pointer-events: none;' +
      ' transition: opacity .25s; }',
    '#taro-scrim.on { opacity: 1; pointer-events: auto; }',
    'tp-yt-iron-dropdown.taro-menu { position: fixed !important; left: 0 !important; right: 0 !important; top: auto !important;' +
      ' bottom: ' + BOT + ' !important; width: auto !important; max-width: none !important; max-height: none !important;' +
      ' box-shadow: 0 ' + BOT + ' 0 rgb(33,33,33); animation: taro-menu-up .25s cubic-bezier(.2,.8,.2,1); }',
    '@keyframes taro-menu-up { from { transform: translateY(100%); } }',
    'tp-yt-iron-dropdown.taro-menu #contentWrapper { background: rgb(33,33,33); border-radius: 16px 16px 0 0;' +
      ' overflow-y: auto; overscroll-behavior: contain; max-height: 65vh; box-sizing: border-box; }',
    // Swiping up on a sheet that has more to show first grows it to the top of the screen (see dragSheet).
    'tp-yt-iron-dropdown.taro-menu #contentWrapper { transition: max-height .25s; }',
    'tp-yt-iron-dropdown.taro-menu.taro-tall #contentWrapper { max-height: calc(100vh - ' + TOP + ' - ' + BOT + '); }',
    'tp-yt-iron-dropdown.taro-menu ytmusic-menu-popup-renderer { display: block; overflow: visible !important; max-height: none !important;' +
      ' width: auto !important; max-width: none !important; background: none; box-shadow: none; }',
    'tp-yt-iron-dropdown.taro-menu #items { border: 0 !important; outline: none; width: auto; }',
    'tp-yt-iron-dropdown.taro-menu tp-yt-paper-listbox { padding: 4px 0 8px !important; }',
    // YouTube's own highlights (`pressed`, `focused` on the first item when the menu opens, sticky :hover after a long press) are all off; only ours (taro-pressed) shows.
    ':is(ytmusic-menu-navigation-item-renderer, ytmusic-menu-service-item-renderer, ytmusic-toggle-menu-service-item-renderer):not([taro-pressed]) { background: none !important; }',
    '.taro-liked-item { display: none !important; }',
    '#taro-mh { display: flex; align-items: center; gap: 4px; padding: 20px 4px 8px 16px; position: sticky; top: 0; z-index: 1;' +
      ' background: rgb(33,33,33);' +
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
    // The box starts below the status bar, which would show the page's tinted backdrop: extend the box's black up over it.
    'ytmusic-nav-bar ytmusic-search-box:is([opened], [has-query])::before { content: ""; position: absolute; left: 0; right: 0; bottom: 100%;' +
      ' height: ' + TOP + '; background: rgb(3,3,3); pointer-events: none; }',
    'ytmusic-search-box:is([opened], [has-query]) :is(.search-container, .search-box) { height: 48px !important;' +
      ' border: 0 !important; border-radius: 0 !important; box-shadow: none !important; }',
    // YouTube hides the back arrow once a search has run and the box loses focus; keep it (see onSearchBack).
    'ytmusic-search-box[has-query]:not([opened]) .search-button { display: inline-block !important; }',
    'ytmusic-search-box:is([opened], [has-query]) #suggestion-list { left: 0 !important; right: 0 !important;' +
      ' width: auto !important; top: 48px !important; border: 0 !important; border-radius: 0 !important; }',
    // YouTube caps the cover's height by the room left (inner height - 408px) but not its width, which
    // leaves it wider than tall (296x285): cap the width the same, and centre it (auto margins end
    // the flex stretch, hence width: 100%).
    '@media (orientation: portrait) { ytmusic-app-layout[player-page-open] ytmusic-player-page[is-mweb-modernization-enabled]' +
      ':not([video-mode], [player-fullscreened]) #player.ytmusic-player-page {' +
      ' width: 100%; max-width: min(100vw - 64px, var(--ytmusic-player-page-inner-height) - 408px) !important;' +
      ' margin-inline: auto !important; } }',
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
      // Select mode for song lists: a "Select" button after the Sort control, only where YouTube allows multi-select.
      var selectable = document.querySelector('ytmusic-playlist-shelf-renderer[contents-multi-selectable]');
      var sort = selectable && document.querySelector('yt-sort-filter-sub-menu-renderer');
      if (sort && !sort.parentNode.querySelector('#taro-select')) {
        var sel = document.createElement('button');
        sel.id = 'taro-select';
        sel.textContent = 'Select';
        sel.addEventListener('click', function () {
          sel.textContent = document.documentElement.classList.toggle('taro-select') ? 'Done' : 'Select';
        });
        sort.after(sel);
      }
      if (!sort) document.documentElement.classList.remove('taro-select');
      // YouTube adds its dropdowns to this container as menus are first opened.
      if (!menus && (menus = document.querySelector('ytmusic-popup-container'))) {
        fitMenus(menus);
        new MutationObserver(function () { fitMenus(menus); }).observe(menus, { childList: true });
      }
      // The Premium promo (hidden by the CSS above) opens in a dialog that makes the whole page inert: no taps register.
      var promo = menus && menus.querySelector('tp-yt-paper-dialog ytmusic-mealbar-promo-renderer');
      if (promo && promo.closest('tp-yt-paper-dialog').opened) promo.closest('tp-yt-paper-dialog').close();
    }, 300);
  }
  // One-off check 15 s after load: warn (logcat TaroMusic) if a selector we rely on is gone.
  setTimeout(function () {
    var gone = ['ytmusic-app', 'ytmusic-app-layout', 'ytmusic-player-bar', 'ytmusic-search-box', 'ytmusic-popup-container', 'ytmusic-player-page']
      .filter(function (s) { return !document.querySelector(s); });
    if (gone.length) console.warn('TARO selectors missing: ' + gone.join(', '));
  }, 15000);
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', buildNav);
  else buildNav();

  // ---- Song menus as a bottom sheet -----------------------------------------------------
  // YouTube opens these as a dropdown at the tapped spot. Here the dropdown is restyled (see the CSS)
  // into a sheet under a bar with the song, its artist, a like button and a close button. Dragging
  // the sheet down, tapping the dimmed page or the close button slides it away.
  var ROW = 'ytmusic-responsive-list-item-renderer, ytmusic-two-row-item-renderer, ytmusic-player-queue-item, ytmusic-player-bar, ytmusic-card-shelf-renderer';
  var menuRow = null, scrim = null, sheet = null;  // the title and artist of the row that opened the menu; the dimmer; the open dropdown
  // The menu doesn't say which song it is for; remember the last touch (3-dots or long press). Read the
  // text now: the row can be re-rendered or recycled before the menu opens, and a touch that isn't on a
  // row (a page header's menu) must not leave the previous song's name behind.
  document.addEventListener('pointerdown', function (e) {
    var r = e.target.closest && e.target.closest(ROW);
    // The full player's own menu button sits in the page, not in a row: it is for the playing song.
    if (!r && e.target.closest && e.target.closest('ytmusic-player-page #main-panel')) r = document.querySelector('ytmusic-player-bar');
    var q = function (s) { var x = r && r.querySelector(s); return x ? x.textContent.trim().replace(/\s+/g, ' ') : ''; };
    if (e.target.closest && e.target.closest('ytmusic-menu-popup-renderer')) return;  // a tap inside the open menu
    // The top-result card holds rows of its own, so its subtitle comes first. Search results lead with a type word.
    var a = (r && r.matches('ytmusic-card-shelf-renderer') ? q('.subtitle') : q('.secondary-flex-columns > *') || q('.subtitle') || q('.byline')).split(' • ');
    if (/^(Song|Video|Episode|Single|EP|Album|Playlist)$/.test(a[0]) && a[1]) a.shift();
    menuRow = r && { title: q('.title'), artist: a[0] };
  }, true);
  // Touch feedback. A finger that lands on something marks it pressed until it lifts, moves off or the
  // browser takes the touch over to scroll (pointercancel), so a press that turns into a drag still shows.
  var BUTTON = 'button, tp-yt-paper-icon-button, yt-icon-button, ytmusic-menu-renderer';
  var CARD = 'ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer, ytmusic-chip-cloud-chip-renderer,' +
    ' ytmusic-player-queue-item, ytmusic-menu-navigation-item-renderer, ytmusic-menu-service-item-renderer,' +
    ' ytmusic-toggle-menu-service-item-renderer, tp-yt-paper-item, ytmusic-guide-entry-renderer';
  var pressed = null, pressTarget = null, pressTimer = 0, px = 0, py = 0;
  // A quick tap (up before the delay) still shows the highlight, for a moment, in place of YouTube's ripple.
  function unpress(e) {
    var quick = pressTarget && !pressed && e && e.type === 'pointerup';
    clearTimeout(pressTimer);
    if (pressed) pressed.removeAttribute('taro-pressed');
    pressed = null;
    if (quick) {
      var t = pressTarget;
      showPress(t);
      setTimeout(function () { t.setAttribute('taro-leaving', ''); }, 250);
      setTimeout(function () {
        t.removeAttribute('taro-pressed'); t.removeAttribute('taro-leaving');
        if (pressed === t) pressed = null;
      }, 450);
    }
    pressTarget = null;
  }
  function showPress(t) {
    pressed = t;
    // Half the gap to the rows above and below (in its own column: a carousel lists its columns one after
    // another), but no further than the box that clips the column. Same for every row in it, top and bottom.
    var a = t.getBoundingClientRect(), pr = t.parentElement.getBoundingClientRect();
    var col = Array.prototype.map.call(t.parentElement.children, function (o) {
      return o.localName === t.localName && o.getBoundingClientRect();
    }).filter(function (b) { return b && Math.abs(b.left - a.left) < 2; });
    var top = Math.min.apply(0, col.map(function (b) { return b.top; })),
        bot = Math.max.apply(0, col.map(function (b) { return b.bottom; }));
    var half = col.length > 1 ? Math.max(0, (col[1].top - col[0].bottom) / 2) : 8;
    var inset = Math.min(half, Math.max(0, Math.min(top - pr.top, pr.bottom - bot))) + 'px';
    t.style.setProperty('--taro-t', inset);
    t.style.setProperty('--taro-b', inset);
    // Reach 8px past the row's content (its padding), which differs from page to page.
    var cs = getComputedStyle(t);
    t.style.setProperty('--taro-l', (parseFloat(cs.paddingLeft) - 8) + 'px');
    t.style.setProperty('--taro-r', (parseFloat(cs.paddingRight) - 8) + 'px');
    t.setAttribute('taro-pressed', '');
  }
  // Native taps are forgiving of neither a wandering finger nor a long press: such a touch isn't a tap.
  // A long press is Android's own (contextmenu, which opens YouTube's menu), not a timer of ours: with a
  // timer, a press released between it and Android's long press did nothing at all.
  var downX = 0, downY = 0, longPressed = false;
  window.addEventListener('contextmenu', function () { longPressed = true; }, true);
  window.addEventListener('click', function (e) {
    if (e.isTrusted && e.pointerType === 'touch' && (longPressed ||
        Math.abs(e.clientX - downX) + Math.abs(e.clientY - downY) > 16)) {
      e.stopImmediatePropagation();
      e.preventDefault();
    }
  }, true);
  // YouTube's own taps (rows, cards) fire from touchend, not click: a long-pressed still finger is no tap
  // there either. (A moving finger is left alone: sliders and drags need their touchend.)
  window.addEventListener('touchend', function (e) {
    var t = e.changedTouches[0];
    if (longPressed && Math.abs(t.clientX - downX) + Math.abs(t.clientY - downY) <= 16) {
      release();  // the player sheet's own touchend, which the stop below would skip (leaving the sheet over the tabs)
      e.stopImmediatePropagation();
      e.preventDefault();
    }
  }, true);
  document.addEventListener('dragstart', function (e) { e.preventDefault(); }, true);
  document.addEventListener('pointerdown', function (e) {
    downX = e.clientX; downY = e.clientY; longPressed = false;
    unpress();
    var t = e.target.closest && (e.target.closest(BUTTON) || e.target.closest(CARD) || e.target.closest('a[href]'));
    if (!t) return;
    px = e.clientX; py = e.clientY;
    // A beat of delay, so a flick that scrolls at once doesn't flash.
    pressTarget = t;
    pressTimer = setTimeout(function () { showPress(t); }, t.closest('.taro-menu') ? 0 : 100);
    pressed = null;
  }, true);
  document.addEventListener('pointermove', function (e) {
    if (Math.abs(e.clientX - px) + Math.abs(e.clientY - py) > 24) unpress();
  }, true);
  ['pointerup', 'pointercancel'].forEach(function (n) { document.addEventListener(n, unpress, true); });
  var HEART = 'M16.5 3c-1.74 0-3.41.81-4.5 2.09C10.91 3.81 9.24 3 7.5 3 4.42 3 2 5.42 2 8.5c0 3.78 3.4 6.86 8.55 11.54L12 21.35l1.45-1.32C18.6 15.36 22 12.28 22 8.5 22 5.42 19.58 3 16.5 3zm-4.4 15.55l-.1.1-.1-.1C7.14 14.24 4 11.39 4 8.5 4 6.5 5.5 5 7.5 5c1.54 0 3.04.99 3.57 2.36h1.87C13.46 5.99 14.96 5 16.5 5c2 0 3.5 1.5 3.5 3.5 0 2.89-3.14 5.74-7.9 10.05z';
  var HEART_ON = 'M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z';
  var CLOSE = 'M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z';
  function svgButton(d, label, onClick) {
    var b = document.createElement('button');
    b.setAttribute('aria-label', label);
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
    var like = svgButton(HEART, 'Like', function () {
      var item = likeItem(m);
      if (item) {
        item.__taroOn = !item.__taroOn;
        // YouTube closes the menu after any item; liking should leave it open.
        var dd = m.closest('tp-yt-iron-dropdown');
        dd.close = function () {};
        setTimeout(function () { delete dd.close; }, 400);
        press(item);
        setLike(like, item.__taroOn);
      }
    });
    h.appendChild(t);
    h.appendChild(like);
    h.appendChild(svgButton(CLOSE, 'Close', function () { closeSheet(); }));
    m.insertBefore(h, m.firstChild);
    return h;
  }
  function setLike(b, on) { b.setAttribute('aria-pressed', !!on); b.firstChild.firstChild.setAttribute('d', on ? HEART_ON : HEART); }
  function fillHead(m) {
    var h = m.querySelector('#taro-mh') || menuHead(m);
    var spans = h.querySelectorAll('span');
    spans[0].textContent = menuRow ? menuRow.title : '';
    spans[1].textContent = menuRow ? menuRow.artist : '';
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
    setTimeout(function () { delete dd.close; dd.close(); dd.style.transition = dd.style.transform = ''; }, 200);
  }
  // Dragging down anywhere on the sheet closes it, unless the sheet is scrolled (then it scrolls back first).
  // Touch events, not pointer events: only a cancelable touchmove can stop the list from scrolling.
  var touch = { n: 0, y: 0, t: 0, target: null, menu: false };  // the latest touchstart
  document.addEventListener('touchstart', function (e) {
    touch = { n: touch.n + 1, y: e.touches[0].clientY, t: e.timeStamp, target: e.target, menu: !!sheet };
  }, { passive: true, capture: true });
  function dragSheet(dd) {
    var list = dd.querySelector('#contentWrapper'), y0 = 0, dy = 0, t0 = 0, drag = false, grow = false, h0 = 0, hMax = 0, own = false;
    // On the document, not the sheet: a long press opens the menu under a finger that landed on the page
    // behind it, and that touch's events keep going to the page. That touch must not drag the sheet (or
    // scroll the page) until it is lifted; the listeners swallow it.
    var on = function (n, f, o) { document.addEventListener(n, f, o); };
    var seen = -1;
    // The menu opens mid-touch, so this can't rely on seeing the touchstart: take it from `touch`.
    var begin = function () {
      seen = touch.n; y0 = touch.y; t0 = touch.t; dy = 0; drag = false; grow = false;
      own = touch.menu && dd.contains(touch.target);  // only a touch that starts on the open sheet drags it
    };
    on('touchmove', function (e) {
      if (sheet !== dd) return;
      if (seen !== touch.n) begin();
      if (!own) {
        if (!touch.menu && e.cancelable) e.preventDefault();  // the long press that opened the menu: inert until lifted
        return;
      }
      var y = e.touches[0].clientY;
      if (!drag) {
        if (list.scrollTop > 0 && !grow) { y0 = y; t0 = e.timeStamp; return; }  // scrolling: start over from here
        // A swipe up on a sheet with more to show grows it with the finger, up to the top of the screen.
        if ((grow || y - y0 < -6) && !dd.classList.contains('taro-tall') && list.scrollHeight > list.clientHeight) {
          if (!grow) {
            grow = true;
            h0 = list.offsetHeight;
            list.style.transition = 'none';
            dd.classList.add('taro-tall');
            hMax = list.offsetHeight;
            dd.classList.remove('taro-tall');
          }
          e.preventDefault();
          list.style.maxHeight = Math.min(hMax, Math.max(h0, h0 + y0 - y - 6)) + 'px';
          return;
        }
        if (y - y0 < 6) return;
        drag = true;
        dd.style.transition = scrim.style.transition = 'none';
      }
      e.preventDefault();
      dy = Math.max(0, y - y0);
      dd.style.transform = 'translateY(' + dy + 'px)';
      scrim.style.opacity = 1 - dy / dd.offsetHeight;
    }, { passive: false, capture: true });
    var up = function (e) {
      if (sheet !== dd && !drag) return;
      if (grow) {
        // Past a little way, or a quick flick, it goes the rest of the way; otherwise it settles back.
        var big = list.offsetHeight - h0 > 40 || (list.offsetHeight - h0) / (e.timeStamp - t0) > 0.3;
        grow = false;
        list.style.transition = list.style.maxHeight = '';
        if (big) dd.classList.add('taro-tall');
        return;
      }
      if (!drag) return;
      drag = false;
      dd.style.transition = scrim.style.transition = '';
      // Far enough or a quick flick closes; otherwise it springs back.
      if (dy > dd.offsetHeight / 3 || dy / (e.timeStamp - t0) > 0.5) return closeSheet();
      dd.style.transition = 'transform .2s';
      dd.style.transform = '';
      scrim.style.opacity = '';
    };
    on('touchend', up, true);
    on('touchcancel', up, true);
  }
  // Tapping an item: YouTube's own close is instant (and a navigation item like Start Mix doesn't close at
  // all), so hold its close() and slide the sheet away ourselves. The item's action still runs.
  document.addEventListener('pointerup', function (e) {
    if (!sheet || longPressed || e.pointerType !== 'touch' ||
        Math.abs(e.clientX - downX) + Math.abs(e.clientY - downY) > 16) return;
    var item = e.target.closest && e.target.closest(
      'ytmusic-menu-navigation-item-renderer, ytmusic-menu-service-item-renderer, ytmusic-toggle-menu-service-item-renderer');
    if (!item || !sheet.contains(item)) return;
    sheet.close = function () {};
    closeSheet();
  }, true);
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
    // YouTube's #player box: for a video, the whole wrapper, which needn't be square (the picture
    // letterboxed in black); for a cover, the last reading at rest (see endSheet), else our square layout
    // (centred, at least 32px margins). The copy is a square showing the picture as YouTube does,
    // trimmed to the box at the full end; in the mini player the box is 48px square.
    var w = wrap.getBoundingClientRect(), s = Math.min(w.width - 64, w.height);
    var b = video ? { x: w.x, y: w.y, w: w.width, h: w.height }
      : coverBox || { x: w.x + (w.width - s) / 2, y: w.y, w: s, h: s };
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
    // A new song reuses the same <video> with a new source; the old capture then freezes on its last frame.
    var live = stream && vcopy.source === v && vcopy.url === v.currentSrc &&
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
      vcopy.url = v.currentSrc;
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
  // Dragging the tabs (up next, lyrics, ...) is YouTube's own code, which assumes the page has no status or
  // navigation bar: its panel distance and art centre come from the window height. Feed it the real ones.
  function fitTabs() {
    var pp = document.querySelector('ytmusic-player-page'), c = pp && pp.polymerController;
    if (!c || c.__taro || !c.applyTransformStyles || !c.setPlayerPosition) return;
    c.__taro = true;
    // The black over the full player's backdrop (0 full player .. 1 tabs open); the bar's content stays above it.
    var band = document.createElement('div');
    band.id = 'taro-band';
    var bg = pp.querySelector('.background-gradient');
    if (!bg) return;
    bg.after(band);
    var shade = function (a, drag) {
      band.style.transition = drag ? 'none' : '';
      band.style.opacity = a;
    };
    var fit = function () {
      var mp = pp.querySelector('#main-panel'), pl = pp.querySelector('#player');
      if (!mp || !pl) return;
      var y = pl.offsetHeight / 2;
      for (var n = pl; n && n !== mp; n = n.offsetParent) y += n.offsetTop;
      c.playerY = y;  // art centre in the main panel, where YouTube guesses from the window height
      c.moveableDistance = mp.offsetHeight - 132;  // the panel's travel: YouTube's CSS rest offset (inner height - 132)
    };
    var setPos = c.setPlayerPosition, apply = c.applyTransformStyles;
    c.setPlayerPosition = function (s) {
      var list = pp.querySelector('#tab-renderer'), sp = pp.querySelector('#side-panel');
      if (list) list.style.visibility = '';
      if (sp) sp.style.backgroundColor = '';  // YouTube's transition carries the blend on to the settled colour
      fit();
      return setPos.call(this, s);
    };
    // The state flips as a drag releases: the band follows it, fading with the panel.
    new MutationObserver(function () {
      var open = pp.getAttribute('player-page-ui-state') === 'TABS_VIEW';
      shade(open ? 1 : 0, false);
    }).observe(pp, { attributes: true, attributeFilter: ['player-page-ui-state'] });
    c.applyTransformStyles = function (dy) {
      fit();
      apply.call(this, dy);
      // YouTube offsets the panel from the window height; redo it so it starts where it rests and follows the finger.
      var d = this.moveableDistance, a = Math.min(Math.abs(dy), d) / d, sp = pp.querySelector('#side-panel');
      if (this.playerPageUiState !== 'FULL_PLAYER_VIEW') a = 1 - a;
      shade(a, true);
      if (sp) {
        sp.style.transform = 'translate(0, ' + d * (1 - a) + 'px)';
        // YouTube's two panel colours (full view, open), blended with the drag instead of switching at the flip.
        sp.style.backgroundColor = 'color-mix(in srgb, var(--ytmusic-static-brand-black) ' + a * 100 +
          '%, var(--ytmusic-player-page-background))';
      }
      // Dragged up, YouTube fades the list in from nothing (and its full-view CSS hides it), which pulls up
      // an empty black sheet; show it. setPlayerPosition, called as the state settles, drops this.
      var list = pp.querySelector('#tab-renderer');
      if (list && this.playerPageUiState === 'FULL_PLAYER_VIEW') {
        list.style.opacity = '1';
        list.style.visibility = 'visible';
      }
    };
  }
  new MutationObserver(function (recs) {
    fitTabs();
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
    if (t.closest('#side-panel')) fitTabs();
    if (t.closest('tp-yt-paper-slider, #side-panel')) return;
    // While the sheet rests at an end (just after a drag), go by what it shows: YouTube's own
    // state may not have caught up yet. The mini player's art is YouTube's #player, not part of the bar.
    var open = geo ? sheetP > 0.5 : isOpen();
    var zone = open ? (t.closest('#player-page #player') ? 'art' : t.closest('#player-page #main-panel') ? 'page' : null)
      : t.closest(MINI) || t.closest('#player-page #player') ? 'mini' : null;
    // With the up next / lyrics / related panel open, the art isn't a handle: dragging it would tear the page.
    if (zone === 'art' && t.closest('ytmusic-player-page[player-page-ui-state=TABS_VIEW]')) zone = null;
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
    if (!drag || sheet) return;  // an open song menu owns the touch (a long press opens it under the finger)
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

  // ---- Pull to refresh: drag down from the top of Home / Explore / Library, release past the threshold to refetch it. ----
  addStyle(
    '#taro-ptr { position: fixed; left: 50%; top: calc(' + TOP + ' + 48px); width: 36px; height: 36px; margin: 8px 0 0 -18px;' +
      ' border-radius: 50%; background: rgb(40,40,40); box-shadow: 0 2px 8px rgba(0,0,0,.5); z-index: 5; opacity: 0;' +
      ' pointer-events: none; display: flex; align-items: center; justify-content: center; will-change: transform, opacity; }' +
    '#taro-ptr svg { width: 22px; height: 22px; }' +
    '#taro-ptr.spin svg { animation: taro-ptr-spin .8s linear infinite; }' +
    '@keyframes taro-ptr-spin { to { transform: rotate(360deg); } }' +
    // No stretch / glow on the page at its top: the pull is drawn by the spinner alone.
    'html, body { overscroll-behavior-y: none; }');
  var ptr = null, ptrEl = null, PTR_AT = 56;
  function ptrDraw(pull) {
    if (!ptrEl) {
      var ns = 'http://www.w3.org/2000/svg', svg = document.createElementNS(ns, 'svg'), c = document.createElementNS(ns, 'circle');
      ptrEl = document.createElement('div');
      ptrEl.id = 'taro-ptr';
      svg.setAttribute('viewBox', '0 0 24 24');
      [['cx', 12], ['cy', 12], ['r', 9], ['fill', 'none'], ['stroke', '#fff'], ['stroke-width', 2.5],
        ['stroke-linecap', 'round'], ['stroke-dasharray', '42 57']].forEach(function (a) { c.setAttribute(a[0], a[1]); });
      svg.appendChild(c);
      ptrEl.appendChild(svg);
      document.documentElement.appendChild(ptrEl);
    }
    ptrEl.style.opacity = Math.min(1, pull / PTR_AT);
    ptrEl.style.transform = 'translateY(' + (pull * 0.6 - 20) + 'px)';
    ptrEl.firstChild.style.transform = 'rotate(' + pull * 5 + 'deg)';
  }
  document.addEventListener('touchstart', function (e) {
    ptr = null;
    // Not over the player, a menu, search or the bars (they have their own drags and scrollers).
    var tab = TABS.filter(function (t) { return t[1] === location.pathname; })[0];
    if (!tab || e.touches.length !== 1 || window.scrollY > 0 || document.documentElement.classList.contains('taro-open') ||
      e.target.closest('ytmusic-player-page, ytmusic-player-bar, ytmusic-search-box, tp-yt-iron-dropdown, #taro-nav, #side-panel')) return;
    ptr = { id: tab[2], x: e.touches[0].clientX, y: e.touches[0].clientY, on: false, pull: 0 };
  }, { capture: true, passive: true });
  document.addEventListener('touchmove', function (e) {
    if (!ptr || sheet) { if (sheet && ptr && ptr.on) ptrEnd(e); ptr = null; return; }
    var dx = e.touches[0].clientX - ptr.x, dy = e.touches[0].clientY - ptr.y;
    if (!ptr.on) {
      if (dy < -8 || Math.abs(dx) > Math.abs(dy) + 8 || window.scrollY > 0) { ptr = null; return; }
      // Stop the scroll from the first downward move: once the browser has begun scrolling, moves can't be cancelled.
      if (dy > Math.abs(dx) && e.cancelable) e.preventDefault();
      if (dy < 12) return;
      ptr.on = true;
    }
    // Once pulling, dragging back up shrinks the pull to nothing instead of ending it.
    ptr.pull = Math.max(0, Math.min(dy * 0.5, 90));
    ptrDraw(ptr.pull);
    // Own the touch from here: otherwise, when the finger reverses, the browser scrolls the page.
    if (e.cancelable) e.preventDefault();
  }, { capture: true, passive: false });
  function ptrEnd(e) {
    if (!ptr) return;
    var p = ptr;
    ptr = null;
    if (!p.on) return;
    if (e.type === 'touchend' && p.pull >= PTR_AT) {
      ptrEl.style.transition = 'transform .15s ease-out';
      ptrEl.style.transform = 'translateY(' + (PTR_AT * 0.6 - 20) + 'px)';
      ptrEl.classList.add('spin');
      // Navigating to the page we're on makes YouTube fetch it again: new recommendations, no reload.
      go(p.id);
      setTimeout(function () {
        ptrEl.style.transition = 'transform .2s ease-out, opacity .2s';
        ptrEl.style.transform = 'translateY(-20px)';
        ptrEl.style.opacity = 0;
        setTimeout(function () { ptrEl.classList.remove('spin'); ptrEl.style.transition = ''; }, 220);
      }, 1200);
      return;
    }
    ptrEl.style.transition = 'transform .2s ease-out, opacity .2s';
    ptrEl.style.transform = 'translateY(-20px)';
    ptrEl.style.opacity = 0;
    setTimeout(function () { if (ptrEl) ptrEl.style.transition = ''; }, 220);
  }
  document.addEventListener('touchend', ptrEnd, { capture: true, passive: true });
  document.addEventListener('touchcancel', ptrEnd, { capture: true, passive: true });

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
