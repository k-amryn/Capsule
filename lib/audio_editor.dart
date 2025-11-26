import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:media_kit/media_kit.dart';

import 'models/compression_settings.dart';
import 'ffmpeg_service.dart';
import 'widgets/media_controls.dart';

class AudioEditor extends StatefulWidget {
  final XFile file;
  final VoidCallback onClear;
  final AudioSettings? settings;
  final ValueChanged<AudioSettings>? onSettingsChanged;
  final VoidCallback? onSaveBatch;
  final String? progressLabel;
  final double? batchProgress;

  const AudioEditor({
    super.key,
    required this.file,
    required this.onClear,
    this.settings,
    this.onSettingsChanged,
    this.onSaveBatch,
    this.progressLabel,
    this.batchProgress,
  });

  @override
  State<AudioEditor> createState() => _AudioEditorState();
}

class _AudioEditorState extends State<AudioEditor> {
  Player? _originalPlayer;
  Player? _compressedPlayer;

  bool _isCompressing = false;
  bool _isPreviewing = false;
  double _bitrate = 128; // kbps
  double _maxBitrate = 320; // kbps
  String _outputFormat = 'mp3';
  double _scrubPosition = 0.0; // 0.0 to 1.0
  Duration _audioDuration = Duration.zero;
  double _progress = 0.0;
  String? _originalSize;

  late FfmpegService _ffmpegService;

  // Optimization
  Timer? _debounceTimer;
  FfmpegTask? _currentPreviewTask;

  @override
  void initState() {
    super.initState();
    _ffmpegService = FfmpegServiceFactory.create();
    _ffmpegService.init();
    _initializeAudio();
    if (widget.settings != null) {
      _outputFormat = widget.settings!.outputFormat;
      _bitrate = widget.settings!.bitrate;
    }
  }

  @override
  void didUpdateWidget(covariant AudioEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _initializeAudio();
    }
    if (widget.settings != null && widget.settings != oldWidget.settings) {
      setState(() {
        _outputFormat = widget.settings!.outputFormat;
        _bitrate = widget.settings!.bitrate;
      });
      _debouncePreview();
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _currentPreviewTask?.cancel();
    _originalPlayer?.dispose();
    _compressedPlayer?.dispose();
    super.dispose();
  }

  Future<void> _initializeAudio() async {
    final player = Player();
    await player.open(Media(widget.file.path), play: false);

    // Get media info to set max bitrate
    try {
      final info = await _ffmpegService.getMediaInfo(widget.file.path);
      if (info.bitrate > 0) {
        setState(() {
          _maxBitrate = info.bitrate.toDouble();
          // Default to 128 or original if lower
          _bitrate = (_maxBitrate).clamp(32.0, 128.0);
        });
      }
    } catch (e) {
      debugPrint('Error getting media info: $e');
    }

    final size = await File(widget.file.path).length();

    // Wait for duration to be available
    Duration? duration = player.state.duration;
    if (duration == Duration.zero) {
      // If duration is not yet available, wait a bit or try to get it from ffmpeg info
      // But usually open() should populate it.
      // Let's rely on ffmpeg info if player doesn't have it yet, or wait for stream.
    }
    
    // We already got info from ffmpeg above, let's use that if available
    try {
      final info = await _ffmpegService.getMediaInfo(widget.file.path);
      if (info.duration != Duration.zero) {
        duration = info.duration;
      }
    } catch (_) {}

    setState(() {
      _originalPlayer = player;
      _audioDuration = duration ?? Duration.zero;
      _originalSize = _formatBytes(size);
    });
    // Generate initial preview at start
    _generatePreview();
  }

  void _onScrubChanged(double value) {
    setState(() {
      _scrubPosition = value;
    });
    _debouncePreview();
  }

  void _onBitrateChanged(double value) {
    setState(() {
      _bitrate = value;
    });
    _debouncePreview();
  }

  void _debouncePreview() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _generatePreview();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 600;

    return Stack(
      children: [
        // Layer 1: Audio Viewer (Split View)
        Positioned.fill(
          child: Container(
            color: Colors.transparent,
            child: Row(
              children: [
                // Original
                Expanded(
                  child: _AudioPanel(
                    player: _originalPlayer,
                    label: 'Original',
                    color: Colors.blue.withValues(alpha: 0.1),
                    onTap: () => _togglePlay(_originalPlayer),
                  ),
                ),
                // Divider
                Container(width: 2, color: Colors.white24),
                // Compressed
                Expanded(
                  child: _AudioPanel(
                    player: _compressedPlayer,
                    label: 'Compressed',
                    color: Colors.orange.withValues(alpha: 0.1),
                    onTap: () => _togglePlay(_compressedPlayer),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Layer 2: Floating Controls
        Positioned(
          left: isNarrow ? 20 : null,
          right: 20,
          bottom: 20,
          child: MediaControls(
            width: isNarrow ? double.infinity : 350,
            scrubPosition: _scrubPosition,
            duration: _audioDuration,
            outputFormat: _outputFormat,
            bitrate: _bitrate,
            maxBitrate: _maxBitrate,
            isCompressing: _isCompressing || widget.batchProgress != null,
            isPreviewing: _isPreviewing,
            progress: widget.batchProgress ?? _progress,
            progressLabel: widget.progressLabel,
            originalSize: _originalSize,
            estimatedSize: _estimateSize(),
            hasAv1Hardware: false, // Not relevant for audio
            resolution: 1.0, // Dummy
            originalResolution: null, // Not relevant for audio
            onScrubChanged: _onScrubChanged,
            onScrubEnd: (value) {
              _debounceTimer?.cancel();
              _generatePreview();
            },
            onFormatChanged: (newValue) {
              if (newValue != null) {
                setState(() {
                  _outputFormat = newValue;
                });
                if (widget.onSettingsChanged != null) {
                  widget.onSettingsChanged!(AudioSettings(
                    outputFormat: _outputFormat,
                    bitrate: _bitrate,
                  ));
                }
                _generatePreview();
              }
            },
            onResolutionChanged: (value) {}, // No-op for audio
            onBitrateChanged: _onBitrateChanged,
            onBitrateEnd: (value) {
              _debounceTimer?.cancel();
              if (widget.onSettingsChanged != null) {
                widget.onSettingsChanged!(AudioSettings(
                  outputFormat: _outputFormat,
                  bitrate: _bitrate,
                ));
              }
              _generatePreview();
            },
            onClear: widget.onClear,
            onSave: widget.onSaveBatch ?? _saveAudio,
            formatItems: const [
              DropdownMenuItem(value: 'mp3', child: Text('MP3')),
              DropdownMenuItem(value: 'ogg', child: Text('Vorbis (OGG)')),
              DropdownMenuItem(value: 'opus', child: Text('Opus')),
            ],
          ),
        ),
      ],
    );
  }

  void _togglePlay(Player? player) {
    if (player == null) return;

    final isPlaying = player.state.playing;
    if (isPlaying) {
      player.pause();
      player.seek(Duration.zero);
    } else {
      // Pause other player
      if (player == _originalPlayer) {
        _compressedPlayer?.pause();
        _compressedPlayer?.seek(Duration.zero);
      } else {
        _originalPlayer?.pause();
        _originalPlayer?.seek(Duration.zero);
      }
      player.seek(Duration.zero);
      player.play();
    }
  }

  Future<void> _generatePreview() async {
    if (_originalPlayer == null) return;

    // Cancel previous task if running
    _currentPreviewTask?.cancel();

    setState(() {
      _isPreviewing = true;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final originalClipPath = '${tempDir.path}/preview_original.wav'; // Use WAV for intermediate
      final ext = _outputFormat == 'mp3' ? 'mp3' : (_outputFormat == 'opus' ? 'opus' : 'ogg');
      final compressedClipPath = '${tempDir.path}/preview_compressed.$ext';

      // Calculate start time
      final startTime = _audioDuration.inMilliseconds * _scrubPosition / 1000.0;
      final startTimeStr = startTime.toStringAsFixed(3);

      // 1. Extract original clip (5s)
      // Use PCM for original preview to avoid re-encoding artifacts in the "original" reference
      await _ffmpegService.execute(
        '-y -ss $startTimeStr -t 5 -i "${widget.file.path}" -c:a pcm_s16le "$originalClipPath"'
      ).then((task) => task.done);

      // 2. Compress clip (5s)
      String codec;
      if (_outputFormat == 'mp3') {
        codec = 'libmp3lame';
      } else if (_outputFormat == 'opus') {
        codec = 'libopus';
      } else {
        codec = 'libvorbis';
      }

      final task = await _ffmpegService.execute(
        '-y -ss $startTimeStr -t 5 -i "${widget.file.path}" -c:a $codec -b:a ${_bitrate.round()}k "$compressedClipPath"'
      );
      _currentPreviewTask = task;
      await task.done;

      // 3. Update players
      final oldOriginal = _originalPlayer;
      final oldCompressed = _compressedPlayer;

      final newOriginal = Player();
      final newCompressed = Player();

      await newOriginal.open(Media(originalClipPath), play: false);
      await newCompressed.open(Media(compressedClipPath), play: false);

      await newOriginal.setPlaylistMode(PlaylistMode.loop);
      await newCompressed.setPlaylistMode(PlaylistMode.loop);

      if (mounted) {
        setState(() {
          _originalPlayer = newOriginal;
          _compressedPlayer = newCompressed;
          _isPreviewing = false;
        });
      }

      // Dispose old players
      oldOriginal?.dispose();
      oldCompressed?.dispose();

    } catch (e) {
      if (e.toString().contains('cancelled')) {
        debugPrint('Preview generation cancelled');
      } else {
        debugPrint('Error generating preview: $e');
      }
      if (mounted) {
        setState(() {
          _isPreviewing = false;
        });
      }
    }
  }

  Future<void> _saveAudio() async {
    setState(() {
      _isCompressing = true;
      _progress = 0.0;
    });

    try {
      final ext = _outputFormat == 'mp3' ? 'mp3' : (_outputFormat == 'opus' ? 'opus' : 'ogg');
      final FileSaveLocation? result = await getSaveLocation(
        suggestedName: 'compressed.$ext',
        acceptedTypeGroups: [
          XTypeGroup(
            label: 'Audio',
            extensions: [ext],
          ),
        ],
      );

      if (result == null) {
        setState(() {
          _isCompressing = false;
        });
        return;
      }

      String codec;
      if (_outputFormat == 'mp3') {
        codec = 'libmp3lame';
      } else if (_outputFormat == 'opus') {
        codec = 'libopus';
      } else {
        codec = 'libvorbis';
      }

      debugPrint('Saving audio with codec: $codec');

      final task = await _ffmpegService.execute(
        '-y -i "${widget.file.path}" -c:a $codec -b:a ${_bitrate.round()}k "${result.path}"',
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _progress = progress;
            });
          }
        },
        totalDuration: _audioDuration,
      );
      await task.done;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Audio saved successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving audio: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCompressing = false;
          _progress = 0.0;
        });
      }
    }
  }

  String _estimateSize() {
    // (Bitrate) * Duration / 8
    // Add 5% overhead for container/headers
    final totalBitrate = _bitrate;
    final durationSeconds = _audioDuration.inSeconds;
    final sizeBytes = (totalBitrate * 1000 * durationSeconds) / 8 * 1.05;

    if (sizeBytes <= 0) return "~0 MB";

    if (sizeBytes < 1024 * 1024) {
      final sizeKB = sizeBytes / 1024;
      return '~${sizeKB.toStringAsFixed(0)} KB';
    }

    final sizeMB = sizeBytes / (1024 * 1024);
    return '~${sizeMB.toStringAsFixed(1)} MB';
  }

  String _formatBytes(int bytes, [int decimals = 2]) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = (bytes.toString().length - 1) ~/ 3;
    i = 0;
    double v = bytes.toDouble();
    while (v >= 1024 && i < suffixes.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(decimals)} ${suffixes[i]}';
  }
}

class _AudioPanel extends StatefulWidget {
  final Player? player;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _AudioPanel({
    required this.player,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  State<_AudioPanel> createState() => _AudioPanelState();
}

class _AudioPanelState extends State<_AudioPanel> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: widget.color,
          child: Center(
            child: _buildPlayButton(),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayButton() {
    if (widget.player == null) {
      return const CircularProgressIndicator();
    }

    return StreamBuilder<bool>(
      stream: widget.player!.stream.playing,
      builder: (context, snapshot) {
        final isPlaying = snapshot.data ?? false;
        // Highlight if hovering OR playing
        final isHighlighted = _isHovering || isPlaying;
        
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 16),
            // Custom Play Button to control hover state manually
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isHighlighted ? Colors.white.withValues(alpha: 0.2) : Colors.transparent,
              ),
              child: Icon(
                isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                size: 64,
                color: isHighlighted ? Colors.white : Colors.white70,
              ),
            ),
          ],
        );
      },
    );
  }
}