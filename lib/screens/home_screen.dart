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
  bool _isCamReady = false;
  bool _camPermitted = false;

  // ── WebSocket ────────────────────────────────────────────────────────────────
  final WebSocketService _ws = WebSocketService();
  WsState _wsState = WsState.disconnected;
  String _wsStatusText = 'Disconnected';
  Color _wsStatusColor = Colors.red;

  // ── Frame streaming ──────────────────────────────────────────────────────────
  Timer? _frameTimer;
  bool _isSendingFrame = false;
  int _framesSent = 0;
  bool _isStreaming = false;

  // ── Attendance processing ────────────────────────────────────────────────────
  // _isProcessing = true while taking snapshot + showing snackbar
  // prevents double-trigger for the same face
  bool _isProcessing = false;
  Timer? _resetTimer;

  // ── Last server message (shown on screen for debug) ──────────────────────────
  String _lastServerMsg = '';

  // ── Clock ────────────────────────────────────────────────────────────────────
  Timer? _clockTimer;
  String _currentTime = '';
  String _currentDate = '';

  // ── Check-in deadline 13:30 ──────────────────────────────────────────────────
  static const int _deadlineHour = 13;
  static const int _deadlineMinute = 30;

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startClock();
    _initWebSocket(); // WS first — camera starts after WS connects
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockTimer?.cancel();
    _frameTimer?.cancel();
    _resetTimer?.cancel();
    _camCtrl?.dispose();
    _ws.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_isCamReady) _initCamera();
      if (_isCamReady && _wsState == WsState.connected) _startStreaming();
    } else if (state == AppLifecycleState.paused) {
      _stopStreaming();
    }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // CLOCK
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
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

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // TIME WINDOW
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  bool get _isCheckInWindow {
    final now = TimeOfDay.now();
    return (now.hour * 60 + now.minute) <= (_deadlineHour * 60 + _deadlineMinute);
  }

  String get _currentMode => _isCheckInWindow ? 'Check-In' : 'Check-Out';

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // CAMERA
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (mounted) setState(() => _camPermitted = false);
      return;
    }
    if (mounted) setState(() => _camPermitted = true);
    if (widget.cameras.isEmpty) return;

    CameraDescription cam = widget.cameras.first;
    for (final c in widget.cameras) {
      if (c.lensDirection == CameraLensDirection.front) { cam = c; break; }
    }

    await _camCtrl?.dispose();
    _camCtrl = CameraController(
      cam, ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await _camCtrl!.initialize();
      if (mounted) {
        setState(() => _isCamReady = true);
        // Start streaming only if WS is already connected
        if (_wsState == WsState.connected) _startStreaming();
      }
    } on CameraException catch (e) {
      debugPrint('Camera error: ${e.code} — ${e.description}');
    }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // WEBSOCKET — THE CRITICAL FIX IS IN onMessage
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

    // ── THIS IS THE KEY FIX ──────────────────────────────────────────────────
    // Server sends JSON after face recognition. Parse it and trigger attendance.
    _ws.onMessage = (dynamic msg) {
      debugPrint('SERVER RESPONSE: $msg');

      if (msg is! String) return; // ignore binary pongs

      if (mounted) setState(() => _lastServerMsg = msg);

      Map<String, dynamic> data;
      try {
        data = jsonDecode(msg) as Map<String, dynamic>;
      } catch (_) {
        debugPrint('Non-JSON message from server: $msg');
        return;
      }

      // ── Extract employee name from any field the server might use ──────────
      final String employeeName = (data['name'] ??
          data['employee'] ??
          data['employee_name'] ??
          data['user'] ??
          '')
          .toString()
          .trim();

      // ── Extract status/event from any field the server might use ──────────
      final String status = (data['status'] ??
          data['event'] ??
          data['result'] ??
          '')
          .toString()
          .toLowerCase()
          .trim();

      debugPrint('Parsed — name: "$employeeName" status: "$status"');

      // ── Trigger attendance if face was recognized ─────────────────────────
      // Handle: "recognized", "success", "checkin_success", "checkout_success",
      //         "checkin", "checkout", "identified", "matched"
      final bool isRecognized = status.contains('recogni') ||
          status.contains('success') ||
          status.contains('checkin') ||
          status.contains('checkout') ||
          status.contains('identif') ||
          status.contains('match') ||
          employeeName.isNotEmpty; // if name came through, face was found

      if (isRecognized && employeeName.isNotEmpty) {
        _onFaceRecognized(employeeName);
      } else if (isRecognized && employeeName.isEmpty) {
        // Recognized but no name — use generic label
        _onFaceRecognized('Employee');
      }
      // If status is "unknown" / "no_face" / "not_found" — do nothing, keep streaming
    };

    _ws.onError = (err) {
      debugPrint('WS error: $err');
    };

    _ws.connect();
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // FRAME STREAMING — sends raw JPEG bytes every 200ms
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  void _startStreaming() {
    if (_isStreaming) return;
    if (!_isCamReady || _camCtrl == null) return;
    if (_wsState != WsState.connected) return;

    setState(() { _isStreaming = true; _framesSent = 0; });

    _frameTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _captureAndSendFrame();
    });
  }

  void _stopStreaming() {
    _frameTimer?.cancel();
    _frameTimer = null;
    if (mounted) setState(() => _isStreaming = false);
  }

  Future<void> _captureAndSendFrame() async {
    if (_isSendingFrame) return;
    if (!_isCamReady || _camCtrl == null) return;
    if (_wsState != WsState.connected) return;
    if (_isProcessing) return; // paused while recording attendance

    _isSendingFrame = true;
    try {
      final XFile file = await _camCtrl!.takePicture();
      final Uint8List bytes = await File(file.path).readAsBytes();
      final sent = _ws.sendBinaryFrame(bytes);
      if (sent && mounted) setState(() => _framesSent++);
      await File(file.path).delete();
    } catch (e) {
      debugPrint('Frame capture error: $e');
    } finally {
      _isSendingFrame = false;
    }
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // ATTENDANCE — called automatically from WS onMessage
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Future<void> _onFaceRecognized(String employeeName) async {
    if (_isProcessing) return;
    if (!_isCamReady || _camCtrl == null) return;

    setState(() => _isProcessing = true);
    _stopStreaming(); // pause stream while taking attendance photo

    final action = _isCheckInWindow ? 'checkin' : 'checkout';
    final label = _isCheckInWindow ? 'Check-In' : 'Check-Out';
    final Color snackColor = _isCheckInWindow
        ? const Color(0xFF00C853)
        : const Color(0xFFFF6D00);

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

      // Notify server of confirmed attendance event
      _ws.sendText(jsonEncode({
        'event': action,
        'employee': employeeName,
        'timestamp': now.toIso8601String(),
      }));

      // ── Show snackbar ────────────────────────────────────────────────────
      _showSnack(
        icon: _isCheckInWindow ? '✅' : '👋',
        title: '$label Recorded',
        subtitle: '$employeeName — $timeStr, $dateStr',
        color: snackColor,
      );

      // ── Wait 2.5 seconds → reset for next employee ───────────────────────
      _resetTimer?.cancel();
      _resetTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) {
          setState(() => _isProcessing = false);
          _startStreaming(); // resume for next employee
        }
      });
    } catch (e) {
      debugPrint('Attendance error: $e');
      _showSnack(
        icon: '❌',
        title: 'Error',
        subtitle: 'Could not record attendance: $e',
        color: Colors.red,
      );
      setState(() => _isProcessing = false);
      _startStreaming();
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

  // ── Top Bar ──────────────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      decoration: const BoxDecoration(
        color: Color(0xFF0D1B3E),
        border: Border(bottom: BorderSide(color: Color(0xFF1A2E5A), width: 1)),
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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

  // ── Status Bar ───────────────────────────────────────────────────────────────
  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: const Color(0xFF0A1428),
      child: Row(children: [
        // WS dot
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _wsStatusColor,
            boxShadow: [BoxShadow(color: _wsStatusColor.withOpacity(0.6), blurRadius: 6)],
          ),
        ),
        const SizedBox(width: 6),
        Text('Server: $_wsStatusText',
            style: TextStyle(color: _wsStatusColor, fontSize: 11, fontWeight: FontWeight.w500)),
        const Spacer(),
        if (_isStreaming)
          Row(children: [
            const Icon(Icons.sensors, color: Colors.greenAccent, size: 13),
            const SizedBox(width: 4),
            Text('Streaming · $_framesSent frames',
                style: const TextStyle(color: Colors.greenAccent, fontSize: 11)),
          ]),
        if (!_isStreaming && _wsState == WsState.disconnected)
          GestureDetector(
            onTap: _ws.connect,
            child: const Text('Retry ↺',
                style: TextStyle(color: Color(0xFF42A5F5), fontSize: 11, fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }

  // ── Camera Area ──────────────────────────────────────────────────────────────
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
        top: 0, left: 0, right: 0, height: 90,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Colors.black.withOpacity(0.55), Colors.transparent],
            ),
          ),
        ),
      ),

      // Bottom gradient
      Positioned(
        bottom: 0, left: 0, right: 0, height: 80,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter, end: Alignment.topCenter,
              colors: [Colors.black.withOpacity(0.45), Colors.transparent],
            ),
          ),
        ),
      ),

      // Oval guide
      Center(
        child: Container(
          width: 230, height: 290,
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
            width: 240, height: 300,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(156),
              border: Border.all(color: Colors.greenAccent.withOpacity(0.2), width: 7),
            ),
          ),
        ),

      // Processing ring + spinner
      if (_isProcessing) ...[
        Center(
          child: Container(
            width: 240, height: 300,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(156),
              border: Border.all(color: Colors.amber.withOpacity(0.45), width: 7),
            ),
          ),
        ),
        const Center(
          child: SizedBox(
            width: 52, height: 52,
            child: CircularProgressIndicator(color: Colors.amber, strokeWidth: 3),
          ),
        ),
      ],

      // Instruction label at top
      Positioned(
        top: 18, left: 16, right: 16,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.65),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              _isProcessing
                  ? 'Processing — please wait...'
                  : (_isCheckInWindow
                  ? '📸  Look at camera to Check-In'
                  : '📸  Look at camera to Check-Out'),
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      ),

      // Last server message (small debug label — remove in production if desired)
      if (_lastServerMsg.isNotEmpty)
        Positioned(
          bottom: 12, left: 16, right: 16,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Server: $_lastServerMsg',
                style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 10),
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
          Icon(Icons.no_photography_outlined, size: 72, color: Colors.red.shade400),
          const SizedBox(height: 20),
          const Text('Camera Access Required',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text('Camera permission is required to record attendance.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 13)),
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
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
        SizedBox(height: 16),
        Text('Initializing camera...',
            style: TextStyle(color: Colors.white54, fontSize: 13)),
      ]),
    );
  }

  // ── Bottom Panel ─────────────────────────────────────────────────────────────
  Widget _buildBottomPanel() {
    final bool isCheckIn = _isCheckInWindow;
    final Color modeColor = isCheckIn ? const Color(0xFF00C853) : const Color(0xFFFF6D00);
    final IconData modeIcon = isCheckIn ? Icons.login_rounded : Icons.logout_rounded;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1B3E),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 24, offset: const Offset(0, -6))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Mode card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: modeColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: modeColor.withOpacity(0.4), width: 1),
            boxShadow: [BoxShadow(color: modeColor.withOpacity(0.12), blurRadius: 14)],
          ),
          child: Row(children: [
            Icon(modeIcon, color: modeColor, size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_currentMode,
                    style: TextStyle(
                        color: modeColor, fontSize: 16,
                        fontWeight: FontWeight.w800, letterSpacing: 1)),
                const SizedBox(height: 2),
                Text(
                  isCheckIn
                      ? 'Check-in window open until 1:30 PM'
                      : 'Check-out window is now active',
                  style: TextStyle(color: Colors.white.withOpacity(0.45), fontSize: 11),
                ),
              ]),
            ),
            // Auto badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.greenAccent.withOpacity(0.35), width: 1),
              ),
              child: const Row(children: [
                Icon(Icons.face_retouching_natural, color: Colors.greenAccent, size: 13),
                SizedBox(width: 4),
                Text('Auto Detect',
                    style: TextStyle(color: Colors.greenAccent, fontSize: 10, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
        ),

        const SizedBox(height: 10),

        Text(
          _isProcessing
              ? 'Recording attendance, please wait...'
              : 'Attendance is recorded automatically via face recognition',
          style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 11, letterSpacing: 0.3),
          textAlign: TextAlign.center,
        ),
      ]),
    );
  }
}