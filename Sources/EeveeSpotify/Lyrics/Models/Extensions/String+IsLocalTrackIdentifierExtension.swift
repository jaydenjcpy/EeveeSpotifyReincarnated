import Foundation

// ── START OF AI GENERATED CODE ──
extension String {
    var isLocalTrackIdentifier: Bool {
        self.hasPrefix("spotify:local:")
    }

    /// A synthetic local-track id we generate (see `localTrackSyntheticId`) so
    /// Spotify sees each local file as a distinct track instead of one shared
    /// placeholder. The 22-char id is `local` + 17 hex chars of a stable hash
    /// of the real local URI. Real Spotify track ids never carry an
    /// all-lowercase `local` prefix, so this can't collide with a genuine
    /// catalog id in practice.
    var isSyntheticLocalTrackId: Bool {
        self.hasPrefix("local")
            && self.count == 22
            && self.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// True for a normal Spotify track id/URI. Spotify track ids are 22 chars of
    /// [A-Za-z0-9]; local files instead surface a short numeric/internal id
    /// (e.g. the lyrics request for a local file is /color-lyrics/v2/track/173).
    /// Anything that isn't a real Spotify id is treated as a local track so we
    /// fall back to a title+artist lyrics source (Genius) instead of one that
    /// requires a real Spotify track id (SpicyLyrics).
    var isLikelySpotifyTrackId: Bool {
        if self.hasPrefix("spotify:track:") { return true }
        // Spotify ids are 22 chars of ASCII [A-Za-z0-9]; use ASCII-only check so
        // non-ASCII letters/digits can't be misclassified as a real Spotify id.
        return self.count >= 20
            && self.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Local for our purposes: an explicit spotify:local: URI, a synthetic
    /// local-track id, OR any id that isn't a real Spotify track id (covers
    /// the local-file numeric id).
    var isLocalOrNonSpotifyTrackId: Bool {
        self.isLocalTrackIdentifier || self.isSyntheticLocalTrackId || !self.isLikelySpotifyTrackId
    }

    /// Strong identities are unique per track and can prove staleness: a real
    /// spotify:local: URI, a synthetic local-track id, or a real catalog id
    /// (>= 20 ASCII alphanumerics, see isLikelySpotifyTrackId — just as unique
    /// as a synthetic id, so a local->normal switch must drop a stale local
    /// payload). Only WEAK keys — short numeric ids (e.g.
    /// /color-lyrics/v2/track/173) and the constant placeholder — are ambiguous
    /// across local files and can never prove a mismatch.
    var isStrongLyricsIdentity: Bool {
        if self == localTrackPlaceholderId { return false }
        return self.isLocalTrackIdentifier || self.isSyntheticLocalTrackId || self.isLikelySpotifyTrackId
    }
}
// ── END OF AI GENERATED CODE ──
