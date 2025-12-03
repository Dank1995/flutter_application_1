import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'models/eff_sample.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  Hive.registerAdapter(EffSampleAdapter());
  await Hive.openBox<EffSample>('efficiencyBox');

  final opt = OptimiserState();
  await opt.loadTarget();

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
// STATE
// ============================================================

class OptimiserState extends ChangeNotifier {
  double hr = 0;
  double velocity = 0; // km/h (smoothed)
  double efficiency = 0; // km/h per bpm
  bool recording = false;

  final Box<EffSample> _effBox = Hive.box<EffSample>('efficiencyBox');
  final List<Map<String, dynamic>> recentEff = [];

  int rhythmTargetBucket = 0;
  String? rhythmTargetPrompt;

  // Smoothed velocity internals
  double _smoothVelocity = 0;
  static const double _alpha = 0.15; // Garmin-ish: very smooth

  void toggleRecording() {
    recording = !recording;
    notifyListeners();
  }

  void setHr(double bpm) {
    if (bpm <= 0 || bpm.isNaN) return;
    hr = bpm;
    _updateEfficiency();
  }

  /// mps = metres per second from GPS
  void setVelocity(double mps) {
    double v = mps * 3.6; // convert to km/h

    // Basic sanity checks
    if (v.isNaN || v.isInfinite || v < 0) return;

    // Hard cap for realistic running speeds; ignore insane spikes
    if (v > 25) {
      // treat as a glitch: do not update velocity at all
      _updateEfficiency();
      return;
    }

    // Exponential Moving Average smoothing
    if (_smoothVelocity == 0) {
      _smoothVelocity = v;
    } else {
      _smoothVelocity = (_alpha * v) + ((1 - _alpha) * _smoothVelocity);
    }

    velocity = _smoothVelocity;
    _updateEfficiency();
  }

  Future<void> loadTarget() async {
    if (_effBox.isNotEmpty) {
      rhythmTargetBucket = _computeOptimalBucket();
      rhythmTargetPrompt = _computeOptimalPrompt();
      notifyListeners();
    }
  }

  void _updateEfficiency() {
    if (!recording || hr <= 0 || velocity <= 0) return;

    efficiency = velocity / hr;
    recentEff.add({
      "eff": efficiency,
      "vel": velocity,
      "time": DateTime.now(),
    });
    if (recentEff.length > 15) recentEff.removeAt(0);

    final rhythm = (efficiency * 100).round();
    final currentPrompt = _computeAdaptivePrompt(rhythm.toDouble());

    _effBox.add(EffSample(DateTime.now(), efficiency, rhythm, currentPrompt));

    rhythmTargetBucket = _computeOptimalBucket();
    rhythmTargetPrompt = _computeOptimalPrompt();
    notifyListeners();
  }

  int _computeOptimalBucket() {
    final now = DateTime.now();
    final samples = _effBox.values
        .where((e) => e.time.isAfter(now.subtract(const Duration(days: 30))))
        .toList();
    if (samples.isEmpty) return 0;

    final Map<int, List<double>> buckets = {};
    for (final s in samples) {
      buckets.putIfAbsent(s.rhythm, () => []).add(s.efficiency);
    }

    int? best;
    double bestEff = -1;
    buckets.forEach((r, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        best = r;
      }
    });
    return best ?? 0;
  }

  String? _computeOptimalPrompt() {
    final now = DateTime.now();
    final samples = _effBox.values
        .where((e) => e.time.isAfter(now.subtract(const Duration(days: 30))))
        .toList();
    if (samples.isEmpty) return null;

    final Map<String, List<double>> prompts = {};
    for (final s in samples) {
      prompts.putIfAbsent(s.prompt, () => []).add(s.efficiency);
    }

    String? bestPrompt;
    double bestEff = -1;
    prompts.forEach((p, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        bestPrompt = p;
      }
    });
    return bestPrompt;
  }

  String _computeAdaptivePrompt(double current) {
    if (rhythmTargetBucket == 0) return "Learning rhythm...";
    if (current < rhythmTargetBucket - 1) return "Increase rhythm";
    if (current > rhythmTargetBucket + 1) return "Ease rhythm";
    return "Optimal rhythm";
  }

  String get rhythmAdvice {
    if (!recording) return "Tap ▶ to start workout";
    return rhythmTargetPrompt ?? "Learning rhythm...";
  }

  Color get rhythmColor {
    if (!recording) return Colors.grey;
    if (rhythmAdvice == "Optimal rhythm") return Colors.green;
    return Colors.orange;
  }

  List<EffSample> get last30Days {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    return _effBox.values
        .where((e) => e.time.isAfter(cutoff))
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));
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

        _hrSub = _ble.subscribeToCharacteristic(hrChar).listen((data) {
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

        // Ignore weird or too-fast updates
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
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '30-day history',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const EfficiencyHistory()),
              );
            },
          ),
        ],
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
// BLE BOTTOM SHEET (NO DOUBLE SCANS)
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
                          trailing: const Icon(Icons.chevron_right),
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
// GRAPHS + HISTORY
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
            FlSpot(e.key.toDouble(), e.value["eff"]))
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

class EfficiencyHistory extends StatelessWidget {
  const EfficiencyHistory({super.key});
  @override
  Widget build(BuildContext context) {
    final opt = context.watch<OptimiserState>();
    final data = opt.last30Days;

    final points = data
        .asMap()
        .entries
        .map((e) =>
            FlSpot(e.key.toDouble(), e.value.efficiency))
        .toList();

    return Scaffold(
      appBar: AppBar(
          title: const Text("30-Day Efficiency History")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: LineChart(
          LineChartData(
            minX: 0,
            maxX:
                points.isEmpty ? 1 : points.length.toDouble(),
            minY: 0,
            lineBarsData: [
              LineChartBarData(
                spots: points,
                isCurved: true,
                color: Colors.orange,
                belowBarData: BarAreaData(
                  show: true,
                  color: Colors.orange.withOpacity(0.2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
