import Orion
import UIKit
import MediaPlayer

// Global variables to store captured track metadata for 9.1.6
// ── START OF AI GENERATED CODE ──
// Accessed from both main thread (viewWillAppear) and background queues
// (lyrics fetch, prefetch) — all access is serialized via captureQueue.
private let captureQueue = DispatchQueue(label: "com.eeveespotify.capture")
private var _capturedTrackTitle: String?
private var _capturedArtistName: String?
private var _capturedTrackId: String?
private var _capturedTrackURI: String?
private var _capturedArtistURI: String?
private var _capturedCanvasVideoFileID: String?

var capturedTrackTitle: String? {
    get { captureQueue.sync { _capturedTrackTitle } }
    set { captureQueue.sync { _capturedTrackTitle = newValue } }
}
var capturedArtistName: String? {
    get { captureQueue.sync { _capturedArtistName } }
    set { captureQueue.sync { _capturedArtistName = newValue } }
}
var capturedTrackId: String? {
    get { captureQueue.sync { _capturedTrackId } }
    set { captureQueue.sync { _capturedTrackId = newValue } }
}
var capturedTrackURI: String? {
    get { captureQueue.sync { _capturedTrackURI } }
    set { captureQueue.sync { _capturedTrackURI = newValue } }
}
var capturedArtistURI: String? {
    get { captureQueue.sync { _capturedArtistURI } }
    set { captureQueue.sync { _capturedArtistURI = newValue } }
}
var capturedCanvasVideoFileID: String? {
    get { captureQueue.sync { _capturedCanvasVideoFileID } }
    set { captureQueue.sync { _capturedCanvasVideoFileID = newValue } }
}

func captureCanvasTrack(_ track: SPTPlayerTrack) {
    let diagnosticsEnabled = requestCanvasNowPlayingProbe()
    let uri = track.URI()
    guard let uriString = (uri as? NSURL)?.absoluteString, !uriString.isEmpty else {
        if diagnosticsEnabled {
            writeDebugLog("[CANVAS][TRACK] missing URI for \(track.trackTitle())")
        }
        return
    }

    capturedTrackURI = uriString
    let trackObject = track as AnyObject
    let artistSelector = Selector(("artistURI"))
    if trackObject.responds(to: artistSelector),
       let artistURL = trackObject.perform(artistSelector)?.takeUnretainedValue() as? NSURL {
        capturedArtistURI = artistURL.absoluteString
    }
    let metadataSelector = Selector(("spt_metadata_canvasVideoFileID"))
    if let metadata = trackObject.value(forKey: "metadata") as? NSDictionary,
       metadata.responds(to: metadataSelector),
       let fileID = metadata.perform(metadataSelector)?.takeUnretainedValue() as? String {
        capturedCanvasVideoFileID = fileID
        if diagnosticsEnabled {
            writeDebugLog("[CANVAS][TRACK] canvasFileID=\(fileID)")
        }
    }
    if diagnosticsEnabled {
        writeDebugLog("[CANVAS][TRACK] uri=\(uriString) title=\(track.trackTitle()) artist=\(track.artistName()) artistURI=\(capturedArtistURI ?? "?")")
    }
}

// Per-track metadata cache populated synchronously by SPTPlayerTrackURIV91Hook
// while the now-playing carousel renders each card, keyed by the track id that
// ends up in the color-lyrics URL (the synthetic id for local files, the real
// id for normal tracks). Because that URL can only carry an id URI() itself
// produced, a lookup keyed by the URL-extracted id is guaranteed to hit, so
// loadCustomLyricsForTrackId can always search with the requested track's OWN
// title/artist instead of a global slot left over from the previous track's
// fetch (the source of stale lyrics on fast switches). Bounded: evicts an
// arbitrary entry when full — a miss degrades to the existing fallbacks, never
// to a wrong result.
private let trackMetadataCacheQueue = DispatchQueue(label: "com.eeveespotify.trackMetadataCache")
private var _trackMetadataCache: [String: (title: String, artist: String)] = [:]
private let trackMetadataCacheLimit = 128

func captureTrackMetadata(id: String, title: String, artist: String) {
    guard !id.isEmpty, !title.isEmpty else { return }
    trackMetadataCacheQueue.sync {
        if _trackMetadataCache[id] == nil, _trackMetadataCache.count >= trackMetadataCacheLimit {
            _trackMetadataCache.removeValue(forKey: _trackMetadataCache.keys.first!)
        }
        _trackMetadataCache[id] = (title, artist)
    }
}

func capturedTrackMetadata(forTrackId id: String) -> (title: String, artist: String)? {
    guard !id.isEmpty else { return nil }
    return trackMetadataCacheQueue.sync { _trackMetadataCache[id] }
}
// ── END OF AI GENERATED CODE ──

// Function to fetch track details using Spotify API if we have a token
func fetchTrackDetails(trackId: String, token: String) -> (title: String, artist: String)? {
    let urlString = "https://api.spotify.com/v1/tracks/\(trackId)"
    guard let url = URL(string: urlString) else { return nil }
    
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 3.0
    
    var result: (String, String)?
    let semaphore = DispatchSemaphore(value: 0)
    
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        guard let data = data, error == nil else { return }
        
        // Simple JSON parsing
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String,
           let artists = json["artists"] as? [[String: Any]],
           let firstArtist = artists.first,
           let artistName = firstArtist["name"] as? String {
            result = (name, artistName)
        }
    }
    
    task.resume()
    _ = semaphore.wait(timeout: .now() + 3.0)
    
    return result
}

// ── START OF AI GENERATED CODE ──
// Search the Spotify catalog for a track by title + artist.
// Returns the first matching Spotify track ID, or nil if no match.
// Used to resolve local files to a real track ID for SpicyLyrics.
func searchSpotifyTrack(title: String, artist: String, token: String) -> String? {
    let query = "track:\(title) artist:\(artist)"
    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    let urlString = "https://api.spotify.com/v1/search?q=\(encoded)&type=track&limit=1"
    guard let url = URL(string: urlString) else { return nil }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 5.0

    var result: String?
    let semaphore = DispatchSemaphore(value: 0)

    let task = URLSession.shared.dataTask(with: request) { data, _, error in
        defer { semaphore.signal() }

        guard let data = data, error == nil else { return }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tracks = json["tracks"] as? [String: Any],
           let items = tracks["items"] as? [[String: Any]],
           let firstItem = items.first,
           let id = firstItem["id"] as? String {
            result = id
        }
    }

    task.resume()
    _ = semaphore.wait(timeout: .now() + 5.0)

    return result
}
// ── END OF AI GENERATED CODE ──
