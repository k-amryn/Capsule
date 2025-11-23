import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ffmpeg_service.dart';
import 'widgets/before_after.dart';

class ImageEditor extends StatefulWidget {
  final XFile file;
  final VoidCallback onClear;

  const ImageEditor({
    super.key,
    required this.file,
    required this.onClear,
  });

  @override
  State<ImageEditor> createState() => _ImageEditorState();
}

class _ImageEditorState extends State<ImageEditor> {
  File? _compressedFile;
  File? _previewFile;
  bool _isCompressing = false;
  double _quality = 80;
  String? _originalSize;
  String? _compressedSize;
  String _outputFormat = 'jpg';
  double _resolution = 1.0; // 1.0, 0.5, 0.25
  Size? _originalResolution;
  late FfmpegService _ffmpegService;
  
  @override
  void initState() {
    super.initState();
    _ffmpegService = FfmpegServiceFactory.create();
    _ffmpegService.init();
    _updateOriginalSize();
    _generatePreview();
    _compressImage();
  }

  @override
  void didUpdateWidget(covariant ImageEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _updateOriginalSize();
      _generatePreview();
      _compressImage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 600;

    return Stack(
      children: [
        // Layer 1: Image Viewer
        Positioned.fill(
          child: Container(
            color: Colors.transparent,
            child: BeforeAfter(
              original: Image.file(
                _previewFile ?? File(widget.file.path),
                fit: BoxFit.contain,
                alignment: Alignment.center,
              ),
              compressed: _compressedFile != null
                  ? Image.file(
                      _compressedFile!,
                      fit: BoxFit.contain,
                      alignment: Alignment.center,
                    )
                  : null,
            ),
          ),
        ),

        // Layer 2: Floating Controls
        Positioned(
          left: isNarrow ? 20 : null,
          right: 20,
          bottom: 20,
          child: Card(
            color: Colors.black.withValues(alpha: 0.9),
            elevation: 8,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Container(
              width: isNarrow ? double.infinity : 300,
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // File Size Info
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Original', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          Text(_originalSize ?? '-', style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const Icon(Icons.arrow_forward, size: 16, color: Colors.grey),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text('Compressed', style: TextStyle(fontSize: 12, color: Colors.grey)),
                          if (_isCompressing)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Text(_compressedSize ?? '-', style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ],
                  ),
                  const Divider(height: 16),

                  // Format Selection
                  SizedBox(
                    height: 40,
                    child: Row(
                      children: [
                        const Text('Format: '),
                        const Spacer(),
                        DropdownButton<String>(
                          value: _outputFormat,
                          isDense: true,
                          underline: Container(),
                          items: const [
                            DropdownMenuItem(value: 'jpg', child: Text('JPEG')),
                            DropdownMenuItem(value: 'png', child: Text('PNG')),
                            DropdownMenuItem(value: 'webp', child: Text('WEBP')),
                            DropdownMenuItem(value: 'avif', child: Text('AVIF')),
                          ],
                          onChanged: (String? newValue) {
                            if (newValue != null) {
                              setState(() {
                                _outputFormat = newValue;
                              });
                              _compressImage();
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Resolution Selection
                  if (_originalResolution != null) ...[
                    SizedBox(
                      height: 40,
                      child: Row(
                        children: [
                          const Text('Resolution: '),
                          const Spacer(),
                          DropdownButton<double>(
                            value: _resolution,
                            isDense: true,
                            underline: Container(),
                            selectedItemBuilder: (BuildContext context) {
                              return [1.0, 0.5, 0.25].map<Widget>((double value) {
                                return Center(
                                  child: Text(
                                    value == 1.0 ? '100%' : (value == 0.5 ? '50%' : '25%'),
                                    style: const TextStyle(fontWeight: FontWeight.bold),
                                  ),
                                );
                              }).toList();
                            },
                            items: [
                              DropdownMenuItem(
                                value: 1.0,
                                child: _buildResolutionItem('100%', _originalResolution!),
                              ),
                              DropdownMenuItem(
                                value: 0.5,
                                child: _buildResolutionItem('50%', Size(_originalResolution!.width * 0.5, _originalResolution!.height * 0.5)),
                              ),
                              DropdownMenuItem(
                                value: 0.25,
                                child: _buildResolutionItem('25%', Size(_originalResolution!.width * 0.25, _originalResolution!.height * 0.25)),
                              ),
                            ],
                            onChanged: (double? newValue) {
                              if (newValue != null) {
                                setState(() {
                                  _resolution = newValue;
                                });
                                _compressImage();
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Quality Slider
                  SizedBox(
                    height: 40,
                    child: Row(
                      children: [
                        const Text('Quality: '),
                        Expanded(
                          child: Slider(
                            value: _quality,
                            min: 1,
                            max: 100,
                            divisions: 100,
                            label: _quality.round().toString(),
                            onChanged: (double value) {
                              setState(() {
                                _quality = value;
                              });
                            },
                            onChangeEnd: (double value) {
                              _compressImage();
                            },
                          ),
                        ),
                        Text('${_quality.round()}%'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Actions
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: widget.onClear,
                          child: const Text('Clear'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _compressedFile != null ? _saveImage : null,
                          icon: const Icon(Icons.save),
                          label: const Text('Save'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _generatePreview() async {
    final ext = p.extension(widget.file.path).toLowerCase();
    if (ext == '.avif' || ext == '.heic') {
      // Convert AVIF/HEIC to PNG for preview
      try {
        final tempDir = await getTemporaryDirectory();
        final previewPath = '${tempDir.path}/preview.png';
        final previewFile = File(previewPath);

        if (await previewFile.exists()) {
          await previewFile.delete();
        }

        // Convert to PNG
        final task = await _ffmpegService.execute('-y -i "${widget.file.path}" -frames:v 1 -update 1 "$previewPath"');
        await task.done;

        if (await previewFile.exists()) {
          // Clear cache
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();

          if (mounted) {
            setState(() {
              _previewFile = previewFile;
            });
          }
        }
      } catch (e) {
        debugPrint('Error generating preview: $e');
      }
    } else {
      // For supported formats, just use the file directly
      if (mounted) {
        setState(() {
          _previewFile = null;
        });
      }
    }
  }

  Future<void> _updateOriginalSize() async {
    final size = await widget.file.length();
    
    // Get image dimensions
    Size? resolution;
    try {
      final decodedImage = await decodeImageFromList(await File(widget.file.path).readAsBytes());
      resolution = Size(decodedImage.width.toDouble(), decodedImage.height.toDouble());
    } catch (e) {
      debugPrint('Error getting image dimensions: $e');
    }

    setState(() {
      _originalSize = _formatBytes(size);
      _originalResolution = resolution;
    });
  }

  Future<void> _compressImage() async {
    setState(() {
      _isCompressing = true;
      _compressedFile = null;
      _compressedSize = null;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      // Use selected format extension
      final outputPath = '${tempDir.path}/compressed.$_outputFormat';

      // Ensure directory exists
      final outputDir = Directory(p.dirname(outputPath));
      if (!await outputDir.exists()) {
        await outputDir.create(recursive: true);
      }

      // Delete previous temp file if exists
      final outputFile = File(outputPath);
      if (await outputFile.exists()) {
        await outputFile.delete();
      }

      debugPrint('Starting compression for ${widget.file.path}');

      // Construct FFmpeg command
      // -y: overwrite output files
      // -i: input file

      int qValue = (31 - ((_quality - 1) * (29 / 99))).round();
      qValue = qValue.clamp(2, 31);

      String command;
      String scaleFilter = '';
      if (_resolution < 1.0) {
        // Scale width and height, ensuring even dimensions
        scaleFilter = '-vf scale=trunc(iw*$_resolution/2)*2:trunc(ih*$_resolution/2)*2';
      }

      if (_outputFormat == 'png') {
        // PNG (lossless, compression level 0-9, default is usually 6 or 7)
        command = '-y -i "${widget.file.path}" $scaleFilter -frames:v 1 -update 1 "$outputPath"';
      } else if (_outputFormat == 'webp') {
        // WEBP (0-100 quality)
        command = '-y -i "${widget.file.path}" $scaleFilter -q:v ${_quality.round()} -pix_fmt yuv420p -frames:v 1 -update 1 "$outputPath"';
      } else if (_outputFormat == 'avif') {
        // AVIF
        int crf = (63 - ((_quality - 1) * (63 / 99))).round();
        crf = crf.clamp(0, 63);
        // Use yuv420p pixel format for better compatibility
        command = '-y -i "${widget.file.path}" $scaleFilter -c:v libaom-av1 -crf $crf -cpu-used 6 -pix_fmt yuv420p -frames:v 1 -update 1 "$outputPath"';
      } else {
        // JPEG
        command = '-y -i "${widget.file.path}" $scaleFilter -q:v $qValue -pix_fmt yuvj420p -frames:v 1 -update 1 "$outputPath"';
      }

      final task = await _ffmpegService.execute(command);
      await task.done;

      debugPrint('Compression finished');

      if (await outputFile.exists()) {
        final size = await outputFile.length();

        // Force image cache eviction to ensure UI updates
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();

        if (mounted) {
          setState(() {
            _compressedFile = outputFile;
            _compressedSize = _formatBytes(size);
          });
        }
      } else {
        debugPrint('Compression failed: Output file not created');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Compression failed: Output file not created')),
          );
        }
      }
    } catch (e, stackTrace) {
      debugPrint('Error compressing: $e');
      debugPrint('Stack trace: $stackTrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error compressing: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCompressing = false;
        });
      }
    }
  }

  Future<void> _saveImage() async {
    if (_compressedFile == null) return;

    if (Platform.isAndroid || Platform.isIOS) {
      try {
        // Request permissions
        if (Platform.isAndroid) {
          // Gal handles permissions, but good to be explicit if needed
        }
        
        await Gal.putImage(_compressedFile!.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved to Gallery')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error saving to gallery: $e')),
          );
        }
      }
    } else {
      final FileSaveLocation? result = await getSaveLocation(
        suggestedName: 'compressed.$_outputFormat',
        acceptedTypeGroups: [
          XTypeGroup(
            label: 'Images',
            extensions: [_outputFormat],
          ),
        ],
      );
      final String? fileName = result?.path;

      if (fileName == null) {
        // Operation was canceled by the user.
        return;
      }

      try {
        await _compressedFile!.copy(fileName);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Saved to $fileName')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error saving file: $e')),
          );
        }
      }
    }
  }

  String _formatBytes(int bytes, [int decimals = 2]) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"];
    var i = (bytes.toString().length - 1) ~/ 3; // Simplified log10
    // Or just loop
    i = 0;
    double v = bytes.toDouble();
    while (v >= 1024 && i < suffixes.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(decimals)} ${suffixes[i]}';
  }

  Widget _buildResolutionItem(String percentage, Size size) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(percentage, style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(
          '${size.width.round()} x ${size.height.round()}',
          style: const TextStyle(fontSize: 10, color: Colors.grey),
        ),
      ],
    );
  }
}