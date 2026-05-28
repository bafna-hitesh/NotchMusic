import Foundation
import AppKit
import SwiftUI

extension Notification.Name {
    static let mediaPlaybackStarted = Notification.Name("mediaPlaybackStarted")
    static let mediaPlaybackStopped = Notification.Name("mediaPlaybackStopped")
    static let mediaHeartbeat = Notification.Name("mediaHeartbeat")
}

final class MediaController: ObservableObject {
    static let shared = MediaController()

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var trackName: String = ""
    @Published private(set) var artistName: String = ""
    @Published private(set) var albumName: String = ""
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var dominantColor: Color?
    @Published var controlError: String?
    @Published private(set) var trackDuration: TimeInterval = 0

    private var positionBase: TimeInterval = 0
    private var positionBaseTime = Date()
    private var pollTimer: Timer?

    var playbackPosition: TimeInterval {
        guard isPlaying else { return positionBase }
        return positionBase + Date().timeIntervalSince(positionBaseTime)
    }

    private func setPlaybackPosition(_ pos: TimeInterval) {
        positionBase = pos
        positionBaseTime = Date()
    }

    private var lastTrackIdentifier: String = ""
    private let bridge = MediaRemoteBridge.shared
    private let targetImageSize: CGFloat = 64
    private var authAttempted = false

    // Poll generation counter — rejects stale results from previous cycles
    private var pollGeneration: UInt64 = 0

    // When richer-source data was last applied (for expiration)
    private var richerSourceLastApplied: Date = .distantPast
    private static let richerSourceTTL: TimeInterval = 3.0

    // Count consecutive MR reports of "not playing" to confirm genuine stop
    private var stoppedCount: Int = 0
    private static let stoppedThreshold: Int = 3

    // MARK: - AppleScript caches

    private var cachedSpotifyInfoScript: NSAppleScript?
    private var cachedSpotifyArtworkScript: NSAppleScript?
    private var cachedMusicInfoScript: NSAppleScript?
    private var cachedMusicArtworkScript: NSAppleScript?

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    // Info dict keys — resolved via the bridge to the actual CFString values
    private lazy var mrTitle: String = bridge.resolveInfoKey("kMRMediaRemoteNowPlayingInfoTitle")
    private lazy var mrArtist: String = bridge.resolveInfoKey("kMRMediaRemoteNowPlayingInfoArtist")
    private lazy var mrAlbum: String = bridge.resolveInfoKey("kMRMediaRemoteNowPlayingInfoAlbum")
    private lazy var mrDuration: String = bridge.resolveInfoKey("kMRMediaRemoteNowPlayingInfoDuration")
    private lazy var mrElapsed: String = bridge.resolveInfoKey("kMRMediaRemoteNowPlayingInfoElapsedTime")
    private lazy var mrArtwork: String = bridge.resolveInfoKey("kMRMediaRemoteNowPlayingInfoArtworkData")
    private lazy var mrRate: String = bridge.resolveInfoKey("kMRMediaRemoteNowPlayingInfoPlaybackRate")
    private lazy var mrIdentifier: String = bridge.resolveInfoKey("kMRMediaRemoteNowPlayingInfoUniqueIdentifier")
    private lazy var mrSeekOption: String = bridge.resolveInfoKey("kMRMediaRemoteOptionPlaybackPosition")

    // Chrome audible-tab script (loops ALL tabs, not just active)
    private var cachedChromeAudibleScript: NSAppleScript?

    // MARK: - Init

    private init() {
        buildScripts()
        startPolling()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAuthReset),
            name: .spotifyAuthDidReset,
            object: nil
        )
    }

    @objc private func handleAuthReset() { authAttempted = false }

    private func buildScripts() {
        cachedSpotifyInfoScript = NSAppleScript(source: """
        tell application "System Events"
            if not (exists process "Spotify") then return "not_running"
        end tell
        tell application "Spotify"
            if player state is playing then
                set trackName to name of current track
                set artistName to artist of current track
                set albumName to album of current track
                set trackId to id of current track
                set trackDur to duration of current track
                set playerPos to player position
                return "playing|" & trackName & "|" & artistName & "|" & albumName & "|" & trackId & "|" & trackDur & "|" & playerPos
            else if player state is paused then
                set trackName to name of current track
                set artistName to artist of current track
                set albumName to album of current track
                set trackId to id of current track
                set trackDur to duration of current track
                set playerPos to player position
                return "paused|" & trackName & "|" & artistName & "|" & albumName & "|" & trackId & "|" & trackDur & "|" & playerPos
            else
                return "stopped"
            end if
        end tell
        """)

        cachedSpotifyArtworkScript = NSAppleScript(source: """
        tell application "Spotify"
            try
                return artwork url of current track
            on error
                return ""
            end try
        end tell
        """)

        cachedMusicInfoScript = NSAppleScript(source: """
        tell application "System Events"
            if not (exists process "Music") then return "not_running"
        end tell
        tell application "Music"
            if player state is playing then
                set trackName to name of current track
                set artistName to artist of current track
                set albumName to album of current track
                set trackDur to duration of current track
                set playerPos to player position
                return "playing|" & trackName & "|" & artistName & "|" & albumName & "|" & trackDur & "|" & playerPos
            else if player state is paused then
                set trackName to name of current track
                set artistName to artist of current track
                set albumName to album of current track
                set trackDur to duration of current track
                set playerPos to player position
                return "paused|" & trackName & "|" & artistName & "|" & albumName & "|" & trackDur & "|" & playerPos
            else
                return "stopped"
            end if
        end tell
        """)

        cachedMusicArtworkScript = NSAppleScript(source: """
        tell application "Music"
            try
                set artworkData to raw data of artwork 1 of current track
                return artworkData
            on error
                return ""
            end try
        end tell
        """)

        // Chrome tab detection — finds ANY tab with media title, not just active
        cachedChromeAudibleScript = NSAppleScript(source: """
        tell application "Google Chrome"
            if it is running then
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set tTitle to title of t
                            if tTitle contains " - YouTube" or tTitle contains " on Spotify" then
                                return tTitle & "|" & URL of t
                            end if
                        end try
                    end repeat
                end repeat
            end if
            return ""
        end tell
        """)
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        fetchFromAllSources()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.fetchFromAllSources()
        }
        pollTimer?.tolerance = 0.5
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func nextGeneration() -> UInt64 { pollGeneration += 1; return pollGeneration }

    private func fetchFromAllSources() {
        let gen = nextGeneration()

        // Tier 0: MRMediaRemote — universal, gives title/artist from ANY source (needs Accessibility)
        bridge.getNowPlayingInfo { [weak self] dict in
            self?.applyMRInfo(dict, generation: gen)
        }

        // Tier 1: Spotify Web API — enriches with artwork, duration, precise position
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let info = await self.fetchFromSpotifyWebAPI() {
                self.applyTrackInfo(info, generation: gen)
            }
        }

        // Tier 2+3: AppleScript fallbacks, then Chrome audible-tab as last resort
        // NSAppleScript must run on main thread; network I/O stays on background
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if let info = self.fetchFromAppleScript(app: "spotify",
                                                    infoScript: self.cachedSpotifyInfoScript,
                                                    artworkScript: self.cachedSpotifyArtworkScript) {
                DispatchQueue.main.async { self.applyTrackInfo(info, generation: gen) }
            } else if let info = self.fetchFromAppleScript(app: "music",
                                                            infoScript: self.cachedMusicInfoScript,
                                                            artworkScript: self.cachedMusicArtworkScript) {
                DispatchQueue.main.async { self.applyTrackInfo(info, generation: gen) }
            } else {
                // Final fallback: Chrome audible-tab (when MR is blocked + no native app)
                if let info = self.fetchFromChromeAudibleTab() {
                    DispatchQueue.main.async { self.applyTrackInfo(info, generation: gen) }
                }
            }
        }
    }

    // MARK: - Tier 0: MRMediaRemote info

    private func applyMRInfo(_ dict: [String: Any], generation: UInt64) {
        guard generation == pollGeneration else { return }

        // Empty dict means MR can't access the source — not that playback stopped.
        // Do nothing; other tiers (AppleScript, Spotify API) will provide data if available.
        guard !dict.isEmpty else { return }

        stoppedCount = 0

        let title = dict[mrTitle] as? String ?? ""
        let artist = dict[mrArtist] as? String ?? ""
        let album = dict[mrAlbum] as? String ?? ""
        let duration = (dict[mrDuration] as? NSNumber)?.doubleValue ?? 0
        let elapsed = (dict[mrElapsed] as? NSNumber)?.doubleValue ?? 0
        let rate = (dict[mrRate] as? NSNumber)?.doubleValue ?? 0
        let playing = rate > 0
        let identifier = dict[mrIdentifier] as? String ?? "\(title)|\(artist)"

        // Richer-source data expires after TTL — prevents stale Spotify data
        // from permanently blocking MR updates when switching to browser sources
        let richerExpired = Date().timeIntervalSince(richerSourceLastApplied) > Self.richerSourceTTL
        let isRicherSourceActive = !richerExpired && trackDuration > 0 && !albumName.isEmpty

        if !isRicherSourceActive {
            if lastTrackIdentifier != identifier || trackName != title {
                lastTrackIdentifier = identifier
                trackName = title
                artistName = artist
                albumName = album
                trackDuration = duration
                setPlaybackPosition(elapsed)
                processArtworkFromMR(dict)
            } else if elapsed > 0 {
                setPlaybackPosition(elapsed)
            }
            if duration > 0 { trackDuration = duration }
        } else if elapsed > 0 {
            // Richer source active — just update position from MR
            setPlaybackPosition(elapsed)
        }

        if isPlaying != playing {
            let wasPlaying = isPlaying
            isPlaying = playing
            if playing && !wasPlaying {
                stoppedCount = 0
                NotificationCenter.default.post(name: .mediaPlaybackStarted, object: nil)
            } else if !playing && wasPlaying {
                NotificationCenter.default.post(name: .mediaPlaybackStopped, object: nil)
            }
        }

        // Detect genuine stop: MR sees the player but rate is 0 across multiple cycles
        if !playing {
            stoppedCount += 1
            if stoppedCount >= Self.stoppedThreshold {
                if isPlaying {
                    isPlaying = false
                    NotificationCenter.default.post(name: .mediaPlaybackStopped, object: nil)
                }
            }
        }
    }

    private func processArtworkFromMR(_ dict: [String: Any]) {
        guard let data = dict[mrArtwork] as? Data, NSImage(data: data) != nil else { return }
        let thumbnail = createThumbnail(from: data, maxPixelSize: targetImageSize * 2)
        if let final = thumbnail.map({ NSImage(cgImage: $0, size: NSSize(width: targetImageSize, height: targetImageSize)) }) {
            artworkImage = final
            dominantColor = averageColor(from: final)
        }
    }

    // MARK: - Tier 1: Spotify Web API

    @MainActor
    private func fetchFromSpotifyWebAPI() async -> TrackInfo? {
        guard let token = await SpotifyAuthController.shared.getValidToken() else {
            if !authAttempted {
                authAttempted = true
                let auth = SpotifyAuthController.shared
                if auth.isConfigured, !auth.isAuthenticated {
                    let spotifyRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
                    if spotifyRunning {
                        print("[MediaController] attempting Spotify auth...")
                        auth.authenticate()
                    }
                }
            }
            return nil
        }
        authAttempted = false

        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 5

        guard let (data, response) = try? await urlSession.data(for: req),
              let http = response as? HTTPURLResponse
        else { return nil }

        if http.statusCode == 204 || http.statusCode == 401 { return nil }

        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let isPlaying = json["is_playing"] as? Bool,
              let item = json["item"] as? [String: Any]
        else { return nil }

        let name = item["name"] as? String ?? ""
        let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let album = (item["album"] as? [String: Any])?["name"] as? String ?? ""
        let durationMs = item["duration_ms"] as? TimeInterval ?? 0
        let progressMs = json["progress_ms"] as? TimeInterval ?? 0
        let trackId = item["id"] as? String ?? ""

        var artwork: NSImage?
        var color: Color?
        if let albumObj = item["album"] as? [String: Any],
           let images = albumObj["images"] as? [[String: Any]],
           let firstImage = images.first,
           let urlStr = firstImage["url"] as? String,
           let url = URL(string: urlStr) {
            if let (imgData, _) = try? await urlSession.data(from: url),
               let img = NSImage(data: imgData) {
                artwork = self.resizeArtwork(img)
                color = artwork.flatMap { self.averageColor(from: $0) }
            }
        }

        return TrackInfo(
            isPlaying: isPlaying,
            title: name,
            artist: artists.joined(separator: ", "),
            album: album,
            trackId: trackId,
            duration: durationMs / 1000.0,
            position: progressMs / 1000.0,
            artwork: artwork,
            color: color
        )
    }

    // MARK: - Tier 2+3: AppleScript

    private func fetchFromAppleScript(app: String, infoScript: NSAppleScript?, artworkScript: NSAppleScript?) -> TrackInfo? {
        guard let script = infoScript else { return nil }
        let output: NSAppleEventDescriptor?
        var error: NSDictionary?
        if Thread.isMainThread {
            output = script.executeAndReturnError(&error)
        } else {
            var outDesc: NSAppleEventDescriptor?
            var outErr: NSDictionary?
            DispatchQueue.main.sync {
                outDesc = script.executeAndReturnError(&outErr)
            }
            output = outDesc
            error = outErr
        }
        guard let result = output?.stringValue else {
            if let error { print("[AppleScript] \(app) info error: \(error)") }
            return nil
        }
        if result == "not_running" || result == "stopped" { return nil }

        let parts = result.components(separatedBy: "|")
        guard parts.count >= 6 else { return nil }

        let isPlaying = parts[0] == "playing"
        let title = parts[1]
        let artist = parts[2]
        let album = parts[3]

        // Spotify returns 7 fields: trackId (string), duration (ms), position (s)
        // Music returns 6 fields: duration (s), position (s) — no trackId
        let trackId: String
        let duration: TimeInterval
        let position: TimeInterval
        if app == "music" {
            // Music: parts[4]=duration(s), parts[5]=position(s)
            trackId = ""
            duration = TimeInterval(parts[4]) ?? 0
            position = TimeInterval(parts[5]) ?? 0
        } else {
            // Spotify: parts[4]=trackId, parts[5]=duration(ms), parts[6]=position(s)
            trackId = parts[4]
            duration = (TimeInterval(parts[5]) ?? 0) / 1000.0
            position = parts.count > 6 ? (TimeInterval(parts[6]) ?? 0) : 0
        }

        var artwork: NSImage?
        var color: Color?
        if app == "spotify", let artScript = artworkScript {
            var artError: NSDictionary?
            if let urlStr = artScript.executeAndReturnError(&artError).stringValue,
               !urlStr.isEmpty, let url = URL(string: urlStr) {
                if let (data, _) = try? urlSession.syncData(from: url),
                   let img = NSImage(data: data) {
                    artwork = self.resizeArtwork(img)
                    color = artwork.flatMap { self.averageColor(from: $0) }
                }
            }
        } else if app == "music", let artScript = artworkScript {
            var artError: NSDictionary?
            let descriptor = artScript.executeAndReturnError(&artError)
            if artError == nil, let img = NSImage(data: descriptor.data) {
                artwork = self.resizeArtwork(img)
                color = artwork.flatMap { self.averageColor(from: $0) }
            }
        }

        return TrackInfo(
            isPlaying: isPlaying, title: title, artist: artist, album: album,
            trackId: trackId, duration: duration, position: position,
            artwork: artwork, color: color
        )
    }

    // MARK: - Chrome audible-tab fallback (when MR is blocked)

    private func fetchFromChromeAudibleTab() -> TrackInfo? {
        guard let script = cachedChromeAudibleScript else { return nil }
        let output: NSAppleEventDescriptor?
        var error: NSDictionary?
        if Thread.isMainThread {
            output = script.executeAndReturnError(&error)
        } else {
            var outDesc: NSAppleEventDescriptor?
            var outErr: NSDictionary?
            DispatchQueue.main.sync {
                outDesc = script.executeAndReturnError(&outErr)
            }
            output = outDesc
            error = outErr
        }
        let result = output?.stringValue
        print("[ChromeTab] output=\(result ?? "nil"), error=\(error?.description ?? "none")")
        guard let result, !result.isEmpty else { return nil }

        // Output format: "title|URL"
        let parts = result.components(separatedBy: "|")
        let title = parts.first ?? ""
        let url = parts.count > 1 ? parts[1] : ""

        // Only handle YouTube/Spotify Web tabs
        guard title.contains(" - YouTube") || title.contains(" on Spotify") else { return nil }

        // Parse title to get song + artist
        var artistName = ""
        var cleaned = title
            .replacingOccurrences(of: " - YouTube", with: "")
            .replacingOccurrences(of: " on Spotify", with: "")

        if let match = try? NSRegularExpression(pattern: #"\s*[\[\(][^\]\)]+[\]\)]\s*$"#)
            .stringByReplacingMatches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "") {
            cleaned = match
        }
        cleaned = cleaned
            .replacingOccurrences(of: "VEVO - ", with: " - ")
            .replacingOccurrences(of: "VEVO", with: "")
            .replacingOccurrences(of: " - Topic", with: "")

        let segs = cleaned.components(separatedBy: " - ")
        let song: String
        if segs.count >= 2 {
            song = segs.last!
            artistName = segs.dropLast().joined(separator: ", ")
        } else {
            song = cleaned
        }

        // Clean artist
        if let match = try? NSRegularExpression(pattern: #"^\(\d+\)\s*"#)
            .firstMatch(in: artistName, range: NSRange(artistName.startIndex..., in: artistName)) {
            artistName = String(artistName.dropFirst(match.range.length))
        }

        // YouTube thumbnail
        var artwork: NSImage?
        var color: Color?
        if let videoID = extractYouTubeVideoID(url),
           let artURL = URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg") {
            if let (data, _) = try? urlSession.syncData(from: artURL),
               let img = NSImage(data: data) {
                artwork = resizeArtwork(img)
                color = artwork.flatMap { averageColor(from: $0) }
            }
        }

        return TrackInfo(
            isPlaying: true,
            title: song.trimmingCharacters(in: .whitespaces),
            artist: artistName.trimmingCharacters(in: .whitespaces),
            album: "",
            trackId: "chrome:\(title)",
            duration: 0,
            position: 0,
            artwork: artwork,
            color: color
        )
    }

    private func extractYouTubeVideoID(_ url: String) -> String? {
        guard let comps = URLComponents(string: url) else { return nil }
        if comps.host?.contains("youtu.be") == true {
            return comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return comps.queryItems?.first(where: { $0.name == "v" })?.value
    }

    // MARK: - Track info struct

    private struct TrackInfo {
        let isPlaying: Bool
        let title: String
        let artist: String
        let album: String
        let trackId: String
        let duration: TimeInterval
        let position: TimeInterval
        let artwork: NSImage?
        let color: Color?
    }

    private func applyTrackInfo(_ info: TrackInfo, generation: UInt64) {
        guard generation == pollGeneration else { return }

        richerSourceLastApplied = Date()

        let identifier = info.trackId.isEmpty ? "\(info.title)|\(info.artist)" : info.trackId
        let trackChanged = lastTrackIdentifier != identifier
        if trackChanged {
            lastTrackIdentifier = identifier
            trackName = info.title
            artistName = info.artist
            albumName = info.album
            trackDuration = info.duration
            setPlaybackPosition(info.position)
            artworkImage = info.artwork
            dominantColor = info.color
        } else {
            setPlaybackPosition(info.position)
            if info.duration > 0 { trackDuration = info.duration }
        }

        if isPlaying != info.isPlaying {
            let wasPlaying = isPlaying
            isPlaying = info.isPlaying
            if info.isPlaying && !wasPlaying {
                NotificationCenter.default.post(name: .mediaPlaybackStarted, object: nil)
            } else if !info.isPlaying && wasPlaying {
                NotificationCenter.default.post(name: .mediaPlaybackStopped, object: nil)
            }
        }
    }

    // MARK: - Artwork helpers

    private func createThumbnail(from data: Data, maxPixelSize: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func resizeArtwork(_ image: NSImage) -> NSImage? {
        guard let data = image.tiffRepresentation else { return image }
        guard let thumb = createThumbnail(from: data, maxPixelSize: targetImageSize * 2) else { return image }
        return NSImage(cgImage: thumb, size: NSSize(width: targetImageSize, height: targetImageSize))
    }

    private func averageColor(from image: NSImage) -> Color? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = 1, height = 1, bitsPerComponent = 8, bytesPerRow = 4 * width
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var pixelData = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixelData, width: width, height: height,
                                      bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let r = CGFloat(pixelData[0]) / 255.0, g = CGFloat(pixelData[1]) / 255.0, b = CGFloat(pixelData[2]) / 255.0
        let nsColor = NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(nsColor: NSColor(calibratedHue: hue,
                                       saturation: min(1.0, saturation * 1.5),
                                       brightness: max(0.5, min(1.0, brightness * 1.2)),
                                       alpha: alpha))
    }

    // MARK: - Controls (MRMediaRemote — works universally)

    private func showControlError() {
        controlError = "Unable to control media playback."
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.controlError = nil
        }
    }

    func playPause() {
        if !bridge.sendCommand(.togglePlayPause) { showControlError() }
    }

    func next() {
        if !bridge.sendCommand(.nextTrack) { showControlError() }
    }

    func previous() {
        if !bridge.sendCommand(.previousTrack) { showControlError() }
    }

    func seek(to position: TimeInterval) {
        let clamped = max(0, min(trackDuration, position))
        setPlaybackPosition(clamped)
        _ = bridge.sendCommand(.changePlaybackPosition, options: [mrSeekOption: NSNumber(value: clamped)])
        Task { [weak self] in
            guard let self, let token = await SpotifyAuthController.shared.getValidToken() else { return }
            let positionMs = Int(clamped * 1000)
            guard let url = URL(string: "https://api.spotify.com/v1/me/player/seek?position_ms=\(positionMs)") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 5
            _ = try? await self.urlSession.data(for: req)
        }
    }
}

// MARK: - URLSession sync helper

private extension URLSession {
    func syncData(from url: URL) throws -> (Data, URLResponse) {
        var result: (Data, URLResponse)?
        var resultError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        dataTask(with: url) { data, response, error in
            if let data, let response { result = (data, response) }
            else if let error { resultError = error }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        if let error = resultError { throw error }
        if let result { return result }
        throw NSError(domain: "MediaController", code: -1)
    }
}
