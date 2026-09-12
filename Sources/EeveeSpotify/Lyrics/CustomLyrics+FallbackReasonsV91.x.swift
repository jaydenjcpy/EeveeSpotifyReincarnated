import Orion
import UIKit

// ── START OF AI GENERATED CODE ──
// 9.1.x port of Show Fallback Reasons. The pre-9.1 hook targets
// Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController, which doesn't exist
// on 9.1.x. This hook covers the now-playing album/playlist header
// (NowPlaying_ModesImpl.HeaderElementsUnit) instead, mounting a dimmed
// "Fallback: <reason>" UILabel right below the album/playlist name.
//
// The header label is bound asynchronously by Spotify's element binders and
// the lyrics error is set asynchronously by the delivery hooks, so the mount
// runs on viewDidAppear and retries for a while. Each step logs its outcome
// so a silent failure can be diagnosed from the tweak log.
//
// 9.1.x rendering notes: the header text is rendered by a
// LegacyUI_ECMCoreKit.MarqueeLabel — a single-line, fixed-height UIView
// wrapper with no text setters that clips its content, so appending text
// *into* it never renders. Instead the port adds its own UILabel as a
// sibling of the marquee, bottom-anchored inside the header so it stays
// off the album art below.

private let fallbackReasonPrefix = "\(("fallback_attribute".localized)): "

// Mounted fallback labels keyed by anchor label instance, each remembering the
// rendered track key it was mounted for so a track switch can remove it.
private var mountedFallbackLabels: [ObjectIdentifier: (label: UILabel, anchor: UIView, trackKey: String?)] = [:]

struct V91HeaderElementsFallbackReasonsGroup: HookGroup {}

class HeaderElementsUnitHook: ClassHook<UIViewController> {
    typealias Group = V91HeaderElementsFallbackReasonsGroup
    
    static var targetName = "NowPlaying_ModesImpl.HeaderElementsUnit"
    
    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        scheduleFallbackReasonAppend(in: target.view, tag: "now-playing header")
    }
}

/// Locates the now-playing album/playlist name label, which is a
/// LegacyUI_ECMCoreKit.MarqueeLabel (verified with a runtime subview dump).
private func findV91FallbackLabel(in view: UIView) -> UIView? {
    return WindowHelper.shared.findFirstSubview("MarqueeLabel", in: view)
}

/// Adds a "Fallback: <reason>" UILabel as a sibling of the marquee label,
/// bottom-anchored inside the header so it sits under the album/playlist
/// name without overlapping the album art. The marquee is a single-line
/// fixed-height view that clips, so we never touch its text — we mount our
/// own label next to it.
private func appendFallbackReasonLabel(to anchorLabel: UIView, tag: String, description: String) -> UILabel? {
    guard let superview = anchorLabel.superview else {
        writeDebugLog("[FallbackReasons] \(tag): anchor label has no superview, skipping")
        return nil
    }
    
    // Diagnostics: dump the real geometry so the label's position can be
    // verified instead of guessed from stale dumps.
    let anchorFrame = anchorLabel.frame
    let superFrame = superview.frame
    let windowFrame = superview.convert(superview.bounds, to: nil)
    writeDebugLog("[FallbackReasons] \(tag): anchor=\(NSCoder.string(for: anchorFrame)) super=\(NSCoder.string(for: superFrame)) superInWindow=\(NSCoder.string(for: windowFrame))")
    
    let fallbackLabel = UILabel()
    fallbackLabel.text = "\(fallbackReasonPrefix)\(description)"
    fallbackLabel.font = .systemFont(ofSize: 12)
    fallbackLabel.textColor = .white
    fallbackLabel.numberOfLines = 1
    fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
    fallbackLabel.accessibilityIdentifier = "EeveeFallbackReasonsLabel"
    
    superview.addSubview(fallbackLabel)
    
    NSLayoutConstraint.activate([
        fallbackLabel.leadingAnchor.constraint(equalTo: anchorLabel.leadingAnchor),
        fallbackLabel.trailingAnchor.constraint(equalTo: anchorLabel.trailingAnchor),
        fallbackLabel.bottomAnchor.constraint(equalTo: superview.bottomAnchor, constant: -8)
    ])
    
    return fallbackLabel
}

/// Removes any mounted fallback label whose track key no longer matches the
/// currently rendered track. Called on track switch (via recordRenderedTrackKey)
/// and from the retry loop, so an error line from a previous song never sticks
/// around after switching — even when the new song has no error at all.
func removeStaleFallbackReasonLabels(tag: String = "now-playing header") {
    let currentKey = uiRenderedTrackKey
    var removed = 0
    for (id, mounted) in mountedFallbackLabels where mounted.trackKey != currentKey {
        mounted.label.removeFromSuperview()
        mountedFallbackLabels[id] = nil
        removed += 1
    }
    if removed > 0 {
        writeDebugLog("[FallbackReasons] \(tag): removed \(removed) stale label(s) (track \(currentKey ?? "nil"))")
    }
}

/// Returns true when the append is done (or permanently skipped); false when a
/// retry could still succeed (label not found yet, or error not set yet).
private func appendFallbackReasonsIfNeeded(in view: UIView, tag: String) -> Bool {
    guard UserDefaults.lyricsOptions.showFallbackReasons else {
        writeDebugLog("[FallbackReasons] \(tag): skipped (showFallbackReasons off)")
        return true
    }
    
    // Sweep first: if the track changed and the new one has no error, the
    // stale label must go regardless of the error guards below.
    removeStaleFallbackReasonLabels(tag: tag)
    
    guard let description = lyricsState.fallbackError?.description, !description.isEmpty else {
        // Error not resolved yet — this is the common race; retry.
        return false
    }
    
    guard let lyricsLabel = findV91FallbackLabel(in: view) else {
        writeDebugLog("[FallbackReasons] \(tag): header label not found yet, will retry")
        return false
    }
    
    let labelID = ObjectIdentifier(lyricsLabel)
    let trackKey = uiRenderedTrackKey
    
    // If this anchor already has a mounted label from a DIFFERENT track, the
    // previous song's error line must not stick around — remove it so the
    // label can be remounted for the current track's error.
    if let mounted = mountedFallbackLabels[labelID] {
        if mounted.trackKey == trackKey {
            return true
        }
        mounted.label.removeFromSuperview()
        mountedFallbackLabels[labelID] = nil
        writeDebugLog("[FallbackReasons] \(tag): removed stale label on track change (\(mounted.trackKey ?? "nil") -> \(trackKey ?? "nil"))")
    }
    
    guard let fallbackLabel = appendFallbackReasonLabel(to: lyricsLabel, tag: tag, description: description) else {
        return true
    }
    
    mountedFallbackLabels[labelID] = (fallbackLabel, lyricsLabel, trackKey)
    writeDebugLog("[FallbackReasons] \(tag): added fallback label under \(lyricsLabel)")
    return true
}

private func scheduleFallbackReasonAppend(in view: UIView, tag: String, attempt: Int = 0) {
    DispatchQueue.main.async {
        if appendFallbackReasonsIfNeeded(in: view, tag: tag) {
            return
        }
        if attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                scheduleFallbackReasonAppend(in: view, tag: tag, attempt: attempt + 1)
            }
        } else {
            writeDebugLog("[FallbackReasons] \(tag): gave up after retries")
        }
    }
}
// ── END OF AI GENERATED CODE ──
