# Agent backlog

One line per item. `- [ ]` open. The agent adds findings here and moves finished items to docs/DONE.md.

## Open
- [ ] [F:small:Home:button.ytSpecButtonShapeNextHost.ytSpecButtonShapeNextText] Home | button.ytSpecButtonShapeNextText at 308,226 | expected: touch target at least 44x44 css px | actual: audit measured 36x36 css px
- [ ] [F:small:Home:button.ytSpecButtonShapeNextHost.ytSpecButtonShapeNextOutline] Home | button.ytSpecButtonShapeNextOutline at 225,180 | expected: touch target at least 44x44 css px (or padded hit area) | actual: audit measured 55x24 css px
- [ ] [F:small:Home:a.yt-simple-endpoint.yt-formatted-string] Home | a.yt-simple-endpoint.yt-formatted-string at 80,226 | expected: touch target at least 44 css px tall (or padded hit area) | actual: audit measured 185x17 css px
- [ ] [F:bottom-inset:Home:ytmusic-two-row-item-renderer.ytmusic-carousel] Home | ytmusic-two-row-item-renderer.ytmusic-carousel | expected: tappable area ends above the navigation bar zone (BOT) | actual: audit measured it crossing the navigation bar zone
- [ ] [F:bottom-inset:Home:a.yt-simple-endpoint.anchor-link] Home | a.yt-simple-endpoint.anchor-link | expected: tappable area ends above the navigation bar zone (BOT) | actual: audit measured it crossing the navigation bar zone

## Rejected
- [F:small:Home:button#button.yt-icon-button] stale: header buttons already 44px, audit no longer reports it (2 runs)
- [F:gap:Library:button#taro-new+ytmusic-play-button-renderer#play-button.ytmusic-item-thumbnail-overlay-re] stale: two Library audits show no taro-new gap (depends on scroll position of cards under the floating button)
(idea: reason)
- 'menu' TypeError in YouTube polymer js (2 of 85 wander gestures, no visible effect): inside YouTube code, cause unknown, not worth chasing
- 'menuRenderer' TypeError in YouTube polymer js (1 in 10 wander gestures, no visible effect): same class as 'menu' error, YouTube's own code
- 'Ignored attempt to cancel a touchmove' console warning during fast flings: browser notice, scroll already running, no visible effect
- 'Ignored attempt to cancel a touchend' console notice during wander: same class as touchmove one, no visible effect
- 'Blocked aria-hidden ... descendant retained focus' warning when song menu closes (wander): browser notice from YouTube's own dropdown, no visible effect
- 'Blocked aria-hidden' warning on YouTube toast button (wander): same class as the menu one, YouTube's own toast
