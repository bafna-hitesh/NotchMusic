import Foundation

final class MediaRemoteBridge {
    static let shared = MediaRemoteBridge()

    private let frameworkHandle: UnsafeMutableRawPointer?
    let isAvailable: Bool

    // MARK: - Function pointers

    private let _getNowPlayingInfo: UnsafeMutableRawPointer?
    private let _sendCommand: UnsafeMutableRawPointer?
    private let _registerForNotifications: UnsafeMutableRawPointer?
    private let _unregisterForNotifications: UnsafeMutableRawPointer?

    // MARK: - Resolved notification names (via dlsym, with fallback)

    let nowPlayingInfoDidChangeNotification: Notification.Name
    let nowPlayingPlaybackStateDidChangeNotification: Notification.Name
    let nowPlayingApplicationDidChangeNotification: Notification.Name
    let nowPlayingApplicationIsPlayingDidChangeNotification: Notification.Name

    private init() {
        frameworkHandle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_LAZY
        )
        isAvailable = frameworkHandle != nil

        guard let handle = frameworkHandle else {
            _getNowPlayingInfo = nil
            _sendCommand = nil
            _registerForNotifications = nil
            _unregisterForNotifications = nil
            nowPlayingInfoDidChangeNotification = Notification.Name("_kMRMediaRemoteNowPlayingInfoDidChangeNotification")
            nowPlayingPlaybackStateDidChangeNotification = Notification.Name("_kMRMediaRemoteNowPlayingPlaybackStateDidChangeNotification")
            nowPlayingApplicationDidChangeNotification = Notification.Name("_kMRMediaRemoteNowPlayingApplicationDidChangeNotification")
            nowPlayingApplicationIsPlayingDidChangeNotification = Notification.Name("_kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")
            return
        }

        _getNowPlayingInfo = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo")
        _sendCommand = dlsym(handle, "MRMediaRemoteSendCommand")
        _registerForNotifications = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications")
        _unregisterForNotifications = dlsym(handle, "MRMediaRemoteUnregisterForNowPlayingNotifications")

        nowPlayingInfoDidChangeNotification = Self.resolveNotification(handle, "kMRMediaRemoteNowPlayingInfoDidChangeNotification")
        nowPlayingPlaybackStateDidChangeNotification = Self.resolveNotification(handle, "kMRMediaRemoteNowPlayingPlaybackStateDidChangeNotification")
        nowPlayingApplicationDidChangeNotification = Self.resolveNotification(handle, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification")
        nowPlayingApplicationIsPlayingDidChangeNotification = Self.resolveNotification(handle, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")
    }

    deinit {
        if let handle = frameworkHandle {
            dlclose(handle)
        }
    }

    // MARK: - Safe CFString resolution

    private var keyCache: [String: String] = [:]

    private func resolveCFString(_ name: String) -> String {
        if let cached = keyCache[name] { return cached }

        guard let handle = frameworkHandle else {
            keyCache[name] = name
            return name
        }

        guard let sym = dlsym(handle, name) else {
            print("[MediaRemoteBridge] dlsym miss for \(name)")
            keyCache[name] = name
            return name
        }

        // dlsym returns the address where the CFStringRef is stored.
        // CFStringRef is itself a pointer. Read the raw pointer-sized value.
        let raw = sym.assumingMemoryBound(to: UInt.self).pointee
        guard raw != 0, let ptr = UnsafeRawPointer(bitPattern: raw) else {
            print("[MediaRemoteBridge] null value for \(name), using literal")
            keyCache[name] = name
            return name
        }

        let str = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        print("[MediaRemoteBridge] resolved \(name) -> \"\(str)\"")
        keyCache[name] = str
        return str
    }

    func resolveInfoKey(_ name: String) -> String {
        resolveCFString(name)
    }

    private static func resolveNotification(_ handle: UnsafeMutableRawPointer, _ name: String) -> Notification.Name {
        // Same safe approach: read raw pointer, convert to CFString
        guard let sym = dlsym(handle, name) else {
            print("[MediaRemoteBridge] dlsym failed for \(name), using fallback")
            return Notification.Name(name)
        }
        let raw = sym.assumingMemoryBound(to: UInt.self).pointee
        guard raw != 0, let ptr = UnsafeRawPointer(bitPattern: raw) else {
            print("[MediaRemoteBridge] null pointer for \(name), using fallback")
            return Notification.Name(name)
        }
        let str = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        print("[MediaRemoteBridge] resolved notification \(name) -> \"\(str)\"")
        return Notification.Name(str)
    }

    // MARK: - Public API

    func registerForNotifications() {
        guard let fn = _registerForNotifications else {
            print("[MediaRemoteBridge] registerForNotifications: fn is nil")
            return
        }
        typealias Func = @convention(c) (DispatchQueue) -> Void
        let register = unsafeBitCast(fn, to: Func.self)
        register(.main)
        print("[MediaRemoteBridge] registered for notifications")
    }

    func unregisterForNotifications() {
        guard let fn = _unregisterForNotifications else { return }
        typealias Func = @convention(c) () -> Void
        let unregister = unsafeBitCast(fn, to: Func.self)
        unregister()
    }

    func getNowPlayingInfo(completion: @escaping ([String: Any]) -> Void) {
        guard let fn = _getNowPlayingInfo else {
            completion([:])
            return
        }

        typealias MRBlock = @convention(block) (NSDictionary?) -> Void
        let callback: MRBlock = { nsDict in
            guard let nsDict else {
                completion([:])
                return
            }
            var result: [String: Any] = [:]
            for (key, value) in nsDict {
                if let keyStr = key as? String {
                    result[keyStr] = value
                }
            }
            completion(result)
        }

        typealias GetFn = @convention(c) (DispatchQueue, MRBlock) -> Void
        let getInfo = unsafeBitCast(fn, to: GetFn.self)
        getInfo(.main, callback)
    }

    func sendCommand(_ command: MRMediaRemoteCommand, options: NSDictionary? = nil) -> Bool {
        guard let fn = _sendCommand else { return false }
        typealias Func = @convention(c) (UInt32, NSDictionary?) -> Bool
        let send = unsafeBitCast(fn, to: Func.self)
        return send(command.rawValue, options)
    }
}

// MARK: - Command enum

enum MRMediaRemoteCommand: UInt32 {
    case play = 0
    case pause = 1
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
    case changePlaybackPosition = 15
}
