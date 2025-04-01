import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

// 너구리 마스크 이미지 메모리 캐시
ui.Image? _raccoonImage;

class InputImagePlaneMetadata {
  final int bytesPerRow;
  final int height;
  final int width;

  InputImagePlaneMetadata({
    required this.bytesPerRow,
    required this.height,
    required this.width,
  });
}

class FaceMaskingService {
  final FaceDetector _faceDetector;
  bool _isProcessing = false;
  ui.Image? raccoonImage;

  FaceMaskingService()
    : _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableLandmarks: true,
          enableContours: true,
          enableTracking: true,
          performanceMode: FaceDetectorMode.accurate,
          minFaceSize: 0.15,
        ),
      ) {
    _loadRaccoonImage();
  }

  // 너구리 이미지 로드
  Future<void> _loadRaccoonImage() async {
    if (_raccoonImage != null) {
      raccoonImage = _raccoonImage;
      return;
    }

    try {
      final ByteData data = await NetworkAssetBundle(
        Uri.parse(
          'https://i.namu.wiki/i/yYbLn1JjcwHiJXSYSPRs46iaW2FytB5AQc1tBpoftJIN_ltHuHzLx09Glc27azN0Rk-SAqzQkB5QQxxDOVOu8w.webp',
        ),
      ).load('');

      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frameInfo = await codec.getNextFrame();

      raccoonImage = frameInfo.image;
      _raccoonImage = raccoonImage; // 캐시에 저장

      print('너구리 이미지 로드 완료: ${raccoonImage!.width}x${raccoonImage!.height}');
    } catch (e) {
      print('너구리 이미지 로드 실패: $e');
    }
  }

  // 영상 스트림 처리
  Future<List<Face>> processImage(CameraImage image) async {
    if (_isProcessing) return [];
    _isProcessing = true;

    try {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      final bytes = allBytes.done().buffer.asUint8List();

      final imageSize = Size(image.width.toDouble(), image.height.toDouble());
      final imageRotation = InputImageRotation.rotation0deg;

      final inputImageFormat = InputImageFormatValue.fromRawValue(
        image.format.raw,
      );
      if (inputImageFormat == null) {
        _isProcessing = false;
        return [];
      }

      final planeData =
          image.planes.map((plane) {
            return InputImageMetadata(
              bytesPerRow: plane.bytesPerRow,
              size: Size(
                plane.width?.toDouble() ?? 0.0,
                plane.height?.toDouble() ?? 0.0,
              ),
              rotation: InputImageRotation.rotation0deg,
              format: inputImageFormat,
            );
          }).toList();

      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: imageSize,
          rotation: imageRotation,
          format: inputImageFormat,
          bytesPerRow: planeData.first.bytesPerRow,
        ),
      );

      final faces = await _faceDetector.processImage(inputImage);
      return faces;
    } catch (e) {
      print('Face detection error: $e');
      return [];
    } finally {
      _isProcessing = false;
    }
  }

  // WebRTC 스트림을 처리하는 메서드
  Future<MediaStream> processVideoStream(MediaStream stream) async {
    // 이미지 로드 확인
    if (raccoonImage == null) {
      await _loadRaccoonImage();
    }

    // 원본 스트림 반환 (실제 처리는 프레임 단위로 이루어짐)
    return stream;
  }

  void dispose() {
    _faceDetector.close();
  }
}
