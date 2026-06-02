import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/websocket_service.dart';

// Top-level function required by compute() — runs in background isolate
Uint8List _convertYuvToJpegInIsolate(Map<String, dynamic> params) {
  try {
    final int width = params['width'] as int;
    final int height = params['height'] as int;
    final Uint8List yBytes = params['yBytes'] as Uint8List;
    final Uint8List uBytes = params['uBytes'] as Uint8List;
    final Uint8List vBytes = params['vBytes'] as Uint8List;
    final int yBytesPerRow = params['yBytesPerRow'] as int;
    final int uvBytesPerRow = params['uvBytesPerRow'] as int;
    final int uvPixelStride = params['uvPixelStride'] as int;

    final imgLib = img.Image(width: width, height: height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int yIndex = y * yBytesPerRow + x;
        final int uvIndex = (y >> 1) * uvBytesPerRow + (x >> 1) * uvPixelStride;

        if (yIndex >= yBytes.length ||
            uvIndex >= uBytes.length ||
            uvIndex >= vBytes.length) continue;

        final int yVal = yBytes[yIndex] & 0xFF;
        final int uVal = uBytes[uvIndex] & 0xFF;
        final int vVal = vBytes[uvIndex] & 0xFF;

        final int r = (yVal + 1.402 * (vVal - 128)).round().clamp(0, 255);
        final int g = (yVal - 0.344136 * (uVal - 128) - 0.714136 * (vVal - 128))
            .round()
            .clamp(0, 255);
        final int b = (yVal + 1.772 * (uVal - 128)).round().clamp(0, 255);

        imgLib.setPixelRgb(x, y, r, g, b);
      }
    }

    return Uint8List.fromList(img.encodeJpg(imgLib, quality: 55));
  } catch (_) {
    return Uint8List(0);
  }
}

class HomeScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const HomeScreen({super.key, required this.cameras});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  CameraController? _camCtrl;
  bool _isInitializingCamera = false;
  bool _isCamReady = false;
  bool _camPermitted = false;

  final WebSocketService _ws = WebSocketService();
  WsState _wsState = WsState.disconnected;
  String _wsStatusText = 'Disconnected';
  Color _wsStatusColor = Colors.red;

  int _framesSent = 0;
  bool _isStreaming = false;
  DateTime? _lastFrameTime;
  bool _isSendingFrame = false;

  bool _isProcessing = false;
  Timer? _resetTimer;

  final Map<String, String> _lastAction = {};
  String _lastServerMsg = '';

  Timer? _clockTimer;
  String _currentTime = '';
  String _currentDate = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Lock to landscape for camera/attendance kiosk use
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _startClock();
    _initWebSocket();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _clockTimer?.cancel();
    _resetTimer?.cancel();
    _camCtrl?.dispose();
    _ws.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_isCamReady) _initCamera();
      if (_isCamReady && _wsState == WsState.connected && !_isProcessing) {
        _startStreaming();
      }
    } else if (state == AppLifecycleState.paused) {
      _stopStreaming();
    }
  }

  // ── Clock ──────────────────────────────────────────────────────────────────
  void _startClock() {
    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
  }

  void _updateClock() {
    final now = DateTime.now();
    if (mounted) {
      setState(() {
        _currentTime = DateFormat('hh:mm:ss a').format(now);
        _currentDate = DateFormat('EEEE, dd MMMM yyyy').format(now);
      });
    }
  }

  String _nextActionFor(String employeeName) {
    final key = employeeName.toLowerCase().trim();
    final last = _lastAction[key];
    if (last == null || last == 'checkout') return 'checkin';
    return 'checkout';
  }

  // ── Camera ─────────────────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    if (_isInitializingCamera) return;
    _isInitializingCamera = true;

    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) { setState(() => _camPermitted = false); }
      _isInitializingCamera = false;
      return;
    }
    if (mounted) setState(() => _camPermitted = true);
    if (widget.cameras.isEmpty) return;

    CameraDescription cam = widget.cameras.first;
    for (final c in widget.cameras) {
      if (c.lensDirection == CameraLensDirection.front) {
        cam = c;
        break;
      }
    }

    final newController = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await newController.initialize();
      if (!mounted) {
        await newController.dispose();
        return;
      }

      final old = _camCtrl;
      if (old != null) {
        try {
          await old.dispose();
        } catch (_) {}
      }
      _camCtrl = newController;

      if (mounted) {
        setState(() => _isCamReady = true);
        if (_wsState == WsState.connected) _startStreaming();
      }
    } on CameraException catch (e) {
      debugPrint('Camera error: ${e.code} — ${e.description}');
      try {
        await newController.dispose();
      } catch (_) {}
    } finally {
      _isInitializingCamera = false;
    }
  }

  // ── WebSocket ──────────────────────────────────────────────────────────────
  void _initWebSocket() {
    _ws.onStateChange = (state) {
      if (!mounted) return;
      setState(() {
        _wsState = state;
        switch (state) {
          case WsState.connecting:
            _wsStatusText = 'Connecting...';
            _wsStatusColor = Colors.amber;
            break;
          case WsState.connected:
            _wsStatusText = 'Connected';
            _wsStatusColor = Colors.greenAccent;
            if (_isCamReady && !_isProcessing) _startStreaming();
            break;
          case WsState.disconnected:
            _wsStatusText = 'Disconnected';
            _wsStatusColor = Colors.red;
            _stopStreaming();
            break;
          case WsState.error:
            _wsStatusText = 'Reconnecting...';
            _wsStatusColor = Colors.orange;
            _stopStreaming();
            break;
        }
      });
    };

    _ws.onMessage = (dynamic msg) {
      debugPrint('SERVER RAW: $msg');
      if (msg is! String) return;
      if (mounted) setState(() => _lastServerMsg = msg);

      Map<String, dynamic> data;
      try {
        data = jsonDecode(msg) as Map<String, dynamic>;
      } catch (_) {
        debugPrint('Non-JSON: $msg');
        return;
      }

      final String employeeName = (data['full_name'] ??
          data['name'] ??
          data['employee'] ??
          data['employee_name'] ??
          data['user'] ??
          '')
          .toString()
          .trim();

      final String status = (data['action'] ??
          data['status'] ??
          data['event'] ??
          data['result'] ??
          '')
          .toString()
          .toLowerCase()
          .trim();

      debugPrint('Parsed — name: "$employeeName"  status: "$status"');

      final bool isNoFace = status.contains('no_face') ||
          status.contains('unknown') ||
          status.contains('not_found') ||
          status.contains('unrecognized') ||
          status.isEmpty;

      if (isNoFace && employeeName.isEmpty) {
        debugPrint('👤 No face / unknown — continuing stream');
        return;
      }

      final bool isRecognized = status.contains('checkin') ||
          status.contains('checkout') ||
          status.contains('checked_in') ||
          status.contains('checked_out') ||
          status.contains('recogni') ||
          status.contains('success') ||
          status.contains('identif') ||
          status.contains('match') ||
          employeeName.isNotEmpty;

      if (isRecognized) {
        debugPrint('🎯 Face recognized → "$employeeName"  action: "$status"');
        final String serverAction = status.contains('checked_out') || status.contains('checkout')
            ? 'checkout'
            : 'checkin';
        _onFaceRecognized(
          employeeName.isNotEmpty ? employeeName : 'Employee',
          serverAction: serverAction,
        );
      }
    };

    _ws.onError = (err) => debugPrint('WS error: $err');
    _ws.connect();
  }

  // ── Frame Streaming (compute isolate — no UI lag) ──────────────────────────
  void _startStreaming() {
    if (_isStreaming) return;
    if (!_isCamReady || _camCtrl == null) return;
    if (_wsState != WsState.connected) return;
    if (_isProcessing) return;

    debugPrint('📹 STREAM: Starting');
    setState(() {
      _isStreaming = true;
      _framesSent = 0;
    });
    _lastFrameTime = null;
    _isSendingFrame = false;
    _camCtrl!.startImageStream(_onCameraFrame);
  }

  Future<void> _stopStreaming() async {
    if (!_isStreaming) return;
    debugPrint('🛑 STREAM: Stopping');
    if (mounted) setState(() => _isStreaming = false);
    try {
      if (_camCtrl != null && _camCtrl!.value.isStreamingImages) {
        await _camCtrl!.stopImageStream();
      }
    } catch (_) {}
  }

  void _onCameraFrame(CameraImage image) {
    if (_isProcessing || _wsState != WsState.connected) return;
    if (_isSendingFrame) return;

    final now = DateTime.now();
    if (_lastFrameTime != null &&
        now.difference(_lastFrameTime!).inMilliseconds < 250) {
      return;
    }
    _lastFrameTime = now;
    _isSendingFrame = true;

    // Extract raw bytes before handing off — CameraImage can't cross isolate
    final params = <String, dynamic>{
      'width': image.width,
      'height': image.height,
      'yBytes': Uint8List.fromList(image.planes[0].bytes),
      'uBytes': Uint8List.fromList(image.planes[1].bytes),
      'vBytes': Uint8List.fromList(image.planes[2].bytes),
      'yBytesPerRow': image.planes[0].bytesPerRow,
      'uvBytesPerRow': image.planes[1].bytesPerRow,
      'uvPixelStride': image.planes[1].bytesPerPixel ?? 1,
    };

    compute(_convertYuvToJpegInIsolate, params).then((jpeg) {
      if (jpeg.isNotEmpty) {
        debugPrint('📤 Frame ${_framesSent + 1} — ${jpeg.length} bytes');
        final sent = _ws.sendBinaryFrame(jpeg);
        if (sent && mounted) setState(() => _framesSent++);
      }
    }).catchError((e) {
      debugPrint('❌ Frame error: $e');
    }).whenComplete(() => _isSendingFrame = false);
  }

  // ── Attendance ─────────────────────────────────────────────────────────────
  Future<void> _onFaceRecognized(String employeeName, {String? serverAction}) async {
    if (_isProcessing) return;
    if (!_isCamReady || _camCtrl == null) return;

    setState(() => _isProcessing = true);
    await _stopStreaming();
    await Future.delayed(const Duration(milliseconds: 300));

    final action = serverAction ?? _nextActionFor(employeeName);
    final isCheckIn = action == 'checkin' || action == 'checked_in';
    final label = isCheckIn ? 'Check-In' : 'Check-Out';
    final Color snackColor =
    isCheckIn ? const Color(0xFF00C853) : const Color(0xFFFF6D00);

    debugPrint('🧾 ATTENDANCE: $employeeName → $action');

    try {
      final XFile photo = await _camCtrl!.takePicture();
      final now = DateTime.now();
      final timeStr = DateFormat('hh:mm a').format(now);
      final dateStr = DateFormat('dd MMM yyyy').format(now);

      final dir = await getApplicationDocumentsDirectory();
      final fileName = '${action}_${now.millisecondsSinceEpoch}.jpg';
      final savedPath = p.join(dir.path, fileName);
      await File(photo.path).copy(savedPath);
      await File(photo.path).delete();
      debugPrint('📸 Photo saved → $savedPath');

      _lastAction[employeeName.toLowerCase().trim()] = action;

      _ws.sendText(jsonEncode({
        'event': action,
        'employee': employeeName,
        'timestamp': now.toIso8601String(),
      }));

      _showSnack(
        icon: isCheckIn ? '✅' : '👋',
        title: '$label Recorded',
        subtitle: '$employeeName — $timeStr, $dateStr',
        color: snackColor,
      );

      _resetTimer?.cancel();
      _resetTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) {
          setState(() => _isProcessing = false);
          if (_wsState == WsState.connected) _startStreaming();
        }
      });
    } catch (e) {
      debugPrint('❌ Attendance error: $e');
      _showSnack(
        icon: '❌',
        title: 'Error',
        subtitle: 'Could not record: $e',
        color: Colors.red,
      );
      setState(() => _isProcessing = false);
      if (_wsState == WsState.connected) _startStreaming();
    }
  }

  void _showSnack({
    required String icon,
    required String title,
    required String subtitle,
    required Color color,
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.all(12),
        content: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF0D1B3E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha:0.6), width: 1.5),
            boxShadow: [
              BoxShadow(color: color.withValues(alpha:0.25), blurRadius: 20)
            ],
          ),
          child: Row(children: [
            Text(icon, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: color,
                          fontSize: 14,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080F22),
      body: SafeArea(
        child: Row(children: [
          // Left: Camera preview (wider)
          Expanded(
            flex: 3,
            child: _buildCameraArea(),
          ),
          // Right: Info panel
          Container(
            width: 260,
            decoration: const BoxDecoration(
              color: Color(0xFF0D1B3E),
              border: Border(left: BorderSide(color: Color(0xFF1A2E5A), width: 1)),
            ),
            child: Column(children: [
              _buildTopBar(),
              _buildStatusBar(),
              Expanded(child: _buildSidePanel()),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF1A2E5A), width: 1)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('MONTEAGE',
            style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 4)),
        const SizedBox(height: 4),
        Text(_currentDate,
            style: TextStyle(
                color: Colors.white.withValues(alpha:0.4),
                fontSize: 9,
                letterSpacing: 0.8)),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0xFF1565C0).withValues(alpha:0.2),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: const Color(0xFF1E88E5).withValues(alpha:0.4), width: 1),
          ),
          child: Text(_currentTime,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Color(0xFF42A5F5),
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace')),
        ),
      ]),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF0A1428),
        border: Border(bottom: BorderSide(color: Color(0xFF1A2E5A), width: 1)),
      ),
      child: Row(children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _wsStatusColor,
            boxShadow: [
              BoxShadow(color: _wsStatusColor.withValues(alpha:0.6), blurRadius: 6)
            ],
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(_wsStatusText,
              style: TextStyle(
                  color: _wsStatusColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w500)),
        ),
        if (_wsState == WsState.disconnected || _wsState == WsState.error)
          GestureDetector(
            onTap: _ws.connect,
            child: const Text('Retry ↺',
                style: TextStyle(
                    color: Color(0xFF42A5F5),
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }

  Widget _buildSidePanel() {
    const Color modeColor = Color(0xFF42A5F5);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Mode card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: modeColor.withValues(alpha:0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: modeColor.withValues(alpha:0.35), width: 1),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.face_retouching_natural, color: modeColor, size: 20),
                const SizedBox(width: 8),
                const Text('Attendance',
                    style: TextStyle(
                        color: modeColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.greenAccent.withValues(alpha:0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: Colors.greenAccent.withValues(alpha:0.35), width: 1),
                  ),
                  child: const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.face_retouching_natural,
                        color: Colors.greenAccent, size: 11),
                    SizedBox(width: 3),
                    Text('Auto',
                        style: TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 9,
                            fontWeight: FontWeight.w700)),
                  ]),
                ),
              ]),
              const SizedBox(height: 8),
              const Text(
                'First scan = Check-In\nSecond scan = Check-Out',
                style: TextStyle(color: Colors.white38, fontSize: 10, height: 1.5),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          // Frames counter
          Row(children: [
            const Icon(Icons.send_rounded, color: Colors.white24, size: 13),
            const SizedBox(width: 6),
            Text('Frames sent: $_framesSent',
                style: const TextStyle(color: Colors.white24, fontSize: 10)),
          ]),
          const Spacer(),
          // Status message
          if (_isProcessing)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha:0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.withValues(alpha:0.4), width: 1),
              ),
              child: const Row(children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(color: Colors.amber, strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Recording attendance...',
                      style: TextStyle(color: Colors.amber, fontSize: 11)),
                ),
              ]),
            )
          else
            Text(
              'Attendance recorded automatically via face recognition',
              style: TextStyle(
                  color: Colors.white.withValues(alpha:0.25),
                  fontSize: 10,
                  height: 1.5),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildCameraArea() {
    if (!_camPermitted) return _buildPermissionView();
    if (!_isCamReady || _camCtrl == null) return _buildLoadingView();

    final Color ovalColor = _isProcessing
        ? Colors.amber
        : (_isStreaming ? Colors.greenAccent : Colors.white38);

    return Stack(fit: StackFit.expand, children: [
      CameraPreview(_camCtrl!),

      // Top gradient
      Positioned(
        top: 0, left: 0, right: 0, height: 80,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withValues(alpha:0.5), Colors.transparent],
            ),
          ),
        ),
      ),

      // Bottom gradient
      Positioned(
        bottom: 0, left: 0, right: 0, height: 70,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black.withValues(alpha:0.4), Colors.transparent],
            ),
          ),
        ),
      ),

      // Face oval guide
      Center(
        child: Container(
          width: 200,
          height: 250,
          decoration: BoxDecoration(
            border: Border.all(color: ovalColor, width: 2.5),
            borderRadius: BorderRadius.circular(130),
          ),
        ),
      ),

      // Streaming glow ring
      if (_isStreaming && !_isProcessing)
        Center(
          child: Container(
            width: 212,
            height: 262,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(138),
              border: Border.all(
                  color: Colors.greenAccent.withValues(alpha:0.2), width: 7),
            ),
          ),
        ),

      // Processing ring + spinner
      if (_isProcessing) ...[
        Center(
          child: Container(
            width: 212,
            height: 262,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(138),
              border: Border.all(color: Colors.amber.withValues(alpha:0.45), width: 7),
            ),
          ),
        ),
        const Center(
          child: SizedBox(
            width: 48,
            height: 48,
            child: CircularProgressIndicator(color: Colors.amber, strokeWidth: 3),
          ),
        ),
      ],

      // Top hint label
      Positioned(
        top: 14, left: 12, right: 12,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha:0.6),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Text(
              _isProcessing
                  ? 'Processing — please wait...'
                  : 'Look at camera to record attendance',
              style: const TextStyle(
                  color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      ),

      // Server message overlay
      if (_lastServerMsg.isNotEmpty)
        Positioned(
          bottom: 10, left: 12, right: 12,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha:0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Server: $_lastServerMsg',
                style: TextStyle(color: Colors.white.withValues(alpha:0.5), fontSize: 9),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _buildPermissionView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.no_photography_outlined, size: 64, color: Colors.red.shade400),
          const SizedBox(height: 16),
          const Text('Camera Access Required',
              style: TextStyle(
                  color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Camera permission is required to record attendance.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha:0.55), fontSize: 12)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () async {
              await openAppSettings();
              await Future.delayed(const Duration(seconds: 1));
              _initCamera();
            },
            icon: const Icon(Icons.settings_rounded),
            label: const Text('Open Settings'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1565C0),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildLoadingView() {
    return const Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        CircularProgressIndicator(color: Color(0xFF1E88E5), strokeWidth: 2.5),
        SizedBox(height: 14),
        Text('Initializing camera...',
            style: TextStyle(color: Colors.white54, fontSize: 12)),
      ]),
    );
  }
}
