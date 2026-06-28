import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:math' as math;
import 'p2p_service.dart';
import 'chat_screen.dart';
import 'storage_service.dart';
import 'background_service.dart';


// ── Boot sequence ─────────────────────────────────────────────────────────────
// Must be async so we can await StorageService and BackgroundService setup
// before the widget tree renders.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialise local database (Hive) — must happen before P2PService
  //    so stored peer keys can be loaded into the crypto cache at startup.
  await StorageService().init();

  // 2. Register the background service with the OS
  //    (creates notification channel on Android, registers BGTask IDs on iOS).
  //    Does NOT start the service yet — that happens after permissions are granted.
  await BackgroundService().configure();

  runApp(
    // Provide the P2PService singleton at the root so every screen can
    // call context.watch<P2PService>() and rebuild on peer list changes.
    ChangeNotifierProvider(
      create: (_) => P2PService(),
      child: const ZeroGridApp(),
    ),
  );
}

class ZeroGridApp extends StatelessWidget {
  const ZeroGridApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZeroGrid',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        primaryColor: const Color(0xFF00E5FF),
        fontFamily: 'Courier',
      ),
      home: const DiscoveryHubScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// DISCOVERY HUB SCREEN
// ──────────────────────────────────────────────────────────────────────────────
class DiscoveryHubScreen extends StatefulWidget {
  const DiscoveryHubScreen({super.key});

  @override
  State<DiscoveryHubScreen> createState() => _DiscoveryHubScreenState();
}

class _DiscoveryHubScreenState extends State<DiscoveryHubScreen>
    with TickerProviderStateMixin {
  late AnimationController _radarController;
  late AnimationController _dotController;

  // ── Status state ────────────────────────────────────────────────────
  String _statusText = 'Initializing...';
  bool _permissionDenied = false;
  bool _p2pActive = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();

    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _dotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);

    WidgetsBinding.instance.addPostFrameCallback((_) => _startP2P());
  }

  void _setStatus(String text) {
    if (mounted) setState(() { _statusText = text; _errorText = null; });
  }

  void _setError(String text) {
    if (mounted) setState(() { _errorText = text; _statusText = 'Error'; });
  }

  Future<void> _startP2P() async {
    if (!mounted) return;
    setState(() {
      _permissionDenied = false;
      _errorText = null;
      _p2pActive = false;
    });

    final service = context.read<P2PService>();

    try {
      // Step 1 — Init crypto (loads/generates X25519 key pair)
      _setStatus('Loading encryption keys...');
      await service.init();

      // Step 2 — Request ALL permissions with dialog
      _setStatus('Requesting permissions...');
      final granted = await service.requestPermissions();

      if (!granted) {
        if (mounted) {
          setState(() {
            _permissionDenied = true;
            _statusText = 'Permissions denied';
          });
        }
        return;
      }

      // Step 3 — Start advertising (makes this device discoverable)
      _setStatus('Starting advertising...');
      await service.startAdvertising();

      // Step 4 — Start discovery (scans for other devices)
      _setStatus('Starting discovery...');
      await service.startDiscovery();

      // Step 5 — Background service
      _setStatus('Starting background service...');
      await BackgroundService().start();

      if (mounted) {
        setState(() {
          _p2pActive = true;
          _statusText = 'Scanning for nearby agents...';
        });
      }
    } catch (e) {
      _setError('$e');
    }
  }

  @override
  void dispose() {
    _radarController.dispose();
    _dotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(flex: 1, child: _buildRadar()),
            Expanded(flex: 1, child: _buildAgentList()),
          ],
        ),
      ),
    );
  }

  // ── Header ──────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24.0, horizontal: 16.0),
      child: Column(
        children: [
          // Title row with active badge
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'ZeroGrid',
                style: TextStyle(
                  color: Color(0xFFEEEEEE),
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 4.0,
                  fontFamily: 'monospace',
                ),
              ),
              if (_p2pActive) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5)),
                  ),
                  child: const Text(
                    'ACTIVE',
                    style: TextStyle(
                      color: Color(0xFF00E5FF),
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),

          // Status line
          if (_errorText != null) ...[
            // Error state
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.4)),
              ),
              child: Column(
                children: [
                  Text(
                    '⚠️ Error: $_errorText',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red, fontSize: 11),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: _startP2P,
                    child: const Text(
                      '↺  RETRY',
                      style: TextStyle(
                        color: Color(0xFF00E5FF),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ] else if (_permissionDenied) ...[
            // Permission denied state
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withOpacity(0.4)),
              ),
              child: Column(
                children: [
                  const Text(
                    '🔒 Bluetooth & Location permissions are required.\nPlease grant them and retry.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.orange, fontSize: 11),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: _startP2P,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00E5FF).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5)),
                          ),
                          child: const Text(
                            '↺  RETRY',
                            style: TextStyle(
                              color: Color(0xFF00E5FF),
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: openAppSettings,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.orange.withOpacity(0.5)),
                          ),
                          child: const Text(
                            '⚙  SETTINGS',
                            style: TextStyle(
                              color: Colors.orange,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            // Normal scanning status row
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _dotController,
                  builder: (context, child) {
                    return Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E5FF)
                            .withOpacity(0.2 + (_dotController.value * 0.8)),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00E5FF),
                            blurRadius: 8 * _dotController.value,
                            spreadRadius: 2 * _dotController.value,
                          )
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(width: 8),
                Text(
                  _statusText,
                  style: const TextStyle(color: Color(0xFF888888), fontSize: 14),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }


  // ── Radar ───────────────────────────────────────────────────────────────────
  Widget _buildRadar() {
    return Center(
      child: AnimatedBuilder(
        animation: _radarController,
        builder: (context, child) => CustomPaint(
          painter: RadarPainter(_radarController.value),
          size: const Size(280, 280),
        ),
      ),
    );
  }

  // ── Agent List (LIVE) ────────────────────────────────────────────────────────
  Widget _buildAgentList() {
    // context.watch rebuilds this widget whenever P2PService calls
    // notifyListeners() — i.e. every time a peer is found or lost.
    final service = context.watch<P2PService>();
    final peers = service.peers.values.toList();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF050505),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border:
            Border.all(color: const Color(0xFF00E5FF).withOpacity(0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'DISCOVERED PEERS',
                  style: TextStyle(
                    color: Color(0xFF888888),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2.0,
                  ),
                ),
                // Live peer count badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: const Color(0xFF00E5FF).withOpacity(0.4)),
                  ),
                  child: Text(
                    '${peers.length} online',
                    style: const TextStyle(
                        color: Color(0xFF00E5FF),
                        fontSize: 10,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: peers.isEmpty
                ? _buildEmptyState()
                : ListView.separated(
                    padding: const EdgeInsets.only(
                        left: 16.0, right: 16.0, bottom: 24.0),
                    itemCount: peers.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      return _buildAgentCard(peers[index], service);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ── Empty state when no peers found yet ─────────────────────────────────────
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.radar, color: Color(0xFF333333), size: 48),
          const SizedBox(height: 16),
          const Text(
            'No agents detected yet.',
            style: TextStyle(color: Color(0xFF555555), fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            'Make sure other ZeroGrid\ndevices are nearby and active.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: const Color(0xFF555555).withOpacity(0.7), fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ── Single Agent Card ────────────────────────────────────────────────────────
  Widget _buildAgentCard(DiscoveredPeer peer, P2PService service) {
    final bool isConnecting = peer.state == PeerState.connecting;
    final bool isConnected = peer.state == PeerState.connected;
    final bool isDisconnected = peer.state == PeerState.found ||
        peer.state == PeerState.disconnected;

    final Color borderColor = (isConnected || isConnecting)
        ? const Color(0xFF00E5FF)
        : const Color(0xFF333333);

    return Opacity(
      opacity: isConnecting ? 0.6 : 1.0,
      child: GestureDetector(
        onTap: () {
          if (isConnected) {
            // Navigate to chat if already connected
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ChatScreen(
                  peerName: peer.endpointName,
                  endpointId: peer.endpointId,
                ),
              ),
            );
          } else {
            // Initiate connection
            service.connectToPeer(peer.endpointId);
          }
        },
        child: Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            children: [
              // Terminal Icon
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isConnected
                        ? const Color(0xFF00E5FF)
                        : const Color(0xFF00E5FF).withOpacity(0.3),
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: const Text(
                  '>_',
                  style: TextStyle(
                    color: Color(0xFF00E5FF),
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 16),

              // Agent Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      peer.endpointName,
                      style: const TextStyle(
                          color: Color(0xFFEEEEEE),
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (isConnecting) ...[
                          const SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              color: Color(0xFF00E5FF),
                              strokeWidth: 1.5,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          peer.statusLabel,
                          style: TextStyle(
                            color: isConnected
                                ? const Color(0xFF00E5FF)
                                : const Color(0xFF888888),
                            fontSize: 13,
                            fontWeight: isConnected
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Action Button or Signal Bars
              if (isDisconnected)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: const Color(0xFF00E5FF).withOpacity(0.5)),
                  ),
                  child: const Text(
                    'CONNECT',
                    style: TextStyle(
                      color: Color(0xFF00E5FF),
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                    ),
                  ),
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _buildSignalBars(peer.signalStrength),
                    const SizedBox(height: 4),
                    const Text(
                      'nearby',
                      style: TextStyle(
                          color: Color(0xFF888888),
                          fontSize: 11,
                          fontFamily: 'monospace'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSignalBars(double strength) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (index) {
        final double threshold = (index + 1) * 0.25;
        final bool isActive = strength >= threshold - 0.1;
        return Container(
          margin: const EdgeInsets.only(left: 2),
          width: 3,
          height: 4.0 + (index * 3),
          decoration: BoxDecoration(
            color: isActive
                ? const Color(0xFF00E5FF)
                : const Color(0xFF333333),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(1)),
          ),
        );
      }),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// RADAR PAINTER  (unchanged)
// ──────────────────────────────────────────────────────────────────────────────
class RadarPainter extends CustomPainter {
  final double progress;
  RadarPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // Center dot
    paint.color = const Color(0xFF00E5FF).withOpacity(0.8);
    paint.style = PaintingStyle.fill;
    canvas.drawCircle(center, 4, paint);

    // Crosshairs
    paint.style = PaintingStyle.stroke;
    paint.color = const Color(0xFF00E5FF).withOpacity(0.3);
    canvas.drawLine(
        Offset(center.dx, center.dy - 10), Offset(center.dx, center.dy + 10), paint);
    canvas.drawLine(
        Offset(center.dx - 10, center.dy), Offset(center.dx + 10, center.dy), paint);

    // 3 expanding rings
    for (int i = 0; i < 3; i++) {
      final waveProgress = (progress + (i * 0.333)) % 1.0;
      final curveProgress = math.sin(waveProgress * math.pi / 2);
      final currentRadius = maxRadius * curveProgress;
      final alpha = 1.0 - waveProgress;
      paint.color = const Color(0xFF00E5FF).withOpacity(alpha);
      canvas.drawCircle(center, currentRadius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant RadarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
