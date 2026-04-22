# NotchMusic - MacBook Pro Notch Music Player

A beautiful, minimal music player that lives in your MacBook Pro's notch area. Shows currently playing Spotify track with playback controls.

![NotchMusic Demo](https://via.placeholder.com/400x200?text=NotchMusic)

## Features

- **Minimal Design**: Sits unobtrusively in the notch area
- **Hover to Expand**: Shows full track info and controls on hover
- **Spotify Integration**: Displays current track, artist, and album
- **Playback Controls**: Play/Pause, Next, Previous
- **Menu Bar Icon**: Quick access to show/hide and quit

## Requirements

- macOS 13.0 or later
- MacBook Pro with notch (2021 or later) - *works on any Mac, but designed for notch*
- Xcode 15.0 or later
- Spotify desktop app installed

## How to Build & Run

### Option 1: Using Xcode (Recommended)

1. **Open the project in Xcode**:
   ```bash
   cd NotchMusic
   open NotchMusic.xcodeproj
   ```

2. **Select your Development Team** (if code signing):
   - Click on the project in the navigator
   - Select "NotchMusic" target
   - Go to "Signing & Capabilities"
   - Select your team or choose "Sign to Run Locally"

3. **Build and Run**:
   - Press `Cmd + R` or click the Play button
   - The app will appear in your menu bar with a music note icon

### Option 2: Using Command Line

```bash
cd NotchMusic
xcodebuild -project NotchMusic.xcodeproj -scheme NotchMusic -configuration Debug build
```

The built app will be in `build/Debug/NotchMusic.app`

## How It Works

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Menu Bar                                 │
├──────────────────────┬───────────────┬──────────────────────┤
│                      │    NOTCH      │                      │
│                      │  ┌─────────┐  │                      │
│                      │  │NotchView│  │                      │
│                      │  └─────────┘  │                      │
└──────────────────────┴───────────────┴──────────────────────┘
```

### Key Components

1. **NotchMusicApp.swift** - Main app entry point
   - Sets up the app delegate
   - Configures the app as accessory (no dock icon)

2. **NotchWindow.swift** - Custom NSWindow
   - Borderless, transparent window
   - Positioned at status bar level above the notch
   - Stays on all spaces

3. **NotchContentView.swift** - SwiftUI view
   - Collapsed state: Small pill showing track name
   - Expanded state: Album art, track info, playback controls
   - Smooth spring animations

4. **SpotifyController.swift** - Spotify integration
   - Uses AppleScript to communicate with Spotify
   - Polls every second for now playing info
   - Controls playback (play/pause/next/previous)

### How the Notch Integration Works

1. The app creates a **borderless window** positioned at the top center of the screen
2. The window is set to **status bar level + 1** so it appears above the menu bar
3. On hover, the window **expands downward** revealing more content
4. The black rounded rectangle mimics the notch's appearance

## Permissions

The app needs **Automation permissions** to control Spotify:

1. On first run, macOS will ask: *"NotchMusic wants to control Spotify"*
2. Click **OK** to allow
3. If you missed it, go to:
   - System Settings → Privacy & Security → Automation
   - Enable NotchMusic → Spotify

## Customization

### Change Colors

In `NotchContentView.swift`, modify the gradient colors:

```swift
LinearGradient(
    colors: [.purple.opacity(0.6), .blue.opacity(0.6)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)
```

### Adjust Size

In `NotchMusicApp.swift`:

```swift
let notchWidth: CGFloat = 200  // Width of the notch view
let notchHeight: CGFloat = 32  // Collapsed height
let expandedHeight: CGFloat = 120  // Expanded height
```

### Support Other Music Apps

To add Apple Music support, modify `SpotifyController.swift`:

```swift
// Change "Spotify" to "Music" for Apple Music
tell application "Music"
    // ... same structure
end tell
```

## Troubleshooting

### App doesn't appear
- Check if it's in the menu bar (music note icon)
- Try clicking "Show/Hide Notch" from the menu

### Can't control Spotify
- Make sure Spotify is running
- Check Automation permissions in System Settings

### Window in wrong position
- The app auto-detects screen size
- For multi-monitor setups, it uses the main screen

## Future Ideas

- [ ] Apple Music support
- [ ] Album artwork from Spotify API
- [ ] Progress bar
- [ ] Volume control
- [ ] Keyboard shortcuts
- [ ] Custom themes

## License

MIT License - Feel free to modify and distribute!

---

Built with SwiftUI for macOS
