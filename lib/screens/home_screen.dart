import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/websocket_service.dart';

class HomeScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const HomeScreen({super.key, required this.cameras});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  // ── Camera ──────────────────────────────────────────────────────────────────
  CameraController? _camCtrl;
  bool _isInitializingCamera = false;
  bool _isCamReady = false;
  bool _camPermitted = false;

  // ── WebSocket ────────────────────────────────────────────────────────────────
  final WebSocketService _ws = WebSocketService();
  WsState _wsState = WsState.disconnected;
  String _wsStatusText = 'Disconnected';
  Color _wsStatusColor = Colors.red;

  // ── Frame streaming ──────────────────────────────────────────────────────────
  int _framesSent = 0;
  bool _isStreaming = false;
  DateTime? _lastFrameTime;

  // ── Attendance processing ────────────────────────────────────────────────────
  bool _isProcessing = false;
  Timer? _resetTimer;

  // ── Check-In / Check-Out toggle ──────────────────────────────────────────────
  // Tracks whether the last action was check-in or check-out PER employee.
  // Key = employeeName (lowercased), Value = 'checkin' | 'checkout'
  final Map<String, String> _lastAction = {};

  // ── Last server message (shown on screen for debug) ──────────────────────────
  String _lastServerMsg = '';

  // ── Clock ────────────────────────────────────────────────────────────────────
  Timer? _clockTimer;
  String _currentTime = '';
  String _currentDate = '';

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startClock();
    _initWebSocket();
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // CLOCK
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  void _startClock() {
    _updateClock();
    _clockTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
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

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MODE — determined by last action per employee, not by clock time
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Returns the NEXT action for this employee:
  /// - If they haven't done anything yet → 'checkin'
  /// - If last action was 'checkin'      → 'checkout'
  /// - If last action was 'checkout'     → 'checkin'  (next day / re-entry)
  String _nextActionFor(String employeeName) {
    final key = employeeName.toLowerCase().trim();
    final last = _lastAction[key];
    if (last == null || last == 'checkout') return 'checkin';
    return 'checkout';
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // CAMERA
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Future<void> _initCamera() async {
    if (_isInitializingCamera) return;
    _isInitializingCamera = true;
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) setState(() => _camPermitted = false);
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

    final CameraController newController = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await newController.initialize();

      // If widget is no longer mounted, dispose the newly initialized controller.
      if (!mounted) {
        await newController.dispose();
        return;
      }

      // Dispose the old controller (if any) and assign the new one.
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

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // WEBSOCKET
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
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
            // Resume streaming only if not in the middle of processing
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
      debugPrint('SERVER RESPONSE: $msg');

      if (msg is! String) return;

      if (mounted) setState(() => _lastServerMsg = msg);

      Map<String, dynamic> data;
      try {
        data = jsonDecode(msg) as Map<String, dynamic>;
      } catch (_) {
        debugPrint('Non-JSON message from server: $msg');
        return;
      }

      final String employeeName = (data['name'] ??
          data['employee'] ??
          data['employee_name'] ??
          data['user'] ??
          '')
          .toString()
          .trim();

      final String status = (data['status'] ??
          data['event'] ??
          data['result'] ??
          '')
          .toString()
          .toLowerCase()
          .trim();

      debugPrint('Parsed — name: "$employeeName" status: "$status"');

      // ── Ignore "no face" / "unknown" responses ─────────────────────────────
      final bool isNoFace = status.contains('no_face') ||
          status.contains('unknown') ||
          status.contains('not_found') ||
          status.contains('unrecognized');

      if (isNoFace) {
        debugPrint('👤 SERVER: No face / unknown — continuing stream');
        return;
      }

      // ── Trigger attendance if face was recognized ──────────────────────────
      final bool isRecognized = status.contains('recogni') ||
          status.contains('success') ||
          status.contains('checkin') ||
          status.contains('checkout') ||
          status.contains('identif') ||
          status.contains('match') ||
          employeeName.isNotEmpty;

      if (isRecognized) {
        debugPrint('🎯 SERVER: Face recognized → employee: "$employeeName"');
        _onFaceRecognized(employeeName.isNotEmpty ? employeeName : 'Employee');
      } else {
        debugPrint('❓ SERVER: Unhandled response — name: "$employeeName" status: "$status"');
      }
    };

    _ws.onError = (err) => debugPrint('WS error: $err');

    _ws.connect();
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // FRAME STREAMING
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  void _startStreaming() {
    if (_isStreaming) return;
    if (!_isCamReady || _camCtrl == null) return;
    if (_wsState != WsState.connected) return;
    if (_isProcessing) return;

    debugPrint('📹 STREAM: Starting image stream');
    setState(() {
      _isStreaming = true;
      _framesSent = 0;
    });
    _lastFrameTime = null;
    _camCtrl!.startImageStream(_onCameraFrame);
  }

  Future<void> _stopStreaming() async {
    if (!_isStreaming) return;
    debugPrint('🛑 STREAM: Stopping image stream');
    if (mounted) setState(() => _isStreaming = false);
    try {
      if (_camCtrl != null && _camCtrl!.value.isStreamingImages) {
        await _camCtrl!.stopImageStream();
      }
    } catch (_) {}
  }

  void _onCameraFrame(CameraImage image) {
    if (_isProcessing || _wsState != WsState.connected) return;

    final now = DateTime.now();
    if (_lastFrameTime != null &&
        now.difference(_lastFrameTime!).inMilliseconds < 200) {
      return;
    }
    _lastFrameTime = now;

    if (image.format.group != ImageFormatGroup.jpeg) {
      debugPrint('⚠️ STREAM: Non-JPEG frame format: ${image.format.group} — skipping');
      return;
    }
    final bytes = Uint8List.fromList(image.planes[0].bytes);
    debugPrint('📤 STREAM: Sending frame ${_framesSent + 1} — ${bytes.length} bytes');
    final sent = _ws.sendBinaryFrame(bytes);
    if (sent && mounted) setState(() => _framesSent++);
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // ATTENDANCE — toggle checkin ↔ checkout per employee
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Future<void> _onFaceRecognized(String employeeName) async {
    if (_isProcessing) return;
    if (!_isCamReady || _camCtrl == null) return;

    setState(() => _isProcessing = true);
    await _stopStreaming();

    // ── Decide action: first time → checkin, then toggle ──────────────────────
    final action = _nextActionFor(employeeName);
    final isCheckIn = action == 'checkin';
    final label = isCheckIn ? 'Check-In' : 'Check-Out';
    final Color snackColor =
    isCheckIn ? const Color(0xFF00C853) : const Color(0xFFFF6D00);

    debugPrint('🧾 ATTENDANCE: $employeeName → $action');

    try {
      final XFile photo = await _camCtrl!.takePicture();
      final now = DateTime.now();
      final timeStr = DateFormat('hh:mm a').format(now);
      final dateStr = DateFormat('dd MMM yyyy').format(now);

      // Save photo locally
      final dir = await getApplicationDocumentsDirectory();
      final fileName = '${action}_${now.millisecondsSinceEpoch}.jpg';
      final savedPath = p.join(dir.path, fileName);
      await File(photo.path).copy(savedPath);
      await File(photo.path).delete();
      debugPrint('📸 ATTENDANCE: Photo saved → $savedPath');

      // ── Mark this action for the employee so next scan toggles ──────────────
      _lastAction[employeeName.toLowerCase().trim()] = action;

      // Notify server
      _ws.sendText(jsonEncode({
        'event': action,
        'employee': employeeName,
        'timestamp': now.toIso8601String(),
      }));
      debugPrint('📡 ATTENDANCE: Notified server — $action for $employeeName at ${now.toIso8601String()}');

      _showSnack(
        icon: isCheckIn ? '✅' : '👋',
        title: '$label Recorded',
        subtitle: '$employeeName — $timeStr, $dateStr',
        color: snackColor,
      );
      debugPrint('✅ ATTENDANCE: Snackbar shown for $employeeName ($label)');

      // Wait 2.5 s → resume for next employee
      _resetTimer?.cancel();
      _resetTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) {
          setState(() => _isProcessing = false);
          debugPrint('▶️ ATTENDANCE: Processing done — resuming stream');
          // Only restart streaming if WS is still connected
          if (_wsState == WsState.connected) _startStreaming();
        }
      });
    } catch (e) {
      debugPrint('❌ ATTENDANCE ERROR: $e');
      _showSnack(
        icon: '❌',
        title: 'Error',
        subtitle: 'Could not record attendance: $e',
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
            border: Border.all(color: color.withOpacity(0.6), width: 1.5),
            boxShadow: [
              BoxShadow(color: color.withOpacity(0.25), blurRadius: 20)
            ],
          ),
          child: Row(
            children: [
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
            ],
          ),
        ),
      ),
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // BUILD
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080F22),
      body: SafeArea(
        child: Column(children: [
          _buildTopBar(),
          _buildStatusBar(),
          Expanded(child: _buildCameraArea()),
          _buildBottomPanel(),
        ]),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1B3E),
        border:
        Border(bottom: BorderSide(color: Color(0xFF1A2E5A), width: 1)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('MONTEAGE',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 4)),
            Text(_currentDate,
                style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 10,
                    letterSpacing: 1)),
          ]),
          Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1565C0).withOpacity(0.2),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                  color: const Color(0xFF1E88E5).withOpacity(0.4), width: 1),
            ),
            child: Text(_currentTime,
                style: const TextStyle(
                    color: Color(0xFF42A5F5),
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: const Color(0xFF0A1428),
      child: Row(children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _wsStatusColor,
            boxShadow: [
              BoxShadow(
                  color: _wsStatusColor.withOpacity(0.6), blurRadius: 6)
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text('Server: $_wsStatusText',
            style: TextStyle(
                color: _wsStatusColor,
                fontSize: 11,
                fontWeight: FontWeight.w500)),
        const Spacer(),
      
        if (!_isStreaming && _wsState == WsState.disconnected)
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
        top: 0,
        left: 0,
        right: 0,
        height: 90,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.55),
                Colors.transparent
              ],
            ),
          ),
        ),
      ),

      // Bottom gradient
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        height: 80,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withOpacity(0.45),
                Colors.transparent
              ],
            ),
          ),
        ),
      ),

      // Oval guide
      Center(
        child: Container(
          width: 230,
          height: 290,
          decoration: BoxDecoration(
            border: Border.all(color: ovalColor, width: 2.5),
            borderRadius: BorderRadius.circular(150),
          ),
        ),
      ),

      // Pulse ring (streaming)
      if (_isStreaming && !_isProcessing)
        Center(
          child: Container(
            width: 240,
            height: 300,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(156),
              border: Border.all(
                  color: Colors.greenAccent.withOpacity(0.2), width: 7),
            ),
          ),
        ),

      // Processing ring + spinner
      if (_isProcessing) ...[
        Center(
          child: Container(
            width: 240,
            height: 300,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(156),
              border: Border.all(
                  color: Colors.amber.withOpacity(0.45), width: 7),
            ),
          ),
        ),
        const Center(
          child: SizedBox(
            width: 52,
            height: 52,
            child: CircularProgressIndicator(
                color: Colors.amber, strokeWidth: 3),
          ),
        ),
      ],

      // Instruction label
      Positioned(
        top: 18,
        left: 16,
        right: 16,
        child: Center(
          child: Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.65),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _isProcessing
                  ? 'Processing — please wait...'
                  : '📸  Look at camera to record attendance',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500),
            ),
          ),
        ),
      ),

      // Debug: last server message
      if (_lastServerMsg.isNotEmpty)
        Positioned(
          bottom: 12,
          left: 16,
          right: 16,
          child: Center(
            child: Container(
              padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Server: $_lastServerMsg',
                style: TextStyle(
                    color: Colors.white.withOpacity(0.55), fontSize: 10),
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
        child:
        Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.no_photography_outlined,
              size: 72, color: Colors.red.shade400),
          const SizedBox(height: 20),
          const Text('Camera Access Required',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text('Camera permission is required to record attendance.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.55), fontSize: 13)),
          const SizedBox(height: 28),
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
              padding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildLoadingView() {
    return const Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        CircularProgressIndicator(
            color: Color(0xFF1E88E5), strokeWidth: 2.5),
        SizedBox(height: 16),
        Text('Initializing camera...',
            style: TextStyle(color: Colors.white54, fontSize: 13)),
      ]),
    );
  }

  // ── Bottom Panel ─────────────────────────────────────────────────────────────
  Widget _buildBottomPanel() {
    // Show what the NEXT action will be for a generic scan
    // (before we know the employee name, we show a neutral state)
    const Color modeColor = Color(0xFF42A5F5);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B3E),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.6),
              blurRadius: 24,
              offset: const Offset(0, -6))
        ],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: double.infinity,
          padding:
          const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: modeColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border:
            Border.all(color: modeColor.withOpacity(0.4), width: 1),
            boxShadow: [
              BoxShadow(
                  color: modeColor.withOpacity(0.12), blurRadius: 14)
            ],
          ),
          child: Row(children: [
            const Icon(Icons.face_retouching_natural,
                color: modeColor, size: 26),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Attendance',
                        style: TextStyle(
                            color: modeColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1)),
                    SizedBox(height: 2),
                    Text(
                      'First scan = Check-In · Second scan = Check-Out',
                      style: TextStyle(
                          color: Colors.white38, fontSize: 11),
                    ),
                  ]),
            ),
            // Auto badge
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: Colors.greenAccent.withOpacity(0.35),
                    width: 1),
              ),
              child: const Row(children: [
                Icon(Icons.face_retouching_natural,
                    color: Colors.greenAccent, size: 13),
                SizedBox(width: 4),
                Text('Auto Detect',
                    style: TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        ),

        const SizedBox(height: 10),

        Text(
          _isProcessing
              ? 'Recording attendance, please wait...'
              : 'Attendance is recorded automatically via face recognition',
          style: TextStyle(
              color: Colors.white.withOpacity(0.3),
              fontSize: 11,
              letterSpacing: 0.3),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }
}