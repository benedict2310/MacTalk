# MacTalk Screenshots

This folder contains screenshots of the MacTalk application.

## Files

### Menu Bar Interface
- **`menu.png`** - Menu bar dropdown showing all available options
  - Shows recording modes (Mic Only / Mic + App Audio)
  - Settings and permissions access
  - Keyboard shortcuts displayed
  - Use for: Documentation, README, tutorials

### Recording HUD
- **`recording-compact.png`** - Compact HUD during active recording
  - Elapsed time
  - Live activity indicator
  - Minimal footprint for dictation
  - Use for: README, release notes, quick-start docs

- **`recording.png`** - Expanded HUD during active recording
  - Partial transcript preview
  - Stop button control
  - Updated Liquid Glass styling
  - Use for: Feature demonstrations, README

## Taking New Screenshots

To capture screenshots for MacTalk:

1. **Menu Bar Screenshot:**
   ```bash
   # Click menu bar icon, then:
   # Press Cmd+Shift+4, press Space, click the menu
   ```

2. **HUD Screenshot:**
   ```bash
   # Start recording to show HUD, then:
   # Press Cmd+Shift+4, press Space, click the HUD window
   ```

3. **Save to this folder:**
   ```bash
   mv ~/Desktop/Screenshot*.png docs/screenshots/
   ```

## Usage in README

Current usage in main README.md:

```markdown
### Menu Bar Interface
![MacTalk Menu](docs/screenshots/menu.png)

### Recording HUD
![Recording HUD Compact](docs/screenshots/recording-compact.png)

![Recording HUD Expanded](docs/screenshots/recording.png)
```

## License

These screenshots are part of the MacTalk project and follow the same license as the main repository.
