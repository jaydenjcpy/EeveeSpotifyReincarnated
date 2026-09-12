import Orion
import SwiftUI
import MediaPlayer

struct BaseLyricsGroup: HookGroup { }

struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }
struct V91LyricsGroup: HookGroup { }            // 9.1.x-safe subset
struct LyricsErrorHandlingGroup: HookGroup { }  // not activated on 9.1.x

// ── START OF AI GENERATED CODE ──
private let lyricsStateQueue = DispatchQueue(label: "com.eeveespotify.lyricsState")
private var _lyricsState = LyricsLoadingState()

var lyricsState: LyricsLoadingState {
    get { lyricsStateQueue.sync { _lyricsState } }
    set { lyricsStateQueue.sync { _lyricsState = newValue } }
}
// ── END OF AI GENERATED CODE ──

// ── START OF AI GENERATED CODE ──
// Title/artist last resolved by loadCustomLyricsForCurrentTrack, used as a
// fallback by loadCustomLyricsForTrackId so Genius can find local tracks on
// 9.1.x where the player object is nil.
private let lyricsSearchQueue = DispatchQueue(label: "com.eeveespotify.lyricsSearch")
private var _lyricsSearchTitle: String? = nil
private var _lyricsSearchArtist: String? = nil

var lyricsSearchTitle: String? {
    get { lyricsSearchQueue.sync { _lyricsSearchTitle } }
    set { lyricsSearchQueue.sync { _lyricsSearchTitle = newValue } }
}
var lyricsSearchArtist: String? {
    get { lyricsSearchQueue.sync { _lyricsSearchArtist } }
    set { lyricsSearchQueue.sync { _lyricsSearchArtist = newValue } }
}
// ── END OF AI GENERATED CODE ──

var hasShownRestrictedPopUp = false
var hasShownUnauthorizedPopUp = false

private let geniusLyricsRepository = GeniusLyricsRepository()
private let petitLyricsRepository = PetitLyricsRepository()

// Overload for 9.1.6 where we only have track ID from URL
private func loadCustomLyricsForTrackId(_ trackIdIn: String) throws -> Lyrics {
    // Local tracks get resolved to a real Spotify id below, so the parameter
    // needs a mutable shadow.
    var trackId = trackIdIn

    // Covers both callers of this function — prefetchLyricsIfNeeded and
    // getLyricsDataForCurrentTrack's bounded-wait fallback — so every fetch,
    // however it started, is recorded here before any network call. See
    // KaraokeLyricsStore.latestRequestedTrackId's doc comment for why this
    // needs to happen at request *start*, not completion.
    KaraokeLyricsStore.shared.noteRequestStarted(trackId: trackId)
    var source = UserDefaults.lyricsSource

    var currentTitle: String? = nil
    var currentArtist: String? = nil
    var hasMetadata = false

    let needsMetadata = source == .genius || source == .lrclib || source == .petit

    // ── START OF AI GENERATED CODE ──
    // 0. Per-track metadata captured at card-render time by the URI() hook,
    // keyed by the exact id in this lyrics request (the synthetic id for local
    // files, the real id for normal tracks). The color-lyrics URL can only
    // carry an id that URI() itself produced, so this is guaranteed to be THIS
    // track's metadata — never a stale global slot left over from the previous
    // track's fetch (steps 5/6 below, which is how D0CT0R's title leaked into
    // DIFFERENT TYPE H0ES's search on a fast switch).
    if let meta = capturedTrackMetadata(forTrackId: trackId) {
        currentTitle = meta.title
        currentArtist = meta.artist
        hasMetadata = true
    }
    // ── END OF AI GENERATED CODE ──

    // 1. Use cached metadata if it's for the same track
    if capturedTrackId == trackId, let title = capturedTrackTitle, let artist = capturedArtistName {
        currentTitle = title
        currentArtist = artist
        hasMetadata = true
    }

    // 2. Try statefulPlayer (most reliable on modern Spotify)
    if !hasMetadata {
        if let player = statefulPlayer,
           let track = player.currentTrack() {
            let currentId = track.URI().spt_trackIdentifier()

            if currentId == trackId {
                currentTitle = track.trackTitle()
                currentArtist = track.artistName()
                hasMetadata = true
                // ── START OF AI GENERATED CODE ──
                if !trackId.isLocalOrNonSpotifyTrackId {
                    capturedTrackId = trackId
                }
                // ── END OF AI GENERATED CODE ──
                capturedTrackTitle = currentTitle
                capturedArtistName = currentArtist
            }
        }
    }

    // 3. MPNowPlayingInfoCenter — must be read on the main thread
    if !hasMetadata {
        var npTitle: String? = nil
        var npArtist: String? = nil
        if Thread.isMainThread {
            npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
            npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
        } else {
            DispatchQueue.main.sync {
                npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
            }
        }
        if let title = npTitle, let artist = npArtist, !title.isEmpty, !artist.isEmpty {
            currentTitle = title
            currentArtist = artist
            hasMetadata = true
            // ── START OF AI GENERATED CODE ──
            // BUG FIX: Don't overwrite capturedTrackId with the URL-based numeric
            // ID for local tracks — all local tracks share that ID, so this would
            // contaminate captures and cause stale metadata to be reused for
            // different songs (capturedTrackId == trackId would always match).
            if !trackId.isLocalOrNonSpotifyTrackId {
                capturedTrackId = trackId
            }
            // ── END OF AI GENERATED CODE ──
            capturedTrackTitle = title
            capturedArtistName = artist
        }
    }

    // 4. Spotify Web API fallback using captured Bearer token
    if !hasMetadata, let token = spotifyAccessToken {
        if let info = fetchTrackDetails(trackId: trackId, token: token) {
            currentTitle = info.title
            currentArtist = info.artist
            hasMetadata = true
            // ── START OF AI GENERATED CODE ──
            if !trackId.isLocalOrNonSpotifyTrackId {
                capturedTrackId = trackId
            }
            // ── END OF AI GENERATED CODE ──
            capturedTrackTitle = currentTitle
            capturedArtistName = currentArtist
        }
    }

        // ── START OF AI GENERATED CODE ──
    // 5. Local track fallback: the captured id (spotify:local:...) may not
    // equal the bare numeric id in the lyrics request, so use the captured
    // title/artist directly when present.
    if !hasMetadata, trackId.isLocalOrNonSpotifyTrackId,
       let title = capturedTrackTitle, let artist = capturedArtistName {
        currentTitle = title
        currentArtist = artist
        hasMetadata = true
    }

    // 6. Fall back to title/artist resolved by loadCustomLyricsForCurrentTrack.
    if !hasMetadata, let title = lyricsSearchTitle, let artist = lyricsSearchArtist {
        currentTitle = title
        currentArtist = artist
hasMetadata = true
    }
    // ── END OF AI GENERATED CODE ──

    if needsMetadata && !hasMetadata {
        throw LyricsError.noSuchSong
    }

        // ── START OF AI GENERATED CODE ──
    // Local files (spotify:local:...) have no real Spotify track ID, so
    // providers that require one (SpicyLyrics, Musixmatch) can't look them
    // up directly. Resolve by searching the Spotify catalog for the
    // title+artist to get a real track ID. Fall back to Genius (which
    // searches by title+artist natively) if the catalog search fails.
    let isLocalTrack = trackId.isLocalOrNonSpotifyTrackId || trackId == localTrackPlaceholderId
    writeDebugLog("[Lyrics] loadCustomLyricsForTrackId: trackId=\(trackId) isLocal=\(isLocalTrack) source=\(source) hasMetadata=\(hasMetadata)")
    if isLocalTrack {
        if !hasMetadata {
            writeDebugLog("[Lyrics] Local track but no metadata, cannot search: \(trackId)")
            throw LyricsError.noSuchSong
        }

        let sourceNeedsTrackId = source == .spicylyrics || source == .musixmatch
        if sourceNeedsTrackId {
            if let token = spotifyAccessToken,
               let resolvedId = searchSpotifyTrack(title: currentTitle ?? "", artist: currentArtist ?? "", token: token) {
                writeDebugLog("[Lyrics] Resolved local track to Spotify id \(resolvedId) for \(source) search")
                trackId = resolvedId
            } else {
                writeDebugLog("[Lyrics] Spotify search failed for local track — falling back to Genius")
                source = .genius
            }
        }
        if source == .genius {
            writeDebugLog("[Lyrics] Genius search local: title=\(currentTitle ?? "") artist=\(currentArtist ?? "")")
        }
    }
    // ── END OF AI GENERATED CODE ──

    let searchQuery = LyricsSearchQuery(
        title: currentTitle ?? "",
        primaryArtist: currentArtist ?? "",
        spotifyTrackId: trackId
    )
    
    let options = UserDefaults.lyricsOptions
    
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .musixmatch:
        repository = MusixmatchLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .spicylyrics:
        repository = SpicyLyricsRepository.shared
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    
    lyricsState = LyricsLoadingState()
    
    do {
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    catch let error {
        if isLocalTrack {
            writeDebugLog("[Lyrics] Genius local search failed: \(error)")
        }
        if let lyricsError = error as? LyricsError {
            lyricsState.fallbackError = lyricsError

            switch lyricsError {
            case .invalidMusixmatchToken:
                if !hasShownUnauthorizedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_unauthorized_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownUnauthorizedPopUp = true
                }
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    DispatchQueue.main.async {
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "musixmatch_restricted_popup".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                    hasShownRestrictedPopUp = true
                }
            default:
                break
            }
        } else {
            lyricsState.fallbackError = .unknownError
        }

        // Attempt Genius fallback if enabled and the primary source isn't already Genius.
        // Genius requires title + artist to search — only attempt if we have them.
        let canFallbackToGenius = source != .genius
            && UserDefaults.lyricsOptions.geniusFallback
            && !(currentTitle ?? "").isEmpty
            && !(currentArtist ?? "").isEmpty
        if canFallbackToGenius {
            source = .genius
            lyricsDto = try geniusLyricsRepository.getLyrics(searchQuery, options: options)
        } else {
            throw error
        }
    }
    
    lyricsState.isEmpty = lyricsDto.lines.isEmpty
    
    lyricsState.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
    
    lyricsState.loadedSuccessfully = true

    if isLocalTrack {
        writeDebugLog("[Lyrics] Genius local search success: title=\(currentTitle ?? "") artist=\(currentArtist ?? "")")
    }

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}

private func loadCustomLyricsForCurrentTrack() throws -> Lyrics {
    
    guard
        let track = statefulPlayer?.currentTrack() ??
                    nowPlayingScrollViewController?.loadedTrack
        else {
            throw LyricsError.noCurrentTrack
        }
    
    let trackTitle = track.trackTitle()
    let artistName = track.artistName()

    // Same reasoning as loadCustomLyricsForTrackId's call to this — see
    // KaraokeLyricsStore.latestRequestedTrackId's doc comment.
    KaraokeLyricsStore.shared.noteRequestStarted(trackId: track.trackIdentifier)
    lyricsSearchTitle = trackTitle
    lyricsSearchArtist = artistName

    let searchQuery = LyricsSearchQuery(
        title: trackTitle,
        primaryArtist: artistName,
        spotifyTrackId: track.trackIdentifier
    )
    
    let options = UserDefaults.lyricsOptions
    var source = UserDefaults.lyricsSource
    
    // Local files have no real Spotify track ID — force Genius which
    // searches by title+artist.
    let isLocal = track.trackIdentifier.isLocalOrNonSpotifyTrackId
    writeDebugLog("[Lyrics] loadCustomLyricsForCurrentTrack: trackId=\(track.trackIdentifier) isLocal=\(isLocal) source=\(source)")
    if isLocal {
        source = .genius
    }

    // switched to swift 5.8 syntax to compile with Theos on Linux.
    var repository: LyricsRepository

    switch source {
    case .genius:
        repository = geniusLyricsRepository
    case .lrclib:
        repository = LrclibLyricsRepository.shared
    case .musixmatch:
        repository = MusixmatchLyricsRepository.shared
    case .petit:
        repository = petitLyricsRepository
    case .spicylyrics:
        repository = SpicyLyricsRepository.shared
    case .notReplaced:
        throw LyricsError.invalidSource
    }
    
    let lyricsDto: LyricsDto
    
    lyricsState = LyricsLoadingState()
    
    do {
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    catch let error {
        if let error = error as? LyricsError {
            lyricsState.fallbackError = error
            
            switch error {
                
            case .invalidMusixmatchToken:
                if !hasShownUnauthorizedPopUp {
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: "musixmatch_unauthorized_popup".localized,
                        buttonText: "OK".uiKitLocalized
                    )
                    
                    hasShownUnauthorizedPopUp.toggle()
                }
            
            case .musixmatchRestricted:
                if !hasShownRestrictedPopUp {
                    PopUpHelper.showPopUp(
                        delayed: false,
                        message: "musixmatch_restricted_popup".localized,
                        buttonText: "OK".uiKitLocalized
                    )
                    
                    hasShownRestrictedPopUp.toggle()
                }
                
            default:
                break
            }
        }
        else {
            lyricsState.fallbackError = .unknownError
        }
        
        if source == .genius || !UserDefaults.lyricsOptions.geniusFallback {
            throw error
        }
        
        source = .genius
        repository = GeniusLyricsRepository()
        
        lyricsDto = try repository.getLyrics(searchQuery, options: options)
    }
    
    lyricsState.isEmpty = lyricsDto.lines.isEmpty
    
    lyricsState.wasRomanized = lyricsDto.romanization == .romanized
        || (lyricsDto.romanization == .canBeRomanized && UserDefaults.lyricsOptions.romanization)
    
    lyricsState.loadedSuccessfully = true

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}

/// Extracts the Spotify track ID from a `/color-lyrics/v2/track/{trackId}` URL path.
/// Returns nil if the path doesn't match the expected format.
/// Handles both regular Spotify track IDs and local file URIs (spotify:local:...).
func extractTrackId(from path: String) -> String? {
    // Try local track URI first (spotify:local:artist:title:duration)
    // Match everything after "/track/" to end of path so slashes in
    // artist/title don't truncate the captured URI.
    if let regex = try? NSRegularExpression(pattern: #"/track/(spotify:local:.*)$"#),
       let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
       let trackRange = Range(match.range(at: 1), in: path) {
        let trackId = String(path[trackRange])
        if !trackId.isEmpty {
            writeDebugLog("[Lyrics] extractTrackId: found local URI '\(trackId)'")
            return trackId
        }
    }
    // Synthetic rewrite form: /track/spotify:track:local<hex> (the synthetic
    // URI may be percent-decoded into the path by the URL builder). Strip the
    // scheme so the guard compares the bare synthetic id against the rendered
    // key instead of a degenerate "spotify" fragment.
    if let regex = try? NSRegularExpression(pattern: #"/track/spotify:track:([a-zA-Z0-9]+)"#),
       let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
       let idRange = Range(match.range(at: 1), in: path) {
        let id = String(path[idRange])
        if !id.isEmpty {
            writeDebugLog("[Lyrics] extractTrackId: synthetic id '\(id)'")
            return id
        }
    }
    // Standard Spotify track ID
    guard let range = path.range(of: #"/track/([a-zA-Z0-9]+)"#, options: .regularExpression) else {
        writeDebugLog("[Lyrics] extractTrackId: no match in path '\(path)'")
        return nil
    }
    let trackId = String(path[range].split(separator: "/").last ?? "")
    if trackId.isEmpty { writeDebugLog("[Lyrics] extractTrackId: empty match in '\(path)'") }
    return trackId.isEmpty ? nil : trackId
}

// Resolve the extracted color hex for a track id, using (in order) the
// metadata() dict ("extracted_color" key, set by Spotify from album art),
// the typed `extractedColorHex()` accessor on SPTPlayerTrack, then nil.
// Works on 9.1.x (both normal and local tracks) without depending on the
// backgroundViewModel — which can be nil on the NPVScrollV2ViewController
// path.
func resolvedTrackExtractedColor(for trackId: String) -> String? {
    guard let track = statefulPlayer?.currentTrack() else { return nil }
    let nsTrack = track as AnyObject
    // 1) metadata()["extracted_color"] — the canonical source the upstream
    // EeveeSpotify uses, set server-side from album art analysis. metadata()
    // is swizzled by SPTPlayerTrackMetadataV91Hook on 9.1.x, but guard with
    // responds(to:) to avoid an unrecognized-selector crash if the runtime
    // class differs from the hooked one.
    let metaSel = Selector(("metadata"))
    guard nsTrack.responds(to: metaSel) else { return nil }
    let meta = track.metadata()
    if let hex = meta["extracted_color"], !hex.isEmpty {
        return hex
    }
    // 2) extractedColorHex() — convenience accessor that may be missing on
    // some builds. Guard with responds(to:) to avoid an unrecognized-selector
    // crash on 9.1.60 if the method was renamed/removed.
    let colorSel = Selector(("extractedColorHex"))
    guard nsTrack.responds(to: colorSel) else { return nil }
    if let hex = track.extractedColorHex(), !hex.isEmpty {
        return hex
    }
    return nil
}

// MARK: - Lyrics prefetch
// Holds the result of the most recently completed prefetch. It's consumed (and
// cleared) by the next getLyricsDataForCurrentTrack call for the same track. If
// the real request arrives before prefetch finishes, or is for a different
// track, the prefetch result is simply ignored — this is a best-effort handoff,
// not a general cache.
private let prefetchQueue = DispatchQueue(label: "com.eeveespotify.prefetch")
private var _prefetchedCache: [String: Data] = [:]
private var _prefetchingInFlight: Set<String> = []

private var prefetchedCache: [String: Data] {
    get { prefetchQueue.sync { _prefetchedCache } }
    set { prefetchQueue.sync { _prefetchedCache = newValue } }
}

private func storePrefetch(trackId: String, data: Data) {
    prefetchQueue.sync {
        _prefetchedCache[trackId] = data
        _prefetchingInFlight.remove(trackId)
    }
}

private func consumePrefetch(trackId: String) -> Data? {
    prefetchQueue.sync {
        guard let data = _prefetchedCache.removeValue(forKey: trackId) else { return nil }
        return data
    }
}

private func peekPrefetch(trackId: String) -> Data? {
    prefetchQueue.sync { _prefetchedCache[trackId] }
}

private func isPrefetching(trackId: String) -> Bool {
    prefetchQueue.sync { _prefetchingInFlight.contains(trackId) }
}

private func markPrefetching(trackId: String) {
    prefetchQueue.sync { _prefetchingInFlight.insert(trackId) }
}

private func finishPrefetching(trackId: String) {
    prefetchQueue.sync { _prefetchingInFlight.remove(trackId) }
}

/// Clears any pending prefetch result and cancels an in-progress prefetch.
/// Called on track change to prevent stale lyrics from leaking across songs.
func clearPrefetch() {
    prefetchQueue.sync {
        _prefetchedCache.removeAll()
        _prefetchingInFlight.removeAll()
    }
}

/// Kicks off a background lyrics fetch for `trackId` so the result is ready
/// before Spotify fires its `/color-lyrics/v2` request.
/// Safe to call multiple times — duplicate calls for the same track are ignored.
private let prefetchThrottle = DispatchQueue(label: "com.eeveespotify.prefetch.throttle", attributes: .concurrent)
private var prefetchActiveCount = 0
private let prefetchMaxConcurrent = 2

func prefetchLyricsIfNeeded(trackId: String) {
    guard UserDefaults.lyricsSource.isReplacingLyrics else { return }
    guard !trackId.isLocalOrNonSpotifyTrackId else { return }
    if prefetchedCache[trackId] != nil { return }
    if isPrefetching(trackId: trackId) { return }
    prefetchThrottle.sync(flags: .barrier) {
        guard prefetchActiveCount < prefetchMaxConcurrent else { return }
        prefetchActiveCount += 1
    }

    markPrefetching(trackId: trackId)
    writeDebugLog("[Lyrics] prefetch start for \(trackId)")

    DispatchQueue.global(qos: .userInitiated).async {
        defer {
            finishPrefetching(trackId: trackId)
            prefetchThrottle.sync(flags: .barrier) { prefetchActiveCount -= 1 }
        }
        do {
            var lyrics = try loadCustomLyricsForTrackId(trackId)

            let lyricsColorsSettings = UserDefaults.lyricsColors
            if !lyricsColorsSettings.displayOriginalColors {
                let color: Color
                if lyricsColorsSettings.useStaticColor {
                    color = Color(hex: lyricsColorsSettings.staticColor)
                } else if let extractedHex = resolvedTrackExtractedColor(for: trackId),
                          !extractedHex.isEmpty {
                    color = Color(hex: extractedHex)
                        .normalized(lyricsColorsSettings.normalizationFactor)
                } else if let uiColor = backgroundViewModel?.color() {
                    color = Color(uiColor).normalized(lyricsColorsSettings.normalizationFactor)
                } else {
                    color = Color.gray
                }
                lyrics.colors = LyricsColors.with {
                    $0.backgroundColor = color.uInt32
                    $0.lineColor = Color.black.uInt32
                    $0.activeLineColor = Color.white.uInt32
                }
            }

            if let data = try? lyrics.serializedData() {
                storePrefetch(trackId: trackId, data: data)
                writeDebugLog("[Lyrics] prefetch complete for \(trackId)")
            }
        } catch {
            writeDebugLog("[Lyrics] prefetch failed for \(trackId): \(error)")
        }
    }
}

/// Returns a serialized empty `Lyrics` protobuf payload.
/// Used as a fallback when every lyrics source (including Genius fallback) fails,
/// so we show "no lyrics" instead of leaking Spotify's own Musixmatch response.
func emptyLyricsData(originalLyrics: Lyrics? = nil) -> Data? {
    let emptyDto = LyricsDto(lines: [], timeSynced: false, romanization: .original, translation: nil)
    var lyrics = Lyrics.with {
        $0.data = emptyDto.toSpotifyLyricsData(source: "")
    }
    if let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    return try? lyrics.serializedData()
}

/// Resolves custom lyrics for the current track, keyed by the track ID extracted
/// from the `/color-lyrics/v2/track/{trackId}` URL path.
///
/// Returns `nil` (instead of empty lyrics) for real Spotify tracks that have no
/// custom lyrics, so callers fall back to Spotify's native "no lyrics" state
/// rather than showing a blank/empty lyrics UI.
///
/// For local/offline tracks, always returns a `Lyrics` protobuf (empty or not)
/// since Spotify has no native lyrics for those.
///
/// Recent fixes (2026-07):
/// - Stale lyrics on track switch: local tracks use short numeric IDs in the
///   lyrics URL that can't distinguish tracks, so we cross-check captured
///   title/artist and MPNowPlayingInfoCenter to detect track changes.
/// - Black UI for non-local tracks: return nil when no custom lyrics are found
///   for real Spotify tracks, so the hook replays Spotify's original response.
func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data? {
    writeDebugLog("[Lyrics] getLyricsDataForCurrentTrack called: path=\(originalPath)")
    
    // track id from URL path; player objects are nil on 9.1.6
    // path: /color-lyrics/v2/track/{trackId}
    var trackIdentifier = extractTrackId(from: originalPath)
    // On 9.1.x the local-track URI is rewritten so Spotify fires both
    // `color-lyrics/v2` and `scrollsita/v1/scroll` for the (rewritten) local
    // track. The rewrite used to be a bare `spotify:track:` (empty id), which
    // left the lyrics request path with no usable id; now it is a synthetic
    // track id (`spotify:track:local<17 hex>`) so the scrollsita URL is
    // valid. Each local file gets a DISTINCT synthetic id, so Spotify re-fires
    // both requests on every local->local switch instead of reusing the old
    // response (the previous constant placeholder made all local tracks look
    // identical and the lyrics card kept showing the previous song's lines).
    // The path still carries no genuine local id, so fall back to the local
    // track id captured by NPVScrollViewControllerV91Hook so the prefetch
    // (keyed by that id) lines up and the Genius/lrclib fallback can still
    // resolve the local file by title+artist.
    if let extracted = trackIdentifier {
        // On 9.1.x, local tracks use a short numeric ID in the lyrics URL
        // that isn't a real Spotify track ID. These IDs can't distinguish
        // local tracks from each other, so we cross-check captured
        // title/artist to detect track changes.
        if extracted.isEmpty || extracted == localTrackPlaceholderId || extracted.isLocalOrNonSpotifyTrackId {
            // Refresh captures from the live player track if possible —
            // captures are only written in viewWillAppear, so a track change
            // while the NPV stays visible would leave stale metadata otherwise.
            //
            // NOTE: URI() is swizzled by SPTPlayerTrackURIV91Hook, so when
            // shouldOverrideLocalTrackURI is true, URI() returns a synthetic
            // `spotify:track:local<hex>` id — spt_trackIdentifier() cannot
            // distinguish a local track from a normal one. Instead, detect a
            // local track by checking if liveId is synthetic or spotify:local:
            // (the rewrite only happens for local tracks), and detect a track
            // change by comparing title/artist (which are NOT overridden).
            if let liveTrack = statefulPlayer?.currentTrack() {
                let liveId = liveTrack.URI().spt_trackIdentifier()
                let liveTitle = liveTrack.trackTitle()
                let liveArtist = liveTrack.artistName()

                if liveId == localTrackPlaceholderId || liveId.isLocalTrackIdentifier || liveId.isSyntheticLocalTrackId {
                    // This is a local track (pre-rewrite via
                    // isLocalTrackIdentifier, or post-rewrite to a synthetic
                    // id). Refresh captures if the title/artist changed (track
                    // change while NPV stays visible).
                    if liveTitle != capturedTrackTitle || liveArtist != capturedArtistName {
                        writeDebugLog("[Lyrics] refreshing stale capture for track change: title=\(liveTitle) artist=\(liveArtist)")
                        // Prefer the genuine local id if available (pre-rewrite);
                        // otherwise fall back to the placeholder id —
                        // loadCustomLyricsForTrackId treats both as local.
                        let realId = liveId.isLocalTrackIdentifier || liveId.isSyntheticLocalTrackId
                            ? liveId
                            : localTrackPlaceholderId
                        capturedTrackId = realId
                        capturedTrackTitle = liveTitle
                        capturedArtistName = liveArtist
                        trackIdentifier = realId
                        // Clear stale prefetch from previous track. The lyric
                        // card rebuild itself is left to the delivery-time
                        // reload in the URLSession hooks — it fires after the
                        // fresh payload is injected into the diffable data
                        // source, whereas a reload here would re-render the
                        // previous track's composition before the new payload
                        // exists.
                        clearPrefetch()
                    } else if let captured = capturedTrackId, !captured.isEmpty, captured != trackIdentifier {
                        // BUG FIX: Title/artist match but URL ID differs from captured
                        // ID (numeric local ID vs the synthetic/placeholder id).
                        // Sync trackIdentifier so loadCustomLyricsForTrackId uses
                        // the captured ID that Genius/lrclib can actually resolve.
                        trackIdentifier = captured
                    } else if let captured = capturedTrackId, !captured.isEmpty {
                        trackIdentifier = captured
                    }
                } else if let captured = capturedTrackId, !captured.isEmpty {
                    trackIdentifier = captured
                }
            } else {
                // statefulPlayer unavailable — try NowPlayingInfoCenter to
                // detect a track change (all local tracks share the same
                // numeric id in the URL, so without this check we'd reuse
                // stale metadata from the previous local track).
                var npTitle: String?
                var npArtist: String?
                if Thread.isMainThread {
                    npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                    npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
                } else {
                    DispatchQueue.main.sync {
                        npTitle = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
                        npArtist = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String
                    }
                }
                if let t = npTitle, let a = npArtist, !t.isEmpty, !a.isEmpty,
                   t != capturedTrackTitle || a != capturedArtistName {
                    writeDebugLog("[Lyrics] refreshing stale capture via NowPlayingInfo: title=\(t) artist=\(a)")
                    capturedTrackTitle = t
                    capturedArtistName = a
                    // BUG FIX: Local tracks use short numeric IDs in the URL that
                    // can't distinguish tracks, so update trackIdentifier to the
                    // placeholder id to prevent stale lyrics from the previous track.
                    capturedTrackId = localTrackPlaceholderId
                    trackIdentifier = localTrackPlaceholderId
                    // Clear stale prefetch from previous track. The lyric
                    // card rebuild itself is left to the delivery-time
                    // reload in the URLSession hooks — it fires after the
                    // fresh payload is injected into the diffable data
                    // source, whereas a reload here would re-render the
                    // previous track's composition before the new payload
                    // exists.
                    clearPrefetch()
                }
                if let captured = capturedTrackId, !captured.isEmpty {
                    trackIdentifier = captured
                }
            }
        }
    } else if let captured = capturedTrackId, !captured.isEmpty {
        writeDebugLog("[Lyrics] extractTrackId nil; falling back to capturedTrackId=\(captured)")
        trackIdentifier = captured
    }
    guard let trackIdentifier = trackIdentifier, !trackIdentifier.isEmpty else {
        throw LyricsError.noCurrentTrack
    }

    // See the comment on updateTrackIdFromLyricsFetch itself for why this is
    // here: on builds where KaraokePlaybackTracker's usual player-observer
    // registration fails, this is the only reliable source it has for the
    // current track ID, and this call site fires on every real track change
    // regardless of that.
    KaraokePlaybackTracker.shared.updateTrackIdFromLyricsFetch(trackIdentifier)

    // If the identifier is still the placeholder (capture never ran and no
    // live track was available), treat it as local so loadCustomLyricsForTrackId
    // forces Genius and doesn't try a provider that needs a real Spotify id.
    // A synthetic id is also treated as local (the rewrite yields a
    // Spotify-looking id; only the isSyntheticLocalTrackId prefix flags it).
    let isLocalOrSyntheticTrack = trackIdentifier == localTrackPlaceholderId
        || trackIdentifier.isLocalTrackIdentifier
        || trackIdentifier.isSyntheticLocalTrackId

    // Only clear captures when we've genuinely resolved to a different REAL
    // Spotify track. The synthetic id the rewrite yields looks like a real
    // Spotify id but is caught by isSyntheticLocalTrackId, so without this
    // guard the captures (title/artist that Genius needs for the local file)
    // would be wiped on every lyrics fetch for a local track.
    if !isLocalOrSyntheticTrack,
       !trackIdentifier.isLocalOrNonSpotifyTrackId,
       capturedTrackId != trackIdentifier {
        capturedTrackTitle = nil
        capturedArtistName = nil
        capturedTrackId = nil
    }

    // Use a prefetched result if one finished in time for this track.
    let canUsePrefetch = !UserDefaults.lyricsColors.displayOriginalColors
    if canUsePrefetch, let data = consumePrefetch(trackId: trackIdentifier) {
        writeDebugLog("[Lyrics] using prefetched result for \(trackIdentifier)")
        return data
    }

    // Bounded wait around the synchronous fallback fetch, specifically
    // because a track stuck "queued" (503) on SpicyLyrics has a retry loop
    // (performQuery) that can legitimately run for up to ~26s — and this
    // function runs on whatever thread Spotify itself calls it from, not a
    // background one. Without a bound, skipping through several
    // back-to-back queued tracks could each block that thread for a long
    // stretch, one after another. This is the leading theory for lyrics
    // "breaking" after rapid skipping and needing an app restart to
    // recover — a real, reachable blocking path — though I don't have a
    // direct log capture of that exact failure to confirm the mechanism
    // beyond this.
    //
    // The underlying fetch keeps running in the background past the
    // timeout — its result still reaches KaraokeLyricsStore (and, via
    // whatever the next prefetch/fetch for the same track does,
    // prefetchedResult) through loadCustomLyricsForTrackId itself; only
    // THIS caller stops waiting on it. A slow fetch isn't wasted, it's just
    // no longer something Spotify's own thread sits through.
    let fallbackTimeout: TimeInterval = 4.0
    let semaphore = DispatchSemaphore(value: 0)
    var fetchedLyrics: Lyrics?
    var fetchedError: Error?
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            fetchedLyrics = try loadCustomLyricsForTrackId(trackIdentifier)
        } catch {
            fetchedError = error
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + fallbackTimeout) == .success else {
        writeDebugLog("[Lyrics] synchronous fetch for \(trackIdentifier) exceeded \(fallbackTimeout)s — falling through without waiting further")
        throw LyricsError.noSuchSong
    }
    if let fetchedError = fetchedError {
        throw fetchedError
    }
    guard var lyrics = fetchedLyrics else {
        throw LyricsError.noSuchSong
    }

    // (local) A fresh API call may come back degraded — e.g. SpicyLyrics
    // answered the same track with a full Syllable result to the prefetch
    // but a short Static response to the real request, which parses to zero
    // lines. Prefer whichever candidate has more lines.
    if let prefetchedData = peekPrefetch(trackId: trackIdentifier),
       let prefetchedLyrics = try? Lyrics(serializedBytes: prefetchedData),
       prefetchedLyrics.data.lines.count > lyrics.data.lines.count {
        writeDebugLog("[Lyrics] preferring richer prefetched result for \(trackIdentifier): prefetch=\(prefetchedLyrics.data.lines.count) fresh=\(lyrics.data.lines.count)")
        _ = consumePrefetch(trackId: trackIdentifier)
        lyrics = prefetchedLyrics
    }

    // (local) For real Spotify tracks with no custom lyrics, return nil so
    // the hook falls through to Spotify's original response instead of
    // delivering an empty object (black/empty lyrics UI).
    let isLocalTrack = trackIdentifier.isLocalOrNonSpotifyTrackId || isLocalOrSyntheticTrack
    if !isLocalTrack, lyrics.data.lines.isEmpty {
        writeDebugLog("[Lyrics] No custom lyrics for Spotify track \(trackIdentifier); falling through to original")
        return nil
    }

    let lyricsColorsSettings = UserDefaults.lyricsColors
    
    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        lyrics.colors = originalLyrics.colors
    }
    else {
        var color: Color
        
        if lyricsColorsSettings.useStaticColor {
            color = Color(hex: lyricsColorsSettings.staticColor)
        }
        else if let extractedHex = resolvedTrackExtractedColor(for: trackIdentifier),
                !extractedHex.isEmpty {
            color = Color(hex: extractedHex)
                .normalized(lyricsColorsSettings.normalizationFactor)
        }
        else if let uiColor = backgroundViewModel?.color() {
            color = Color(uiColor)
                .normalized(lyricsColorsSettings.normalizationFactor)
        }
        else {
            color = Color.gray
        }
        
        lyrics.colors = LyricsColors.with {
            $0.backgroundColor = color.uInt32
            $0.lineColor = Color.black.uInt32
            $0.activeLineColor = Color.white.uInt32
        }
    }
    
    return try lyrics.serializedData()
}

// On a local->local switch the synthetic id makes Spotify re-fire scrollsita,
// but if scrollsita returns no content for the new id (500), the now-playing
// collection retains the previous track's lyric card composition, so the
// freshly injected color-lyrics payload never reaches the screen. Force the
// lyric card item to reload through the diffable data source (plain
// collectionView().reloadData() is a no-op on diffable-backed collections,
// and the HideOnError V1 path is unusable on 9.1.68 because scrollDataSource
// is never populated there). FLEX on 9.1.68 showed the diffable wrapper's
// `_impl` ivar is nil, so the real __UIDiffableDataSource is reached via the
// `_diffableDataSourceImpl` accessor, and its item identifiers are opaque
// Element_List.ItemIdentifier values (not provider instances). FLEX
// (visibleCells -> indexPathsForVisibleItems) verified the lyric card
// (`Lyrics_CardElementImpl.CardView`) is diffable item 0, so only that item
// is reloaded.
private func nowPlayingCollectionView(from controller: NPVScrollViewController) -> UICollectionView? {
    let controllerObject = Dynamic.convert(controller, to: NSObject.self)
    if controllerObject.responds(to: Selector("collectionView")) {
        return controller.collectionView()
    }
    let viewController = Dynamic.convert(controller, to: UIViewController.self)
    return firstCollectionView(in: viewController.view)
}

private func firstCollectionView(in view: UIView?) -> UICollectionView? {
    guard let view = view else { return nil }
    if let collectionView = view as? UICollectionView {
        return collectionView
    }
    for subview in view.subviews {
        if let found = firstCollectionView(in: subview) {
            return found
        }
    }
    return nil
}

func reloadNowPlayingCollectionForLocalSwitch() {
    guard let controller = npvScrollViewController else {
        writeDebugLog("[Lyrics] reloadNowPlayingCollectionForLocalSwitch skipped: npvScrollViewController is nil")
        return
    }
    let reload = {
        guard let collectionView = nowPlayingCollectionView(from: controller) else {
            writeDebugLog("[Lyrics] reload skipped: no collectionView on \(NSStringFromClass(type(of: controller)))")
            return
        }
        guard let dataSource = collectionView.dataSource else {
            writeDebugLog("[Lyrics] reload skipped: dataSource unavailable")
            return
        }

        let dataSourceClassName = NSStringFromClass(type(of: dataSource))
        guard dataSourceClassName.contains("Diffable") else {
            writeDebugLog("[Lyrics] reload skipped: dataSource is \(dataSourceClassName), not diffable-backed")
            return
        }

        guard let dataSourceObject = dataSource as? NSObject,
              let impl = dataSourceObject.perform(NSSelectorFromString("_diffableDataSourceImpl"))?.takeUnretainedValue() as? NSObject else {
            writeDebugLog("[Lyrics] reload skipped: _diffableDataSourceImpl unavailable")
            return
        }

        guard let itemIdentifiers = impl.perform(NSSelectorFromString("itemIdentifiers"))?.takeUnretainedValue() as? NSArray,
              itemIdentifiers.count > 0 else {
            writeDebugLog("[Lyrics] reload skipped: no diffable items to reload")
            return
        }

        let lyricIdentifier = itemIdentifiers[0]

        writeDebugLog("[Lyrics] diffable identifiers (\(itemIdentifiers.count)): \(itemIdentifiers)")
        impl.perform(NSSelectorFromString("reloadItemsWithIdentifiers:"), with: [lyricIdentifier])
        writeDebugLog("[Lyrics] reloaded lyric item (index 0) for local switch")
    }
    if Thread.isMainThread {
        reload()
    } else {
        DispatchQueue.main.async(execute: reload)
    }
}

/// True when the lyrics URL path carries a local/synthetic/placeholder track id,
/// i.e. a local-file lyrics request whose injected payload needs a forced
/// collection reload to reach the screen.
func isLocalLyricsRequestPath(_ path: String) -> Bool {
    guard let id = extractTrackId(from: path) else { return false }
    return id.isEmpty || id == localTrackPlaceholderId || id.isLocalOrNonSpotifyTrackId
}

/// Canonical identity for a lyrics track key: a real `spotify:local:` URI and
/// its synthetic rewrite hash to the SAME synthetic id, so comparisons can't
/// misfire just because one side saw the pre-rewrite URI and the other the
/// rewritten one. A `spotify:track:` scheme is stripped unconditionally — the
/// scheme carries no identity, and spt_trackIdentifier() returns
/// scheme-prefixed values for normal tracks too, so without the strip the
/// player-fallback branch of currentTrackIdentityKey() would mismatch the bare
/// path-extracted id. Normal (non-local) keys pass through unchanged.
func normalizedLyricsIdentity(_ key: String) -> String {
    if key.isLocalTrackIdentifier {
        return localTrackSyntheticId(from: key)
    }
    if key.hasPrefix("spotify:track:") {
        return String(key.dropFirst("spotify:track:".count))
    }
    return key
}

/// Stale-lyrics delivery check for the guard sites in the URLSession hooks.
///
/// Returns true only when we can PROVE the fetch belongs to a different track
/// than the one currently rendered. Crucially:
/// - A nil/empty current key is NOT stale for local requests. On 9.1.x
///   statefulPlayer is often nil and uiRenderedTrackKey is only set once the
///   scrollsita render runs the URI override — a color-lyrics response landing
///   before that must still deliver, otherwise local lyrics are dropped
///   outright (the "sometimes works" race). Non-local requests keep the old
///   behavior (nil current key drops), since the normal-track path always has a
///   rendered key in practice.
/// - Identities are compared in normalized form: the pre-rewrite
///   `spotify:local:` URI, the bare synthetic id, and the scheme-prefixed
///   synthetic all collapse to the bare synthetic id, so matching files always
///   compare equal and scheme-prefixed keys can't slip a stale delivery past
///   the per-file classification.
/// - The strong-identity leniency below is LOCAL-ONLY. Non-local requests drop
///   unconditionally on mismatch (a normal track's current key is always a
///   strong 22-char id, so the strict drop never discards a valid delivery and
///   only removes stale ones). For local requests, only STRONG identities can
///   prove staleness: a per-file local form (spotify:local: URI or synthetic
///   id) or a real catalog id (just as unique). Weak keys — short numeric ids
///   (e.g. /track/173) and the constant placeholder — are ambiguous across
///   local files, so a mismatch against them proves nothing; the fetch pipeline
///   resolves to the live track by title/artist anyway (see
///   getLyricsDataForCurrentTrack), so dropping would discard a payload
///   computed for the track actually playing.
func isStaleLyricsDelivery(fetchTrackKey: String?, path: String) -> Bool {
    let isLocalRequest = isLocalLyricsRequestPath(path)
    guard let fetchKey = fetchTrackKey, !fetchKey.isEmpty else { return false }
    guard let currentKey = currentTrackIdentityKey(), !currentKey.isEmpty else {
        return !isLocalRequest
    }
    let normalizedFetchKey = normalizedLyricsIdentity(fetchKey)
    let normalizedCurrentKey = normalizedLyricsIdentity(currentKey)
    if normalizedFetchKey == normalizedCurrentKey {
        return false
    }
    if !isLocalRequest {
        return true
    }
    return normalizedFetchKey.isStrongLyricsIdentity
        && normalizedCurrentKey.isStrongLyricsIdentity
}

/// Settle-aware delivery gate, layered on top of isStaleLyricsDelivery.
///
/// Once the now-playing carousel has settled (drag begin/end callbacks in
/// NPVScrollViewControllerURIHook), uiRenderedTrackKey is stable and identifies
/// the ACTIVE card, so a lyrics fetch for any other id belongs to a card that
/// scrolled away — the previous track (carry-over onto a recycled cell) or an
/// in-transit neighbor (the C0FFIN-style flash) — and must not paint.
///
/// While the carousel is mid-swipe the key flaps between cards, so this gate
/// defers to isStaleLyricsDelivery's strong-identity logic instead of dropping
/// the incoming card's own fetch. It applies the same weak-identity rule: a
/// short numeric local id or the placeholder can never prove a mismatch, so
/// those fetches are never dropped here.
func isLyricsDeliverySuperseded(fetchTrackKey: String?, path: String) -> Bool {
    guard !npvScrollMoving else { return false }
    guard let fetchKey = fetchTrackKey, !fetchKey.isEmpty else { return false }
    guard let renderedKey = uiRenderedTrackKey, !renderedKey.isEmpty else { return false }
    let normalizedFetchKey = normalizedLyricsIdentity(fetchKey)
    let normalizedRenderedKey = normalizedLyricsIdentity(renderedKey)
    if normalizedFetchKey == normalizedRenderedKey {
        return false
    }
    let isLocalRequest = isLocalLyricsRequestPath(path)
    if isLocalRequest && (!normalizedFetchKey.isStrongLyricsIdentity || !normalizedRenderedKey.isStrongLyricsIdentity) {
        return false
    }
    writeDebugLog("[Lyrics] superseded delivery dropped (settled on \(normalizedRenderedKey)): fetch=\(normalizedFetchKey)")
    return true
}

/// Stable identity for the currently rendered track, used to drop stale lyrics
/// deliveries when the user switches tracks while a lyrics fetch is in flight.
///
/// Prefers `uiRenderedTrackKey` — the id of the track the now-playing card is
/// currently rendering, captured synchronously by SPTPlayerTrackURIV91Hook.URI()
/// while Spotify builds the scrollsita / color-lyrics URLs. It updates at
/// card-render time, so unlike statefulPlayer.currentTrack() it never lags a
/// track switch (the previous caveat: player state could still report the old
/// track for a brief window, letting a stale payload slip through).
///
/// Falls back to the player track id (possibly synthetic), then title+artist,
/// then captured metadata — only for requests that never went through the URI
/// hook (e.g. a lyrics URL fired while the now-playing scroll was inactive).
func currentTrackIdentityKey() -> String? {
    if let renderedKey = uiRenderedTrackKey, !renderedKey.isEmpty {
        return renderedKey
    }
    if let track = statefulPlayer?.currentTrack() {
        let id = track.URI().spt_trackIdentifier()
        if !id.isEmpty {
            return id
        }
        let title = track.trackTitle()
        let artist = track.artistName()
        if !title.isEmpty || !artist.isEmpty {
            return "\(title)\u{0}\(artist)"
        }
    }
    if let id = capturedTrackId, !id.isEmpty {
        return id
    }
    if let title = capturedTrackTitle, let artist = capturedArtistName, !title.isEmpty {
        return "\(title)\u{0}\(artist)"
    }
    return nil
}
