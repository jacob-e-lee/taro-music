# Agent backlog

One line per item. `- [ ]` open. The agent adds findings here and moves finished items to docs/DONE.md.

## Open
- [ ] [F:thumb:TabsPanel:.next-button] TabsPanel | tap next in mini bar with up-next panel open | expected: next reachable in lower thumb zone | actual: .next-button centre at y=71 of 780 css px, out of easy thumb reach
- [ ] [F:thumb:TabsPanel:ytmusic-player-page_tp-yt-paper-tab] TabsPanel | tap Up next / Lyrics / Related tabs | expected: tab switcher within thumb reach | actual: tp-yt-paper-tab centre at y=143 of 780 css px, out of easy thumb reach
- [ ] [F:motion:FullPlayer:player-sheet-close] FullPlayer | close full player (sheet close) | expected: sheet slides down over several frames | actual: lens motion measured only 1 distinct position in 700 ms (jumps), same result on 2 runs
- [ ] [F:motion:SongMenu:song-menu-open] SongMenu | open song menu | expected: sheet slides up over several frames | actual: lens motion measured only 1 distinct position in 700 ms (jumps), same result on 2 runs

## Rejected
- [F:thumb:TabsPanel:.play-pause-button] not reproducible: lens thumb run twice, no TabsPanel finding (the y=71 hit was the invisible top player bar)
- [F:bottom-inset:Home:a.yt-simple-endpoint.anchor-link] not reproducible: two audits, no bottom-inset finding
- [M:hygiene-397] nothing to prune: no unused identifiers, taro-* classes, imports or duplicate channel calls found; inject.js split needs a build step, not worth the risk
- [F:bottom-inset:Home:ytmusic-two-row-item-renderer.ytmusic-carousel] not reproducible: two audits, no bottom-inset finding
- [F:small:Home:a.yt-simple-endpoint.yt-formatted-string] not reproducible: live audit (2 runs) shows no small-target finding for it
- [F:small:Home:button.ytSpecButtonShapeNextHost.ytSpecButtonShapeNextOutline] Stale: audit run twice, no Outline button found (transient 55x24 button gone).
- [F:small:Home:button.ytSpecButtonShapeNextHost.ytSpecButtonShapeNextText] stale: inject.js:171 already sets 44px min size; audit no longer reports it
- [F:small:Home:button#button.yt-icon-button] stale: header buttons already 44px, audit no longer reports it (2 runs)
- [F:gap:Library:button#taro-new+ytmusic-play-button-renderer#play-button.ytmusic-item-thumbnail-overlay-re] stale: two Library audits show no taro-new gap (depends on scroll position of cards under the floating button)
(idea: reason)
- 'menu' TypeError in YouTube polymer js (2 of 85 wander gestures, no visible effect): inside YouTube code, cause unknown, not worth chasing
- 'menuRenderer' TypeError in YouTube polymer js (1 in 10 wander gestures, no visible effect): same class as 'menu' error, YouTube's own code
- 'Ignored attempt to cancel a touchmove' console warning during fast flings: browser notice, scroll already running, no visible effect
- 'Ignored attempt to cancel a touchend' console notice during wander: same class as touchmove one, no visible effect
- 'Blocked aria-hidden ... descendant retained focus' warning when song menu closes (wander): browser notice from YouTube's own dropdown, no visible effect
- 'Blocked aria-hidden' warning on YouTube toast button (wander): same class as the menu one, YouTube's own toast
