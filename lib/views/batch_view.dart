import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio_editor.dart';
import '../ffmpeg_service.dart';
import '../image_editor.dart';
import '../models/compression_settings.dart';
import '../video_editor.dart';

class BatchView extends StatefulWidget {
  final List<XFile> files;
  final MediaType mediaType;
  final VoidCallback onClose;

  const BatchView({
    super.key,
    required this.files,
    required this.mediaType,
    required this.onClose,
  });

  @override
  State<BatchView> createState() => _BatchViewState();
}

class _BatchViewState extends State<BatchView> {
  final ScrollController _scrollController = ScrollController();
  int _selectedIndex = 0;
  CompressionSettings? _settings;
  bool _isSaving = false;
  double _batchProgress = 0.0;
  late FfmpegService _ffmpegService;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _ffmpegService = FfmpegServiceFactory.create();
    _ffmpegService.init();
    _initializeSettings();
  }

  void _initializeSettings() {
    switch (widget.mediaType) {
      case MediaType.video:
        _settings = VideoSettings();
        break;
      case MediaType.image:
        _settings = ImageSettings();
        break;
      case MediaType.audio:
        _settings = AudioSettings();
        break;
      case MediaType.unknown:
        // Should not happen in batch view as we filter before
        _settings = ImageSettings();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      body: Stack(
        children: [
          // Editor Area
          Positioned.fill(
            child: _buildEditor(),
          ),

          // Floating Thumbnails
          Positioned(
            top: 20,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                height: 80,
                constraints: const BoxConstraints(maxWidth: 800),
                child: Listener(
                  onPointerSignal: (event) {
                    if (event is PointerScrollEvent) {
                      final newOffset = _scrollController.offset + event.scrollDelta.dy;
                      if (newOffset >= _scrollController.position.minScrollExtent &&
                          newOffset <= _scrollController.position.maxScrollExtent) {
                        _scrollController.jumpTo(newOffset);
                      }
                    }
                  },
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(
                      dragDevices: {
                        PointerDeviceKind.touch,
                        PointerDeviceKind.mouse,
                      },
                    ),
                    child: ListView.builder(
                      controller: _scrollController,
                      scrollDirection: Axis.horizontal,
                      itemCount: widget.files.length,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shrinkWrap: true,
                      itemBuilder: (context, index) {
                        final file = widget.files[index];
                        final isSelected = index == _selectedIndex;
                        return Tooltip(
                          message: p.basename(file.path),
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _selectedIndex = index;
                                });
                              },
                              child: Container(
                                width: 60,
                                margin: const EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  border: isSelected
                                      ? Border.all(color: Theme.of(context).primaryColor, width: 2)
                                      : Border.all(color: Colors.white24, width: 1),
                                  borderRadius: BorderRadius.circular(8),
                                  color: Colors.black54,
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: _buildThumbnail(file),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail(XFile file) {
    if (widget.mediaType == MediaType.image) {
      return Image.file(
        File(file.path),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, size: 20),
      );
    } else if (widget.mediaType == MediaType.video) {
      return const Center(child: Icon(Icons.videocam, color: Colors.white54, size: 24));
    } else {
      return const Center(child: Icon(Icons.audiotrack, color: Colors.white54, size: 24));
    }
  }

  Widget _buildEditor() {
    final file = widget.files[_selectedIndex];
    final progressLabel = _isSaving ? '${(_batchProgress * 100).round()}% (${(_batchProgress * widget.files.length).floor() + 1}/${widget.files.length})' : null;
    
    switch (widget.mediaType) {
      case MediaType.video:
        return VideoEditor(
          key: ValueKey(file.path), // Force rebuild on file change
          file: file,
          onClear: widget.onClose,
          settings: _settings as VideoSettings?,
          onSettingsChanged: (newSettings) {
            setState(() {
              _settings = newSettings;
            });
          },
          onSaveBatch: _saveBatch,
          batchProgress: _isSaving ? _batchProgress : null,
          progressLabel: progressLabel,
        );
      case MediaType.image:
        return ImageEditor(
          key: ValueKey(file.path),
          file: file,
          onClear: widget.onClose,
          settings: _settings as ImageSettings?,
          onSettingsChanged: (newSettings) {
            setState(() {
              _settings = newSettings;
            });
          },
          onSaveBatch: _saveBatch,
          batchProgress: _isSaving ? _batchProgress : null,
          progressLabel: progressLabel,
        );
      case MediaType.audio:
        return AudioEditor(
          key: ValueKey(file.path),
          file: file,
          onClear: widget.onClose,
          settings: _settings as AudioSettings?,
          onSettingsChanged: (newSettings) {
            setState(() {
              _settings = newSettings;
            });
          },
          onSaveBatch: _saveBatch,
          batchProgress: _isSaving ? _batchProgress : null,
          progressLabel: progressLabel,
        );
      case MediaType.unknown:
        return const Center(child: Text('Unknown media type'));
    }
  }

  Future<void> _saveBatch() async {
    if (_settings == null) return;

    setState(() {
      _isSaving = true;
      _batchProgress = 0.0;
    });

    try {
      String? outputDirPath;

      if (Platform.isAndroid || Platform.isIOS) {
        final tempDir = await getTemporaryDirectory();
        outputDirPath = tempDir.path;
      } else {
        final String? directoryPath = await getDirectoryPath();
        if (directoryPath == null) {
          setState(() {
            _isSaving = false;
          });
          return;
        }
        
        final folderName = 'Batch_Compressed_${DateTime.now().millisecondsSinceEpoch}';
        final newDir = Directory(p.join(directoryPath, folderName));
        await newDir.create();
        outputDirPath = newDir.path;
      }

      int completed = 0;
      for (final file in widget.files) {
        await _processFile(file, outputDirPath, (fileProgress) {
          if (mounted) {
            setState(() {
              // Calculate total progress: (completed files + current file progress) / total files
              _batchProgress = (completed + fileProgress) / widget.files.length;
            });
          }
        });
        completed++;
      }
      
      // Ensure we hit 100% at the end
      if (mounted) {
        setState(() {
          _batchProgress = 1.0;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Batch processing complete! Saved to $outputDirPath')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error during batch processing: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _processFile(XFile file, String outputDir, Function(double) onProgress) async {
    final fileName = p.basenameWithoutExtension(file.path);
    String extension = '';
    String command = '';

    if (widget.mediaType == MediaType.video) {
      final s = _settings as VideoSettings;
      extension = s.outputFormat == 'vp9' ? 'webm' : 'mp4';
      
      String codec;
      String speed = '';
      bool hasHw = await _ffmpegService.hasEncoder('av1_videotoolbox');
      
      if (s.outputFormat == 'av1') {
        if (hasHw) {
          codec = 'av1_videotoolbox';
        } else {
          codec = 'libaom-av1';
          speed = '-cpu-used 6';
        }
      } else {
        codec = 'libvpx-vp9';
        speed = '-cpu-used 6';
      }

      final scaleFilter = 'scale=trunc(iw*${s.resolution}/2)*2:trunc(ih*${s.resolution}/2)*2';
      final outputPath = p.join(outputDir, '${fileName}_compressed.$extension');
      
      // Get duration for progress calculation
      Duration duration = Duration.zero;
      try {
        final info = await _ffmpegService.getMediaInfo(file.path);
        duration = info.duration;
      } catch (e) {
        debugPrint('Error getting duration for progress: $e');
      }

      await _ffmpegService.execute(
        '-y -i "${file.path}" -vf $scaleFilter -c:v $codec -b:v ${s.bitrate.round()}k $speed -threads 0 -row-mt 1 "$outputPath"',
        onProgress: onProgress,
        totalDuration: duration,
      ).then((t) => t.done);

    } else if (widget.mediaType == MediaType.image) {
      final s = _settings as ImageSettings;
      extension = s.outputFormat;
      final outputPath = p.join(outputDir, '${fileName}_compressed.$extension');
      
      String scaleFilter = '';
      if (s.resolution < 1.0) {
        scaleFilter = '-vf scale=trunc(iw*${s.resolution}/2)*2:trunc(ih*${s.resolution}/2)*2';
      }

      if (s.outputFormat == 'png') {
        command = '-y -i "${file.path}" $scaleFilter -frames:v 1 -update 1 "$outputPath"';
      } else if (s.outputFormat == 'webp') {
        command = '-y -i "${file.path}" $scaleFilter -q:v ${s.quality.round()} -pix_fmt yuva420p -frames:v 1 -update 1 "$outputPath"';
      } else if (s.outputFormat == 'avif') {
        int crf = (63 - ((s.quality - 1) * (63 / 99))).round().clamp(0, 63);
        
        // Check if yuva420p is supported by the encoder
        bool supportsYuva420p = await _ffmpegService.hasPixelFormat('libaom-av1', 'yuva420p');

        if (supportsYuva420p) {
          command = '-y -i "${file.path}" $scaleFilter -c:v libaom-av1 -crf $crf -cpu-used 6 -pix_fmt yuva420p -frames:v 1 -update 1 "$outputPath"';
        } else {
          String filterComplex;
          if (scaleFilter.isNotEmpty) {
            // Extract scale parameters from "-vf scale=..."
            final scaleParams = scaleFilter.replaceAll('-vf ', '');
            filterComplex = '[0:v]$scaleParams[scaled];[scaled]format=rgba[in];[in]split=2[color_in][alpha_in];[color_in]format=yuv420p[color];[alpha_in]alphaextract,format=gray,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709[alpha]';
          } else {
            filterComplex = '[0:v]format=rgba[in];[in]split=2[color_in][alpha_in];[color_in]format=yuv420p[color];[alpha_in]alphaextract,format=gray,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709[alpha]';
          }

          command = '-y -i "${file.path}" -filter_complex "$filterComplex" -map "[color]" -map "[alpha]" -c:v libaom-av1 -crf $crf -cpu-used 6 -frames:v 1 -update 1 "$outputPath"';
        }
      } else {
        // JPEG
        int qValue = (31 - ((s.quality - 1) * (29 / 99))).round().clamp(2, 31);
        command = '-y -i "${file.path}" $scaleFilter -q:v $qValue -pix_fmt yuvj420p -frames:v 1 -update 1 "$outputPath"';
      }
      
      // Image compression is usually fast, but we can simulate progress or just mark done
      // FFmpeg doesn't give great progress for single image
      onProgress(0.5);
      await _ffmpegService.execute(command).then((t) => t.done);
      onProgress(1.0);

    } else if (widget.mediaType == MediaType.audio) {
      final s = _settings as AudioSettings;
      extension = s.outputFormat == 'mp3' ? 'mp3' : (s.outputFormat == 'opus' ? 'opus' : 'ogg');
      final outputPath = p.join(outputDir, '${fileName}_compressed.$extension');

      String codec;
      if (s.outputFormat == 'mp3') {
        codec = 'libmp3lame';
      } else if (s.outputFormat == 'opus') {
        codec = 'libopus';
      } else {
        codec = 'libvorbis';
      }

      // Get duration for progress calculation
      Duration duration = Duration.zero;
      try {
        final info = await _ffmpegService.getMediaInfo(file.path);
        duration = info.duration;
      } catch (e) {
        debugPrint('Error getting duration for progress: $e');
      }

      await _ffmpegService.execute(
        '-y -i "${file.path}" -c:a $codec -b:a ${s.bitrate.round()}k "$outputPath"',
        onProgress: onProgress,
        totalDuration: duration,
      ).then((t) => t.done);
    }
  }
}