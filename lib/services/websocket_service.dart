import 'dart:async';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

enum WsState { disconnected, connecting, connected, error }

typedef OnStateChange = void Function(WsState state);
typedef OnMessageReceived = void Function(dynamic message);
typedef OnError = void Function(String error);

class WebSocketService {
  static const String _wsUrl = 'wss://att.whatido.in/ws/';

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;

  WsState _state = WsState.disconnected;
  WsState get state => _state;

  OnStateChange? onStateChange;
  OnMessageReceived? onMessage;
  OnError? onError;

  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 15;

  bool _intentionalClose = false;

  // ── Connect ────────────────────────────────────────────────────────────────
  Future<void> connect() async {
    if (_state == WsState.connecting || _state == WsState.connected) return;

    _intentionalClose = false;
    _setState(WsState.connecting);
    print('🔌 WS: Attempting connection to $_wsUrl');

    try {
      final uri = Uri.parse(_wsUrl);
      _channel = WebSocketChannel.connect(uri);

      await _channel!.ready.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('WS handshake timed out after 15s'),
      );

      _setState(WsState.connected);
      _reconnectAttempts = 0;
      print('✅ WS: Connected successfully to $_wsUrl');

      _subscription = _channel!.stream.listen(
            (data) {
          // Log every single byte/message from server
          if (data is String) {
            print('📨 WS TEXT from server: $data');
          } else if (data is List<int>) {
            print('📦 WS BINARY from server: ${data.length} bytes');
          } else {
            print('📬 WS OTHER from server: ${data.runtimeType} — $data');
          }
          onMessage?.call(data);
        },
        onError: (error, stack) {
          print('❌ WS STREAM ERROR: $error');
          _handleError('Stream error: $error');
        },
        onDone: () {
          print('🔴 WS STREAM DONE (closed by server or network)');
          if (!_intentionalClose) {
            _handleError('Connection closed unexpectedly');
          }
        },
        cancelOnError: false,
      );
    } on TimeoutException catch (e) {
      print('⏱️ WS TIMEOUT: ${e.message}');
      _handleError(e.message ?? 'Connection timed out');
    } catch (e) {
      print('💥 WS CONNECT FAILED: $e');
      _handleError('Connection failed: $e');
    }
  }

  // ── Send Binary (JPEG bytes) ───────────────────────────────────────────────
  bool sendBinaryFrame(Uint8List jpegBytes) {
    if (_state != WsState.connected || _channel == null) {
      return false;
    }
    try {
      _channel!.sink.add(jpegBytes);
      return true;
    } catch (e) {
      print('❌ WS SEND BINARY ERROR: $e');
      _handleError('Send failed: $e');
      return false;
    }
  }

  // ── Send Text ─────────────────────────────────────────────────────────────
  bool sendText(String message) {
    if (_state != WsState.connected || _channel == null) {
      return false;
    }
    try {
      _channel!.sink.add(message);
      print('📤 WS TEXT SENT: $message');
      return true;
    } catch (e) {
      print('❌ WS SEND TEXT ERROR: $e');
      _handleError('Send text failed: $e');
      return false;
    }
  }

  // ── Disconnect ────────────────────────────────────────────────────────────
  Future<void> disconnect() async {
    print('🔌 WS: Intentional disconnect');
    _intentionalClose = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;

    await _subscription?.cancel();
    _subscription = null;

    try {
      await _channel?.sink.close(ws_status.goingAway);
    } catch (_) {}
    _channel = null;

    _setState(WsState.disconnected);
  }

  // ── Error + Reconnect ─────────────────────────────────────────────────────
  void _handleError(String msg) {
    print('⚠️ WS ERROR: $msg — scheduling reconnect #${_reconnectAttempts + 1}');
    _setState(WsState.error);
    onError?.call(msg);

    _subscription?.cancel();
    _subscription = null;
    _channel = null;

    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_intentionalClose) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      print('🚫 WS: Max reconnect attempts reached');
      onError?.call('Max reconnect attempts reached. Please check your network.');
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectAttempts++;
    // Exponential backoff: 2s, 4s, 6s ... max 20s
    final delaySec = (_reconnectAttempts * 2).clamp(2, 20);
    final delay = Duration(seconds: delaySec);

    print('🔄 WS: Reconnecting in ${delaySec}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(delay, () {
      if (!_intentionalClose) connect();
    });
  }

  void _setState(WsState newState) {
    if (_state == newState) return;
    _state = newState;
    print('🔁 WS STATE → $newState');
    onStateChange?.call(_state);
  }

  void dispose() {
    disconnect();
  }
}