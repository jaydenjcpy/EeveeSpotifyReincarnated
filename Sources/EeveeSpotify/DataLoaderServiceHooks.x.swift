import Foundation
import Orion

// Bearer token captured from premium-relevant requests; reused by lyrics fetch etc.
// ── START OF AI GENERATED CODE ──
// Accessed from background delegate queues and the lyrics fetch queue — serialized.
private let tokenQueue = DispatchQueue(label: "com.eeveespotify.token")
private var _spotifyAccessToken: String?

public var spotifyAccessToken: String? {
    get { tokenQueue.sync { _spotifyAccessToken } }
    set { tokenQueue.sync { _spotifyAccessToken = newValue } }
}

/// Upper bound for one custom-lyrics fetch: repository network timeouts
/// (SpicyLyrics 15s, lrclib 10s) plus the fallback chain, matching the original
/// "18s budget" design comment. The URLSession hooks wait up to this long for
/// the background fetch before falling back to Spotify's own response; a fetch
/// that exceeds it is discarded (slow networks lose the custom result).
let lyricsFetchBudget: TimeInterval = 18
// ── END OF AI GENERATED CODE ──

// Spotify's primary URLSession delegate (wg-spclient: bootstrap, customize, PAM).
// Patching lives in SpotifyResponsePatcher so HttpClientURLSessionHook can share it.

class SPTDataLoaderServiceHook: ClassHook<NSObject>, SpotifySessionDelegate {
    typealias Group = PremiumBootstrapGroup
    static let targetName = "SPTDataLoaderService"

    func URLSession(
        _ session: URLSession,
        task: URLSessionDataTask,
        didCompleteWithError error: Error?
    ) {
        if let request = task.currentRequest,
           let headers = request.allHTTPHeaderFields,
           let auth = headers["Authorization"] ?? headers["authorization"],
           auth.hasPrefix("Bearer ") {
            let token = String(auth.dropFirst(7))
            spotifyAccessToken = token
            // TEMP DEBUG: log token shape + source URL, never the token itself.
            let dotCount = token.filter { $0 == "." }.count
            let shape = "len=\(token.count) dots=\(dotCount) prefix=\(token.prefix(6))"
            writeDebugLog("[TokenCapture] \(shape) from \(task.currentRequest?.url?.absoluteString ?? "<no url>")")
        }

        guard let url = task.currentRequest?.url else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        // ── START OF AI GENERATED CODE ──
        // If didReceiveResponse already fully delivered custom lyrics (4xx/5xx
        // path), suppress the redundant didCompleteWithError re-delivery.
        if SpotifyResponsePatcher.consumeLyricsTask(task.taskIdentifier) {
            return
        }

        if url.isScrollsita, shouldOverrideLocalTrackURI {
            writeDebugLog("[LyricsV91] scrollsita request completed: \(url.absoluteString) status=\(String(describing: (task.response as? HTTPURLResponse)?.statusCode)) err=\(String(describing: error))")
        }
        // ── END OF AI GENERATED CODE ──

        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.flush(task, url: url)
        }

        if SpotifyResponsePatcher.shouldBlock(url) {
            orig.URLSession(session, dataTask: task, didReceiveData: SpotifyResponsePatcher.blockedResponseData(for: url))
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        // 304 already served — suppress the second completion.
        if SpotifyResponsePatcher.consumeCustomizeTask(task.taskIdentifier) {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        guard error == nil, SpotifyResponsePatcher.shouldModify(url) else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        let buffer = URLSessionHelper.shared.obtainData(for: task)

        // ── START OF AI GENERATED CODE ──
        // Lyrics — deliver custom payload even when the buffered original body is nil
        // (local tracks may not buffer a body). Async fetch with 18s budget, falls back
        // to Spotify's own response on failure.
        //
        // iOS 27 / Spotify 9.1.60 fix: Spotify's URLSession delegate handler for
        // didReceiveData now accesses @MainActor-isolated state. When we call orig.*
        // from the SPTDataLoaderService delegate queue (a background serial queue),
        // Swift's strict concurrency runtime trips _swift_task_checkIsolatedSwift and
        // kills the process with EXC_BREAKPOINT / SIGTRAP.
        //
        // Fix: dispatch the orig.URLSession calls onto the main queue.
        if url.isLyrics {
            writeDebugLog("[LyricsNet] SPTDataLoader lyrics request: \(url.path)")
            let originalLyrics = buffer.flatMap { try? Lyrics(serializedBytes: $0) }

            let semaphore = DispatchSemaphore(value: 0)
            var customLyricsData: Data?
            let fetchTrackKey = extractTrackId(from: url.path) ?? currentTrackIdentityKey()

            DispatchQueue.global(qos: .userInitiated).async {
                customLyricsData = try? getLyricsDataForCurrentTrack(url.path, originalLyrics: originalLyrics)
                semaphore.signal()
            }

            // Wait for the background fetch up to the full fetch budget. The
            // fetch runs on its own thread, but this delegate queue is blocked
            // while we wait, so a budget longer than needed would stall other
            // session callbacks; 18s matches the original "18s budget" design
            // and the longest repository timeout (Genius may still exceed it —
            // such fetches lose the custom result and fall back below).
            _ = semaphore.wait(timeout: .now() + .milliseconds(Int(lyricsFetchBudget * 1000)))
            // Drop the payload if the user switched tracks while the fetch was
            // in flight — delivering it would paste the previous track's lyrics
            // into the now-playing card ("carry-over" race). Local-aware: a nil
            // current key (9.1.x player absent / URI override not yet rendered)
            // or matching synthetic identity does NOT count as stale.
            let trackChanged = isStaleLyricsDelivery(fetchTrackKey: fetchTrackKey, path: url.path)
                || isLyricsDeliverySuperseded(fetchTrackKey: fetchTrackKey, path: url.path)
            if trackChanged {
                writeDebugLog("[Lyrics] stale lyrics delivery dropped (track changed during fetch): \(url.path)")
            }
            let lyricsPayload: Data
            if !trackChanged, let customLyricsData = customLyricsData {
                lyricsPayload = customLyricsData
            } else if UserDefaults.lyricsSource.isReplacingLyrics {
                // Custom source selected but no custom lyrics landed (fetch
                // timed out, source found nothing, or the delivery went stale).
                // Deliver an empty payload so Spotify's native Musixmatch
                // lyrics don't leak through; originalLyrics carries the native
                // colors. Replacing the bare Data() fallback also guarantees a
                // valid protobuf instead of raw empty bytes.
                lyricsPayload = emptyLyricsData(originalLyrics: originalLyrics) ?? buffer ?? Data()
            } else {
                // Spotify source — pass the native response through unchanged.
                lyricsPayload = buffer ?? Data()
            }
            DispatchQueue.main.async { [self] in
                orig.URLSession(session, dataTask: task, didReceiveData: lyricsPayload)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                // Reload the lyric card item for local paths even when the
                // payload was dropped as stale — otherwise a local->local
                // switch whose own request fails (500-scrollsita) leaves the
                // previous track's composition in the diffable data source.
                if isLocalLyricsRequestPath(url.path) {
                    reloadNowPlayingCollectionForLocalSwitch()
                }
            }
            return
        }
        // ── END OF AI GENERATED CODE ──

        guard let buffer = buffer else {
            // Customize 304 fallback — wg-spclient returned 304, no buffer
            // to patch, but we have a cached body from a prior 200.
            if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData {
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            } else {
                // Some Spotify builds complete "modified" tasks with 0 body bytes.
                // Forwarding completion only can crash consumers that assume at least
                // one didReceiveData callback before completion.
                writeDebugLog("[DL] Missing buffered body for \(url.absoluteString) (taskId=\(task.taskIdentifier))")
                orig.URLSession(session, dataTask: task, didReceiveData: Data())
                // Always forward completion; otherwise Spotify may hang and get watchdog-killed.
                orig.URLSession(session, task: task, didCompleteWithError: error)
            }
            return
        }

        do {
            if let result = try SpotifyResponsePatcher.patch(url: url, buffer: buffer) {
                writeDebugLog("[DL] Patched \(result.tag.rawValue)")
                orig.URLSession(session, dataTask: task, didReceiveData: result.data)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            // patch() returned nil but didReceiveData already suppressed the original —
            // replay the buffer or the consumer hangs (casita/browsita with no ad sections).
            orig.URLSession(session, dataTask: task, didReceiveData: buffer)
            orig.URLSession(session, task: task, didCompleteWithError: nil)
        } catch {
            orig.URLSession(session, task: task, didCompleteWithError: error)
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveResponse response: HTTPURLResponse,
        completionHandler handler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        // ── START OF AI GENERATED CODE ──
        if let url = task.currentRequest?.url, url.isScrollsita, shouldOverrideLocalTrackURI {
            writeDebugLog("[LyricsV91] scrollsita response received: \(url.absoluteString) status=\(response.statusCode)")
        }
        // ── END OF AI GENERATED CODE ──
        if let url = task.currentRequest?.url, url.isCustomize, response.statusCode == 304,
           let cached = SpotifyResponsePatcher.cachedCustomizeData {
            // 304, but our cache holds the already-patched body; force 200 so the
            // consumer accepts the cached data we replay next.
            guard let synthetic = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
                return
            }
            orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic, completionHandler: handler)
            orig.URLSession(session, dataTask: task, didReceiveData: cached)
            SpotifyResponsePatcher.markCustomizeTaskHandled(task.taskIdentifier)
            return
        }

        // Lyrics 4xx/5xx — replace with our custom fetch result so the
        // consumer doesn't show "no lyrics available".
        //
        // IMPORTANT: getLyricsDataForCurrentTrack is a blocking network call.
        // Calling it synchronously here deadlocks because this delegate queue is
        // also needed to deliver subsequent delegate callbacks (didReceiveData,
        // didCompleteWithError). The fix is to fetch on a background queue while
        // holding the URLSession completion handler open — URLSession won't
        // proceed until we call handler(.allow/.cancel), so we have time to fetch
        // and then deliver everything ourselves.
        guard let url = task.currentRequest?.url, url.isLyrics, response.statusCode != 200 else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // ── START OF AI GENERATED CODE ──
            let fetchTrackKey = extractTrackId(from: url.path) ?? currentTrackIdentityKey()
            let data = try? getLyricsDataForCurrentTrack(url.path)
            // Drop stale 4xx-path deliveries when the user switched tracks
            // while the fetch was in flight (same carry-over race as the
            // didCompleteWithError path). Local-aware, see isStaleLyricsDelivery.
            let trackChanged = isStaleLyricsDelivery(fetchTrackKey: fetchTrackKey, path: url.path)
                || isLyricsDeliverySuperseded(fetchTrackKey: fetchTrackKey, path: url.path)
            if trackChanged {
                writeDebugLog("[Lyrics] stale 4xx lyrics delivery dropped (track changed during fetch): \(url.path)")
            }

            guard let lyricsData = data, !trackChanged,
                  let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                // Fetch failed or went stale — let Spotify handle the original
                // non-200 response. Deliver on main to match Spotify's
                // @MainActor delegate context.
                DispatchQueue.main.async {
                    handler(.allow)
                    orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: { _ in })
                }
                return
            }

            writeDebugLog("[DL] Delivering custom lyrics for local track")
            SpotifyResponsePatcher.markLyricsTaskHandled(task.taskIdentifier)
            DispatchQueue.main.async { [self] in
                orig.URLSession(session, dataTask: task, didReceiveResponse: ok, completionHandler: handler)
                orig.URLSession(session, dataTask: task, didReceiveData: lyricsData)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                if isLocalLyricsRequestPath(url.path) {
                    reloadNowPlayingCollectionForLocalSwitch()
                }
            }
            // ── END OF AI GENERATED CODE ──
        }
    }

    func URLSession(
        _ session: URLSession,
        dataTask task: URLSessionDataTask,
        didReceiveData data: Data
    ) {
        guard let url = task.currentRequest?.url else { return }

        // Suppress original data for endpoints we'll replace in
        // didCompleteWithError — otherwise the consumer sees both.
        if SpotifyResponsePatcher.shouldBlock(url) { return }
        if CasitaResponseProbe.shouldProbe(url) {
            CasitaResponseProbe.append(data, for: task)
        }
        if SpotifyResponsePatcher.shouldModify(url) {
            URLSessionHelper.shared.setOrAppend(data, for: task)
            return
        }
        orig.URLSession(session, dataTask: task, didReceiveData: data)
    }
}
