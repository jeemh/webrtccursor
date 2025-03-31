import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'dart:core';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'face_masking_service.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'dart:ui' as ui;
import 'dart:async';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WebRTC 화상통화',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const VideoCallPage(),
    );
  }
}

class VideoCallPage extends StatefulWidget {
  const VideoCallPage({Key? key}) : super(key: key);

  @override
  State<VideoCallPage> createState() => _VideoCallPageState();
}

class _VideoCallPageState extends State<VideoCallPage> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  MediaStream? _localStream;
  RTCPeerConnection? _peerConnection;
  bool _isConnected = false;

  // 시그널링 서버 연결을 위한 변수
  IO.Socket? _socket;
  String? _userId;
  List<String> _users = [];
  String? _selectedUser;
  bool _incomingCall = false;
  String? _caller;
  RTCSessionDescription? _offer;

  final FaceMaskingService _faceMaskingService = FaceMaskingService();
  MediaStream? _processedLocalStream;

  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  List<Face>? _faces;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _initRenderers();
    _requestPermissions();
    _connectToSignalingServer();
    _initializeCamera();
    _initializeFaceDetector();
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _localStream?.getTracks().forEach((track) => track.stop());
    _peerConnection?.close();
    _socket?.disconnect();
    _faceMaskingService.dispose();
    _faceDetector?.close();
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  Future<void> _requestPermissions() async {
    await [Permission.camera, Permission.microphone].request();
  }

  Future<void> _getUserMedia() async {
    final Map<String, dynamic> mediaConstraints = {
      'audio': true,
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
      },
    };

    try {
      final stream = await navigator.mediaDevices.getUserMedia(
        mediaConstraints,
      );

      // 얼굴 가리기를 적용한 처리된 스트림 생성
      _processedLocalStream = await _processVideoStream(stream);

      setState(() {
        _localStream = _processedLocalStream;
        _localRenderer.srcObject = _processedLocalStream;
      });
    } catch (e) {
      print('카메라 및 마이크 접근 오류: $e');
    }
  }

  // 시그널링 서버 연결
  void _connectToSignalingServer() {
    // 웹이면 localhost, 모바일 에뮬레이터면 10.0.2.2 사용
    final serverUrl = kIsWeb ? 'http://localhost:5000' : 'http://10.0.2.2:5000';

    _socket = IO.io(
      serverUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    _socket!.connect();

    _socket!.onConnect((_) {
      print('서버에 연결되었습니다!');
      // 임의의 사용자 ID 생성 (실제 앱에서는 로그인 시스템 구현 필요)
      _userId = 'user_${DateTime.now().millisecondsSinceEpoch}';
      _socket!.emit('register', _userId);
    });

    _socket!.on('updateUserList', (userList) {
      setState(() {
        _users = List<String>.from(userList);
        // 자신은 리스트에서 제외
        _users.remove(_userId);
      });
    });

    _socket!.on('incomingCall', (data) {
      final caller = data['caller'];
      final offerData = data['offer'];

      setState(() {
        _incomingCall = true;
        _caller = caller;
        _offer = RTCSessionDescription(offerData['sdp'], offerData['type']);
      });
    });

    _socket!.on('callAnswered', (data) async {
      final answerData = data['answer'];
      final rtcAnswer = RTCSessionDescription(
        answerData['sdp'],
        answerData['type'],
      );

      await _peerConnection!.setRemoteDescription(rtcAnswer);
    });

    _socket!.on('ice-candidate', (data) async {
      if (_peerConnection != null) {
        final candidateData = data['candidate'];
        final rtcCandidate = RTCIceCandidate(
          candidateData['candidate'],
          candidateData['sdpMid'],
          candidateData['sdpMLineIndex'],
        );

        await _peerConnection!.addCandidate(rtcCandidate);
      }
    });

    _socket!.on('callEnded', (_) {
      _endCall();
    });
  }

  Future<void> _createPeerConnection() async {
    final Map<String, dynamic> configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    };

    final Map<String, dynamic> offerSdpConstraints = {
      'mandatory': {'OfferToReceiveAudio': true, 'OfferToReceiveVideo': true},
      'optional': [],
    };

    _peerConnection = await createPeerConnection(configuration);

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      // 시그널링 서버를 통해 ICE 후보 전송
      _socket!.emit('ice-candidate', {
        'target': _selectedUser,
        'candidate': candidate.toMap(),
      });
    };

    _peerConnection!.onAddStream = (MediaStream stream) {
      setState(() {
        _remoteRenderer.srcObject = stream;
      });
    };

    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });
  }

  // 통화 시작 (발신자)
  void _startCall() async {
    if (_selectedUser == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('통화할 사용자를 선택해주세요')));
      return;
    }

    await _getUserMedia();
    await _createPeerConnection();

    // 오퍼 생성
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    // 시그널링 서버를 통해 오퍼 전송
    _socket!.emit('call', {'target': _selectedUser, 'offer': offer.toMap()});

    setState(() {
      _isConnected = true;
    });
  }

  // 통화 응답 (수신자)
  void _answerCall() async {
    await _getUserMedia();
    await _createPeerConnection();

    // 수신한 오퍼 설정
    await _peerConnection!.setRemoteDescription(_offer!);

    // 응답 생성
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    // 시그널링 서버를 통해 응답 전송
    _socket!.emit('answer', {'target': _caller, 'answer': answer.toMap()});

    setState(() {
      _incomingCall = false;
      _isConnected = true;
      _selectedUser = _caller;
    });
  }

  // 통화 거절
  void _rejectCall() {
    setState(() {
      _incomingCall = false;
      _caller = null;
      _offer = null;
    });
  }

  void _endCall() {
    if (_selectedUser != null) {
      _socket!.emit('endCall', {'target': _selectedUser});
    }

    _localStream?.getTracks().forEach((track) => track.stop());
    _peerConnection?.close();
    setState(() {
      _localStream = null;
      _peerConnection = null;
      _localRenderer.srcObject = null;
      _remoteRenderer.srcObject = null;
      _isConnected = false;
      _selectedUser = null;
    });
  }

  // 비디오 스트림 처리 메서드
  Future<MediaStream> _processVideoStream(MediaStream originalStream) async {
    // 현재 기술적 제한으로 인해 원본 스트림을 그대로 사용
    // 프레임 처리는 비디오 렌더링 시 UI 레이어에서 수행
    return originalStream;
  }

  // 얼굴 가리기를 적용한 비디오 뷰 위젯 추가
  Widget _buildVideoWithFaceBlurring(RTCVideoRenderer renderer) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RTCVideoView(
          renderer,
          mirror: renderer == _localRenderer, // 로컬 카메라만 미러링
        ),
        // 간단한 고정 얼굴 마스크 오버레이 추가
        Center(
          child: Container(
            width: 150,
            height: 150,
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.7),
              shape: BoxShape.circle,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    final frontCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(frontCamera, ResolutionPreset.medium);

    await _cameraController!.initialize();

    if (mounted) {
      setState(() {});
      _processCameraImage();
    }
  }

  void _initializeFaceDetector() {
    _faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        enableContours: true,
        enableClassification: true,
      ),
    );
  }

  Future<void> _processCameraImage() async {
    _cameraController!.startImageStream((CameraImage image) {
      if (_isProcessing) return;
      _isProcessing = true;

      // 이미지 변환 및 처리
      _detectFaces(image).then((_) {
        _isProcessing = false;
      });
    });
  }

  Future<void> _detectFaces(CameraImage image) async {
    // CameraImage를 InputImage로 변환
    final inputImage = _convertCameraImageToInputImage(image);
    if (inputImage == null) return;

    final faces = await _faceDetector!.processImage(inputImage);
    if (mounted) {
      setState(() {
        _faces = faces;
      });
    }
  }

  // CameraImage를 InputImage로 변환하는 메서드
  InputImage? _convertCameraImageToInputImage(CameraImage image) {
    final camera = _cameraController!.description;
    final orientation = InputImageRotationValue.fromRawValue(
      camera.sensorOrientation,
    );

    if (orientation == null) return null;

    // 이미지 형식에 따라 변환 방식이 다름
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    // YUV 또는 NV21 형식인 경우 (안드로이드 대부분)
    if (image.planes.length >= 3) {
      return InputImage.fromBytes(
        bytes: image.planes[0].bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: orientation,
          format: format,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    }

    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebRTC 화상통화'),
        actions: [
          // 네트워크 테스트 버튼 추가
          IconButton(
            icon: Icon(Icons.network_check),
            onPressed: () async {
              try {
                final response = await http.get(
                  kIsWeb
                      ? Uri.parse('http://localhost:5000/test')
                      : Uri.parse('http://10.0.2.2:5000/test'),
                );
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '서버 응답: ${response.statusCode} ${response.body}',
                    ),
                  ),
                );
              } catch (e) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('네트워크 오류: $e')));
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 사용자 ID 표시를 강제로 함
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              '사용자 ID: ${_userId ?? "연결 중..."}',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          if (!_isConnected && !_incomingCall)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text('통화할 사용자 선택:'),
                  DropdownButton<String>(
                    hint: Text('사용자 선택'),
                    value: _selectedUser,
                    items:
                        _users
                            .map(
                              (user) => DropdownMenuItem(
                                value: user,
                                child: Text(user),
                              ),
                            )
                            .toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedUser = value;
                      });
                    },
                  ),
                ],
              ),
            ),
          if (_incomingCall)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Text(
                    '${_caller}님으로부터 통화 요청이 왔습니다',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: _answerCall,
                        child: const Text('수락'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                        ),
                      ),
                      SizedBox(width: 16),
                      ElevatedButton(
                        onPressed: _rejectCall,
                        child: const Text('거절'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                Container(
                  key: const Key('remote'),
                  margin: const EdgeInsets.all(5.0),
                  decoration: BoxDecoration(color: Colors.black),
                  child: _buildVideoWithFaceBlurring(_remoteRenderer),
                ),
                Positioned(
                  right: 20,
                  bottom: 20,
                  width: 120,
                  height: 160,
                  child: Container(
                    key: const Key('local'),
                    decoration: BoxDecoration(
                      color: Colors.black,
                      border: Border.all(color: Colors.white, width: 2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: _buildVideoWithFaceBlurring(_localRenderer),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (!_isConnected && !_incomingCall)
                  ElevatedButton(
                    onPressed: _startCall,
                    child: const Text('통화 시작'),
                  )
                else if (_isConnected)
                  ElevatedButton(
                    onPressed: _endCall,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                    ),
                    child: const Text('통화 종료'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// 얼굴 위에 마스크를 그리는 CustomPainter
class FaceMaskPainter extends CustomPainter {
  final List<Face> faces;
  final Size imageSize;
  final MaskType maskType;

  FaceMaskPainter({
    required this.faces,
    required this.imageSize,
    required this.maskType,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final face in faces) {
      // 얼굴 위치 계산 (카메라와 화면 비율 조정)
      final faceRect = _scaleRect(
        rect: face.boundingBox,
        imageSize: imageSize,
        widgetSize: size,
      );

      if (maskType == MaskType.mosaic) {
        // 모자이크 효과 그리기
        final mosaicSize = 15.0;
        for (double x = faceRect.left; x < faceRect.right; x += mosaicSize) {
          for (double y = faceRect.top; y < faceRect.bottom; y += mosaicSize) {
            canvas.drawRect(
              Rect.fromLTWH(x, y, mosaicSize, mosaicSize),
              Paint()..color = Colors.black.withOpacity(0.7),
            );
          }
        }
      } else if (maskType == MaskType.animal) {
        // 동물 탈 이미지를 얼굴 위치에 그리기
        // 이미지는 미리 로드되어 있어야 함
        canvas.drawRect(
          faceRect,
          Paint()..color = Colors.yellow.withOpacity(0.7),
        );

        // 눈, 코, 입 위치에 동물 특징 그리기
        // face.landmarks를 사용하여 더 정확한 위치에 그릴 수 있음
      }
    }
  }

  Rect _scaleRect({
    required Rect rect,
    required Size imageSize,
    required Size widgetSize,
  }) {
    final scaleX = widgetSize.width / imageSize.width;
    final scaleY = widgetSize.height / imageSize.height;

    return Rect.fromLTRB(
      rect.left * scaleX,
      rect.top * scaleY,
      rect.right * scaleX,
      rect.bottom * scaleY,
    );
  }

  @override
  bool shouldRepaint(FaceMaskPainter oldDelegate) => true;
}

enum MaskType { mosaic, animal }
