import Foundation
import AppKit
import SwiftUI

extension Notification.Name {
    static let spotifyPlaybackStarted = Notification.Name("spotifyPlaybackStarted")
    static let spotifyRunningStateChanged = Notification.Name("spotifyRunningStateChanged")
    static let spotifyHeartbeat = Notification.Name("spotifyHeartbeat")
}

final class SpotifyController: ObservableObject {
    static let shared = SpotifyController()
    
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isSpotifyRunning: Bool = false
    @Published private(set) var trackName: String = ""
    @Published private(set) var artistName: String = ""
    @Published private(set) var albumName: String = ""
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var dominantColor: Color?
    @Published var controlError: String?
    private var positionBase: TimeInterval = 0
    private var positionBaseTime = Date()
    private var correctionTimer: Timer?

    /// Wall-clock interpolated position. Consumers poll this 2-10×/s so no timer needed.
    var playbackPosition: TimeInterval {
        guard isPlaying else { return positionBase }
        return positionBase + Date().timeIntervalSince(positionBaseTime)
    }

    private func setPlaybackPosition(_ pos: TimeInterval) {
        positionBase = pos
        positionBaseTime = Date()
    }

    private var cachedScript: NSAppleScript?
    private var cachedArtworkScript: NSAppleScript?
    private var cachedPlayPauseScript: NSAppleScript?
    private var cachedNextScript: NSAppleScript?
    private var cachedPreviousScript: NSAppleScript?
    
    private var lastTrackId: String = ""
    private var currentFetchId: UUID?
    
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    
    private let targetImageSize: CGFloat = 64

    // MARK: - Position Tracking

    private func startPositionTimer() {
        stopPositionTimer()
        setPlaybackPosition(0)
        correctionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.fetchPlaybackState() }
            NotificationCenter.default.post(name: .spotifyHeartbeat, object: nil)
        }
        correctionTimer?.tolerance = 2.0
    }

    private func stopPositionTimer() {
        correctionTimer?.invalidate()
        correctionTimer = nil
    }

#if DEBUG
    private var apiHealthCounter = 0
#endif

    @MainActor
    private func fetchPlaybackState() async {
        guard let token = await SpotifyAuthController.shared.getValidToken() else {
            print("[SpotifyAPI] no token — falling back to AppleScript")
            correctViaAppleScript()
            return
        }
        var req = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 5

        guard let (data, response) = try? await urlSession.data(for: req),
              let http = response as? HTTPURLResponse
        else {
            print("[SpotifyAPI] network error — falling back to AppleScript")
            correctViaAppleScript()
            return
        }

        if http.statusCode == 204 {
            return
        }

        if http.statusCode == 401 {
            print("[SpotifyAPI] 401 — refreshing token")
            _ = await SpotifyAuthController.shared.refreshAccessToken()
            correctViaAppleScript()
            return
        }

        if http.statusCode == 429 {
            print("[SpotifyAPI] 429 rate limited")
            return
        }

        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let progressMs = json["progress_ms"] as? TimeInterval
        else {
            print("[SpotifyAPI] unexpected response (HTTP \(http.statusCode))")
            correctViaAppleScript()
            return
        }

        setPlaybackPosition(progressMs / 1000.0)

        // If API says paused but we think we're playing, we missed a notification
        // (hardware media key, Touch Bar, etc). Self-correct before drift accumulates.
        let apiIsPlaying = json["is_playing"] as? Bool ?? true
        if !apiIsPlaying, isPlaying {
            isPlaying = false
            stopPositionTimer()
        }

#if DEBUG
        // Periodic health log — once every ~30s so it's not noisy
        apiHealthCounter += 1
        if apiHealthCounter % 6 == 1 {
            let item = json["item"] as? [String: Any]
            let name = item?["name"] as? String ?? "?"
            let artists = (item?["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            print("[SpotifyAPI] OK | now: \(name) — \(artists.joined(separator: ", ")) | pos: \(Int(progressMs / 1000))s")
        }
#endif
    }

    private func correctViaAppleScript() {
        let script = NSAppleScript(source: """
        tell application "Spotify"
            return player position
        end tell
        """)
        var error: NSDictionary?
        if let result = script?.executeAndReturnError(&error).doubleValue, result > 0 {
            setPlaybackPosition(result)
        } else if error != nil {
            print("[AppleScript] correctViaAppleScript error: \(error!)")
        }
    }

    private init() {
        setupCachedScripts()
        setupSpotifyNotifications()
        setupWorkspaceNotifications()
        checkSpotifyRunning()
        updateNowPlaying()
    }
    
    private func setupWorkspaceNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }
    
    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.spotify.client" else { return }
        
        DispatchQueue.main.async { [weak self] in
            self?.isSpotifyRunning = true
            NotificationCenter.default.post(name: .spotifyRunningStateChanged, object: nil, userInfo: ["isRunning": true])
        }
    }
    
    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.spotify.client" else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isSpotifyRunning = false
            self.isPlaying = false
            self.stopPositionTimer()
            self.setPlaybackPosition(0)
            self.trackName = ""
            self.artistName = ""
            self.albumName = ""
            self.artworkImage = nil
            self.dominantColor = nil
            self.lastTrackId = ""
            NotificationCenter.default.post(name: .spotifyRunningStateChanged, object: nil, userInfo: ["isRunning": false])
        }
    }
    
    private func checkSpotifyRunning() {
        let isRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
        isSpotifyRunning = isRunning
        if isRunning {
            NotificationCenter.default.post(name: .spotifyRunningStateChanged, object: nil, userInfo: ["isRunning": true])
        }
    }
    
    private func setupSpotifyNotifications() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(spotifyStateChanged),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
    }
    
    @objc private func spotifyStateChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let newState = userInfo["Player State"] as? String ?? ""
            let newIsPlaying = newState == "Playing"
            let newTrackName = userInfo["Name"] as? String ?? ""
            let newArtistName = userInfo["Artist"] as? String ?? ""
            let newAlbumName = userInfo["Album"] as? String ?? ""
            let trackId = userInfo["Track ID"] as? String ?? ""
            
            if self.isPlaying != newIsPlaying {
                let wasPlaying = self.isPlaying
                self.isPlaying = newIsPlaying

                if newIsPlaying && !wasPlaying {
                    self.startPositionTimer()
                    NotificationCenter.default.post(name: .spotifyPlaybackStarted, object: nil)
                } else if !newIsPlaying {
                    self.stopPositionTimer()
                }
            }

            if self.lastTrackId != trackId || self.trackName != newTrackName {
                self.lastTrackId = trackId
                self.trackName = newTrackName
                self.artistName = newArtistName
                self.albumName = newAlbumName
                self.setPlaybackPosition(0)
                self.fetchArtwork(for: trackId)
            }
        }
    }

    private func fetchArtwork(for trackId: String) {
        let fetchId = UUID()
        currentFetchId = fetchId
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            var error: NSDictionary?
            guard let script = self.cachedArtworkScript,
                  let result = script.executeAndReturnError(&error).stringValue,
                  !result.isEmpty,
                  let url = URL(string: result) else {
                if let error = error { print("[AppleScript] fetchArtwork error: \(error)") }
                self.resetArtwork(for: trackId, fetchId: fetchId)
                return
            }
            
            self.urlSession.dataTask(with: url) { [weak self] data, response, error in
                guard let self = self,
                      self.currentFetchId == fetchId,
                      let data = data else {
                    self?.resetArtwork(for: trackId, fetchId: fetchId)
                    return
                }

                let thumbnail = self.createThumbnail(from: data, maxPixelSize: self.targetImageSize * 2)
                let image = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: self.targetImageSize, height: self.targetImageSize)) }
                let color = image.flatMap { self.averageColor(from: $0) }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self,
                          self.currentFetchId == fetchId,
                          self.lastTrackId == trackId else { return }

                    self.artworkImage = image
                    self.dominantColor = color
                }
            }.resume()
        }
    }
    
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
    
    private func resetArtwork(for trackId: String, fetchId: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.currentFetchId == fetchId,
                  self.lastTrackId == trackId else { return }
            
            self.artworkImage = nil
            self.dominantColor = nil
        }
    }
    
    private func averageColor(from image: NSImage) -> Color? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        
        let width = 1
        let height = 1
        let bitsPerComponent = 8
        let bytesPerRow = 4 * width
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        
        var pixelData = [UInt8](repeating: 0, count: 4)
        
        guard let context = CGContext(data: &pixelData,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: bitsPerComponent,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else {
            return nil
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        let r = CGFloat(pixelData[0]) / 255.0
        let g = CGFloat(pixelData[1]) / 255.0
        let b = CGFloat(pixelData[2]) / 255.0
        
        let nsColor = NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
        
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        
        let boostedColor = NSColor(calibratedHue: hue,
                                   saturation: min(1.0, saturation * 1.5),
                                   brightness: max(0.5, min(1.0, brightness * 1.2)),
                                   alpha: alpha)
        
        return Color(nsColor: boostedColor)
    }
    
    private func setupCachedScripts() {
        cachedScript = NSAppleScript(source: """
        tell application "System Events"
            if not (exists process "Spotify") then
                return "not_running"
            end if
        end tell
        
        tell application "Spotify"
            if player state is playing then
                set trackName to name of current track
                set artistName to artist of current track
                set albumName to album of current track
                set trackId to id of current track
                return "playing|" & trackName & "|" & artistName & "|" & albumName & "|" & trackId
            else if player state is paused then
                set trackName to name of current track
                set artistName to artist of current track
                set albumName to album of current track
                set trackId to id of current track
                return "paused|" & trackName & "|" & artistName & "|" & albumName & "|" & trackId
            else
                return "stopped"
            end if
        end tell
        """)
        
        cachedArtworkScript = NSAppleScript(source: """
        tell application "Spotify"
            try
                return artwork url of current track
            on error
                return ""
            end try
        end tell
        """)
        
        cachedPlayPauseScript = NSAppleScript(source: """
        tell application "Spotify"
            playpause
        end tell
        """)
        
        cachedNextScript = NSAppleScript(source: """
        tell application "Spotify"
            next track
        end tell
        """)
        
        cachedPreviousScript = NSAppleScript(source: """
        tell application "Spotify"
            previous track
        end tell
        """)
    }
    
    func updateNowPlaying() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let info = self.getSpotifyInfo()

            let newIsPlaying = info?.isPlaying ?? false
            let newTrackName = info?.track ?? ""
            let newArtistName = info?.artist ?? ""
            let newAlbumName = info?.album ?? ""
            let newTrackId = info?.trackId ?? ""

            if self.isPlaying != newIsPlaying {
                let wasPlaying = self.isPlaying
                self.isPlaying = newIsPlaying

                if newIsPlaying && !wasPlaying {
                    self.startPositionTimer()
                    NotificationCenter.default.post(name: .spotifyPlaybackStarted, object: nil)
                } else if !newIsPlaying {
                    self.stopPositionTimer()
                }
            }

            if self.lastTrackId != newTrackId {
                self.lastTrackId = newTrackId
                self.trackName = newTrackName
                self.artistName = newArtistName
                self.albumName = newAlbumName
                self.setPlaybackPosition(0)
                self.fetchArtwork(for: newTrackId)
            }
        }
    }
    
    private func getSpotifyInfo() -> (isPlaying: Bool, track: String, artist: String, album: String, trackId: String)? {
        guard let script = cachedScript else { return nil }
        
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        
        guard let result = output.stringValue else {
            if let error = error { print("[AppleScript] getSpotifyInfo error: \(error)") }
            return nil
        }

        if result == "not_running" || result == "stopped" {
            return (false, "", "", "", "")
        }

        let parts = result.components(separatedBy: "|")
        guard parts.count >= 5 else { return nil }

        let isPlaying = parts[0] == "playing"
        return (isPlaying, parts[1], parts[2], parts[3], parts[4])
    }

    private func showControlError() {
        controlError = "Unable to control Spotify. Check Automation permission in System Settings."
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.controlError = nil
        }
    }

    func playPause() {
        var error: NSDictionary?
        cachedPlayPauseScript?.executeAndReturnError(&error)
        if error != nil { print("[AppleScript] playPause error: \(error!)"); showControlError() }
    }

    func next() {
        var error: NSDictionary?
        cachedNextScript?.executeAndReturnError(&error)
        if error != nil { print("[AppleScript] next error: \(error!)"); showControlError() }
    }

    func previous() {
        var error: NSDictionary?
        cachedPreviousScript?.executeAndReturnError(&error)
        if error != nil { print("[AppleScript] previous error: \(error!)"); showControlError() }
    }
}
