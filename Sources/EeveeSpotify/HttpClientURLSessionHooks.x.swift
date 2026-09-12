import Foundation
import Orion

// Sibling delegate to SPTDataLoaderService. Some regions (e.g. gae2) ship
// bootstrap / customize / PAM responses through this delegate instead — without
// hooking both, server-rendered free-tier strings slip through.
class HttpClientURLSessionHook: ClassHook<NSObject>, SpotifySessionDelegate {
    typealias Group = PremiumBootstrapGroup
    static let targetName = "Connectivity_HttpClientKit.HttpClientURLSession"

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
            writeDebugLog("[LyricsV91] scrollsita request completed (HttpClient): \(url.absoluteString) status=\(String(describing: (task.response as? HTTPURLResponse)?.statusCode)) err=\(String(describing: error))")
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

        if SpotifyResponsePatcher.consumeCustomizeTask(task.taskIdentifier) {
            orig.URLSession(session, task: task, didCompleteWithError: nil)
            return
        }

        guard error == nil, SpotifyResponsePatcher.shouldModify(url) else {
            orig.URLSession(session, task: task, didCompleteWithError: error)
            return
        }

        // ── START OF AI GENERATED CODE ──
        if url.isLyrics {
            writeDebugLog("[LyricsNet] HttpClient lyrics request: \(url.path)")
            // The body may be absent for LOCAL tracks ("Missing buffered body");
            // deliver the custom Genius payload regardless of whether the original
            // body was buffered. Fall through only when we have no custom data.
            let buffer = URLSessionHelper.shared.obtainData(for: task)
            let originalLyrics = buffer.flatMap { try? Lyrics(serializedBytes: $0) }

            let semaphore = DispatchSemaphore(value: 0)
            var customLyricsData: Data?
            let fetchTrackKey = extractTrackId(from: url.path) ?? currentTrackIdentityKey()
            DispatchQueue.global(qos: .userInitiated).async {
                customLyricsData = try? getLyricsDataForCurrentTrack(url.path, originalLyrics: originalLyrics)
                semaphore.signal()
            }
            // Wait up to the full fetch budget (see the "18s budget" comment in
            // DataLoaderServiceHooks.x.swift). This delegate queue is blocked
            // while waiting, so a budget longer than needed would stall other
            // session callbacks; 18s matches the original design and the longest
            // repository timeout (Genius may still exceed it — such fetches lose
            // the custom result and fall back below).
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

        guard let buffer = URLSessionHelper.shared.obtainData(for: task) else {
            // marked for modify but no body bytes (0-byte/early-completion/redirect).
            // Always forward completion or Spotify hangs and gets watchdog-killed.
            if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData {
                orig.URLSession(session, dataTask: task, didReceiveData: cached)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
            } else {
                // Some Spotify builds complete "modified" tasks with 0 body bytes.
                // We previously forwarded completion only, which can crash callers that
                // assume at least one didReceiveData before completion.
                writeDebugLog("[HCUS] Missing buffered body for \(url.absoluteString) (taskId=\(task.taskIdentifier))")
                orig.URLSession(session, dataTask: task, didReceiveData: Data())
                orig.URLSession(session, task: task, didCompleteWithError: error)
            }
            return
        }

        do {
            if let result = try SpotifyResponsePatcher.patch(url: url, buffer: buffer) {
                writeDebugLog("[HCUS] Patched \(result.tag.rawValue)")
                orig.URLSession(session, dataTask: task, didReceiveData: result.data)
                orig.URLSession(session, task: task, didCompleteWithError: nil)
                return
            }
            // patch() returned nil — no transform, but didReceiveData already
            // suppressed the original. Replay or consumer hangs.
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
            writeDebugLog("[LyricsV91] scrollsita response received (HttpClient): \(url.absoluteString) status=\(response.statusCode)")
        }
        // ── END OF AI GENERATED CODE ──
        if let url = task.currentRequest?.url, url.isCustomize, response.statusCode == 304,
           let cached = SpotifyResponsePatcher.cachedCustomizeData {
            guard let synthetic = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "2.0", headerFields: [:]) else {
                orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
                return
            }
            orig.URLSession(session, dataTask: task, didReceiveResponse: synthetic, completionHandler: handler)
            orig.URLSession(session, dataTask: task, didReceiveData: cached)
            SpotifyResponsePatcher.markCustomizeTaskHandled(task.taskIdentifier)
            return
        }

        guard let url = task.currentRequest?.url, url.isLyrics, response.statusCode != 200 else {
            orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: handler)
            return
        }

        // Fetch on a background queue while holding the completion handler open.
        // Calling getLyricsDataForCurrentTrack synchronously here would block the
        // delegate queue and prevent subsequent delegate callbacks from firing.
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
                DispatchQueue.main.async {
                    handler(.allow)
                    orig.URLSession(session, dataTask: task, didReceiveResponse: response, completionHandler: { _ in })
                }
                return
            }

            // Mark before delivery so didCompleteWithError can't slip in
            // between the delivery and the mark (race found in review).
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
