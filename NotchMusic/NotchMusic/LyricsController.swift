import Foundation
import Combine

@MainActor
final class LyricsController: ObservableObject {
    static let shared = LyricsController()

    @Published private(set) var currentLine: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var hasLyrics: Bool = false

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
        let spotify = SpotifyController.shared
        let currentTrack = spotify.trackName
        let currentArtist = spotify.artistName
        if !currentTrack.isEmpty, !currentArtist.isEmpty {
            fetchLyrics(artist: currentArtist, track: currentTrack)
        }

        spotify.$trackName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self = self else { return }
                let artist = SpotifyController.shared.artistName
                guard !track.isEmpty, !artist.isEmpty else { return }
                self.resetLyrics()
                self.fetchLyrics(artist: artist, track: track)
            }
            .store(in: &cancellables)

        spotify.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                if isPlaying {
                    self?.startLyricTimer()
                } else {
                    self?.stopLyricTimer()
                }
            }
            .store(in: &cancellables)

        if spotify.isPlaying {
            startLyricTimer()
        }
    }

    private func startLyricTimer() {
        stopLyricTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.updateLine(for: SpotifyController.shared.playbackPosition)
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

        guard let artistEncoded = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let trackEncoded = track.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://lrclib.net/api/get?artist_name=\(artistEncoded)&track_name=\(trackEncoded)") else {
            isLoading = false
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

        if let synced = response.syncedLyrics, !synced.isEmpty {
            syncedLines = parseLRC(synced)
            if !syncedLines.isEmpty {
                isSynced = true
                hasLyrics = true
                restartTimerIfPlaying()
                return
            }
        }

        if let plain = response.plainLyrics, !plain.isEmpty {
            plainLines = plain.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                }
                .filter { !$0.isEmpty }
            isSynced = false
            hasLyrics = !plainLines.isEmpty
            currentLine = plainLines.first ?? ""
            return
        }

        hasLyrics = false
    }

    private func restartTimerIfPlaying() {
        guard SpotifyController.shared.isPlaying else { return }
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
