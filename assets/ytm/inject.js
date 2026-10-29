// Injected into every music.youtube.com page by RiPlayWebView.loadYtm().
// Edit this file to change the UX; no Kotlin rebuild logic is involved.
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

  // Fallback that also reaches into shadow roots, where the page-level CSS above can't.
  function hideOpenApp(root) {
    root.querySelectorAll('*').forEach(function (el) {
      if (el.shadowRoot) hideOpenApp(el.shadowRoot);
      if (el.matches('.app-install-link, a[href^="https://app.music.youtube.com"]')) {
        el.style.setProperty('display', 'none', 'important');
      }
    });
  }
  setInterval(function () { hideOpenApp(document); }, 500);

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

  setInterval(function () {
    var v = document.querySelector('video');
    if (!v || !document.querySelector('.ad-showing, .ad-interrupting, .ytp-ad-player-overlay')) return;
    v.muted = true;
    v.playbackRate = 16;
    if (isFinite(v.duration) && v.duration > 0) v.currentTime = v.duration;
    var skip = document.querySelector('.ytp-ad-skip-button, .ytp-skip-ad-button, .ytp-ad-skip-button-modern');
    if (skip) skip.click();
  }, 100);
})();
