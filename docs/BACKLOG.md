# Agent backlog

One line per item. `- [ ]` open. The agent adds findings here and moves finished items to docs/DONE.md.

## Open
- [ ] [F:small:Library:button.ytSpecButtonShapeNextHost.ytSpecButtonShapeNextText] Library | button.ytSpecButtonShapeNextHost.ytSpecButtonShapeNextText at 132,152 | expected: touch target at least 44x44 css px | actual: audit measured 36x36 css px
- [ ] [F:gap:Library:button#taro-new+ytmusic-play-button-renderer#play-button.ytmusic-item-thumbnail-overlay-re] Library | button#taro-new next to a card's play button | expected: tappable targets at least 8 px apart so a thumb hits one | actual: audit measured targets 3 px apart
- [ ] [F:small:Home:button#button.yt-icon-button] Home | button#button.yt-icon-button at 264,47 (header) | expected: touch target at least 44x44 css px (or padded hit area) | actual: audit measured 32x32 css px
- [ ] [F:small:Home:a.yt-simple-endpoint.ytmusic-logo] Home | a.yt-simple-endpoint.ytmusic-logo at 16,51 (header logo) | expected: touch target at least 44x44 css px | actual: audit measured 71x24 css px
- [ ] [F:small:Home:button.ytSpecButtonShapeNextHost.ytSpecButtonShapeNextText] Home | button.ytSpecButtonShapeNextText at 308,226 | expected: touch target at least 44x44 css px | actual: audit measured 36x36 css px

## Rejected
(idea: reason)
- 'menu' TypeError in YouTube polymer js (2 of 85 wander gestures, no visible effect): inside YouTube code, cause unknown, not worth chasing
- 'menuRenderer' TypeError in YouTube polymer js (1 in 10 wander gestures, no visible effect): same class as 'menu' error, YouTube's own code
- 'Ignored attempt to cancel a touchmove' console warning during fast flings: browser notice, scroll already running, no visible effect
- 'Ignored attempt to cancel a touchend' console notice during wander: same class as touchmove one, no visible effect
- 'Blocked aria-hidden ... descendant retained focus' warning when song menu closes (wander): browser notice from YouTube's own dropdown, no visible effect
- 'Blocked aria-hidden' warning on YouTube toast button (wander): same class as the menu one, YouTube's own toast
