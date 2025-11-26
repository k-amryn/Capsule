import 'dart:async';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

class AudioRecordView extends StatefulWidget {
  final ValueChanged<XFile> onCapture;

  const AudioRecordView({
    super.key,
    required this.onCapture,
  });

  @override
  State<AudioRecordView> createState() => _AudioRecordViewState();
}

class _AudioRecordViewState extends State<AudioRecordView> {
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  Timer? _timer;
  int _recordDuration = 0;

  @override
  void dispose() {
    _timer?.cancel();
    _audioRecorder.dispose();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _recordDuration = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _recordDuration++;
      });
    });
  }

  void _stopTimer() {
    _timer?.cancel();
  }

  String _formatDuration(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final remainingSeconds = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remainingSeconds';
  }

  Future<void> _toggleRecording() async {
    try {
      if (_isRecording) {
        await _stopAudio();
      } else {
        await _startAudio();
      }
    } catch (e) {
      debugPrint('Error toggling audio: $e');
    }
  }

  Future<void> _startAudio() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        final path = '${tempDir.path}/audio_capture_${DateTime.now().millisecondsSinceEpoch}.m4a';
        
        debugPrint('Starting audio recording to $path');
        await _audioRecorder.start(const RecordConfig(), path: path);
        
        setState(() {
          _isRecording = true;
        });
        _startTimer();
      } else {
        debugPrint('Audio permission denied');
      }
    } catch (e) {
      debugPrint('Error starting audio: $e');
    }
  }

  Future<void> _stopAudio() async {
    try {
      debugPrint('Stopping audio recording...');
      final path = await _audioRecorder.stop();
      _stopTimer();
      
      setState(() {
        _isRecording = false;
      });
      
      if (path != null) {
        debugPrint('Audio recording finished: $path');
        widget.onCapture(XFile(path));
      }
    } catch (e) {
      debugPrint('Error stopping audio: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Main Content
        Container(
          color: Colors.transparent,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_isRecording)
                  Text(
                    _formatDuration(_recordDuration),
                    style: const TextStyle(
                      color: Colors.red,
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                const SizedBox(height: 40),
                GestureDetector(
                  onTap: _toggleRecording,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isRecording ? Colors.red.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.1),
                      border: Border.all(
                        color: _isRecording ? Colors.red : Colors.white,
                        width: 4,
                      ),
                    ),
                    child: Icon(
                      _isRecording ? Icons.stop : Icons.mic,
                      size: 48,
                      color: _isRecording ? Colors.red : Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  _isRecording ? 'Recording...' : 'Tap to Record',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ],
            ),
          ),
        ),

      ],
    );
  }
}