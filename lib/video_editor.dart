import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'ffmpeg_service.dart';
import 'models/compression_settings.dart';
import 'widgets/before_after.dart';
import 'widgets/media_controls.dart';

class VideoEditor extends StatefulWidget {
  final XFile file;
  final VoidCallback onClear;
  final VideoSettings? settings;
  final ValueChanged<VideoSettings>? onSettingsChanged;
  final VoidCallback? onSaveBatch;
  final String? progressLabel;
  final double? batchProgress;

  const VideoEditor({
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
  State<VideoEditor> createState() => _VideoEditorState();
}

class _VideoEditorState extends State<VideoEditor> {
  // Single composite player for synchronized before/after preview
  // The composite video has original on left half, compressed on right half
  late final Player _compositePlayer;
  late final VideoController _compositeController;

  // Transform controller for pan/zoom - persists across preview regenerations
  final TransformationController _transformController =
      TransformationController();

  bool _isCompressing = false;
  bool _isPreviewing = false;
  bool _isCompositeReady = false;
  double _bitrate = 5000; // kbps
  double _maxBitrate = 10000; // kbps
  String _outputFormat = 'h265'; // av1, vp9, h265, h264
  final ValueNotifier<double> _scrubPosition = ValueNotifier(0.0); // 0.0 to 1.0
  Duration _videoDuration = Duration.zero;
  double _progress = 0.0;

  String? _av1Encoder;
  String? _h265Encoder;
  String? _h264Encoder;

  bool _hasAv1Hardware = false;
  bool _hasH265Hardware = false;
  bool _hasH265Software = false;
  bool _hasH264 = false;
  String? _originalSize;
  double _resolution = 1.0; // 1.0, 0.5, 0.25
  double? _aspectRatio;
  int _originalWidth = 0;
  int _originalHeight = 0;

  late FfmpegService _ffmpegService;

  // Optimization
  Timer? _debounceTimer;
  FfmpegTask? _currentPreviewTask;
  StreamSubscription? _playerSubscription;

  @override
  void initState() {
    super.initState();
    _ffmpegService = FfmpegServiceFactory.create();
    _ffmpegService.init();

    // Initialize single composite player
    _compositePlayer = Player();
    _compositeController = VideoController(_compositePlayer);

    // Listen to video dimensions to correct aspect ratio if metadata extraction failed
    _playerSubscription = _compositePlayer.stream.videoParams.listen((params) {
      if (params.w != null &&
          params.h != null &&
          params.w! > 0 &&
          params.h! > 0) {
        // The composite video is 2x width.
        // So original aspect ratio is (width/2) / height.
        final newRatio = (params.w! / 2) / params.h!;
        // Update if significantly different
        if (_aspectRatio == null || (_aspectRatio! - newRatio).abs() > 0.01) {
          if (mounted) {
            setState(() {
              _aspectRatio = newRatio;
            });
          }
        }
      }
    });

    // Mute audio as requested
    _compositePlayer.setVolume(0);

    _initializeVideo();

    if (widget.settings != null) {
      _outputFormat = widget.settings!.outputFormat;
      _bitrate = widget.settings!.bitrate;
      _resolution = widget.settings!.resolution;
    }
  }

  @override
  void didUpdateWidget(covariant VideoEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _initializeVideo();
    }
    if (widget.settings != null && widget.settings != oldWidget.settings) {
      setState(() {
        _outputFormat = widget.settings!.outputFormat;
        _bitrate = widget.settings!.bitrate;
        _resolution = widget.settings!.resolution;
      });
      _debouncePreview();
    }
  }

  @override
  void dispose() {
    _playerSubscription?.cancel();
    _debounceTimer?.cancel();
    _currentPreviewTask?.cancel();

    _compositePlayer.dispose();
    _transformController.dispose();
    _scrubPosition.dispose();

    super.dispose();
  }

  Future<void> _initializeVideo() async {
    try {
      debugPrint('Initializing video: ${widget.file.path}');
      final file = File(widget.file.path);
      if (!await file.exists()) {
        throw Exception('File does not exist');
      }

      // 1. Get file size and media info
      int size = 0;
      try {
        size = await file.length();
      } catch (e) {
        debugPrint('Error getting file size: $e');
      }

      // Check for hardware acceleration and encoders
      try {
        // 1. AV1: Prefer libsvtav1 (System) then libaom-av1 (FFmpegKit)
        _av1Encoder = await _ffmpegService.getBestEncoder([
          'libsvtav1',
          'av1_videotoolbox',
          'libaom-av1',
        ]);

        // 2. H.265: Prefer Hardware (FFmpegKit) then libx265 (System)
        _h265Encoder = await _ffmpegService.getBestEncoder([
          'hevc_videotoolbox',
          'hevc_mediacodec',
          'hevc_nvenc',
          'hevc_amf',
          'hevc_qsv',
          'hevc_vaapi',
          'libx265',
        ]);

        // 3. H.264: Prefer Hardware (FFmpegKit) then libx264 (System)
        _h264Encoder = await _ffmpegService.getBestEncoder([
          'h264_videotoolbox',
          'h264_mediacodec',
          'h264_nvenc',
          'h264_amf',
          'h264_qsv',
          'h264_vaapi',
          'libx264',
        ]);

        _hasAv1Hardware =
            _av1Encoder != null && !_av1Encoder!.startsWith('lib');
        _hasH265Hardware =
            _h265Encoder != null && !_h265Encoder!.startsWith('lib');
        _hasH265Software = _h265Encoder == 'libx265';
        _hasH264 = _h264Encoder != null;

        // Set default format based on availability
        if (_outputFormat == 'av1' && _av1Encoder == null) {
          _outputFormat = 'h265';
        }
        if (_outputFormat == 'h265' && _h265Encoder == null) {
          _outputFormat = 'h264';
        }
      } catch (e) {
        debugPrint('Error checking encoders: $e');
      }

      // Get media info to set max bitrate and aspect ratio
      try {
        final info = await _ffmpegService.getMediaInfo(widget.file.path);
        if (info.bitrate > 0) {
          setState(() {
            _maxBitrate = info.bitrate.toDouble();
            _bitrate = (_maxBitrate * 0.5).clamp(10.0, 5000.0);
          });
        }
        if (info.width > 0 && info.height > 0) {
          setState(() {
            _aspectRatio = info.width / info.height;
            _videoDuration = info.duration;
            _originalWidth = info.width;
            _originalHeight = info.height;
          });
        }
      } catch (e) {
        debugPrint('Error getting media info: $e');

        // Fallback: Try to get info using a temporary player
        Duration fallbackDuration = const Duration(seconds: 10);
        double fallbackAspectRatio = 16 / 9;
        int fallbackWidth = 1920;
        int fallbackHeight = 1080;

        try {
          final tempPlayer = Player();
          await tempPlayer.open(Media(widget.file.path), play: false);

          // Wait for duration
          try {
            final duration = await tempPlayer.stream.duration
                .firstWhere((d) => d != Duration.zero)
                .timeout(const Duration(seconds: 2));
            fallbackDuration = duration;
          } catch (_) {}

          // Wait for dimensions
          try {
            final params = await tempPlayer.stream.videoParams
                .firstWhere((p) => p.w != null && p.h != null)
                .timeout(const Duration(seconds: 2));
            if (params.w != null && params.h != null && params.h! > 0) {
              fallbackAspectRatio = params.w! / params.h!;
              fallbackWidth = params.w!;
              fallbackHeight = params.h!;
            }
          } catch (_) {}

          await tempPlayer.dispose();
        } catch (e) {
          debugPrint('Fallback media info failed: $e');
        }

        if (mounted) {
          setState(() {
            _aspectRatio = fallbackAspectRatio;
            _videoDuration = fallbackDuration;
            _originalWidth = fallbackWidth;
            _originalHeight = fallbackHeight;
          });
        }
      }

      setState(() {
        _originalSize = _formatBytes(size);
      });

      // 2. Generate initial preview
      _generatePreview();
    } catch (e) {
      debugPrint('Error initializing video: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error loading video: $e')));
      }
    }
  }

  void _onScrubChanged(double value) {
    _scrubPosition.value = value;
    // Clear composite preview while scrubbing
    if (_isCompositeReady) {
      setState(() {
        _isCompositeReady = false;
      });
    }
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
        // Layer 1: Composite Video Viewer (synchronized before/after)
        Positioned.fill(
          child: Container(
            color: Colors.transparent,
            child: _isPreviewing && !_isCompositeReady
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text(
                          'Generating preview...',
                          style: TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  )
                : _aspectRatio != null
                ? BeforeAfterComposite(
                    controller: _compositeController,
                    aspectRatio: _aspectRatio!,
                    isReady: _isCompositeReady,
                    transformController: _transformController,
                  )
                : const Center(
                    child: Text(
                      'Loading video...',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
          ),
        ),

        // Layer 2: Floating Controls
        if (_aspectRatio != null)
          Positioned(
            left: isNarrow ? 20 : null,
            right: 20,
            bottom: 20,
            child: ValueListenableBuilder<double>(
              valueListenable: _scrubPosition,
              builder: (context, scrubPos, _) {
                return MediaControls(
                  width: isNarrow ? double.infinity : 350,
                  scrubPosition: scrubPos,
                  duration: _videoDuration,
                  outputFormat: _outputFormat,
                  bitrate: _bitrate,
                  maxBitrate: _maxBitrate,
                  isCompressing: _isCompressing || widget.batchProgress != null,
                  isPreviewing: _isPreviewing,
                  progress: widget.batchProgress ?? _progress,
                  progressLabel: widget.progressLabel,
                  originalSize: _originalSize,
                  estimatedSize: _estimateSize(),
                  hasAv1Hardware: _hasAv1Hardware,
                  resolution: _resolution,
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
                        widget.onSettingsChanged!(
                          VideoSettings(
                            outputFormat: _outputFormat,
                            bitrate: _bitrate,
                            resolution: _resolution,
                          ),
                        );
                      }
                      _generatePreview();
                    }
                  },
                  onResolutionChanged: (newValue) {
                    if (newValue != null) {
                      setState(() {
                        _resolution = newValue;
                      });
                      if (widget.onSettingsChanged != null) {
                        widget.onSettingsChanged!(
                          VideoSettings(
                            outputFormat: _outputFormat,
                            bitrate: _bitrate,
                            resolution: _resolution,
                          ),
                        );
                      }
                      _generatePreview();
                    }
                  },
                  originalResolution: Size(
                    _originalWidth.toDouble(),
                    _originalHeight.toDouble(),
                  ),
                  onBitrateChanged: _onBitrateChanged,
                  onBitrateEnd: (value) {
                    _debounceTimer?.cancel();
                    if (widget.onSettingsChanged != null) {
                      widget.onSettingsChanged!(
                        VideoSettings(
                          outputFormat: _outputFormat,
                          bitrate: _bitrate,
                          resolution: _resolution,
                        ),
                      );
                    }
                    _generatePreview();
                  },
                  onClear: widget.onClear,
                  onSave: widget.onSaveBatch ?? _saveVideo,
                  formatItems: [
                    if (_h265Encoder != null)
                      DropdownMenuItem(
                        value: 'h265',
                        child: Row(
                          children: [
                            const Text('H.265 (MP4)'),
                            if (_hasH265Hardware) ...[
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.bolt,
                                size: 16,
                                color: Colors.amber,
                              ),
                              const Text(
                                ' HW',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.amber,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    if (_h264Encoder != null)
                      DropdownMenuItem(
                        value: 'h264',
                        child: Row(
                          children: [
                            const Text('H.264 (MP4)'),
                            if (_h264Encoder != null &&
                                !_h264Encoder!.startsWith('lib')) ...[
                              const SizedBox(width: 4),
                              const Icon(
                                Icons.bolt,
                                size: 16,
                                color: Colors.amber,
                              ),
                              const Text(
                                ' HW',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.amber,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    DropdownMenuItem(
                      value: 'av1',
                      child: Row(
                        children: [
                          const Text('AV1 (MP4)'),
                          if (_hasAv1Hardware) ...[
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.bolt,
                              size: 16,
                              color: Colors.amber,
                            ),
                            const Text(
                              ' HW',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.amber,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const DropdownMenuItem(
                      value: 'vp9',
                      child: Text('VP9 (WebM)'),
                    ),
                  ],
                );
              },
            ),
          ),
      ],
    );
  }

  Future<void> _generatePreview() async {
    // Cancel previous task if running
    _currentPreviewTask?.cancel();

    setState(() {
      _isPreviewing = true;
      _isCompositeReady = false;
    });

    try {
      final tempDir = await getTemporaryDirectory();

      // Use unique filenames to avoid lock issues
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final originalClipPath = p.join(
        tempDir.path,
        'preview_original_$timestamp.mp4',
      );
      final compressedClipPath = p.join(
        tempDir.path,
        'preview_compressed_$timestamp.mp4',
      );
      final compositePath = p.join(
        tempDir.path,
        'preview_composite_$timestamp.mp4',
      );
      final tempVp9Path = p.join(tempDir.path, 'temp_vp9_$timestamp.webm');

      // Calculate start time
      final startTime =
          _videoDuration.inMilliseconds * _scrubPosition.value / 1000.0;
      final startTimeStr = startTime.toStringAsFixed(3);

      // Determine codec and settings
      String codec;
      String speed = '';

      if (_outputFormat == 'av1') {
        codec = _av1Encoder ?? 'libaom-av1';
        speed = _ffmpegService.getPresetFlag(codec, '8');
      } else if (_outputFormat == 'vp9') {
        codec = 'libvpx-vp9';
        speed = '-cpu-used 5';
      } else if (_outputFormat == 'h265') {
        codec = _h265Encoder ?? 'libx265';
        speed = _ffmpegService.getPresetFlag(codec, 'ultrafast');
      } else {
        // h264 or default
        codec = _h264Encoder ?? 'libx264';
        speed = _ffmpegService.getPresetFlag(codec, 'ultrafast');
      }

      debugPrint('Generating preview with codec: $codec');
      var h264 = _h264Encoder ?? 'libx264';
      var h264Preset = _ffmpegService.getPresetFlag(h264, 'ultrafast');

      // Use correct quality flag based on encoder
      String h264Quality = '-crf 18';
      if (h264.contains('nvenc')) {
        h264Quality = '-cq 18';
      } else if (h264.contains('videotoolbox')) {
        h264Quality = '-q:v 65';
      }

      final scaleFilter =
          'scale=trunc(iw*$_resolution/2)*2:trunc(ih*$_resolution/2)*2';

      // Step 1 & 2: Generate original and compressed clips in PARALLEL
      final originalFuture = _ffmpegService
          .execute(
            '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -c:v $h264 $h264Preset $h264Quality -pix_fmt yuv420p -an "$originalClipPath"',
          )
          .then((task) => task.done)
          .catchError((e) async {
        debugPrint('Original clip failed with $h264, falling back to libx264');

        // Update state to disable broken hardware encoder
        if (h264 != 'libx264') {
          h264 = 'libx264';
          h264Preset = _ffmpegService.getPresetFlag(h264, 'ultrafast');
          _h264Encoder = 'libx264';
          if (mounted) setState(() {});
        }

        final task = await _ffmpegService.execute(
          '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p -an "$originalClipPath"',
        );
        return task.done;
      });

      Future<void> compressedFuture;

      if (_outputFormat == 'vp9') {
        // For VP9: First compress to VP9 (to generate artifacts), then transcode to H.264
        compressedFuture = _ffmpegService
            .execute(
              '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -vf $scaleFilter -c:v $codec -b:v ${_bitrate.round()}k $speed -pix_fmt yuv420p -threads 0 -row-mt 1 -an "$tempVp9Path"',
            )
            .then((task) {
          _currentPreviewTask = task;
          return task.done;
        }).then(
          (_) => _ffmpegService.execute(
            '-y -i "$tempVp9Path" -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p -threads 0 -an "$compressedClipPath"',
          ),
        ).then((task) {
          _currentPreviewTask = task;
          return task.done;
        });
      } else {
        // AV1 (or others) - direct compression to MP4
        compressedFuture = _ffmpegService
            .execute(
              '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -vf $scaleFilter -c:v $codec -b:v ${_bitrate.round()}k $speed -pix_fmt yuv420p -threads 0 -row-mt 1 -an "$compressedClipPath"',
            )
            .then((task) {
          _currentPreviewTask = task;
          return task.done;
        });
      }

      // Wait for both clips to be generated
      try {
        await Future.wait([originalFuture, compressedFuture]);
      } catch (e) {
        debugPrint('Preview generation failed with $codec: $e');

        // If the compressed clip failed and we were using a hardware encoder, disable it
        if (codec != 'libx264' &&
            codec != 'libx265' &&
            codec != 'libaom-av1' &&
            codec != 'libsvtav1' &&
            codec != 'libvpx-vp9') {
          debugPrint('Disabling broken encoder: $codec');
          if (_outputFormat == 'h265') {
            _h265Encoder = 'libx265';
          } else if (_outputFormat == 'h264') {
            _h264Encoder = 'libx264';
          } else if (_outputFormat == 'av1') {
            _av1Encoder = 'libaom-av1';
          }
          if (mounted) setState(() {});
        }

        // Fallback to libx264 if anything fails
        debugPrint('Falling back to libx264 for preview');
        final fallbackTask = await _ffmpegService.execute(
          '-y -ss $startTimeStr -t 2 -i "${widget.file.path}" -vf $scaleFilter -c:v libx264 -preset ultrafast -b:v ${_bitrate.round()}k -pix_fmt yuv420p -an "$compressedClipPath"',
        );
        _currentPreviewTask = fallbackTask;
        await fallbackTask.done;
      }

      // Step 3: Create composite video using FFmpeg hstack filter
      // This combines original (left) and compressed (right) into a single video
      // Using -crf 18 for high quality to preserve visible compression artifacts
      // Recalculate quality flag in case h264 changed (fallback)
      if (h264.contains('libx264')) {
        h264Quality = '-crf 18';
      } else if (h264.contains('nvenc')) {
        h264Quality = '-cq 18';
      }

      final compositeTask = await _ffmpegService.execute(
        '-y -i "$originalClipPath" -i "$compressedClipPath" '
        '-filter_complex "[0:v]setpts=PTS-STARTPTS[a];[1:v]setpts=PTS-STARTPTS[b];[b][a]scale2ref=ref_w:ref_h[b_scaled][a_ref];[a_ref][b_scaled]hstack=inputs=2[v]" '
        '-map "[v]" -c:v $h264 $h264Preset $h264Quality -pix_fmt yuv420p -an "$compositePath"',
      );
      _currentPreviewTask = compositeTask;
      await compositeTask.done;

      // Step 4: Open composite video in player
      await _compositePlayer.open(Media(compositePath));
      await _compositePlayer.setPlaylistMode(PlaylistMode.loop);
      await _compositePlayer.play();

      if (mounted) {
        setState(() {
          _isPreviewing = false;
          _isCompositeReady = true;
        });
      }
    } catch (e) {
      if (e.toString().contains('cancelled')) {
        debugPrint('Preview generation cancelled');
      } else {
        debugPrint('Error generating preview: $e');
      }
      if (mounted) {
        setState(() {
          _isPreviewing = false;
          _isCompositeReady = false;
        });
      }
    }
  }

  Future<void> _saveVideo() async {
    setState(() {
      _isCompressing = true;
      _progress = 0.0;
    });

    try {
      String? outputPath;

      if (Platform.isAndroid || Platform.isIOS) {
        final tempDir = await getTemporaryDirectory();
        outputPath =
            '${tempDir.path}/compressed_${DateTime.now().millisecondsSinceEpoch}.${_outputFormat == 'vp9' ? 'webm' : 'mp4'}';
      } else {
        final inputBasename = p.basenameWithoutExtension(widget.file.path);
        final FileSaveLocation? result = await getSaveLocation(
          suggestedName:
              '$inputBasename.${_outputFormat == 'vp9' ? 'webm' : 'mp4'}',
          acceptedTypeGroups: [
            XTypeGroup(
              label: 'Videos',
              extensions: [_outputFormat == 'vp9' ? 'webm' : 'mp4'],
            ),
          ],
        );
        outputPath = result?.path;
      }

      if (outputPath == null) {
        setState(() {
          _isCompressing = false;
        });
        return;
      }

      // Ensure extension
      final expectedExt = _outputFormat == 'vp9' ? '.webm' : '.mp4';
      if (!outputPath!.toLowerCase().endsWith(expectedExt)) {
        outputPath = '$outputPath$expectedExt';
      }

      String codec;
      String speed = '';

      if (_outputFormat == 'av1') {
        codec = _av1Encoder ?? 'libaom-av1';
        speed = _ffmpegService.getPresetFlag(codec, '6');
      } else if (_outputFormat == 'vp9') {
        codec = 'libvpx-vp9';
        speed = '-cpu-used 6'; // Faster encoding
      } else if (_outputFormat == 'h265') {
        codec = _h265Encoder ?? 'libx265';
        speed = _ffmpegService.getPresetFlag(codec, 'fast');
      } else {
        // h264
        codec = _h264Encoder ?? 'libx264';
        speed = _ffmpegService.getPresetFlag(codec, 'fast');
      }

      debugPrint('Saving video with codec: $codec');

      // Add -row-mt 1 for better multi-threading performance
      // Add scaling
      final scaleFilter =
          'scale=trunc(iw*$_resolution/2)*2:trunc(ih*$_resolution/2)*2';

      try {
        final task = await _ffmpegService.execute(
          '-y -i "${widget.file.path}" -vf $scaleFilter -c:v $codec -b:v ${_bitrate.round()}k $speed -pix_fmt yuv420p -threads 0 -row-mt 1 "$outputPath"',
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                _progress = progress;
              });
            }
          },
          totalDuration: _videoDuration,
        );
        await task.done;
      } catch (e) {
        // Check for hardware encoder failure and fallback
        bool isHardware = codec != 'libx264' &&
            codec != 'libx265' &&
            codec != 'libaom-av1' &&
            codec != 'libsvtav1' &&
            codec != 'libvpx-vp9';

        if (isHardware) {
          debugPrint('Saving failed with $codec, falling back to software');

          // Update state for future files
          if (_outputFormat == 'h265') {
            _h265Encoder = 'libx265';
            codec = 'libx265';
          } else if (_outputFormat == 'h264') {
            _h264Encoder = 'libx264';
            codec = 'libx264';
          } else if (_outputFormat == 'av1') {
            _av1Encoder = 'libaom-av1';
            codec = 'libaom-av1';
          }
          if (mounted) setState(() {});

          // Update speed preset for software
          if (_outputFormat == 'av1') {
            speed = _ffmpegService.getPresetFlag(codec, '6');
          } else {
            speed = _ffmpegService.getPresetFlag(codec, 'fast');
          }

          // Retry with software encoder
          final task = await _ffmpegService.execute(
            '-y -i "${widget.file.path}" -vf $scaleFilter -c:v $codec -b:v ${_bitrate.round()}k $speed -pix_fmt yuv420p -threads 0 -row-mt 1 "$outputPath"',
            onProgress: (progress) {
              if (mounted) {
                setState(() {
                  _progress = progress;
                });
              }
            },
            totalDuration: _videoDuration,
          );
          await task.done;
        } else {
          rethrow;
        }
      }

      if (Platform.isAndroid || Platform.isIOS) {
        await Gal.putVideo(outputPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Video saved to Gallery')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Video saved to $outputPath')));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving video: $e')));
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
    // (Video Bitrate + Audio Bitrate) * Duration / 8
    // Assume 128kbps audio
    final totalBitrate = _bitrate + 128;
    final durationSeconds = _videoDuration.inSeconds;
    final sizeBytes = (totalBitrate * 1000 * durationSeconds) / 8;

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
