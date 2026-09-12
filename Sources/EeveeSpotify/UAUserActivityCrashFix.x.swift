import Orion
import Foundation
import ObjectiveC.runtime

// ── START OF AI GENERATED CODE ──
// Defends against the crash that happens when a synthetic
// `spotify:track:local<hex>` URI (produced by SPTPlayerTrackURIV91Hook while
// shouldOverrideLocalTrackURI is true) flows into Handoff:
//   +[UAUserActivity(Internal) checkWebpageURL:actionType:throwIfFailed:]
// throws an ObjC exception for any scheme other than http/https, terminating
// the app.  This happens during track switches because the
// viewWillDisappear → shouldOverrideLocalTrackURI=false toggle races the
// NSUserActivity build on the main queue.  Scoping the URI rewrite to the
// now-playing lifecycle shrinks the window but does not close it: a dispatch
// already in flight carries the synthetic URI into setWebpageURL: after the
// flag flips.  Hooking the setter itself makes the path safe regardless of
// the flag's state, so the lyrics card pipeline is unaffected (lyrics travels
// through network interception of /color-lyrics/v2 and scrollsita/v1/scroll,
// not UserActivity).  Silently dropping non-web URLs trades an unusable
// Handoff entry for keeping the process alive — Handoff restoring a spotify:
// URI never worked anyway (Safari would just fail to open it).
struct UAUserActivityCrashFixGroup: HookGroup {}

class UAUserActivitySetWebpageURLHook: ClassHook<NSObject> {
    typealias Group = UAUserActivityCrashFixGroup
    static let targetName = "UAUserActivity"

    @objc(setWebpageURL:)
    func setWebpageURL(_ url: NSURL?) {
        if let u = url, let scheme = u.scheme {
            if scheme == "http" || scheme == "https" {
                orig.setWebpageURL(u)
                return
            }
            // spotify: / spotify-moments: / file: / etc. would throw — swallow silently.
            return
        }
        orig.setWebpageURL(nil)
    }
}

func activateUAUserActivityCrashFix() {
    guard let cls = NSClassFromString("UAUserActivity"),
          class_getInstanceMethod(cls, Selector(("setWebpageURL:"))) != nil else {
        writeDebugLog("[UAUserActivityFix] Skipped (UAUserActivity or setWebpageURL: missing)")
        return
    }
    UAUserActivityCrashFixGroup().activate()
    writeDebugLog("[UAUserActivityFix] Activated")
}
// ── END OF AI GENERATED CODE ──
