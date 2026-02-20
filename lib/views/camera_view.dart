import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

// Platform-specific imports
import 'package:camera/camera.dart' as camera_pkg;
import 'package:camera_macos/camera_macos.dart' as camera_macos;
import 'package:camera_linux/camera_linux.dart' as camera_linux;

enum CaptureMode { photo, video }

class CameraView extends StatefulWidget {
  final ValueChanged<XFile> onCapture;

  const CameraView({super.key, required this.onCapture});

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  CaptureMode _mode = CaptureMode.photo;

  // Standard camera controller (Android / Windows / iOS)
  camera_pkg.CameraController? _cameraController;
  List<camera_pkg.CameraDescription>? _cameras;

  // macOS-specific camera controller
  camera_macos.CameraMacOSController? _macOSController;

  // Linux camera
  camera_linux.CameraLinux? _linuxCamera;
  Uint8List? _linuxLatestFrame;
  Timer? _linuxTimer;
  Process? _linuxRecordingProcess;
  String? _linuxRecordingPath;

  bool _isRecording = false;
  bool _isInitializing = true;
  String? _errorMessage;

  bool get _isMacOS => Platform.isMacOS;
  bool get _isLinux => Platform.isLinux;

  // Key to force rebuild of CameraMacOSView when mode changes
  Key? _macOSViewKey;

  @override
  void initState() {
    super.initState();
    _macOSViewKey = UniqueKey();
    if (_isLinux) {
      _initializeLinuxCamera();
    } else if (!_isMacOS) {
      _initializeStandardCamera();
    }
  }

  camera_macos.CameraMacOSMode get _macOSCameraMode {
    return _mode == CaptureMode.photo
        ? camera_macos.CameraMacOSMode.photo
        : camera_macos.CameraMacOSMode.video;
  }

  // ─── Initialisation ────────────────────────────────────────────────────────

  Future<void> _initializeLinuxCamera() async {
    try {
      _linuxCamera = camera_linux.CameraLinux();
      _linuxCamera!.initializeCamera();
      await Process.run('v4l2-ctl', ['-c', 'exposure_dynamic_framerate=0']);
      // Give the capture thread a moment to grab the first frame
      await Future.delayed(const Duration(milliseconds: 200));
      _linuxTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
        final frame = _linuxCamera?.captureFrame();
        if (frame != null && mounted) {
          setState(() => _linuxLatestFrame = frame);
          if (_isRecording && _linuxRecordingProcess != null) {
            try {
              _linuxRecordingProcess!.stdin.add(frame);
            } catch (e) {
              debugPrint('Error writing frame to ffmpeg: $e');
            }
          }
        }
      });
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    } catch (e) {
      debugPrint('Error initializing Linux camera: $e');
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _errorMessage = 'Error initializing camera: $e';
        });
      }
    }
  }

  Future<void> _initializeStandardCamera() async {
    try {
      _cameras = await camera_pkg.availableCameras();
      if (_cameras != null && _cameras!.isNotEmpty) {
        _cameraController = camera_pkg.CameraController(
          _cameras!.first,
          camera_pkg.ResolutionPreset.max,
          enableAudio: true,
        );
        await _cameraController!.initialize();
        if (mounted) setState(() => _isInitializing = false);
      } else {
        if (mounted) {
          setState(() {
            _isInitializing = false;
            _errorMessage = 'No cameras found';
          });
        }
      }
    } catch (e) {
      debugPrint('Error initializing camera: $e');
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _errorMessage = 'Error initializing camera: $e';
        });
      }
    }
  }

  void _onMacOSCameraInitialized(camera_macos.CameraMacOSController ctrl) {
    debugPrint('macOS camera initialized');
    _macOSController = ctrl;
    if (mounted) setState(() => _isInitializing = false);
  }

  // ─── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _linuxTimer?.cancel();
    _linuxCamera?.stopCamera();
    _cameraController?.dispose();
    _macOSController?.destroy();
    super.dispose();
  }

  // ─── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(color: Colors.grey[900], child: _buildPreview()),
        ),
        Positioned(
          bottom: 30,
          left: 0,
          right: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Mode switcher
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildModeButton(CaptureMode.photo, 'Photo'),
                    const SizedBox(width: 16),
                    _buildModeButton(CaptureMode.video, 'Video'),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Capture button
              GestureDetector(
                onTap: _onCaptureTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                    color: _isRecording ? Colors.red : Colors.white,
                  ),
                  child: _isRecording
                      ? Center(
                          child: Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ─── Preview widgets ────────────────────────────────────────────────────────

  Widget _buildPreview() {
    if (_isMacOS) return _buildMacOSPreview();
    if (_isLinux) return _buildLinuxPreview();
    return _buildStandardPreview();
  }

  Widget _buildLinuxPreview() {
    if (_isInitializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(
        child: Text(
          _errorMessage!,
          style: const TextStyle(color: Colors.white),
        ),
      );
    }

    if (_linuxLatestFrame == null) {
      return const Center(
        child: Text(
          'Waiting for camera...',
          style: TextStyle(color: Colors.white),
        ),
      );
    }
    return Center(
      child: Image.memory(
        _linuxLatestFrame!,
        fit: BoxFit.contain,
        gaplessPlayback: true,
      ),
    );
  }

  Widget _buildMacOSPreview() {
    if (_errorMessage != null) {
      return Center(
        child: Text(
          _errorMessage!,
          style: const TextStyle(color: Colors.white),
        ),
      );
    }
    return camera_macos.CameraMacOSView(
      key: _macOSViewKey,
      cameraMode: _macOSCameraMode,
      fit: BoxFit.contain,
      pictureFormat: camera_macos.PictureFormat.jpg,
      videoFormat: camera_macos.VideoFormat.mp4,
      enableAudio: true,
      onCameraInizialized: _onMacOSCameraInitialized,
      onCameraLoading: (error) {
        if (error != null) {
          return Center(
            child: Text(
              'Camera error: $error',
              style: const TextStyle(color: Colors.white),
            ),
          );
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }

  Widget _buildStandardPreview() {
    if (_isInitializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(
        child: Text(
          _errorMessage!,
          style: const TextStyle(color: Colors.white),
        ),
      );
    }
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Center(
        child: Text(
          'Camera not initialized',
          style: TextStyle(color: Colors.white),
        ),
      );
    }
    return Center(
      child: AspectRatio(
        aspectRatio: _cameraController!.value.aspectRatio,
        child: camera_pkg.CameraPreview(_cameraController!),
      ),
    );
  }

  Widget _buildModeButton(CaptureMode mode, String label) {
    final isSelected = _mode == mode;
    return GestureDetector(
      onTap: () {
        if (_isRecording || _mode == mode) return;
        setState(() {
          _mode = mode;
          if (_isMacOS) {
            _isInitializing = true;
            _macOSController = null;
            _macOSViewKey = UniqueKey();
          }
        });
      },
      child: Text(
        label,
        style: TextStyle(
          color: isSelected ? Colors.yellow : Colors.white,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 16,
        ),
      ),
    );
  }

  // ─── Capture ────────────────────────────────────────────────────────────────

  Future<void> _onCaptureTap() async {
    if (_isLinux) {
      if (_linuxCamera == null) return;
    } else if (_isMacOS) {
      if (_macOSController == null) return;
    } else {
      if (_cameraController == null || !_cameraController!.value.isInitialized)
        return;
    }

    if (_mode == CaptureMode.photo) {
      await _takePhoto();
    } else {
      _isRecording ? await _stopVideo() : await _startVideo();
    }
  }

  Future<void> _takePhoto() async {
    try {
      debugPrint('Taking photo...');

      if (_isLinux) {
        final bytes = _linuxLatestFrame;
        if (bytes == null) {
          debugPrint('No frame available yet');
          return;
        }
        final tempDir = await getTemporaryDirectory();
        final path =
            '${tempDir.path}/camera_photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await File(path).writeAsBytes(bytes);
        debugPrint('Photo saved to: $path');
        widget.onCapture(XFile(path));
      } else if (_isMacOS) {
        final result = await _macOSController!.takePicture();
        if (result == null) {
          debugPrint('Photo capture returned null');
          return;
        }
        debugPrint('Result url: ${result.url}, bytes: ${result.bytes?.length}');
        if (result.url != null && result.url!.isNotEmpty) {
          widget.onCapture(XFile(result.url!));
        } else if (result.bytes != null && result.bytes!.isNotEmpty) {
          final tempDir = await getTemporaryDirectory();
          final path =
              '${tempDir.path}/camera_photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
          await File(path).writeAsBytes(result.bytes!);
          debugPrint('Photo saved to: $path');
          widget.onCapture(XFile(path));
        } else {
          debugPrint('Photo capture returned result but no URL or bytes');
        }
      } else {
        final file = await _cameraController!.takePicture();
        debugPrint('Photo taken: ${file.path}');
        widget.onCapture(file);
      }
    } catch (e, st) {
      debugPrint('Error taking photo: $e\n$st');
    }
  }

  Future<void> _startVideo() async {
    try {
      debugPrint('Starting video recording...');
      if (_isLinux) {
        final tempDir = await getTemporaryDirectory();
        _linuxRecordingPath =
            '${tempDir.path}/camera_video_${DateTime.now().millisecondsSinceEpoch}.mp4';
        // Video recording on Linux uses ffmpeg separately while the preview
        // continues via the timer.
        await Process.run('v4l2-ctl', ['-c', 'exposure_dynamic_framerate=0']);
        _linuxRecordingProcess = await Process.start('ffmpeg', [
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'image2pipe',
          '-vcodec',
          'mjpeg',
          '-framerate',
          '30',
          '-i',
          '-',
          '-c:v',
          'libx264',
          '-preset',
          'ultrafast',
          '-pix_fmt',
          'yuv420p',
          '-movflags',
          '+faststart',
          '-y',
          _linuxRecordingPath!,
        ]);
        _linuxRecordingProcess!.stderr.transform(utf8.decoder).listen((data) {
          debugPrint('FFMPEG STDERR: $data');
        });
      } else if (_isMacOS) {
        final tempDir = await getTemporaryDirectory();
        final path =
            '${tempDir.path}/camera_video_${DateTime.now().millisecondsSinceEpoch}.mp4';
        await _macOSController!.recordVideo(url: path, enableAudio: true);
      } else {
        await _cameraController!.startVideoRecording();
      }
      setState(() => _isRecording = true);
    } catch (e) {
      debugPrint('Error starting video: $e');
    }
  }

  Future<void> _stopVideo() async {
    try {
      debugPrint('Stopping video recording...');
      if (_isLinux) {
        final savedPath = _linuxRecordingPath;
        setState(() {
          _isRecording = false;
        });
        
        if (_linuxRecordingProcess != null) {
          try {
            await _linuxRecordingProcess!.stdin.close();
          } catch (_) {}
          await _linuxRecordingProcess!.exitCode.timeout(
            const Duration(seconds: 5),
            onTimeout: () { _linuxRecordingProcess!.kill(); return -1; },
          );
        }
        
        setState(() {
          _linuxRecordingPath = null;
          _linuxRecordingProcess = null;
        });
        if (savedPath != null) {
          debugPrint('Video saved to: $savedPath');
          widget.onCapture(XFile(savedPath));
        }
      } else if (_isMacOS) {
        final result = await _macOSController!.stopRecording();
        setState(() => _isRecording = false);
        if (result?.url != null) {
          debugPrint('Video stopped on macOS: ${result!.url}');
          widget.onCapture(XFile(result.url!));
        } else {
          debugPrint('Video stop returned null or no URL');
        }
      } else {
        final file = await _cameraController!.stopVideoRecording();
        setState(() => _isRecording = false);
        debugPrint('Video stopped: ${file.path}');
        widget.onCapture(file);
      }
    } catch (e) {
      debugPrint('Error stopping video: $e');
    }
  }
}
