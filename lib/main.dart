import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:vibration/vibration.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final opt = OptimiserState();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => opt),
        ChangeNotifierProvider(create: (_) => BleManager()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Physiological Optimiser',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        appBarTheme: const AppBarTheme(centerTitle: true),
      ),
      home: const OptimiserDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ============================================================
// OPTIMISER STATE – REAL-TIME HAPTIC GRADIENT ASCENT
// ============================================================

class OptimiserState extends ChangeNotifier {
  // ---------- Core state ----------
  double hr = 0;
  double velocity = 0; // km/h (smoothed)
  double efficiency = 0; // km/h per bpm
  bool recording = false;

  // Short-term in-memory samples for the live graph only
  final List<Map<String, dynamic>> recentEff = [];

  // Smoothed velocity internals
  double _smoothVelocity = 0;
  static const double _alpha = 0.15; // smoothing factor for velocity

  // ---------- Gradient-ascent loop ----------
  Timer? _loopTimer;

  // Test timing
  DateTime? _lastTestTime;
  bool _testInProgress = false;
  DateTime? _testStartTime;
  String? _testDirection; // "up" or "down"

  // Snapshot before test
  double? _effBeforeTest;
  double? _hrBeforeTest;
  double? _velBeforeTest;

  // Plateau state (top of gradient)
  bool _plateau = false;
  double? _plateauHr;
  double? _plateauVel;

  // Simple reinforcement stats
  double _avgUpDelta = 0.0;
  double _avgDownDelta = 0.0;
  int _upCount = 0;
  int _downCount = 0;

  String _currentAdvice = "Tap ▶ to start workout";

  // ---------- Public controls ----------

  void toggleRecording() {
    recording = !recording;

    if (recording) {
      _startLoop();
      _resetGradientState();
      _currentAdvice = "Learning rhythm...";
    } else {
      _stopLoop();
      _currentAdvice = "Tap ▶ to start workout";
    }

    notifyListeners();
  }

  void _resetGradientState() {
    _plateau = false;
    _plateauHr = null;
    _plateauVel = null;
    _lastTestTime = null;
    _testInProgress = false;
    _testStartTime = null;
    _testDirection = null;
    _effBeforeTest = null;
    _hrBeforeTest = null;
    _velBeforeTest = null;
    _avgUpDelta = 0.0;
    _avgDownDelta = 0.0;
    _upCount = 0;
    _downCount = 0;
  }

  void _startLoop() {
    _loopTimer?.cancel();
    _loopTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _tickGradient();
    });
  }

  void _stopLoop() {
    _loopTimer?.cancel();
    _loopTimer = null;
  }

  // ---------- Inputs from sensors ----------

  void setHr(double bpm) {
    if (bpm <= 0 || bpm.isNaN) return;
    hr = bpm;
    _updateEfficiency();
  }

  /// mps = metres per second from GPS
  void setVelocity(double mps) {
    double v = mps * 3.6; // convert to km/h

    if (v.isNaN || v.isInfinite || v < 0) return;

    // Hard cap: ignore insane spikes (>25 km/h running)
    if (v > 25) {
      _updateEfficiency(); // keep previous smoothed velocity
      return;
    }

    // Exponential moving average smoothing
    if (_smoothVelocity == 0) {
      _smoothVelocity = v;
    } else {
      _smoothVelocity = (_alpha * v) + ((1 - _alpha) * _smoothVelocity);
    }

    velocity = _smoothVelocity;
    _updateEfficiency();
  }

  void _updateEfficiency() {
    if (!recording || hr <= 0 || velocity <= 0) return;

    efficiency = velocity / hr;

    // Track recent samples for live graph only
    recentEff.add({
      "eff": efficiency,
      "vel": velocity,
      "time": DateTime.now(),
    });
    if (recentEff.length > 60) recentEff.removeAt(0);

    notifyListeners();
  }

  // ---------- Gradient-ascent control loop ----------

  void _tickGradient() {
    if (!recording || hr <= 0 || velocity <= 0 || efficiency <= 0) return;

    final now = DateTime.now();
    const int testIntervalSec = 15;
    const int evalDelaySec = 15;

    // If a test is in progress, see if it's time to evaluate
    if (_testInProgress) {
      if (_testStartTime != null &&
          now.difference(_testStartTime!).inSeconds >= evalDelaySec) {
        _evaluateTest();
      }
      return;
    }

    // No test in progress: see if it's time to start a new one
    if (_lastTestTime != null &&
        now.difference(_lastTestTime!).inSeconds < testIntervalSec) {
      return; // wait until interval elapsed
    }

    // If on plateau, only re-test if conditions changed enough
    if (_plateau && _plateauHr != null && _plateauVel != null) {
      final hrDiff = (hr - _plateauHr!).abs();
      final velDiff = (velocity - _plateauVel!).abs();
      if (hrDiff < 3.0 && velDiff < 1.0) {
        // Still in same state – stay in optimal plateau, no buzz
        _currentAdvice = "Optimal rhythm";
        return;
      } else {
        // Conditions changed (hill, pace, fatigue) – re-explore
        _plateau = false;
      }
    }

    // Decide direction to test: up or down
    String dir;
    const double deltaEps = 0.0003; // tiny efficiency difference

    if (_upCount + _downCount < 2) {
      // Early phase – alternate to explore both directions
      if (_testDirection == "up") {
        dir = "down";
      } else {
        dir = "up";
      }
    } else {
      // Use whichever direction tends to improve efficiency
      if (_avgUpDelta > _avgDownDelta + deltaEps) {
        dir = "up";
      } else if (_avgDownDelta > _avgUpDelta + deltaEps) {
        dir = "down";
      } else {
        // Both similar – alternate
        if (_testDirection == "up") {
          dir = "down";
        } else {
          dir = "up";
        }
      }
    }

    _startTest(dir);
  }

  void _startTest(String dir) {
    _testInProgress = true;
    _testDirection = dir;
    _testStartTime = DateTime.now();
    _lastTestTime = _testStartTime;

    _effBeforeTest = efficiency;
    _hrBeforeTest = hr;
    _velBeforeTest = velocity;

    if (dir == "up") {
      _currentAdvice = "Increase rhythm";
      _vibrateUp(); // 2 buzzes
    } else {
      _currentAdvice = "Ease rhythm";
      _vibrateDown(); // 1 buzz
    }

    notifyListeners();
  }

  void _evaluateTest() {
    _testInProgress = false;

    if (_effBeforeTest == null || _hrBeforeTest == null) {
      return;
    }

    final effAfter = efficiency;
    final hrAfter = hr;
    final effDelta = effAfter - _effBeforeTest!;
    final hrDelta = hrAfter - _hrBeforeTest!;

    const double effEps = 0.0003;
    const double plateauHrEps = 1.0; // ~1 bpm as you requested

    // Plateau detection: change in HR and efficiency both tiny
    if (effDelta.abs() < effEps && hrDelta.abs() < plateauHrEps) {
      _plateau = true;
      _plateauHr = hrAfter;
      _plateauVel = velocity;
      _currentAdvice = "Optimal rhythm";
      notifyListeners();
      return;
    }

    // Not plateau – update stats for chosen direction
    if (_testDirection == "up") {
      _upCount++;
      _avgUpDelta =
          ((_avgUpDelta * (_upCount - 1)) + effDelta) / _upCount;
    } else if (_testDirection == "down") {
      _downCount++;
      _avgDownDelta =
          ((_avgDownDelta * (_downCount - 1)) + effDelta) / _downCount;
    }

    // Advice stays as last prompt; plateau state will suppress future tests
    notifyListeners();
  }

  void _vibrateUp() {
    // 2 short buzzes
    Vibration.vibrate(pattern: [0, 120, 100, 120]);
  }

  void _vibrateDown() {
    // 1 short buzz
    Vibration.vibrate(duration: 120);
  }

  // ---------- Public getters for UI ----------

  String get rhythmAdvice {
    if (!recording) return "Tap ▶ to start workout";
    return _currentAdvice;
  }

  Color get rhythmColor {
    if (!recording) return Colors.grey;
    if (_currentAdvice == "Optimal rhythm") return Colors.green;
    if (_currentAdvice == "Learning rhythm...") return Colors.grey;
    return Colors.orange;
  }
}

// ============================================================
// BLE MANAGER
// ============================================================

class BleManager extends ChangeNotifier {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  final Uuid hrService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid hrMeasurement =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _hrSub;

  String? connectedId;
  String? connectedName;
  bool scanning = false;

  Future<void> ensurePermissions() async {
    await Permission.locationWhenInUse.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
  }

  Future<List<DiscoveredDevice>> scanDevices(
      {Duration timeout = const Duration(seconds: 5)}) async {
    await ensurePermissions();
    final List<DiscoveredDevice> devices = [];
    _scanSub?.cancel();
    scanning = true;
    notifyListeners();

    final completer = Completer<List<DiscoveredDevice>>();

    _scanSub = _ble.scanForDevices(withServices: []).listen((device) {
      if (!devices.any((d) => d.id == device.id)) {
        devices.add(device);
        notifyListeners();
      }
    }, onError: (_) {
      if (!completer.isCompleted) completer.complete(devices);
    });

    Future.delayed(timeout, () async {
      await _scanSub?.cancel();
      scanning = false;
      notifyListeners();
      if (!completer.isCompleted) completer.complete(devices);
    });

    return completer.future;
  }

  Future<void> connect(String id, String name, OptimiserState opt) async {
    _connSub?.cancel();
    _hrSub?.cancel();

    _connSub = _ble.connectToDevice(id: id).listen((event) {
      if (event.connectionState == DeviceConnectionState.connected) {
        connectedId = id;
        connectedName = name.isEmpty ? "(unknown)" : name;
        notifyListeners();

        final hrChar = QualifiedCharacteristic(
          deviceId: id,
          serviceId: hrService,
          characteristicId: hrMeasurement,
        );

        _hrSub =
            _ble.subscribeToCharacteristic(hrChar).listen((data) {
          // Basic HR parsing: 2nd byte is bpm when 8-bit format
          if (data.length > 1) opt.setHr(data[1].toDouble());
        });
      } else if (event.connectionState ==
          DeviceConnectionState.disconnected) {
        connectedId = null;
        connectedName = null;
        notifyListeners();
      }
    }, onError: (_) {
      connectedId = null;
      connectedName = null;
      notifyListeners();
    });
  }

  Future<void> disconnect() async {
    await _hrSub?.cancel();
    await _connSub?.cancel();
    connectedId = null;
    connectedName = null;
    notifyListeners();
  }
}

// ============================================================
// DASHBOARD UI
// ============================================================

class OptimiserDashboard extends StatefulWidget {
  const OptimiserDashboard({super.key});
  @override
  State<OptimiserDashboard> createState() =>
      _OptimiserDashboardState();
}

class _OptimiserDashboardState extends State<OptimiserDashboard> {
  Position? _lastPosition;
  StreamSubscription<Position>? _posSub;

  @override
  void initState() {
    super.initState();
    _initPermissions();
    _startGPS();
  }

  Future<void> _initPermissions() async {
    await Geolocator.requestPermission();
    await Permission.locationWhenInUse.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
  }

  void _startGPS() {
    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
      ),
    ).listen((pos) {
      final opt = context.read<OptimiserState>();

      if (_lastPosition != null &&
          pos.timestamp != null &&
          _lastPosition!.timestamp != null) {
        final dt = pos.timestamp!
                .difference(_lastPosition!.timestamp!)
                .inMilliseconds /
            1000.0;

        // Ignore weird or too-fast / too-slow updates
        if (dt >= 0.5 && dt <= 5) {
          final dist = Geolocator.distanceBetween(
            _lastPosition!.latitude,
            _lastPosition!.longitude,
            pos.latitude,
            pos.longitude,
          );

          // Ignore big jumps (GPS glitches), e.g. >20m in one step
          if (dist <= 20) {
            final v = dist / dt; // m/s
            opt.setVelocity(v);
          }
        }
      }

      _lastPosition = pos;
    });
  }

  Future<void> _showBleSheet() async {
    final ble = context.read<BleManager>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return ChangeNotifierProvider.value(
          value: ble,
          child: const _BleBottomSheet(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final opt = context.watch<OptimiserState>();
    final ble = context.watch<BleManager>();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            ble.connectedId == null
                ? Icons.bluetooth
                : Icons.bluetooth_connected,
          ),
          tooltip: ble.connectedName == null
              ? 'Bluetooth devices'
              : 'Connected: ${ble.connectedName}',
          onPressed: _showBleSheet,
        ),
        title: const Text("Physiological Optimiser"),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            opt.rhythmAdvice,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: opt.rhythmColor,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text("HR: ${opt.hr.toStringAsFixed(0)} bpm"),
          Text("Velocity: ${opt.velocity.toStringAsFixed(2)} km/h"),
          Text(
              "Efficiency: ${opt.efficiency.toStringAsFixed(3)} km/h per bpm"),
          const SizedBox(height: 20),
          SizedBox(height: 200, child: EfficiencyGraph(opt: opt)),
          const SizedBox(height: 12),
          if (ble.connectedName != null)
            Text(
              "Connected to: ${ble.connectedName}",
              style: const TextStyle(
                  fontSize: 12, color: Colors.black54),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor:
            opt.recording ? Colors.red : Colors.green,
        child: Icon(
            opt.recording ? Icons.stop : Icons.play_arrow),
        onPressed: () => opt.toggleRecording(),
      ),
    );
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }
}

// ============================================================
// BLE BOTTOM SHEET
// ============================================================

class _BleBottomSheet extends StatefulWidget {
  const _BleBottomSheet();

  @override
  State<_BleBottomSheet> createState() =>
      _BleBottomSheetState();
}

class _BleBottomSheetState extends State<_BleBottomSheet> {
  List<DiscoveredDevice> devices = [];

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    final ble = context.read<BleManager>();
    devices = await ble.scanDevices();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleManager>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth),
                const SizedBox(width: 8),
                Text(
                  ble.scanning
                      ? "Scanning for devices…"
                      : "Bluetooth devices",
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (ble.connectedId != null)
                  IconButton(
                    tooltip: 'Disconnect',
                    icon: const Icon(Icons.link_off),
                    onPressed: () => ble.disconnect(),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: devices.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        "No devices found yet.\n"
                        "Ensure your HR strap is powered on.",
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.separated(
                      itemCount: devices.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final d = devices[i];
                        final name =
                            d.name.isNotEmpty ? d.name : "(unknown)";
                        return ListTile(
                          leading: const Icon(Icons.watch),
                          title: Text(name),
                          subtitle: Text(d.id),
                          trailing:
                              const Icon(Icons.chevron_right),
                          onTap: () async {
                            final opt =
                                context.read<OptimiserState>();
                            await ble.connect(d.id, name, opt);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _startScan,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Rescan"),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Close"),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// LIVE EFFICIENCY GRAPH (RECENT ONLY)
// ============================================================

class EfficiencyGraph extends StatelessWidget {
  final OptimiserState opt;
  const EfficiencyGraph({super.key, required this.opt});

  @override
  Widget build(BuildContext context) {
    final points = opt.recentEff
        .asMap()
        .entries
        .map((e) =>
            FlSpot(e.key.toDouble(), e.value["eff"] as double))
        .toList();

    return LineChart(
      LineChartData(
        minX: 0,
        maxX:
            points.isEmpty ? 1 : points.length.toDouble(),
        minY: 0,
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: true,
            dotData: FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: Colors.blue.withOpacity(0.2),
            ),
          ),
        ],
      ),
    );
  }
}
