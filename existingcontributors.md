# How custom lyrics work in this fork

This walkthrough covers the lyrics feature as it works on current builds (Spotify 9.1.x), from the moment the app decides a track can have lyrics all the way down to brushing aside a stale response so the previous song's lines never flash onto the wrong card. It reads top to bottom as a complete story, then looks at the two places people usually get stuck: getting the lyrics UI to appear at all for local files, and stopping stale lyrics on a fast track switch.

The code lives in `Sources/EeveeSpotify/Lyrics/`, plus two URLSession hook files in `Sources/EeveeSpotify/`. The delivery work is split across two parallel hook classes, `SPTDataLoaderServiceHook` and `HttpClientURLSessionHook`, which together cover Spotify's networking entry points on 9.1.x. They behave identically at the delivery points described below.

---

## 1. The concept, in one paragraph

Spotify reads lyrics from a network endpoint, `/color-lyrics/v2/track/{trackId}`, and paints whatever protobuf comes back into a lyrics scroll card in the Now Playing screen. On 9.1.x most of the old ObjC lyrics machinery (`Lyrics_CoreImpl`, the scroll provider, the player object) is gone or behaves differently, so this fork does three jobs: convince Spotify the current track is allowed to have a lyrics card at all (the gates), answer the `/color-lyrics/v2` request with our own lyrics while Spotify thinks it was its own network call (the pipeline), and refuse to paint a reply that belongs to a different song once the user has switched (the stale fix). For normal Spotify tracks all three happen naturally. For local files, which carry no real Spotify ID and which Spotify refuses lyrics for, each job needs extra coaxing.

---

## 2. The gates: making Spotify think a track can have lyrics

On 9.1.x there is no single "does this track have lyrics" switch anymore. There are several independent checks, each of which can silently drop the lyrics card, and this fork patches every one of them. They are activated in `Tweak.x.swift` during init, each guarded by a runtime `NSClassFromString` / selector check so a hook never swizzles a class that isn't there (that would make Orion `fatalError` at dyld init).

The metadata gate. `SPTPlayerTrackMetadataV91Hook` (in `CustomLyrics+AllTracksLyrics.x.swift`) swizzles `SPTPlayerTrack.metadata()` and injects `meta["has_lyrics"] = "true"` for every track. That single bit is what tells Spotify's internals a track is worth sending to `/color-lyrics/v2` in the first place. It is deliberately the only injector of `metadata()` on 9.1.x, since the older `SPTPlayerTrackHook` is a pass-through there, so two hooks never swizzle the same selector. It is also deliberately silent: on Spotify's side `metadata()` is called on a background queue, and file logging there crashed with an Orion queue fault.

The local-file gate. `V91LyricsLocalFileGateGroup` forces `NSURL.spt_isLocalFile()` to return `false` for genuine `spotify:local:` URIs. Spotify uses this to decide whether to register the lyrics card provider in the first place; if a URI reports "I am a local file", registration is dropped before our rewrite or the metadata injection can do anything.

The scroll-provider gate (pre-9.1 only). `LyricsScrollProviderV91Hook` overrides `isEnabledForTrack(_:)` to return `true`. This only matters on versions where `Lyrics_CoreImpl.LyricsScrollProvider` still exists; on 9.1.x it is gone, so the hook group is activated only when `NSClassFromString("Lyrics_CoreImpl.LyricsScrollProvider")` returns non-nil.

The inline machine-code gate. `LyricsCardGatePatch.x.swift` is the surgical one. On 9.1.68 the real gate is inside `LyricsUIServiceImplementation.registerScrollProviderIn:`. It calls the provider's Swift availability witness, and if that returns `false` a `tbz w20, #0, …` instruction jumps straight to the epilogue, skipping `registerProvider:` entirely. So even with every ObjC hook in place, the lyrics card is silently dropped for local files. The fix is a two-byte NOP on that single `tbz` opcode. `patchLyricsCardGate()` resolves the main Spotify image base from dyld, computes the runtime address by adding the ASLR slide to the linked address, verifies the bytes are exactly the expected `tbz` (so a different Spotify build just skips the patch instead of corrupting itself), and NOPs it. The patch is idempotent, because a build-time patch may have already done it.

The UAUserActivity guard. The URI rewrite (see below) must only be live while the Now Playing scroll view is on screen; if a synthetic `spotify:track:` URI leaks into Handoff's `UAUserActivity.setWebpageURL:`, that API rejects non-web schemes and crashes. `NPVScrollViewControllerURIHook` toggles `shouldOverrideLocalTrackURI` in `viewWillAppear`/`viewWillDisappear` exactly for this, and `UAUserActivityCrashFix` swallows non-web schemes as defense-in-depth whenever the rewrite is active.

Taken together, these gates (plus the on/off lifecycle handling) are the reason a lyrics card is allowed to appear at all. None of them produce lyrics; they just stop Spotify from refusing to try.

---

## 3. The URI rewrite: making local files a valid network target

Even with the card allowed, Spotify still needs a real-looking track ID for a local file before it will fire the two network requests the lyrics card depends on: `scrollsita/v1/scroll/{uri}` (which builds the card's section list) and `/color-lyrics/v2/track/{trackId}` (the lyrics themselves). Spotify never fires either for a `spotify:local:` URI. A bare `spotify:track:` rewrite (empty ID) was tried earlier and produced a malformed scrollsita URL that Spotify dropped before it left the device: zero sections, no card slot.

`SPTPlayerTrackURIV91Hook.URI()` fixes this by rewriting a local URI to `spotify:track:local<17 hex>`. `localTrackSyntheticId(from:)` derives that ID deterministically from the real local URI (two FNV-1a hashes, percent-decoded so a title with a space hashes identically whether it arrives encoded or not). Two consequences follow:

- each local file is a distinct track to Spotify, which forces scrollsita and color-lyrics to re-fire on every local-to-local switch instead of reusing the previous song's response (a constant placeholder made every local track look identical, which is why the card kept showing old lines);
- every `spotify:local:` URI and its synthetic rewrite collapse to the same canonical id, which matters for the stale checks in section 5.

Normal (non-local) tracks skip the rewrite and pass their real ID through untouched.

---

## 4. The pipeline: answering `/color-lyrics/v2` with our lyrics

When Spotify requests `color-lyrics`, one of the two URLSession hooks intercepts it. There are two interception shapes, both gated the same way.

The "completed" shape (`didCompleteWithError`): the reply is captured and patched, or replaced by our fetch result. This is where a normal `/color-lyrics/v2` 200 response gets swapped.

The "4xx/5xx" shape (`didReceiveResponse` with a non-200 code): for a non-200 we hold the URLSession completion handler open and run our fetch on a background queue, then hand back a synthetic 200 with our payload, making a track Spotify had no lyrics for suddenly succeed. The background dispatch matters: the delegate queue is also needed to deliver later callbacks, so calling a blocking network fetch inline would deadlock.

In both shapes the function that actually produces lyrics is `getLyricsDataForCurrentTrack(_ path:, originalLyrics:)` in `CustomLyrics.x.swift`. It works from the `trackId` parsed out of the URL by `extractTrackId` (which handles three forms: a raw `spotify:local:` fragment, the synthetic `spotify:track:local…` form, and a plain Spotify ID). From there it calls `loadCustomLyricsForTrackId`, which resolves the track's title and artist through a carefully ordered chain:

1. Per-track metadata cache, the newest and most important step (section 5).
2. A global "recently captured" slot, only when its recorded ID matches this request's ID.
3. `statefulPlayer.currentTrack()`, reliable on modern Spotify.
4. `MPNowPlayingInfoCenter` (must be read on the main thread).
5. The Spotify Web API, using a captured Bearer token.
6. A last-resort fallback to title/artist the pipeline saw earlier.

Once it has title, artist, and source, it asks the chosen repository (Genius, lrclib, Musixmatch, Petit, or SpicyLyrics) for lyrics, applies any Genius fallback if configured, colors the payload from album-art extraction or user settings, and serializes it to the Spotify lyrics protobuf (`Lyrics`).

For normal Spotify tracks, if no custom lyrics are found, `getLyricsDataForCurrentTrack` returns `nil` so the hook falls through to Spotify's own response. An empty serialized zero-lyrics payload would otherwise produce a black/empty lyrics UI for songs that legitimately have none. For local tracks it always returns a `Lyrics` protobuf (empty or not), since Spotify has no native lyrics to fall back to.

There is also a best-effort prefetch. The `URI()` hook calls `prefetchLyricsIfNeeded(trackId:)` for real tracks so lyrics are warming in the background before Spotify asks; the result is stored keyed by track ID and consumed by the matching request if it arrives before the fetch would finish. This is a handoff, not a cache: if a real request comes for a different track, the prefetch is simply ignored, and on a track change `clearPrefetch()` wipes it.

Finally, because a diffable-backed Now Playing collection won't repaint just from `reloadData()`, `reloadNowPlayingCollectionForLocalSwitch()` reaches into the `__UIDiffableDataSource` and reloads lyric item index 0. This is what actually pushes the freshly injected payload onto the screen when the request was for a local file.

---

## 5. The stale-lyrics fix: never paint the previous song's lines

This is the part that stops `D0CT0R`'s lyrics from landing on `DIFFERENT TYPE H0ES` after a fast swipe, and stops a neighbor card like `C0FFIN` (never even played) from flashing its lines mid-gesture. It works at three layers.

### 5a. Per-track metadata, not a global slot

The naive approach, a single global "last seen title/artist" slot, fails here. The lyrics request for track B runs so soon after the switch that Spotify's player object still describes track A, so a global slot would still hold A's title, and Genius would be asked for A's song. The fix is `capturedTrackMetadata(forTrackId:)`, a per-ID dictionary in `V91TrackMetadataCapture.x.swift` (bounded at 128 entries, evicting arbitrarily on overflow; a miss degrades to the old fallbacks, never to a wrong result).

Metadata is written by the same `URI()` hook, keyed by the exact ID that will appear in the `color-lyrics` URL: the synthetic id for local files, the real id for normal tracks. Because that URL can only carry an ID `URI()` itself produced, a lookup keyed by the URL-extracted ID is guaranteed to hit and is guaranteed to be this track's title/artist. Cross-contamination is structurally impossible: the previous song's entry is keyed to its own ID and only ever answers its own requests. This is step 0 of `loadCustomLyricsForTrackId`, consulted before any stale global slot.

### 5b. A race-free "what is on screen right now" identity

To decide whether an in-flight fetch is stale, the delivery code needs the ID of the track the card is currently rendering. It reads this from `uiRenderedTrackKey`, written synchronously by `SPTPlayerTrackURIV91Hook.URI()` as Spotify lays out the card. That updates at card-render time, so unlike `statefulPlayer.currentTrack()` it never lags a switch. `currentTrackIdentityKey()` prefers it, then falls back (only for requests that never went through the URI hook) to player state, then title+artist, then captured metadata.

Comparisons go through `normalizedLyricsIdentity(_:)`, so representation mismatches can't misfire: a `spotify:local:` URI and its synthetic rewrite both hash to the same id, and a `spotify:track:` scheme is stripped since most IDs arrive scheme-prefixed while others don't. Normal IDs pass through unchanged.

### 5c. Two complementary delivery gates

`isStaleLyricsDelivery(fetchTrackKey:path:)` and `isLyricsDeliverySuperseded(fetchTrackKey:path:)` are OR'd together at every delivery site. They are complementary: the first reasons from the (possibly laggy) player state; the second reasons from the (race-free but during-a-swipe flapping) card key. A stale delivery happens only when either proves a mismatch.

`isStaleLyricsDelivery` returns `true` only when staleness is provable, and it is local-aware. For non-local requests a key mismatch drops unconditionally (a real track's rendered key is always a strong ID, so this never discards a valid delivery). For local requests it only drops when both keys are strong identities (a real `spotify:local:` URI, a synthetic id, or a real catalog ID), because short numeric local IDs (e.g. `/color-lyrics/v2/track/173`) and the constant placeholder are ambiguous across files and can't prove anything. It also deliberately does not treat a `nil` current key as stale for local requests: a reply landing before the first scrollsita render has completed must still be allowed through, or local lyrics drop outright.

`isLyricsDeliverySuperseded` is the settle-aware layer. While the Now Playing carousel is mid-swipe, `uiRenderedTrackKey` flaps between neighbor cards, so it defers (returns `false`) whenever `npvScrollMoving` is true, letting the strong-identity logic above make the call. Once the carousel has actually settled, the key is stable and names the active card; a fetch for any other ID belongs to a card that scrolled away and cannot paint. The settle state is driven by real scroll delegate callbacks (`scrollViewWillBeginDragging` sets `npvScrollMoving`, and `scrollViewDidEndDragging`/`scrollViewDidEndDecelerating` clear it) rather than a timed window, so it can't get stuck: a programmatic scroll never calls `willBeginDragging`, and an ended drag always clears it. `collectionView(_:targetContentOffsetForProposedContentOffset:)` logs the predicted landing page (axis-agnostic) as an early settle diagnostic.

These two gates are wired into all four delivery sites: the `didCompleteWithError` path and the 4xx `didReceiveResponse` path, in both `SPTDataLoaderServiceHook` and `HttpClientURLSessionHook`.

### 5d. What happens when a delivery is dropped

If a fetch comes back stale, the payload is not delivered. Instead the hook delivers an empty `Lyrics` protobuf (`emptyLyricsData`) when a replacing source is selected, so Spotify's native Musixmatch lines can't leak through either. A local path additionally forces the diffable reload, so even a dropped stale delivery doesn't leave the previous track's composition stuck in the data source.

---

## 6. Where each piece lives

| Piece | File |
| --- | --- |
| Metadata gate (`has_lyrics`) | `Lyrics/CustomLyrics+AllTracksLyrics.x.swift` |
| Local-file gate (`spt_isLocalFile`) | activated in `Tweak.x.swift` |
| Scroll-provider gate | `Lyrics/CustomLyrics+AllTracksLyrics.x.swift` |
| Inline `tbz` NOP gate | `Lyrics/LyricsCardGatePatch.x.swift` |
| URI rewrite + synthetic id + settle hooks | `Lyrics/CustomLyrics+AllTracksLyrics.x.swift` |
| Per-ID metadata cache | `Lyrics/V91TrackMetadataCapture.x.swift` |
| Fetch pipeline, gates, prefetch, reload | `Lyrics/CustomLyrics.x.swift` |
| Delivery (both shapes) | `SPTDataLoaderServiceHook` / `HttpClientURLSessionHook` |
| ID identity classifiers | `Lyrics/Models/Extensions/String+IsLocalTrackIdentifierExtension.swift` |

If you are tracing a specific symptom: a card that never appears points at the gates (section 2) or the URI rewrite (section 3); lyrics that are wrong or missing on a normal track point at the pipeline's metadata resolution (section 4); lyrics from the song before the one you're playing point at the stale fix (section 5).
