![Capsule Logo](assets/homescreen.png)

## About
The idea for Capsule sprung from my desire to add more images and videos to my journal entries in Obsidian without bloating the size of my vault. Quick images for my journal don't need the giant 5MB quality that my phone saves by default. I wanted something like [Squoosh](https://squoosh.app/) but with a built-in camera that would let me compress images immediately after capturing.

After researching and discovering that ffmpeg can handle still images as well as video and audio, I realized that Capsule could be a sleek general purpose media compressor in addition to the quick-capture tool I envisioned, using ffmpeg as the compression backend.

## ffmpeg
- macOS: prefers ffmpeg in PATH, uses [ffmpeg_kit_flutter_new_full](https://pub.dev/packages/ffmpeg_kit_flutter_new_full) as fallback
- Windows: ffmpeg must be in PATH
- Linux: ffmpeg must be in PATH
- Android: uses [ffmpeg_kit_flutter_new_full](https://pub.dev/packages/ffmpeg_kit_flutter_new_full)

## Note
Capsule is almost entirely coded with AI, so there will be quirks and bugs. Feel free to submit issues and pull requests!

## Building
```bash
git clone https://github.com/kamryn404/Capsule
```

```bash
cd Capsule
```

```bash
flutter pub get
```

```bash
flutter build
```

## Support development
Donations are very welcome and would be really cool.

https://buymeacoffee.com/kamryn404 

Solana: Bk2w4gY4CajxyzB57UQdGo16tC4tnm5D7UENreHkqbzJ
