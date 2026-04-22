import Foundation
import AppKit
import SwiftUI

final class SpotifyController: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var trackName: String = ""
    @Published private(set) var artistName: String = ""
    @Published private(set) var albumName: String = ""
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var dominantColor: Color?
    
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
    
    init() {
        setupCachedScripts()
        setupSpotifyNotifications()
        updateNowPlaying()
    }
    
    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        urlSession.invalidateAndCancel()
        cachedScript = nil
        cachedArtworkScript = nil
        cachedPlayPauseScript = nil
        cachedNextScript = nil
        cachedPreviousScript = nil
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
                self.isPlaying = newIsPlaying
            }
            
            if self.lastTrackId != trackId || self.trackName != newTrackName {
                self.lastTrackId = trackId
                self.trackName = newTrackName
                self.artistName = newArtistName
                self.albumName = newAlbumName
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
                self.resetArtwork(for: trackId, fetchId: fetchId)
                return
            }
            
            self.urlSession.dataTask(with: url) { [weak self] data, response, error in
                guard let self = self,
                      self.currentFetchId == fetchId,
                      let data = data,
                      let originalImage = NSImage(data: data) else {
                    self?.resetArtwork(for: trackId, fetchId: fetchId)
                    return
                }
                
                let downsampledImage = self.downsample(image: originalImage, to: self.targetImageSize)
                let color = self.averageColor(from: downsampledImage ?? originalImage)
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self,
                          self.currentFetchId == fetchId,
                          self.lastTrackId == trackId else { return }
                    
                    self.artworkImage = downsampledImage ?? originalImage
                    self.dominantColor = color
                }
            }.resume()
        }
    }
    
    private func downsample(image: NSImage, to targetSize: CGFloat) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetSize * 2
        ]
        
        guard let imageData = image.tiffRepresentation,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        
        return NSImage(cgImage: thumbnail, size: NSSize(width: targetSize, height: targetSize))
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
                                   brightness: min(1.0, brightness * 1.2),
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
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let info = self.getSpotifyInfo()
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                let newIsPlaying = info?.isPlaying ?? false
                let newTrackName = info?.track ?? ""
                let newArtistName = info?.artist ?? ""
                let newAlbumName = info?.album ?? ""
                let newTrackId = info?.trackId ?? ""
                
                if self.isPlaying != newIsPlaying {
                    self.isPlaying = newIsPlaying
                }
                
                if self.lastTrackId != newTrackId {
                    self.lastTrackId = newTrackId
                    self.trackName = newTrackName
                    self.artistName = newArtistName
                    self.albumName = newAlbumName
                    self.fetchArtwork(for: newTrackId)
                }
            }
        }
    }
    
    private func getSpotifyInfo() -> (isPlaying: Bool, track: String, artist: String, album: String, trackId: String)? {
        guard let script = cachedScript else { return nil }
        
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        
        guard let result = output.stringValue else { return nil }
        
        if result == "not_running" || result == "stopped" {
            return (false, "", "", "", "")
        }
        
        let parts = result.components(separatedBy: "|")
        guard parts.count >= 5 else { return nil }
        
        let isPlaying = parts[0] == "playing"
        return (isPlaying, parts[1], parts[2], parts[3], parts[4])
    }
    
    func playPause() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            self?.cachedPlayPauseScript?.executeAndReturnError(&error)
        }
    }
    
    func next() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            self?.cachedNextScript?.executeAndReturnError(&error)
        }
    }
    
    func previous() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            self?.cachedPreviousScript?.executeAndReturnError(&error)
        }
    }
}
