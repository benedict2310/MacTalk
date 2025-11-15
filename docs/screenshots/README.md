# MacTalk Screenshots & Marketing Assets

This folder contains marketing materials and screenshots for MacTalk.

## Files

### Hero Image
- **`mactalk-hero.svg`** - Main hero image showing the app in action with HUD overlay
  - Dimensions: 1600x900px (16:9)
  - Use for: Website header, GitHub README, documentation

### Social Media
- **`social-card.svg`** - Optimized for social media sharing (Twitter, LinkedIn, etc.)
  - Dimensions: 1200x630px (Open Graph standard)
  - Use for: Social media previews, link sharing

### Feature Showcase
- **`feature-grid.svg`** - 2x3 grid showcasing all major features
  - Dimensions: 1400x800px
  - Use for: Documentation, presentations, website

## Design Philosophy

All marketing assets follow the **Technical Elegance** design philosophy:
- Dark, sophisticated color palette inspired by developer tools
- Minimal, purposeful typography
- Grid-based layouts with precise spacing
- Monospace fonts for technical authenticity
- Color accents: Green (#33b34d), Blue (#6699ff), Orange (#ff9933)

## Converting to PNG

To convert SVG files to PNG for better compatibility:

```bash
# Using ImageMagick (if installed)
for file in *.svg; do
  convert "$file" "${file%.svg}.png"
done

# Or using macOS's built-in qlmanage
for file in *.svg; do
  qlmanage -t -s 1600 -o . "$file"
done
```

Alternatively, open the SVG files in a browser and take screenshots, or use online converters like:
- https://cloudconvert.com/svg-to-png
- https://svgtopng.com/

## Usage in README

Add to your README.md:

```markdown
## Screenshots

### MacTalk in Action
![MacTalk Hero](docs/screenshots/mactalk-hero.svg)

### Features
![Features Grid](docs/screenshots/feature-grid.svg)
```

## Customization

All files are SVG format and can be edited in:
- **Figma**: Import SVG
- **Sketch**: Open SVG file
- **Inkscape**: Free, open-source SVG editor
- **VS Code**: Install SVG extension for live preview
- **Text Editor**: SVG is XML-based text format

## Color Palette

```css
--background-dark: #14141a
--background-medium: #1a1a20
--background-light: #26262b
--border: #2a2a30
--text-primary: #f2f2f7
--text-secondary: #9999a6
--text-tertiary: #80808c
--accent-green: #33b34d
--accent-blue: #6699ff
--accent-orange: #ff9933
--accent-red: #cc3333
```

## License

These marketing assets are part of the MacTalk project and follow the same license as the main repository.
