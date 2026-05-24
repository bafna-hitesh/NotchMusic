# NotchMusic

A beautiful, minimal Spotify player that lives in your MacBook Pro's notch.

## Features

- Sits cleanly inside the hardware notch, always visible but never in the way
- Click the notch to expand and see full album art, track info, and controls
- Real-time Spotify sync with dominant album color extraction
- Lyrics display synced to the current track
- 0% background CPU — zero polling, fully event-driven
- Collapses automatically when Spotify is not running

## Requirements

- macOS 13.0+
- MacBook Pro with a notch (2021 or later)
- Spotify desktop app installed and running
- A free Spotify Developer account (for API access)

## Quick Install (Download & Use)

1. Go to [Releases](https://github.com/bafna-hitesh/NotchMusic/releases) and download the latest `NotchMusic.zip`
2. Unzip and drag `NotchMusic.app` to your Applications folder
3. **Important:** The first time you open it, macOS will block it because the app is not notarized. Right-click (or Ctrl-click) the app and select **Open** → then click **Open** in the dialog. You only need to do this once.
4. Grant permission when macOS asks to control Spotify. Click **OK**.

## Build from Source

### 1. Get a Spotify Client ID

- Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
- Log in and click **Create App**
- Give it a name (e.g. "NotchMusic")
- Set **Redirect URI** to: `notchmusic://callback`
- Under **APIs Used**, select **Web API**
- Copy your **Client ID**

### 2. Configure the project

```bash
git clone https://github.com/bafna-hitesh/NotchMusic.git
cd NotchMusic
```

Create `NotchMusic/NotchMusic/Secrets.xcconfig` with your Client ID:

```
SPOTIFY_CLIENT_ID = your_client_id_here
```

Or copy the example file and edit it:

```bash
cp NotchMusic/NotchMusic/Secrets.xcconfig.example NotchMusic/NotchMusic/Secrets.xcconfig
# Then edit Secrets.xcconfig and paste your Client ID
```

### 3. Open & Build

- Open `NotchMusic/NotchMusic.xcodeproj` in Xcode
- Select **Product → Run** (or press `Cmd+R`)
- The app appears in your menu bar, docked to the notch

### 4. Install permanently

After building, right-click `NotchMusic.app` in Xcode's Products folder → **Show in Finder** → drag it to your Applications folder.

## Troubleshooting

**"NotchMusic can't be opened because it can't be verified"**
→ Right-click the app → **Open** → click **Open**. This is a one-time bypass.

**Spotify not connecting?**
- Make sure Spotify desktop app is running
- Check that you configured the Spotify Client ID and Redirect URI correctly
- Try quitting and reopening NotchMusic

**Window not appearing in the notch?**
- Make sure you're on a MacBook Pro with a notch (2021+)
- External monitors don't have notches — the app targets the built-in display only

## License

MIT License
