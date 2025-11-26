import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

enum CaptureMode { photo, video }

class CameraView extends StatefulWidget {
  final ValueChanged<XFile> onCapture;

  const CameraView({
    super.key,
    required this.onCapture,
  });

  @override
  State<CameraView> createState() => _CameraViewState();
}

class _CameraViewState extends State<CameraView> {
  CaptureMode _mode = CaptureMode.photo;
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  
  bool _isRecording = false;
  bool _isInitializing = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras != null && _cameras!.isNotEmpty) {
        // Use the first camera (usually back camera on mobile, or webcam on desktop)
        final camera = _cameras!.first;
        _cameraController = CameraController(
          camera,
          ResolutionPreset.max,
          enableAudio: true,
        );

        await _cameraController!.initialize();
        if (mounted) {
          setState(() {
            _isInitializing = false;
          });
        }
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

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Preview Area
        Positioned.fill(
          child: Container(
            color: Colors.grey[900],
            child: _buildPreview(),
          ),
        ),


        // Controls
        Positioned(
          bottom: 30,
          left: 0,
          right: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Mode Switcher
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
              
              // Capture Button
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

  Widget _buildPreview() {
    if (_isInitializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorMessage != null) {
      return Center(child: Text(_errorMessage!, style: const TextStyle(color: Colors.white)));
    }
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Center(child: Text('Camera not initialized', style: TextStyle(color: Colors.white)));
    }

    return Center(
      child: AspectRatio(
        aspectRatio: _cameraController!.value.aspectRatio,
        child: CameraPreview(_cameraController!),
      ),
    );
  }

  Widget _buildModeButton(CaptureMode mode, String label) {
    final isSelected = _mode == mode;
    return GestureDetector(
      onTap: () {
        if (!_isRecording) {
          setState(() {
            _mode = mode;
          });
        }
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

  Future<void> _onCaptureTap() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;

    debugPrint('Capture tapped. Mode: $_mode, Recording: $_isRecording');
    if (_mode == CaptureMode.photo) {
      await _takePhoto();
    } else if (_mode == CaptureMode.video) {
      if (_isRecording) {
        await _stopVideo();
      } else {
        await _startVideo();
      }
    }
  }

  Future<void> _takePhoto() async {
    try {
      debugPrint('Taking photo...');
      final file = await _cameraController!.takePicture();
      debugPrint('Photo taken: ${file.path}');
      widget.onCapture(file);
    } catch (e) {
      debugPrint('Error taking photo: $e');
    }
  }

  Future<void> _startVideo() async {
    try {
      debugPrint('Starting video recording...');
      await _cameraController!.startVideoRecording();
      
      setState(() {
        _isRecording = true;
      });
    } catch (e) {
      debugPrint('Error starting video: $e');
    }
  }

  Future<void> _stopVideo() async {
    try {
      debugPrint('Stopping video recording...');
      final file = await _cameraController!.stopVideoRecording();
      setState(() {
        _isRecording = false;
      });
      
      debugPrint('Video stopped and file returned: ${file.path}');
      widget.onCapture(file);
    } catch (e) {
      debugPrint('Error stopping video: $e');
    }
  }
}