import Orion
import Foundation
import MachO.dyld
import EeveeSpotifyC

// The actual lyrics-card gate on 9.1.68:
//
//   LyricsUIServiceImplementation.registerScrollProviderIn:  (IMP 0x10772ad94)
//       → bl 0x1034f57c8 (shared lyrics scroll-card registration helper)
//           → casts the lyrics provider to SPTNowPlayingScrollCardProvidable
//           → invokes a Swift witness method returning Bool in w0
//           → tbz w20, #0x0, exit  (at 0x1034f584c)
//
// If that Bool is false (the witness says "not available for this track"),
// the function jumps straight to the epilogue WITHOUT calling
// NowPlayingScrollDataSourceImplementation registerProvider:, so the
// lyrics scroll card is silently dropped. For local files the witness
// returns false — the lyrics card never appears even though our lyrics
// delivery pipeline works end-to-end.
//
// Fix: NOP the single `tbz` instruction at 0x1034f584c so registration
// always proceeds. Two-byte surgical patch. The provider itself still
// decides whether to render a card based on loaded lyrics data, but
// registration can no longer be skipped up-front.

struct V91LyricsCardGatePatchGroup: HookGroup {}

private enum LyricsCardGateAddress {
    // __TEXT segment vmaddr in the decrypted Spotify binary.
    static let textSegmentVmaddr: UInt64 = 0x100000000

    // ── START OF AI GENERATED CODE ──
    // File offset of the `tbz w20, #0x0, epilogue` gate inside
    // __TEXT,__text, per Spotify build. The gate sits in the shared
    // lyrics scroll-card registration flow reached from
    // LyricsUIServiceImplementation.registerScrollProviderIn:.
    //  - 9.1.68: verified 0x34f584c → 0x360004f4 (tbz w20, #0, 0x1034f58e8)
    //  - 9.1.78: verified 0x316c30c → 0x360004f4 (tbz w20, #0, 0x10316c3a8;
    //            reached via the availability thunk at 0x10316c288)
    // Every candidate is verified at runtime before NOP-ing, so a stale or
    // unknown offset is simply skipped.
    static let knownGates: [String: UInt] = [
        "9.1.68": 0x34f584c,
        "9.1.78": 0x316c30c,
    ]
    // Fallback for unknown builds: the 9.1.x series so far keeps the same
    // instruction; try each known offset and let the byte check decide.
    static var tbzFileOffset: UInt {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return knownGates[version] ?? knownGates.values.min()!
    }
    // All offsets to try (unknown builds get every known candidate).
    static var candidateOffsets: [UInt] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if let known = knownGates[version] { return [known] }
        return Array(knownGates.values).sorted()
    }
    // The linked (pre-slide) runtime address of that instruction.
    static var tbzLinkedAddress: UInt64 { textSegmentVmaddr + UInt64(tbzFileOffset) }
    // ── END OF AI GENERATED CODE ──
}

// Resolve the runtime load address of the main Spotify executable image.
// Iterate dyld images and match by name — safer than trusting index 0,
// which can be wrong if injection reorders images.
private func spotifyMainImageBase() -> UInt64 {
    var idx: UInt32 = 0
    while let header = _dyld_get_image_header(idx) {
        if let nameC = _dyld_get_image_name(idx) {
            let name = String(cString: nameC)
            if name.hasSuffix("/Spotify") {
                return UInt64(UInt(bitPattern: header))
            }
        }
        idx &+= 1
    }
    // Fallback to image 0 if name-based lookup fails.
    guard let header = _dyld_get_image_header(0) else { return 0 }
    return UInt64(UInt(bitPattern: header))
}

// Patch the gate instruction. Must run AFTER Spotify's __TEXT segment is
// already mapped — safest in the tweak init flow inside Tweak.x.swift
// (well past constructor time). Idempotent.
func patchLyricsCardGate() {
    let mainBase = spotifyMainImageBase()
    guard mainBase != 0 else {
        writeDebugLog("[LyricsGatePatch] Could not resolve Spotify main image base")
        return
    }

    // The image slide is mainBase - linked-vmaddr (slide applies uniformly to
    // every segment offset). Runtime address of the gate = linked + slide.
    let slide = mainBase &- LyricsCardGateAddress.textSegmentVmaddr

    let expectedTbz: UInt32 = 0x360004f4
    let expectedNop: UInt32 = 0xD503201F

    // ── START OF AI GENERATED CODE ──
    for offset in LyricsCardGateAddress.candidateOffsets {
        let runtimeAddress = LyricsCardGateAddress.textSegmentVmaddr
            &+ UInt64(offset) &+ slide

        writeDebugLog("[LyricsGatePatch] mainBase=0x\(String(mainBase, radix: 16)) "
                    + "slide=0x\(String(slide, radix: 16)) "
                    + "candidate offset=0x\(String(offset, radix: 16)) "
                    + "target=0x\(String(runtimeAddress, radix: 16))")

        // Verify the byte at the target is the expected tbz instruction.
        // If the build-time IPA patch already NOP'd it, we're done.
        let actual = unsafeBitLoad32(at: runtimeAddress)
        if actual == expectedNop {
            writeDebugLog("[LyricsGatePatch] Already NOP-patched (build-time) at 0x\(String(runtimeAddress, radix: 16)), nothing to do")
            return
        }
        guard actual == expectedTbz else {
            writeDebugLog("[LyricsGatePatch] candidate 0x\(String(offset, radix: 16)) has "
                        + "0x\(String(actual, radix: 16)), expected 0x\(String(expectedTbz, radix: 16)) — trying next")
            continue
        }

        let success = EeveeSBPatchInstruction(UInt(runtimeAddress))
        if success {
            writeDebugLog("[LyricsGatePatch] Runtime NOP applied at 0x\(String(runtimeAddress, radix: 16))")
        } else {
            writeDebugLog("[LyricsGatePatch] Runtime NOP FAILED (vm_protect denied by PPL) — build-time patch must handle it")
        }
        return
    }

    writeDebugLog("[LyricsGatePatch] No known gate offset matched this Spotify build — lyrics card gate left untouched")
    // ── END OF AI GENERATED CODE ──
}

@inline(__always)
private func unsafeBitLoad32(at address: UInt64) -> UInt32 {
    let ptr = UnsafeRawPointer(bitPattern: UInt(address))
    guard let p = ptr else { return 0 }
    return p.load(as: UInt32.self)
}
