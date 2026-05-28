import Foundation
import Combine
import SwiftUI

enum LyricsFontSize: String, CaseIterable {
    case small, medium, large

    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var collapsedSize: CGFloat {
        switch self {
        case .small: return 7
        case .medium: return 9
        case .large: return 11
        }
    }

    var expandedSize: CGFloat {
        switch self {
        case .small: return 8
        case .medium: return 10
        case .large: return 13
        }
    }
}

enum LyricsColorOption: String, CaseIterable {
    case matchMusic, white, yellow, green, blue, pink

    var displayName: String {
        switch self {
        case .matchMusic: return "Match Music"
        case .white: return "White"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        }
    }

    var color: Color {
        switch self {
        case .matchMusic: return Color.white.opacity(0.3)
        case .white: return Color.white.opacity(0.3)
        case .yellow: return Color.yellow.opacity(0.5)
        case .green: return Color.green.opacity(0.5)
        case .blue: return Color.blue.opacity(0.5)
        case .pink: return Color.pink.opacity(0.5)
        }
    }
}

@MainActor
final class LyricsController: ObservableObject {
    static let shared = LyricsController()

    @Published private(set) var currentLine: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var hasLyrics: Bool = false
    @Published private(set) var plainLyricsText: String = ""
    @Published private(set) var isPlainMode: Bool = false
    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: "showLyrics") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "showLyrics")
            if isEnabled {
                triggerFetchForCurrentTrack()
            } else {
                resetLyrics()
            }
        }
    }

    @Published var fontSize: LyricsFontSize = {
        if let raw = UserDefaults.standard.string(forKey: "lyricsFontSize"),
           let value = LyricsFontSize(rawValue: raw) {
            return value
        }
        return .medium
    }() {
        didSet {
            UserDefaults.standard.set(fontSize.rawValue, forKey: "lyricsFontSize")
        }
    }

    @Published var lyricsColor: LyricsColorOption = {
        if let raw = UserDefaults.standard.string(forKey: "lyricsColor"),
           let value = LyricsColorOption(rawValue: raw) {
            return value
        }
        return .white
    }() {
        didSet {
            UserDefaults.standard.set(lyricsColor.rawValue, forKey: "lyricsColor")
        }
    }

    private var syncedLines: [(time: TimeInterval, text: String)] = []
    private var plainLines: [String] = []
    private var isSynced: Bool = false
    private var currentFetchTask: URLSessionDataTask?
    private var cancellables = Set<AnyCancellable>()
    private var lastSyncedIndex: Int = -1
    private var lyricPositionTimer: Timer?

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private init() {
        setupObservers()
    }

    private func setupObservers() {
        let mediaController = MediaController.shared

        if isEnabled {
            let currentTrack = mediaController.trackName
            let currentArtist = mediaController.artistName
            if !currentTrack.isEmpty, !currentArtist.isEmpty {
                fetchLyrics(artist: currentArtist, track: currentTrack)
            }
        }

        mediaController.$trackName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self = self else { return }
                guard self.isEnabled else {
                    print("[Lyrics] track changed but isEnabled=false, skipping")
                    return
                }
                let artist = MediaController.shared.artistName
                guard !track.isEmpty, !artist.isEmpty else {
                    print("[Lyrics] track=\"\(track)\" artist=\"\(artist)\" — empty, skipping")
                    return
                }
                print("[Lyrics] track changed: \"\(track)\" by \"\(artist)\", fetching...")
                self.resetLyrics()
                self.fetchLyrics(artist: artist, track: track)
            }
            .store(in: &cancellables)

        mediaController.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                guard let self else { return }
                if self.isPlainMode { return }
                if isPlaying {
                    self.startLyricTimer()
                } else {
                    self.stopLyricTimer()
                }
            }
            .store(in: &cancellables)

        mediaController.$trackDuration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updatePlainMode()
            }
            .store(in: &cancellables)

        if mediaController.isPlaying, !isPlainMode {
            startLyricTimer()
        }
    }

    private func startLyricTimer() {
        stopLyricTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.updateLine(for: MediaController.shared.playbackPosition)
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        lyricPositionTimer = timer
    }

    private func stopLyricTimer() {
        lyricPositionTimer?.invalidate()
        lyricPositionTimer = nil
    }

    // MARK: - Fetching

    private func fetchLyrics(artist: String, track: String) {
        currentFetchTask?.cancel()
        isLoading = true
        print("[Lyrics] fetching: \"\(track)\" by \"\(artist)\"")

        guard let artistEncoded = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let trackEncoded = track.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lrclib.net/api/get?artist_name=\(artistEncoded)&track_name=\(trackEncoded)") else {
            isLoading = false
            print("[Lyrics] failed to build URL")
            return
        }

        currentFetchTask = urlSession.dataTask(with: url) { [weak self] data, _, error in
            guard let self, let data, error == nil else {
                Task { @MainActor [weak self] in
                    self?.fetchFromSearch(artist: artist, track: track)
                }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(LRCLibResponse.self, from: data)
                Task { @MainActor [weak self] in
                    self?.processLyrics(decoded)
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.fetchFromSearch(artist: artist, track: track)
                }
            }
        }
        currentFetchTask?.resume()
    }

    private func fetchFromSearch(artist: String, track: String) {
        let query = "\(artist) \(track)"
        guard let queryEncoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lrclib.net/api/search?q=\(queryEncoded)") else {
            isLoading = false
            hasLyrics = false
            return
        }

        currentFetchTask = urlSession.dataTask(with: url) { [weak self] data, _, error in
            guard let self, let data, error == nil else {
                Task { @MainActor [weak self] in
                    self?.isLoading = false
                    self?.hasLyrics = false
                }
                return
            }
            do {
                let results = try JSONDecoder().decode([LRCLibResponse].self, from: data)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let first = results.first {
                        self.processLyrics(first)
                    } else {
                        self.isLoading = false
                        self.hasLyrics = false
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.isLoading = false
                    self?.hasLyrics = false
                }
            }
        }
        currentFetchTask?.resume()
    }

    // MARK: - Processing

    private struct LRCLibResponse: Codable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    private func processLyrics(_ response: LRCLibResponse) {
        isLoading = false
        print("[Lyrics] response — synced=\(response.syncedLyrics != nil) plain=\(response.plainLyrics != nil)")

        let hasPosition = MediaController.shared.trackDuration > 0

        if let synced = response.syncedLyrics, !synced.isEmpty, hasPosition {
            syncedLines = parseLRC(synced)
            if !syncedLines.isEmpty {
                isSynced = true
                hasLyrics = true
                isPlainMode = false
                plainLyricsText = ""
                print("[Lyrics] synced lyrics parsed: \(syncedLines.count) lines")
                restartTimerIfPlaying()
                return
            }
        }

        // If no position data or no synced lyrics, use plain text
        if let synced = response.syncedLyrics, !synced.isEmpty, !hasPosition {
            // We have synced data but can't sync — extract just the text
            let lines = parseLRC(synced).map { $0.text }
            plainLines = lines
            plainLyricsText = lines.joined(separator: "\n")
            isSynced = false
            hasLyrics = true
            isPlainMode = true
            stopLyricTimer()
            return
        }

        if let plain = response.plainLyrics, !plain.isEmpty {
            plainLines = plain.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                }
                .filter { !$0.isEmpty }
            isSynced = false
            hasLyrics = true
            plainLyricsText = plain
            // Check if we should use plain mode (no position = browser source)
            updatePlainMode()
            return
        }

        hasLyrics = false
        plainLyricsText = ""
        isPlainMode = false
    }

    private func updatePlainMode() {
        let hasPosition = MediaController.shared.trackDuration > 0
        isPlainMode = !isSynced || !hasPosition
        if isPlainMode {
            stopLyricTimer()
        } else {
            restartTimerIfPlaying()
        }
    }

    private func restartTimerIfPlaying() {
        guard MediaController.shared.isPlaying else { return }
        startLyricTimer()
    }

    // MARK: - LRC Parsing

    private func parseLRC(_ lrc: String) -> [(time: TimeInterval, text: String)] {
        let lines = lrc.components(separatedBy: "\n")
        var parsed: [(TimeInterval, String)] = []

        let pattern = #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for line in lines {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }

            guard let minRange = Range(match.range(at: 1), in: line),
                  let secRange = Range(match.range(at: 2), in: line),
                  let textRange = Range(match.range(at: 4), in: line) else { continue }

            let minutes = TimeInterval(line[minRange]) ?? 0
            let seconds = TimeInterval(line[secRange]) ?? 0
            let centiseconds: TimeInterval = {
                if let msRange = Range(match.range(at: 3), in: line),
                   let ms = TimeInterval(line[msRange]) {
                    return ms >= 100 ? ms / 1000 : ms / 100
                }
                return 0
            }()

            let totalSeconds = minutes * 60 + seconds + centiseconds
            let text = String(line[textRange])
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            
            if !text.isEmpty {
                parsed.append((totalSeconds, text))
            }
        }

        return parsed.sorted { $0.0 < $1.0 }
    }

    // MARK: - Line Mapping

    private func updateLine(for position: TimeInterval) {
        guard hasLyrics, isSynced, !syncedLines.isEmpty else { return }

        var bestIndex = -1
        for i in 0..<syncedLines.count {
            if syncedLines[i].time <= position {
                bestIndex = i
            } else {
                break
            }
        }

        if bestIndex >= 0, bestIndex != lastSyncedIndex {
            lastSyncedIndex = bestIndex
            let newLine = syncedLines[bestIndex].text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            currentLine = newLine
        }
    }

    private func triggerFetchForCurrentTrack() {
        let mediaController = MediaController.shared
        let track = mediaController.trackName
        let artist = mediaController.artistName
        guard !track.isEmpty, !artist.isEmpty else { return }
        resetLyrics()
        fetchLyrics(artist: artist, track: track)
    }

    // MARK: - Reset

    private func resetLyrics() {
        currentFetchTask?.cancel()
        currentFetchTask = nil
        syncedLines = []
        plainLines = []
        isSynced = false
        hasLyrics = false
        currentLine = ""
        isLoading = false
        lastSyncedIndex = -1
        stopLyricTimer()
    }
}
