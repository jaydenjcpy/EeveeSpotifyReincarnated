import Foundation
import Orion
import MediaPlayer
import UIKit
import AVFoundation

// ── START OF AI GENERATED CODE ──
struct CanvasPublisherGroup: HookGroup {}

private var canvasObservedFileIDs: Set<String> = []
private let canvasObservedFileIDsLock = NSLock()

class CanvasMetadataFileIDHook: ClassHook<NSObject> {
    typealias Group = CanvasPublisherGroup
    static let targetName = "NSDictionary"

    func spt_metadata_canvasVideoFileID() -> NSObject? {
        let result = orig.spt_metadata_canvasVideoFileID()
        if let fileID = result as? String {
            canvasObservedFileIDsLock.lock()
            let isNew = canvasObservedFileIDs.insert(fileID).inserted
            canvasObservedFileIDsLock.unlock()
            if isNew {
                writeDebugLog("[CANVAS][META] observed canvas fileID=\(fileID)")
            }
        }
        return result
    }
}

// Runtime probe: captures where Spotify actually places canvas video files on
// disk. Static analysis (class dump + binary strings) could not pin the
// downloader's cacheDirectory, so we observe every file move/copy and every
// URLSession download completion that lands a video file and log the
// destination path. One test cycle reveals the true location.
private let canvasVideoExtensions: Set<String> = ["mp4", "m4v", "mov"]

private func logCanvasVideoPath(_ url: URL, source: String) {
    guard canvasVideoExtensions.contains(url.pathExtension.lowercased()) else { return }
    writeDebugLog("[CANVAS][PROBE] \(source) -> \(url.path)")
}

class CanvasDownloadTaskProbeHook: ClassHook<NSObject> {
    typealias Group = CanvasPublisherGroup
    static let targetName = "NSURLSession"

    func downloadTaskWithRequest(_ request: URLRequest) -> NSObject {
        let task = orig.downloadTaskWithRequest(request)
        if let url = request.url {
            writeDebugLog("[CANVAS][PROBE] download started: \(url.absoluteString)")
        }
        return task
    }

    func downloadTaskWithRequest(
        _ request: URLRequest,
        completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void
    ) -> NSObject {
        let wrapped: (URL?, URLResponse?, Error?) -> Void = { location, response, error in
            if let location = location {
                logCanvasVideoPath(location, source: "download completion")
            }
            completionHandler(location, response, error)
        }
        if let url = request.url {
            writeDebugLog("[CANVAS][PROBE] download(handler) started: \(url.absoluteString)")
        }
        return orig.downloadTaskWithRequest(request, completionHandler: wrapped)
    }
}

private let canvasKey3x4 = "MPNowPlayingInfoProperty3x4AnimatedArtwork"
private let canvasKey1x1 = "MPNowPlayingInfoProperty1x1AnimatedArtwork"

private let canvasAnimatedKey: String? = {
    guard MPNowPlayingInfoCenter.responds(to: Selector(("supportedAnimatedArtworkKeys"))) else { return nil }
    guard let keys = MPNowPlayingInfoCenter.perform(Selector(("supportedAnimatedArtworkKeys")))?.takeUnretainedValue()
        as? [String] else { return nil }
    if keys.contains(canvasKey3x4) { return canvasKey3x4 }
    if keys.contains(canvasKey1x1) { return canvasKey1x1 }
    return keys.first
}()

private let canvasVideoSupported: Bool = canvasAnimatedKey != nil

private var canvasAnimatedAspect: CGFloat {
    canvasAnimatedKey == canvasKey1x1 ? 1.0 : 0.75
}

private let canvasPublishQueue = DispatchQueue(label: "com.eeveespotify.canvas.publish")
private var _canvasURI: String?
private var _canvasVideoURL: URL?
private var _canvasArtworkBox: AnyObject?
private var _canvasPreviewImage: UIImage?
private var _canvasScanStart: Date?
private var _canvasResolving = false
private var _lastScanAttempt: Date = .distantPast
private var _canvasResolvedSources: [String: URL] = [:]

private let canvasScanWindow: TimeInterval = 600
private let canvasScanThrottle: TimeInterval = 5

private var canvasURI: String? {
    get { canvasPublishQueue.sync { _canvasURI } }
    set { canvasPublishQueue.sync { _canvasURI = newValue } }
}
private var canvasVideoURL: URL? {
    get { canvasPublishQueue.sync { _canvasVideoURL } }
    set { canvasPublishQueue.sync { _canvasVideoURL = newValue } }
}
private var canvasArtworkBox: AnyObject? {
    get { canvasPublishQueue.sync { _canvasArtworkBox } }
    set { canvasPublishQueue.sync { _canvasArtworkBox = newValue } }
}
private var canvasPreviewImage: UIImage? {
    get { canvasPublishQueue.sync { _canvasPreviewImage } }
    set { canvasPublishQueue.sync { _canvasPreviewImage = newValue } }
}
private var canvasScanStart: Date? {
    get { canvasPublishQueue.sync { _canvasScanStart } }
    set { canvasPublishQueue.sync { _canvasScanStart = newValue } }
}
private var canvasRepushing = false
private var canvasResolving: Bool {
    get { canvasPublishQueue.sync { _canvasResolving } }
    set { canvasPublishQueue.sync { _canvasResolving = newValue } }
}
private var lastScanAttempt: Date {
    get { canvasPublishQueue.sync { _lastScanAttempt } }
    set { canvasPublishQueue.sync { _lastScanAttempt = newValue } }
}
private var canvasResolvedSources: [String: URL] {
    get { canvasPublishQueue.sync { _canvasResolvedSources } }
    set { canvasPublishQueue.sync { _canvasResolvedSources = newValue } }
}

private func findCanvasVideoFile(modifiedSince cutoff: Date, excluding pinnedPaths: Set<String>) -> URL? {
    let fm = FileManager.default
    var roots: [URL] = []
    roots.append(URL(fileURLWithPath: NSTemporaryDirectory()))
    roots.append(contentsOf: fm.urls(for: .cachesDirectory, in: .userDomainMask))
    roots.append(contentsOf: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask))

    let artistID = capturedArtistURI?.split(separator: ":").last.map(String.init)
    var fileIDMatch: (mod: Date, url: URL)?
    var artistMatch: (mod: Date, url: URL)?
    var newestRecent: (mod: Date, url: URL)?
    var inspected = 0
    for root in roots {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { continue }
        while let item = enumerator.nextObject() {
            inspected += 1
            if inspected > 30000 { break }
            guard let url = item as? URL else { continue }
            if url.lastPathComponent.hasPrefix("canvas_") { continue }
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            guard canvasVideoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            // Skip files that were already pinned to a different (still-tracked) track.
            // Without this, a fast skip / gapless prefetch can make the adjacent track's
            // cache file look like "the newest one" for the track we're currently resolving.
            if pinnedPaths.contains(url.path) { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let mod = values.contentModificationDate else { continue }
            let name = url.lastPathComponent
            let isCanvasCache = name.contains("upload-artist-") || name.contains(".cnvs")
            let matchesArtist = artistID.map { name.contains("artist-\($0)") } ?? false
            var matchesFileID = false
            canvasObservedFileIDsLock.lock()
            for fileID in canvasObservedFileIDs where name.contains(fileID) {
                matchesFileID = true
                break
            }
            canvasObservedFileIDsLock.unlock()
            if matchesFileID {
                if fileIDMatch == nil || mod > fileIDMatch!.mod {
                    fileIDMatch = (mod, url)
                }
            } else if isCanvasCache && matchesArtist {
                if artistMatch == nil || mod > artistMatch!.mod {
                    artistMatch = (mod, url)
                }
            } else if isCanvasCache && mod > cutoff {
                if newestRecent == nil || mod > newestRecent!.mod {
                    newestRecent = (mod, url)
                }
            }
        }
    }
    // Stability-gate only the winners, not every file enumerated: the in-loop
    // double-read slept 150ms per candidate and stalled each resolve by seconds.
    // Winner priority is unchanged (fileID > artist > newest). An
    // existing-but-unstable candidate means the right file is still being
    // written — return nil and retry next window rather than pinning a
    // weaker (possibly adjacent-track) match.
    if let c = fileIDMatch { return isCanvasFileStable(c.url) ? c.url : nil }
    if let c = artistMatch { return isCanvasFileStable(c.url) ? c.url : nil }
    if let c = newestRecent { return isCanvasFileStable(c.url) ? c.url : nil }
    return nil
}

// Fix for "wrong/adjacent track" and "sometimes never loads": a candidate file whose
// size is still changing is either an in-progress download (grabbing it now can yield
// a partial/corrupt video, which silently fails to crop) or a file being overwritten
// for the next track (grabbing it now can attach the wrong track's canvas). A 150ms
// double-read is enough to distinguish "still writing" from "already on disk".
private func isCanvasFileStable(_ url: URL) -> Bool {
    let fm = FileManager.default
    guard let size1 = try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64 else { return false }
    Thread.sleep(forTimeInterval: 0.15)
    guard let size2 = try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64 else { return false }
    return size1 == size2 && size1 > 0
}

private func canvasCleanupOldCrops() {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    if let files = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
        for f in files where f.lastPathComponent.hasPrefix("canvas_") {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

private func canvasCropVideo(_ source: URL, aspect: CGFloat) -> URL? {
    let asset = AVURLAsset(url: source)
    guard let track = asset.tracks(withMediaType: .video).first else { return nil }
    let size = track.naturalSize.applying(track.preferredTransform)
    let w = abs(size.width)
    let h = abs(size.height)
    guard w > 0, h > 0 else { return nil }
    let ratio = w / h
    if abs(ratio - aspect) < 0.05 { return source }

    let cropRect: CGRect
    if ratio > aspect {
        let newW = h * aspect
        cropRect = CGRect(x: (w - newW) / 2, y: 0, width: newW, height: h)
    } else {
        let newH = w / aspect
        cropRect = CGRect(x: 0, y: (h - newH) / 2, width: w, height: newH)
    }

    let composition = AVMutableVideoComposition()
    composition.renderSize = cropRect.size
    composition.frameDuration = CMTime(value: 1, timescale: 30)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layerInstruction.setTransform(
        track.preferredTransform.concatenating(CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y)),
        at: .zero
    )
    instruction.layerInstructions = [layerInstruction]
    composition.instructions = [instruction]

    let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("canvas_\(UUID().uuidString).mp4")
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
        return nil
    }
    session.outputURL = outputURL
    session.outputFileType = .mp4
    session.videoComposition = composition
    session.shouldOptimizeForNetworkUse = false
    let sema = DispatchSemaphore(value: 0)
    var ok = false
    session.exportAsynchronously {
        ok = session.status == .completed
        sema.signal()
    }
    _ = sema.wait(timeout: .now() + 30)
    return ok ? outputURL : nil
}

private func canvasPreviewFrame(_ url: URL, aspect: CGFloat) -> UIImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 640)
    let time = CMTime(value: 0, timescale: 600)
    guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
    let image = UIImage(cgImage: cg)
    let w = image.size.width
    let h = image.size.height
    guard w > 0, h > 0 else { return nil }
    let rect: CGRect
    if w / h > aspect {
        let newW = h * aspect
        rect = CGRect(x: (w - newW) / 2, y: 0, width: newW, height: h)
    } else {
        let newH = w / aspect
        rect = CGRect(x: 0, y: (h - newH) / 2, width: w, height: newH)
    }
    guard let cropped = image.cgImage?.cropping(to: rect) else { return nil }
    return UIImage(cgImage: cropped)
}

@available(iOS 19.0, *)
private func makeCanvasArtwork(
    uri: String,
    url: URL,
    staticArtwork: MPMediaItemArtwork?
) -> MPMediaItemAnimatedArtwork {
    MPMediaItemAnimatedArtwork(
        artworkID: uri,
        previewImageRequestHandler: { size in
            if let preview = canvasPreviewImage { return preview }
            return staticArtwork?.image(at: size)
        },
        videoAssetFileURLRequestHandler: { _ in
            url
        }
    )
}

private func rebuildCanvasArtwork(for uri: String) {
    guard canvasVideoSupported, let url = canvasVideoURL else { return }
    var staticArtwork: MPMediaItemArtwork?
    if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
       let art = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
        staticArtwork = art
    }
    if #available(iOS 19.0, *) {
        canvasArtworkBox = makeCanvasArtwork(uri: uri, url: url, staticArtwork: staticArtwork)
        canvasURI = uri
        writeDebugLog("[CANVAS][PUB] built animated artwork uri=\(uri) video=\(url.path) preview=\(canvasPreviewImage != nil)")
        if let key = canvasAnimatedKey,
           let artwork = canvasArtworkBox as? MPMediaItemAnimatedArtwork,
           var info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
           info[key] == nil {
            info[key] = artwork
            canvasRepushing = true
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            canvasRepushing = false
            writeDebugLog("[CANVAS][PUB] re-pushed nowPlayingInfo with animated artwork")
        }
    }
}

private func ensureCanvasArtwork(for uri: String) {
    guard canvasVideoSupported else { return }
    if uri != canvasURI {
        canvasURI = uri
        canvasVideoURL = nil
        canvasArtworkBox = nil
        canvasPreviewImage = nil
        canvasScanStart = Date()
        canvasResolving = false
        // Fix for slow lock screen artwork: previously a track change inherited the
        // previous track's throttle timer, so the first scan for the *new* track could
        // be delayed up to canvasScanThrottle seconds for no reason. A track change is
        // always worth scanning for immediately.
        lastScanAttempt = .distantPast
        canvasCleanupOldCrops()
        writeDebugLog("[CANVAS][PUB] new track uri=\(uri)")
    }
    if canvasArtworkBox != nil { return }
    if let url = canvasVideoURL {
        rebuildCanvasArtwork(for: uri)
        return
    }
    if let pinned = canvasResolvedSources[uri] {
        canvasVideoURL = pinned
        rebuildCanvasArtwork(for: uri)
        return
    }
    guard let scanStart = canvasScanStart else { return }
    let now = Date()
    guard now.timeIntervalSince(scanStart) < canvasScanWindow else { return }
    guard now.timeIntervalSince(lastScanAttempt) > canvasScanThrottle else { return }
    guard !canvasResolving else { return }
    lastScanAttempt = now
    canvasResolving = true
    let pinnedPaths = Set(canvasResolvedSources.values.map { $0.path })
    DispatchQueue.global(qos: .utility).async {
        let found = findCanvasVideoFile(modifiedSince: scanStart, excluding: pinnedPaths)
        var cropped: URL?
        var preview: UIImage?
        if let found = found {
            cropped = canvasCropVideo(found, aspect: canvasAnimatedAspect)
            preview = cropped.flatMap { canvasPreviewFrame($0, aspect: canvasAnimatedAspect) }
        }
        DispatchQueue.main.async {
            canvasResolving = false
            guard uri == canvasURI else { return }
            if let found = found, let cropped = cropped {
                canvasVideoURL = cropped
                canvasPreviewImage = preview
                var sources = canvasResolvedSources
                if sources.count > 64 { sources.removeValue(forKey: sources.keys.first!) }
                sources[uri] = found
                canvasResolvedSources = sources
                writeDebugLog("[CANVAS][PUB] resolved video \(found.path) cropped=\(cropped.path) pinned=\(found.lastPathComponent)")
            } else if let found = found {
                writeDebugLog("[CANVAS][PUB] crop failed for \(found.path), skipping")
            }
            if canvasArtworkBox == nil {
                rebuildCanvasArtwork(for: uri)
            }
        }
    }
}

class CanvasNowPlayingInfoCenterHook: ClassHook<NSObject> {
    typealias Group = CanvasPublisherGroup
    static let targetName = "MPNowPlayingInfoCenter"

    func setNowPlayingInfo(_ info: [String: Any]?) {
        if #available(iOS 19.0, *) {
            if canvasRepushing {
                orig.setNowPlayingInfo(info)
                return
            }
            if canvasVideoSupported {
                let dictURI = (info?["MPNowPlayingInfoPropertyExternalContentIdentifier"] as? String)
                    .flatMap { $0.hasPrefix("spotify:") ? $0 : nil }
                let uri = dictURI ?? capturedTrackURI
                if let uri = uri {
                    if dictURI != nil {
                        writeDebugLog("[CANVAS][NPIC] dictURI=\(dictURI!) captured=\(capturedTrackURI ?? "nil")")
                    }
                    ensureCanvasArtwork(for: uri)
                    if canvasURI == uri,
                       let artwork = canvasArtworkBox as? MPMediaItemAnimatedArtwork,
                       let key = canvasAnimatedKey {
                        var merged = info ?? [:]
                        merged[key] = artwork
                        orig.setNowPlayingInfo(merged)
                        return
                    }
                }
            }
        }
        orig.setNowPlayingInfo(info)
    }
}

private var canvasHeartbeatStarted = false
private let canvasHeartbeatQueue = DispatchQueue(label: "com.eeveespotify.canvas.heartbeat")

private func canvasStartHeartbeat() {
    guard !canvasHeartbeatStarted else { return }
    canvasHeartbeatStarted = true
    canvasHeartbeatQueue.async {
        while true {
            Thread.sleep(forTimeInterval: 3)
            autoreleasepool {
                if #available(iOS 19.0, *) {
                    guard let key = canvasAnimatedKey else { return }
                    guard let uri = canvasURI else { return }
                    if canvasArtworkBox as? MPMediaItemAnimatedArtwork == nil {
                        ensureCanvasArtwork(for: uri)
                        return
                    }
                    guard let artwork = canvasArtworkBox as? MPMediaItemAnimatedArtwork else { return }
                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    if info[key] == nil {
                        info[key] = artwork
                        canvasRepushing = true
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                        canvasRepushing = false
                        writeDebugLog("[CANVAS][PUB] heartbeat re-injected animated artwork")
                    }
                }
            }
        }
    }
}

func activateCanvasArtworkPublisher() {
    guard canvasVideoSupported else {
        writeDebugLog("[CANVAS][PUB] disabled: supportedAnimatedArtworkKeys unavailable (iOS < 26)")
        return
    }
    canvasStartHeartbeat()
    CanvasPublisherGroup().activate()
    writeDebugLog("[CANVAS][PUB] activated (iOS 26 animated artwork publisher) key=\(canvasAnimatedKey ?? "nil")")
}
// ── END OF AI GENERATED CODE ──
