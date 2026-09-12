import Orion
import UIKit

// ── START OF AI GENERATED CODE ──
let shouldOverrideQueue = DispatchQueue(label: "com.eeveespotify.uriOverride")
private var _shouldOverrideLocalTrackURI = false

var shouldOverrideLocalTrackURI: Bool {
    get { shouldOverrideQueue.sync { _shouldOverrideLocalTrackURI } }
    set { shouldOverrideQueue.sync { _shouldOverrideLocalTrackURI = newValue } }
}
// ── END OF AI GENERATED CODE ──

// ── START OF AI GENERATED CODE ──
let uiTrackKeyQueue = DispatchQueue(label: "com.eeveespotify.uiTrackKey")
private var _uiRenderedTrackKey: String?

/// Identity of the track the now-playing card is CURRENTLY rendering. Recorded
/// in SPTPlayerTrackURIV91Hook.URI() (or the local-URI override branch), which
/// Spotify calls synchronously while building the scrollsita / color-lyrics
/// URLs for the displayed track — so this updates at card-render time, NOT at
/// player-commit time. Unlike statefulPlayer.currentTrack(), it never lags a
/// track switch, making stale-lyrics delivery checks race-free.
var uiRenderedTrackKey: String? {
    get { uiTrackKeyQueue.sync { _uiRenderedTrackKey } }
    set { uiTrackKeyQueue.sync { _uiRenderedTrackKey = newValue } }
}
// ── END OF AI GENERATED CODE ──

/// Change-gated writer for `uiRenderedTrackKey`. Spotify calls `URI()` on every
/// layout/scroll pass of the now-playing card, so a raw write would overwrite
/// the key (and spam the debug log) hundreds of times with the same id per
/// render. Gating on an actual id change keeps the value live (a swipe makes
/// the key flap A->B->A->B, and each flap MUST update the key for delivery
/// staleness checks), while logging happens at most once per id (see
/// `logRenderedTrackKeyOnce`).
// ── START OF AI GENERATED CODE ──
private func recordRenderedTrackKey(_ key: String) {
    guard uiRenderedTrackKey != key else { return }
    uiRenderedTrackKey = key
    removeStaleFallbackReasonLabels(tag: "now-playing header")
    logRenderedTrackKeyOnce(key, detail: "now-playing card render")
}
// ── END OF AI GENERATED CODE ──

/// Logs a rendered-track key at most once per id per session. `URI()` runs on
/// every layout/scroll pass of the carousel, so even a change-gated log fires
/// hundreds of times while a swipe transitions between cards (A->B->A->B...).
/// First-time-only logging keeps the diagnostic value (every distinct track
/// appears once) without the spam.
// ── START OF AI GENERATED CODE ──
private let renderedKeyLogQueue = DispatchQueue(label: "com.eeveespotify.renderedKeyLog")
private var _loggedRenderedKeys: Set<String> = []

private func logRenderedTrackKeyOnce(_ key: String, detail: String) {
    renderedKeyLogQueue.sync {
        guard !_loggedRenderedKeys.contains(key) else { return }
        _loggedRenderedKeys.insert(key)
        writeDebugLog("[LyricsV91] rendered track: \(key) — \(detail)")
    }
}
// ── END OF AI GENERATED CODE ──

// Now-playing carousel settle state, maintained by the scroll delegate hooks on
// NPVScrollViewControllerURIHook. "Moving" is true only between
// scrollViewWillBeginDragging and scrollViewDidEndDragging/DidEndDecelerating,
// so it can never get stuck (a programmatic scroll never calls
// willBeginDragging, and an ended drag always clears it). The lyrics-delivery
// gate uses it to avoid dropping the incoming card's fetch while the key is
// still flapping between cards mid-swipe.
// ── START OF AI GENERATED CODE ──
private let npvSettleQueue = DispatchQueue(label: "com.eeveespotify.npvSettle")
private var _npvScrollMoving = false

var npvScrollMoving: Bool {
    get { npvSettleQueue.sync { _npvScrollMoving } }
    set { npvSettleQueue.sync { _npvScrollMoving = newValue } }
}

func markNPVScrollSettled() {
    npvSettleQueue.sync { _npvScrollMoving = false }
}

func resetNPVScrollSettleState() {
    npvSettleQueue.sync { _npvScrollMoving = false }
}
// ── END OF AI GENERATED CODE ──

// ── START OF AI GENERATED CODE ──
// Synthetic Spotify track URI that local files are rewritten to when
// `shouldOverrideLocalTrackURI` is true. On Spotify 9.1.60 the Now-Playing
// scroll view (NPVScrollV2ViewController) is section-based: it renders its
// cards (incl. the lyrics card) from the response of a
// `scrollsita/v1/scroll/{uri}` network request, which Spotify never fires
// for `spotify:local:` URIs. The previous rewrite used a bare `spotify:track:`
// (empty id) so `color-lyrics/v2` would still fetch with the captured local
// id; but an empty track id makes the scrollsita URL malformed, so Spotify
// drops the request before it ever leaves the device — leaving zero sections
// and no card slot for our (already-registered) lyrics provider.
//
// The id is a deterministic 22-char hash of the real local URI (`local` + 17
// hex chars, see `localTrackSyntheticId`), so each local file is a DISTINCT
// track to Spotify. A constant placeholder made every local track look like
// the same track, so Spotify's track-change pipeline never re-fetched lyrics
// on a local->local switch — the lyrics card kept showing the previous song's
// lines. A unique id forces the scrollsita + color-lyrics reload per song.
// Spotify still treats it as a non-existent track (its own colour-lyrics fetch
// resolves to be replaced by us). The lyrics pipeline routes the synthetic id
// back to the captured local id (see `getLyricsDataForCurrentTrack`), so
// Genius/lrclib lookup for the local file keeps working.
let localTrackPlaceholderSpotifyURI = "spotify:track:0000000000000000000000"
let localTrackPlaceholderId = "0000000000000000000000"

/// Deterministically maps a real `spotify:local:` URI to a 22-char synthetic
/// track id (`local` + 17 hex chars of two FNV-1a hashes of the URI). Unique
/// per local file, stable across lookups, and never a valid catalog id.
///
/// The input is percent-decoded before hashing: the rewrite side feeds
/// `NSURL.absoluteString` (which can retain percent-escapes for spaces/unicode
/// in artist/title), while the comparison side feeds `URL.path` (which is
/// already percent-decoded). Hashing the decoded form keeps both sides
/// byte-identical, so a local file whose title contains a space can't hash
/// differently depending on which representation the key arrived in.
func localTrackSyntheticId(from localURI: String) -> String {
    func fnv1a(_ input: String, _ seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
    let decodedURI = localURI.removingPercentEncoding ?? localURI
    let h1 = String(format: "%016llx", fnv1a(decodedURI, 0xcbf29ce484222325))
    let h2 = String(format: "%01llx", (fnv1a(decodedURI, 0x811c9dc5) >> 56) & 0xf)
    return "local" + h1 + h2
}
// ── END OF AI GENERATED CODE ──

// SPTPlayerTrack metadata hooks not compatible with 9.1.x
class SPTPlayerTrackHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    static let targetName = EeveeSpotify.hookTarget == .latest
        ? "SPTPlayerTrackImplementation"
        : "SPTPlayerTrack"

    func metadata() -> [String: String] {
        // ── START OF AI GENERATED CODE ──
        // On 9.1.x the metadata injection is owned exclusively by
        // SPTPlayerTrackMetadataV91Hook (activated in its own group) to avoid
        // two hooks swizzling the same selector. Here we just pass through.
        guard EeveeSpotify.hookTarget != .v91 else {
            return orig.metadata()
        }
        // ── END OF AI GENERATED CODE ──
        var meta = orig.metadata()
        meta["has_lyrics"] = "true"
        return meta
    }
    
    func URI() -> SPTURL? {
        // ── START OF AI GENERATED CODE ──
        let uri = orig.URI()

        guard shouldOverrideLocalTrackURI,
              uri?.spt_trackIdentifier().isLocalTrackIdentifier == true else {

            if let trackId = uri?.spt_trackIdentifier(),
               trackId.hasPrefix("spotify:track:") {
                let id = String(trackId.dropFirst("spotify:track:".count))
                if !id.isEmpty {
                    prefetchLyricsIfNeeded(trackId: id)
                }
            }

            return uri
        }

        return Dynamic.convert(NSURL(string: "spotify:track:")!, to: SPTURL.self)
        // ── END OF AI GENERATED CODE ──
    }
}

// LyricsScrollProvider not compatible with 9.1.x
class LyricsScrollProviderHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x
    // ── START OF AI GENERATED CODE ──
    static var targetName = EeveeSpotify.hookTarget == .v91
        ? "UIView" // LyricsScrollProvider class may not exist on 9.1.x
        : "Lyrics_CoreImpl.LyricsScrollProvider"
    // ── END OF AI GENERATED CODE ──
    
    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        return true
    }
}

// NPVScrollViewController not compatible with 9.1.x  
class NPVScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LyricsErrorHandlingGroup  // Not activated for 9.1.x (moved from ModernLyricsGroup)
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

// ── START OF AI GENERATED CODE ──
// Separate group for the URI rewrite hook so it can be activated independently
// of NPVScrollV2ViewController's existence. On 9.1.68 NPVScrollV2ViewController
// is gone, which would skip the entire V91LyricsGroup and prevent the URI
// rewrite — making local tracks generate a malformed scrollsita URL and lose
// the lyrics card slot. Contains a viewWillAppear/disappear hook on V1
// NPVScrollViewController (which exists on 9.1.68) to toggle the override flag
// only when the now-playing scroll view is active — avoiding the UAUserActivity
// crash that occurs when synthetic URIs flow through Handoff outside the
// now-playing lifecycle.
struct V91LyricsURIGroup: HookGroup {}

// Hook NPVScrollViewController (V1, present on 9.1.68) to toggle
// shouldOverrideLocalTrackURI. Without this, the flag defaults to false and
// local-track URI rewrites never fire; but setting it globally true causes
// synthetic URIs to reach UAUserActivity.setWebpageURL: which rejects them.
// NPVScrollViewController.viewWillAppear is a safe trigger that fires only
// when the now-playing scroll view is on-screen and lyrics are live.
class NPVScrollViewControllerURIHook: ClassHook<NSObject> {
    typealias Group = V91LyricsURIGroup
    static let targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        // Capture the on-screen V1 now-playing scroll controller. The global is
        // otherwise only set by NowPlayingScrollPrivateServiceImplementationHook
        // (BaseLyricsGroup), which is skipped on 9.1.68 — so reload helpers that
        // guard on npvScrollViewController silently no-op there.
        npvScrollViewController = Dynamic.convert(target, to: NPVScrollViewController.self)
        if let track = statefulPlayer?.currentTrack() {
            captureCanvasTrack(track)
        }
        shouldOverrideLocalTrackURI = true
        resetNPVScrollSettleState()
        orig.viewWillAppear(animated)
    }

    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        uiRenderedTrackKey = nil
        resetNPVScrollSettleState()
        orig.viewWillDisappear(animated)
    }

    // --- Carousel settle signal ---
    // The now-playing carousel renders neighbor cards during a swipe, so URI()
    // (and with it uiRenderedTrackKey) flaps between cards until the gesture
    // ends. These delegate callbacks pin down when the carousel is actually
    // still vs. in transition, giving the lyrics-delivery gate a real
    // "settled" signal instead of a timed window. `targetContentOffset` is
    // logged for diagnostics (predicted settle page); the moving flag is
    // toggled only by the drag begin/end callbacks so it can never get stuck
    // on a programmatic scroll.

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        npvScrollMoving = true
        orig.scrollViewWillBeginDragging(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        if !willDecelerate {
            markNPVScrollSettled()
        }
        orig.scrollViewDidEndDragging(scrollView, willDecelerate: willDecelerate)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        markNPVScrollSettled()
        orig.scrollViewDidEndDecelerating(scrollView)
    }

    func collectionView(_ collectionView: UICollectionView, targetContentOffsetForProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        let target = orig.collectionView(collectionView, targetContentOffsetForProposedContentOffset: proposedContentOffset)
        // Fires at drag-end BEFORE deceleration with the predicted landing
        // offset. Logged (one line per swipe, not per render pass) as the
        // early settle signal; the delivery gate itself relies on the drag
        // begin/end callbacks above so a programmatic scroll can't wedge the
        // moving flag. A future offset->page->track mapping could settle the
        // active card here before deceleration even finishes.
        let current = collectionView.contentOffset
        let bounds = collectionView.bounds
        let scrollsHorizontally = abs(target.x - current.x) >= abs(target.y - current.y)
        if scrollsHorizontally {
            let pageWidth = max(bounds.width, 1)
            let page = Int((target.x + pageWidth * 0.5) / pageWidth)
            writeDebugLog("[LyricsV91] scroll settle target: page=\(page) offsetX=\(target.x)")
        } else {
            let pageHeight = max(bounds.height, 1)
            let page = Int((target.y + pageHeight * 0.5) / pageHeight)
            writeDebugLog("[LyricsV91] scroll settle target: page=\(page) offsetY=\(target.y)")
        }
        return target
    }
}
// ── END OF AI GENERATED CODE ──

// ── START OF AI GENERATED CODE ──
// V91-compatible URI hook — converts local URIs to fake track URIs so Spotify
// fires /color-lyrics/v2 which our network hooks can intercept.
// Only hooks URI() (not metadata()) because metadata() is incompatible with 9.1.x.
// Return type MUST match SPTPlayerTrack.URI() exactly: optional NSURL (see the
// baseline SPTPlayerTrackHook). A non-optional or wrong-class return type is a
// method-signature mismatch that makes Orion fatalError() at dyld init.
class SPTPlayerTrackURIV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsURIGroup
    static let targetName = "SPTPlayerTrack"

    func URI() -> NSURL? {
        let uri = orig.URI()

        guard shouldOverrideLocalTrackURI,
              let absoluteString = uri?.absoluteString,
              absoluteString.isLocalTrackIdentifier else {

            if let uriString = uri?.absoluteString,
               uriString.hasPrefix("spotify:track:") {
                let trackId = uriString.replacingOccurrences(of: "spotify:track:", with: "")
                if !trackId.isEmpty {
                    // The now-playing card is rendering this normal track (when
                    // the scroll view is live) — record its id + metadata so
                    // stale-fetch delivery checks can compare against the card's
                    // CURRENT track without reading (laggy) player state, and so
                    // the fetch for this id searches with THIS track's
                    // title/artist (see capturedTrackMetadata).
                    if shouldOverrideLocalTrackURI {
                        recordRenderedTrackKey(trackId)
                        let renderedTrack = Dynamic.convert(target, to: SPTPlayerTrack.self)
                        captureTrackMetadata(id: trackId, title: renderedTrack.trackTitle(), artist: renderedTrack.artistName())
                    }
                    prefetchLyricsIfNeeded(trackId: trackId)
                }
            }

            return uri
        }

        // Rewrite to a WELL-FORMED (non-local) Spotify track URI so the
        // scrollsita URL builder produces a valid request URL and Spotify
        // fires `scrollsita/v1/scroll/{uri}` instead of dropping it pre-flight
        // (the empty-id form made the URL malformed, so zero scroll sections
        // appeared and the lyrics card had no slot to render into). Each local
        // file gets a deterministic unique synthetic id (see
        // `localTrackSyntheticId`), so Spotify treats every local song as a
        // distinct track and re-fires scrollsita + color-lyrics on each
        // local->local switch — fixing lyrics that stayed stale because a
        // constant placeholder made every local track look identical. The
        // synthetic id is routed back to the captured local id by the
        // lyrics fetch pipeline (see getLyricsDataForCurrentTrack), so the
        // Genius fallback for local files keeps working.
        let syntheticId = localTrackSyntheticId(from: absoluteString)
        let syntheticURI = "spotify:track:\(syntheticId)"
        if uiRenderedTrackKey != syntheticId {
            uiRenderedTrackKey = syntheticId
            // Capture the local file's metadata keyed by the synthetic id — the
            // id the color-lyrics URL will carry — so the fetch for this track
            // searches Genius with ITS OWN title/artist. A single global slot
            // would still hold the previous song's metadata when the player
            // lags (the stale-lyrics bug), but the per-id cache can't
            // cross-contaminate: the previous song's entry is keyed to its own
            // synthetic id and only ever serves that id's requests.
            let renderedTrack = Dynamic.convert(target, to: SPTPlayerTrack.self)
            captureTrackMetadata(id: syntheticId, title: renderedTrack.trackTitle(), artist: renderedTrack.artistName())
            logRenderedTrackKeyOnce(syntheticId, detail: "URI override: local -> synthetic \(syntheticURI) (from \(absoluteString))")
        }
        return NSURL(string: syntheticURI)!
    }
}
// ── END OF AI GENERATED CODE ──

// V91-compatible version of NPVScrollViewController hook
// ── START OF AI GENERATED CODE ──
// On 9.1.60, the actual NPV scroll view controller is NPVScrollV2ViewController
// (not the older NPVScrollViewController). The V1 class may still exist but
// isn't the one used at runtime.
class NPVScrollViewControllerV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollV2ViewController"
// ── END OF AI GENERATED CODE ──

    func viewWillAppear(_ animated: Bool) {
        // ── START OF AI GENERATED CODE ──
        // Capture local metadata from the REAL track URI. The override must not
        // be enabled yet: once shouldOverrideLocalTrackURI is true,
        // SPTPlayerTrackURIV91Hook rewrites the URI to a synthetic
        // `spotify:track:local<hex>` id, so spt_trackIdentifier() returns the
        // synthetic id and the local check below would no longer fire (capture
        // would never run and Genius would get empty title/artist). On V2,
        // nowPlayingScrollViewController is nil (it's only set for V1), so use
        // statefulPlayer.currentTrack() as the primary source.
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        if let track = track {
            captureCanvasTrack(track)
            let trackId = track.URI().spt_trackIdentifier()
            let title = track.trackTitle()
            let artist = track.artistName()
            let isLocal = trackId.isLocalTrackIdentifier
            writeDebugLog("[LyricsV91] NPVScrollV2 viewWillAppear: trackId=\(trackId) local=\(isLocal)")
            if isLocal {
                capturedTrackTitle = title
                capturedArtistName = artist
                capturedTrackId = trackId
                writeDebugLog("[V91] captured local track: title=\(title) artist=\(artist)")
                // BUG FIX: Clear any stale prefetch from the previous track —
                // local tracks share the URL-based numeric ID, so prefetch
                // results from the old song would incorrectly match the new one.
                clearPrefetch()
                prefetchLyricsIfNeeded(trackId: trackId)
            }
        } else {
            writeDebugLog("[LyricsV91] NPVScrollV2 viewWillAppear: no track available")
        }

        // Now enable the URI override so Spotify fires both
        // /color-lyrics/v2 and scrollsita/v1/scroll for the (rewritten) local
        // track. The synthetic id is unique per local file, so a local->local
        // switch changes the URI and forces Spotify to re-fire both requests
        // (a constant placeholder id made every local track look identical and
        // the lyrics card kept showing the previous song's lines). The
        // synthetic id is routed back to the captured local id by the lyrics
        // fetch pipeline, keeping the Genius fallback intact.
        // ── END OF AI GENERATED CODE ──
        shouldOverrideLocalTrackURI = true
        orig.viewWillAppear(animated)
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
    }
}

// ── START OF AI GENERATED CODE ──
// V91-compatible hook — forces LyricsScrollProvider to report lyrics as enabled
// for ALL tracks, including local files. Without this, Spotify's internal
// lyrics availability check rejects local files based on their URI.
// NOTE: On 9.1.x the Lyrics_CoreImpl module no longer exists (lyrics was
// rewritten to Lyrics_TextComponentImpl), so this target resolves to a dummy
// UIView to avoid a dyld crash. The real lyrics-enabling point on 9.1.x must
// be found in the new Lyrics_TextComponentImpl architecture.
// Separate group so this hook only registers when the real
// Lyrics_CoreImpl.LyricsScrollProvider class actually exists. On 9.1.x that
// class is gone (lyrics rewritten to Lyrics_TextComponentImpl), so the group
// stays unactivated and the hook is never registered — avoiding the dyld
// fatalError that the old dummy-"UIView" target caused (UIView has no
// isEnabledForTrack: method for Orion to swizzle).
struct V91LyricsScrollProviderGroup: HookGroup {}

// 9.1.x lyrics-availability GATE: inject `has_lyrics: true` into
// SPTPlayerTrack.metadata() so Spotify fires `/color-lyrics/v2` for every
// track (incl. locals). SPTPlayerTrackHook is a no-op pass-through on 9.1.x,
// so this is the sole metadata injector (no double-swizzle). Deliberately has
// NO logging: metadata() is called on a background queue by Spotify and
// writeDebugLog (file I/O) there triggered an Orion fatalError / queue crash
// on normal tracks. Mirrors SPTPlayerTrackHook.metadata() exactly.
struct V91LyricsMetadataGroup: HookGroup {}

class SPTPlayerTrackMetadataV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsMetadataGroup
    static let targetName = "SPTPlayerTrack"

    func metadata() -> [String: String] {
        var meta = orig.metadata()
        meta["has_lyrics"] = "true"
        return meta
    }
}

class LyricsScrollProviderV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsScrollProviderGroup
    static let targetName = "Lyrics_CoreImpl.LyricsScrollProvider"

    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        return true
    }
}
// ── END OF AI GENERATED CODE ──

class NowPlayingScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = LegacyLyricsGroup
    static var targetName = EeveeSpotify.hookTarget == .v91
        ? "UIView" // Dummy target for 9.1.6
        : "NowPlaying_ScrollImpl.NowPlayingScrollViewController"
    
    func nowPlayingScrollViewModelWithDidLoadComponentsFor(
        _ track: SPTPlayerTrack,
        withDifferentProviders: Bool,
        scrollEnabledValueChanged: Bool
    ) -> NowPlayingScrollViewController {
        let controller = orig.nowPlayingScrollViewModelWithDidLoadComponentsFor(
            track,
            withDifferentProviders: withDifferentProviders,
            scrollEnabledValueChanged: scrollEnabledValueChanged
        )
        
        if !scrollEnabledValueChanged {
            controller.scrollEnabled = true
            controller.nowPlayingScrollViewModelDidChangeScrollEnabledValue()
        }

        return controller
    }
}

// ── START OF AI GENERATED CODE ──
// 9.1.x lyrics-UI GATE: Spotify registers the lyrics card provider only if a
// track-state predicate in LyricsUIServiceImplementation passes. That predicate
// reads SPTURL.spt_isLocalFile() and drops registration for local files BEFORE
// our URI rewrite / has_lyrics injection can take effect (the reactive Combine
// subscription evaluates at track-change time, before viewWillAppear). Forcing
// spt_isLocalFile() to return false for genuine `spotify:local:` URIs makes the
// predicate register the lyrics provider for local files too, so the lyrics card
// actually appears. Scoped to local URIs to avoid perturbing non-local callers.
struct V91LyricsLocalFileGateGroup: HookGroup {}

class SPTURLIsLocalFileV91Hook: ClassHook<NSObject> {
    typealias Group = V91LyricsLocalFileGateGroup
    static let targetName = "NSURL"

    func spt_isLocalFile() -> Bool {
        let origLocal = orig.spt_isLocalFile()
        if origLocal,
           let abs = (target as? NSURL)?.absoluteString,
           abs.hasPrefix("spotify:local:") {
            return false
        }
        return origLocal
    }
}
// ── END OF AI GENERATED CODE ──
