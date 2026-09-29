import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/theme.dart';
import '../../app/i18n.dart';

/// Camera scanning is offered on Android only: on the web, mobile_scanner
/// would load its decoder from a CDN (blocked by our CSP, privacy leak).
bool get cameraScanSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Live camera QR scanner. Calls [onCode] once per distinct code
/// (the same code is ignored for a few seconds to avoid double handling).
class ScannerView extends StatefulWidget {
  const ScannerView({super.key, required this.onCode, this.height = 320});
  final Future<void> Function(String raw) onCode;
  final double height;

  @override
  State<ScannerView> createState() => _ScannerViewState();
}

class _ScannerViewState extends State<ScannerView> {
  // Started/stopped by visibility: the shell keeps hidden tabs alive, and there is
  // only one camera session – a scanner left running on the Scannen tab made the
  // round's scanner fail with "Kamera nicht verfügbar".
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
    autoStart: false,
  );
  bool? _visible;
  Future<void> _camera = Future.value();
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled; // false in hidden tabs and covered routes
    if (visible == _visible) return;
    _visible = visible;
    // Chained, so a stop never races a start that is still in progress.
    // Start errors are shown by the errorBuilder via the controller state.
    _camera = _camera.then((_) => visible ? _controller.start() : _controller.stop()).catchError((Object _) {});
  }

  @override
  void dispose() {
    _camera.then((_) => _controller.dispose());
    super.dispose();
  }

  Future<void> _detect(BarcodeCapture c) async {
    final raw = c.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null || _busy) return;
    if (raw == _last && DateTime.now().difference(_lastAt).inSeconds < 4) return;
    _last = raw;
    _lastAt = DateTime.now();
    _busy = true;
    HapticFeedback.mediumImpact();
    try {
      await widget.onCode(raw);
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(20),
    child: SizedBox(
      height: widget.height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _detect,
            errorBuilder: (context, error) => Container(
              color: context.colors.surface2,
              padding: const EdgeInsets.all(24),
              alignment: Alignment.center,
              child: Text(
                error.errorCode == MobileScannerErrorCode.permissionDenied
                    ? tr('Kein Kamerazugriff. Erlaube die Kamera in den App-Einstellungen.')
                    : tr('Kamera nicht verfügbar.'),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          // Target frame
          Center(
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withValues(alpha: .85), width: 3),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: ValueListenableBuilder<MobileScannerState>(
              valueListenable: _controller,
              builder: (context, s, _) => IconButton.filledTonal(
                tooltip: tr('Taschenlampe'),
                onPressed: _controller.toggleTorch,
                icon: Icon(s.torchState == TorchState.on ? Icons.flashlight_off : Icons.flashlight_on),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
