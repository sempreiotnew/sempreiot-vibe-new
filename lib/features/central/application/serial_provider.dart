import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:usb_serial/usb_serial.dart';

import '../domain/safr/safr_v2_frame.dart';

enum SerialStatus { disconnected, connecting, connected, error }

class SerialNotifier extends StateNotifier<SerialStatus> {
  SerialNotifier() : super(SerialStatus.disconnected) {
    _init();
  }

  static const _baudRate = 115200;

  // SAFR framing constants (docs/safr/protocol-safr-v3.md §9)
  static const _safrSof = 0xA5;
  static const _safrMinFrame = 32;
  static const _safrMaxFrame = 256;

  StreamSubscription<UsbEvent>? _usbEventSub;
  StreamSubscription<Uint8List?>? _inputSub;
  UsbPort? _port;
  String? _connectedDeviceId;
  final _byteBuffer = <int>[];
  final _dataController = StreamController<Uint8List>.broadcast();

  // Link diagnostics — read by serialLinkProvider and the Logs console so a
  // link that carries bytes but never a valid frame is distinguishable from
  // a dead cable (and never silently invisible).
  int _rawByteCount = 0;
  int _droppedByteCount = 0;
  int _validFrameCount = 0;
  DateTime? _lastBytesAt;

  String? get connectedDeviceId => _connectedDeviceId;

  Stream<Uint8List> get dataStream => _dataController.stream;

  /// Total raw bytes received since the port opened.
  int get rawByteCount => _rawByteCount;

  /// Bytes discarded during resync (noise / corrupt candidates).
  int get droppedByteCount => _droppedByteCount;

  /// Frames that passed framing (SOF + LEN + CRC) since the port opened.
  int get validFrameCount => _validFrameCount;

  /// When the last raw bytes (valid or not) arrived.
  DateTime? get lastBytesAt => _lastBytesAt;

  Future<void> _init() async {
    if (kIsWeb) return;

    try {
      _usbEventSub = UsbSerial.usbEventStream?.listen((UsbEvent event) {
        if (event.event == UsbEvent.ACTION_USB_ATTACHED) {
          debugPrint('[Serial] USB device attached');
          _connect();
        } else if (event.event == UsbEvent.ACTION_USB_DETACHED) {
          debugPrint('[Serial] USB device detached');
          _onDisconnected();
        }
      });
    } catch (e) {
      debugPrint('[Serial] Failed to listen to USB events: $e');
    }

    await _connect();
  }

  Future<void> _connect() async {
    if (kIsWeb || state == SerialStatus.connecting) return;

    state = SerialStatus.connecting;

    await _inputSub?.cancel();
    _inputSub = null;
    try {
      await _port?.close();
    } catch (_) {}
    _port = null;

    try {
      final devices = await UsbSerial.listDevices();

      if (devices.isEmpty) {
        debugPrint('[Serial] No USB devices found');
        if (mounted) state = SerialStatus.disconnected;
        return;
      }

      final device = devices.first;
      _connectedDeviceId = '${device.vid}:${device.pid}';
      debugPrint(
        '[Serial] Found: ${device.productName} '
        '[VID:${device.vid} PID:${device.pid}]',
      );

      final port = await device.create();
      if (port == null) {
        debugPrint('[Serial] Failed to create port');
        if (mounted) state = SerialStatus.error;
        return;
      }

      if (!await port.open()) {
        debugPrint('[Serial] Failed to open port');
        await port.close();
        if (mounted) state = SerialStatus.error;
        return;
      }

      await port.setPortParameters(
        _baudRate,
        UsbPort.DATABITS_8,
        UsbPort.STOPBITS_1,
        UsbPort.PARITY_NONE,
      );

      // Deterministic modem lines: on ESP32 dev boards DTR/RTS drive the
      // auto-reset circuit — both deasserted keeps EN high (chip running).
      try {
        await port.setDTR(false);
        await port.setRTS(false);
      } catch (_) {
        // Some adapters don't support modem-line control — fine.
      }

      _port = port;
      _rawByteCount = 0;
      _droppedByteCount = 0;
      _validFrameCount = 0;
      _lastBytesAt = null;

      _inputSub = port.inputStream?.listen(
        (Uint8List? data) {
          if (data == null || data.isEmpty) return;
          _rawByteCount += data.length;
          _lastBytesAt = DateTime.now();
          _byteBuffer.addAll(data);
          _drainFrames();
        },
        onError: (Object err) {
          debugPrint('[Serial] Stream error: $err');
          _onDisconnected();
        },
        onDone: () {
          debugPrint('[Serial] Stream closed by device');
          _onDisconnected();
        },
        cancelOnError: false,
      );

      if (mounted) state = SerialStatus.connected;
      debugPrint('[Serial] Connected at $_baudRate baud');
    } catch (e, st) {
      debugPrint('[Serial] Connection error: $e\n$st');
      if (mounted) state = SerialStatus.error;
    }
  }

  // Scans _byteBuffer for complete SAFR frames and emits each one.
  // Frame boundary: SOF(0xA5) at offset 0, total length at bytes [2..3].
  // v2 frames are additionally CRC-checked here so a false SOF inside noise
  // (e.g. ESP32 boot-ROM chatter) costs exactly one discarded byte, never a
  // whole misframed window (docs/safr/protocol-safr-v3.md §9).
  void _drainFrames() {
    while (true) {
      // 1. Find next SOF byte.
      final sofIdx = _byteBuffer.indexOf(_safrSof);
      if (sofIdx < 0) {
        _droppedByteCount += _byteBuffer.length;
        _byteBuffer.clear();
        return;
      }
      if (sofIdx > 0) {
        debugPrint('[Serial] Discarding $sofIdx garbage bytes before SOF');
        _droppedByteCount += sofIdx;
        _byteBuffer.removeRange(0, sofIdx);
      }

      // 2. Need at least 4 bytes to read the VER + LEN fields.
      if (_byteBuffer.length < 4) return;

      final version = _byteBuffer[1];
      if (version != safrVer1 && version != safrVer2 && version != safrVer3) {
        _droppedByteCount++;
        _byteBuffer.removeAt(0);
        continue;
      }

      // 3. Parse total frame length from header bytes [2..3] (big-endian).
      final frameLen = (_byteBuffer[2] << 8) | _byteBuffer[3];
      if (frameLen < _safrMinFrame || frameLen > _safrMaxFrame) {
        // Invalid length — this SOF byte was garbage; skip and retry.
        debugPrint(
            '[Serial] Invalid SAFR frame length $frameLen, skipping SOF');
        _droppedByteCount++;
        _byteBuffer.removeAt(0);
        continue;
      }

      // 4. Wait until the full frame has arrived.
      if (_byteBuffer.length < frameLen) return;

      final frame = Uint8List.fromList(_byteBuffer.sublist(0, frameLen));

      // 5. v2/v3 carry a trailing CRC: a mismatch means this SOF was not a
      // real frame start (or the link corrupted it) — resync by one byte.
      if ((version == safrVer2 || version == safrVer3) && !safrCrcOk(frame)) {
        debugPrint('[Serial] CRC mismatch at candidate frame, resyncing');
        _droppedByteCount++;
        _byteBuffer.removeAt(0);
        continue;
      }

      // 6. Emit the complete frame.
      _byteBuffer.removeRange(0, frameLen);
      _validFrameCount++;
      if (!_dataController.isClosed) {
        debugPrint('[Serial] RX SAFR frame: $frameLen bytes');
        _dataController.add(frame);
      }
    }
  }

  /// Sends a fully-built SAFR frame to the root node (downlink).
  /// Returns false when no port is open.
  Future<bool> write(Uint8List frame) async {
    final port = _port;
    if (port == null) return false;
    try {
      await port.write(frame);
      return true;
    } catch (e) {
      debugPrint('[Serial] TX failed: $e');
      return false;
    }
  }

  void _onDisconnected() {
    _inputSub?.cancel();
    _inputSub = null;
    try {
      _port?.close();
    } catch (_) {}
    _port = null;
    _connectedDeviceId = null;
    _byteBuffer.clear();
    if (mounted) state = SerialStatus.disconnected;
  }

  @override
  void dispose() {
    _usbEventSub?.cancel();
    _inputSub?.cancel();
    try {
      _port?.close();
    } catch (_) {}
    _dataController.close();
    super.dispose();
  }
}

final serialProvider =
    StateNotifierProvider<SerialNotifier, SerialStatus>((ref) {
  return SerialNotifier();
});

/// Raw bytes stream from the serial port — only emits when connected.
final serialDataProvider = StreamProvider<Uint8List>((ref) {
  return ref.watch(serialProvider.notifier).dataStream;
});
