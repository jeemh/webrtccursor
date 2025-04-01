import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'dart:core';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:ui' as ui;
import 'dart:async';
import 'dart:math' as Math;
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

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

  @override
  void initState() {
    super.initState();
    _initRenderers();
    _requestPermissions();
    _connectToSignalingServer();
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _localStream?.getTracks().forEach((track) => track.stop());
    _peerConnection?.close();
    _socket?.disconnect();
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

      setState(() {
        _localStream = stream;
        _localRenderer.srcObject = stream;
      });
    } catch (e) {
      print('카메라 및 마이크 접근 오류: $e');
    }
  }

  // 시그널링 서버 연결
  void _connectToSignalingServer() {
    // !!! 중요: 노트북의 실제 로컬 IP 주소로 변경하세요 !!!
    // 예: final serverUrl = 'http://192.168.1.10:5000';
    final serverUrl = 'http://192.168.1.50:5000'; // <--- 이 부분을 수정하세요

    // 웹 환경에서는 여전히 localhost 사용 (테스트용)
    // final effectiveUrl = kIsWeb ? 'http://localhost:5000' : serverUrl;

    print('서버 연결 시도: $serverUrl'); // 연결 주소 로그 추가

    _socket = IO.io(
      serverUrl, // 수정된 URL 사용
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
      // 연결 성공 시 상태 업데이트
      if (mounted) {
        setState(() {}); // userId가 업데이트되었음을 UI에 반영
      }
    });

    _socket!.onDisconnect((_) {
      print('서버 연결 끊김');
      if (mounted) {
        _showErrorSnackBar('서버와의 연결이 끊어졌습니다.');
        _resetState(); // 연결 끊김 시 상태 초기화
      }
    });

    _socket!.onConnectError((data) {
      print('서버 연결 오류: $data');
      if (mounted) {
        _showErrorSnackBar('서버($serverUrl)에 연결할 수 없습니다. IP 주소와 방화벽 설정을 확인하세요.');
        setState(() {}); // 연결 실패 상태 UI 반영
      }
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
      print('[Flutter] 원격 응답 수신됨');
      final answerData = data['answer'];
      final rtcAnswer = RTCSessionDescription(
        answerData['sdp'],
        answerData['type'],
      );
      print('[Flutter] 원격 설명 설정 시도 (응답)');
      await _peerConnection!.setRemoteDescription(rtcAnswer);
      print('[Flutter] 원격 설명 설정 완료 (응답)');
    });

    _socket!.on('ice-candidate', (data) async {
      if (_peerConnection != null) {
        print('[Flutter] 원격 ICE 후보 수신됨');
        final candidateData = data['candidate'];
        final rtcCandidate = RTCIceCandidate(
          candidateData['candidate'],
          candidateData['sdpMid'],
          candidateData['sdpMLineIndex'],
        );
        try {
          await _peerConnection!.addCandidate(rtcCandidate);
          print('[Flutter] 원격 ICE 후보 추가 성공');
        } catch (e) {
          print('[Flutter] 원격 ICE 후보 추가 실패: $e');
        }
      }
    });

    _socket!.on('callEnded', (_) => _handleCallEnded());
  }

  Future<void> _createPeerConnection() async {
    final Map<String, dynamic> configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
      // 'sdpSemantics': 'unified-plan', // flutter_webrtc의 기본값이므로 명시적으로 필요 없을 수 있음
    };

    _peerConnection = await createPeerConnection(configuration);

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      print('[Flutter] 생성된 ICE 후보: ${candidate.candidate}');
      // 시그널링 서버를 통해 ICE 후보 전송
      if (_selectedUser != null) {
        // _selectedUser가 null이 아닌지 확인
        _socket!.emit('ice-candidate', {
          'target': _selectedUser,
          'candidate': candidate.toMap(),
        });
      } else {
        print('[Flutter] 경고: ICE 후보 전송 대상(_selectedUser)이 없습니다.');
      }
    };

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      print('[Flutter] 원격 트랙 수신됨: ${event.track.kind}');
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        print(
          '[Flutter] 원격 비디오 트랙을 렌더러에 연결합니다. 스트림 ID: ${event.streams[0].id}',
        );
        setState(() {
          // 수신된 트랙이 포함된 스트림을 원격 렌더러에 연결
          _remoteRenderer.srcObject = event.streams[0];
        });
      }
      // 오디오 트랙 처리도 필요하다면 여기에 추가
      // if (event.track.kind == 'audio') { ... }
    };

    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      print('[Flutter] 피어 연결 상태 변경: $state');
      // 연결 상태에 따른 추가 처리 (예: 연결 끊김 시 UI 업데이트)
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        // 연결이 끊어졌을 때 로컬에서 통화 종료 처리 (상대방이 종료하지 않은 경우 대비)
        if (_isConnected) {
          print('[Flutter] 피어 연결 끊김 감지. 로컬에서 통화 종료 처리.');
          _endCallLocally(); // 내부 상태 정리 함수 호출
        }
      } else if (state ==
          RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        print('[Flutter] 피어 연결 성공!');
        // 연결 성공 시 UI 상태 업데이트 (이미 _isConnected로 관리 중)
      }
    };

    // 로컬 스트림의 각 트랙을 PeerConnection에 추가
    _localStream?.getTracks().forEach((track) {
      print('[Flutter] 로컬 트랙 추가 시도: ${track.kind}');
      _peerConnection!.addTrack(track, _localStream!).catchError((e) {
        print('[Flutter] 로컬 트랙 추가 실패: $e');
      });
    });
  }

  // 통화 종료 로직 분리 (내부 상태 정리용)
  void _endCallLocally() {
    if (!_isConnected && _peerConnection == null) return; // 이미 종료되었거나 시작 전이면 무시

    print('[Flutter] 로컬 통화 종료 처리 시작');
    _localStream?.getTracks().forEach((track) {
      print('[Flutter] 로컬 트랙 중지: ${track.kind}');
      track.stop();
    });
    _peerConnection?.close(); // PeerConnection 닫기

    if (mounted) {
      setState(() {
        _localStream = null;
        _peerConnection = null;
        _localRenderer.srcObject = null;
        _remoteRenderer.srcObject = null;
        _isConnected = false;
        _incomingCall = false; // 수신 중 상태도 초기화
        _selectedUser = null;
        _caller = null; // 발신자 정보 초기화
        _offer = null; // 오퍼 정보 초기화
        print('[Flutter] 로컬 통화 상태 초기화 완료');
      });
    }
  }

  // 사용자가 통화 종료 버튼을 눌렀을 때 호출되는 함수
  void _endCallButtonPressed() {
    print('[Flutter] 통화 종료 버튼 누름');
    if (_selectedUser != null) {
      print('[Flutter] 상대방($_selectedUser)에게 통화 종료 이벤트 전송');
      _socket!.emit('endCall', {'target': _selectedUser});
    } else if (_caller != null) {
      // 수신자 입장에서 종료 시 _caller에게 전송
      print('[Flutter] 상대방($_caller)에게 통화 종료 이벤트 전송');
      _socket!.emit('endCall', {'target': _caller});
    }
    _endCallLocally(); // 로컬 상태 정리
  }

  // 서버로부터 통화 종료 이벤트를 받았을 때
  void _handleCallEnded() {
    print('[Flutter] 서버로부터 통화 종료 이벤트 수신');
    if (mounted) {
      _showInfoSnackBar('상대방이 영상통화를 종료했습니다.');
      _endCallLocally(); // 로컬 상태 정리
    }
  }

  // 통화 시작 (발신자)
  void _startCall() async {
    if (_selectedUser == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('통화할 사용자를 선택해주세요')));
      return;
    }

    print('[Flutter] 통화 시작: 대상 - $_selectedUser');
    await _getUserMedia();
    await _createPeerConnection();

    // 오퍼 생성
    final offer = await _peerConnection!.createOffer();
    print('[Flutter] 오퍼 생성됨');
    await _peerConnection!.setLocalDescription(offer);
    print('[Flutter] 로컬 설명 설정됨 (오퍼)');

    // 시그널링 서버를 통해 오퍼 전송
    _socket!.emit('call', {'target': _selectedUser, 'offer': offer.toMap()});
    print('[Flutter] 오퍼 전송됨');

    setState(() {
      _isConnected = true;
    });
  }

  // 통화 응답 (수신자)
  void _answerCall() async {
    if (_caller == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('통화할 사용자를 선택해주세요')));
      return;
    }

    print('[Flutter] 통화 응답 시작: 발신자 - $_caller');
    await _getUserMedia();
    await _createPeerConnection();

    // 수신한 오퍼 설정
    print('[Flutter] 수신된 오퍼 설정 시도');
    await _peerConnection!.setRemoteDescription(_offer!);
    print('[Flutter] 원격 설명 설정됨 (오퍼)');

    // 응답 생성
    final answer = await _peerConnection!.createAnswer();
    print('[Flutter] 응답 생성됨');
    await _peerConnection!.setLocalDescription(answer);
    print('[Flutter] 로컬 설명 설정됨 (응답)');

    // 시그널링 서버를 통해 응답 전송
    _socket!.emit('answer', {'target': _caller, 'answer': answer.toMap()});
    print('[Flutter] 응답 전송됨');

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

  // 상태 초기화 함수 추가 (연결 끊김 또는 실패 시 호출)
  void _resetState() {
    if (mounted) {
      setState(() {
        _localStream?.getTracks().forEach((track) => track.stop());
        _peerConnection?.close();
        _localStream = null;
        _peerConnection = null;
        _localRenderer.srcObject = null;
        _remoteRenderer.srcObject = null;
        _isConnected = false;
        _incomingCall = false;
        _selectedUser = null;
        _caller = null;
        _offer = null;
        _userId = null; // 사용자 ID도 초기화
        _users = [];
        // _socket?.disconnect(); // 필요에 따라 소켓 연결 해제
      });
    }
  }

  // 오류 메시지 표시 함수 추가 (옵션)
  void _showErrorSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.red),
      );
    }
  }

  // 정보 메시지 표시 함수 추가 (옵션)
  void _showInfoSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), backgroundColor: Colors.blue),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebRTC 화상통화'),
        actions: [
          // 서버 연결 상태 표시 (옵션)
          Padding(
            padding: const EdgeInsets.only(right: 10.0),
            child: Center(
              child: Text(
                _socket?.connected ?? false ? '연결됨' : '연결안됨',
                style: TextStyle(
                  color:
                      _socket?.connected ?? false ? Colors.green : Colors.red,
                ),
              ),
            ),
          ),
          // 네트워크 테스트 버튼 추가
          IconButton(
            icon: Icon(Icons.network_check),
            onPressed: () async {
              // 서버 URL 테스트
              final testUrl =
                  'http://YOUR_LAPTOP_IP_ADDRESS:5000/test'; // <--- 여기도 수정
              try {
                final response = await http
                    .get(Uri.parse(testUrl))
                    .timeout(Duration(seconds: 5));
                if (response.statusCode == 200) {
                  _showInfoSnackBar('서버 연결 테스트 성공!');
                } else {
                  _showErrorSnackBar('서버 응답 오류: ${response.statusCode}');
                }
              } catch (e) {
                _showErrorSnackBar('서버($testUrl) 연결 테스트 실패: $e');
              }
            },
          ),
        ],
      ),
      body: _buildBody(), // 상태에 따라 다른 UI 표시
      floatingActionButton: _buildFloatingActionButton(), // 상태에 따라 다른 FAB 표시
    );
  }

  // 상태에 따라 다른 본문 UI를 반환하는 메서드
  Widget _buildBody() {
    if (_isConnected) {
      // 통화 중 화면
      return _buildCallView();
    } else if (_incomingCall) {
      // 전화 수신 화면
      return _buildIncomingCallView();
    } else {
      // 대기 화면 (사용자 선택)
      return _buildIdleView();
    }
  }

  // 대기 화면 UI 수정 (userId 표시 및 사용자 선택 추가)
  Widget _buildIdleView() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // userId가 null이면 "연결 중..." 표시
          Text('내 ID: ${_userId ?? "연결 중..."}'),
          const SizedBox(height: 20),

          // --- 사용자 선택 드롭다운 추가 ---
          if (_socket?.connected == true) // 서버에 연결된 경우에만 표시
            if (_users.isEmpty)
              const Text('다른 사용자가 없습니다.') // 다른 사용자가 없을 때
            else
              DropdownButton<String>(
                hint: const Text('통화할 사용자 선택'), // 기본 안내 문구
                value: _selectedUser, // 현재 선택된 사용자
                items:
                    _users
                        .map(
                          (user) => DropdownMenuItem(
                            // 사용자 목록으로 메뉴 아이템 생성
                            value: user,
                            child: Text(user),
                          ),
                        )
                        .toList(),
                onChanged: (value) {
                  // 사용자를 선택했을 때
                  setState(() {
                    _selectedUser = value; // 선택된 사용자 업데이트
                  });
                },
                isExpanded: true, // 드롭다운 너비 확장
              )
          else
            const Text('서버에 연결 중이거나 연결할 수 없습니다.'), // 서버 연결 안 된 경우
          // --- 사용자 선택 드롭다운 끝 ---
          const SizedBox(height: 20),
          // 로컬 비디오 미리보기 (옵션) - 필요하면 주석 해제
          // Text('내 카메라 미리보기:'),
          // Container(
          //   width: 150,
          //   height: 200,
          //   decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
          //   child: _localRenderer.textureId != null
          //       ? RTCVideoView(_localRenderer, mirror: true)
          //       : Center(child: Text('카메라 준비 중...')),
          // ),
        ],
      ),
    );
  }

  // 얼굴 위에 너구리 마스크를 그리는 CustomPainter
  Widget _buildVideoWithFaceBlurring(RTCVideoRenderer renderer) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 기본 비디오 피드
        RTCVideoView(renderer, mirror: renderer == _localRenderer),
      ],
    );
  }

  // 상태에 따라 다른 플로팅 액션 버튼을 반환하는 메서드
  Widget? _buildFloatingActionButton() {
    if (_isConnected) {
      // 통화 중일 때: 통화 종료 버튼
      return FloatingActionButton(
        onPressed: _endCallButtonPressed, // 수정된 함수 호출
        tooltip: '통화 종료',
        backgroundColor: Colors.red,
        child: const Icon(Icons.call_end),
      );
    } else if (!_incomingCall && _selectedUser != null) {
      // 대기 중이고 사용자가 선택되었을 때: 통화 시작 버튼
      return FloatingActionButton(
        onPressed: _startCall, // _startCall 메서드 호출
        tooltip: '영상통화 시작',
        backgroundColor: Colors.green,
        child: const Icon(Icons.video_call),
      );
    }
    return null; // 그 외의 경우 FAB 없음
  }

  // 통화 중 화면 UI
  Widget _buildCallView() {
    return Stack(
      children: [
        // 큰 화면: 상대방 영상
        Positioned.fill(
          child: RTCVideoView(
            _remoteRenderer,
            objectFit:
                RTCVideoViewObjectFit.RTCVideoViewObjectFitCover, // 화면 채우기
          ),
        ),
        // 작은 화면: 내 영상 (오버레이)
        Positioned(
          right: 20.0,
          bottom: 20.0,
          child: SizedBox(
            width: 100, // 작은 화면 크기
            height: 150,
            child: RTCVideoView(
              _localRenderer,
              mirror: true, // 내 화면은 거울 모드
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
          ),
        ),
      ],
    );
  }

  // 전화 수신 화면 UI
  Widget _buildIncomingCallView() {
    return Center(
      child: Card(
        margin: const EdgeInsets.all(20),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_caller ?? "알 수 없음"}님으로부터 영상통화 요청',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    onPressed: _rejectCall, // _rejectCall 메서드 호출
                    icon: const Icon(Icons.call_end),
                    label: const Text('거절'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: _answerCall, // _answerCall 메서드 호출
                    icon: const Icon(Icons.call),
                    label: const Text('수락'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 얼굴 위에 너구리 마스크를 그리는 CustomPainter
class FaceMaskPainter extends CustomPainter {
  final List<Face> faces;
  final Size imageSize;
  final MaskType maskType;
  final ui.Image? raccoonImage;

  FaceMaskPainter({
    required this.faces,
    required this.imageSize,
    required this.maskType,
    this.raccoonImage,
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
      } else if (maskType == MaskType.animal && raccoonImage != null) {
        // 너구리 이미지를 얼굴에 맞게 그리기
        try {
          // 얼굴 각도 계산 (눈 위치 기반)
          double rotation = 0.0;
          if (face.landmarks[FaceLandmarkType.leftEye] != null &&
              face.landmarks[FaceLandmarkType.rightEye] != null) {
            final leftEye = face.landmarks[FaceLandmarkType.leftEye]!;
            final rightEye = face.landmarks[FaceLandmarkType.rightEye]!;

            final dx = rightEye.position.x - leftEye.position.x;
            final dy = rightEye.position.y - leftEye.position.y;
            rotation = -1 * Math.atan2(dy, dx);
          }

          // 얼굴 크기에 맞게 이미지 크기 조정 (좀 더 크게)
          final maskWidth = faceRect.width * 1.4;
          final maskHeight = faceRect.height * 1.4;

          // 이미지 그리기 준비
          final centerX = faceRect.left + faceRect.width / 2;
          final centerY = faceRect.top + faceRect.height / 2;

          // 회전 처리를 위한 캔버스 상태 저장
          canvas.save();

          // 얼굴 중심으로 회전
          canvas.translate(centerX, centerY);
          canvas.rotate(rotation);

          // 너구리 이미지 그리기
          canvas.drawImageRect(
            raccoonImage!,
            Rect.fromLTWH(
              0,
              0,
              raccoonImage!.width.toDouble(),
              raccoonImage!.height.toDouble(),
            ),
            Rect.fromLTWH(
              -maskWidth / 2,
              -maskHeight / 2,
              maskWidth,
              maskHeight,
            ),
            Paint(),
          );

          // 캔버스 상태 복원
          canvas.restore();
        } catch (e) {
          print('이미지 그리기 오류: $e');
        }
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
  bool shouldRepaint(FaceMaskPainter oldDelegate) =>
      oldDelegate.faces != faces ||
      oldDelegate.maskType != maskType ||
      oldDelegate.raccoonImage != raccoonImage;
}

enum MaskType { mosaic, animal }
