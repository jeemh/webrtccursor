import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

class FaceMaskingService {
  final FaceDetector _faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.accurate,
      enableContours: true,
    ),
  );

  // 이미지에서 얼굴을 감지하고 블러 또는 마스크 처리
  Future<Uint8List?> maskFacesInImage(Uint8List imageBytes) async {
    final inputImage = InputImage.fromBytes(
      bytes: imageBytes,
      metadata: InputImageMetadata(
        size: Size(640, 480), // 이미지 크기에 맞게 조정 필요
        rotation: InputImageRotation.rotation0deg,
        format: InputImageFormat.nv21, // 이미지 포맷에 맞게 조정 필요
        bytesPerRow: 640, // 이미지 너비에 맞게 조정 필요
      ),
    );

    final faces = await _faceDetector.processImage(inputImage);

    if (faces.isEmpty) return imageBytes;

    // 이미지 디코딩
    final decodedImage = img.decodeImage(imageBytes);
    if (decodedImage == null) return null;

    // 얼굴 영역에 블러 또는 마스크 적용
    for (final face in faces) {
      final boundingBox = face.boundingBox;

      // 얼굴 영역을 추출하여 블러 처리
      final faceRegion = img.copyCrop(
        decodedImage,
        x: boundingBox.left.toInt(),
        y: boundingBox.top.toInt(),
        width: boundingBox.width.toInt(),
        height: boundingBox.height.toInt(),
      );

      // 블러 처리 적용
      img.gaussianBlur(faceRegion, radius: 20);

      // 처리된 영역을 다시 원본 이미지에 복사
      img.compositeImage(
        decodedImage,
        faceRegion,
        dstX: boundingBox.left.toInt(),
        dstY: boundingBox.top.toInt(),
      );
    }

    // 처리된 이미지 인코딩하여 반환
    return Uint8List.fromList(img.encodeJpg(decodedImage));
  }

  void dispose() {
    _faceDetector.close();
  }
}
