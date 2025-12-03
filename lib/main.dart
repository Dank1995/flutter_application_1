import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'models/eff_sample.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  Hive.registerAdapter(EffSampleAdapter());
  await Hive.openBox<EffSample>('efficiencyBox');

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => RideState()),
        Provider(create: (_) => BleManager()),
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
      title: 'PhysiologicalOptimiser',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const RideDashboard(),
    );
  }
}

// -----------------------------------------------------------
// Core Optimiser State
// -----------------------------------------------------------
class RideState extends ChangeNotifier {
  int hr = 0;
  double velocity = 0.0;
  double efficiency = 0.0;
  double optimalVelocity = 0.0;
  bool recording = false;

  final int windowSize = 10;
  final List<Map<String, dynamic>> recentEff = [];
  final Box<EffSample> _effBox = Hive.box<EffSample>('efficiencyBox');

  // BLE + GPS tracking
  Stream<Position>? _posStream;
  StreamSubscription<Position>? _posSub;

  void startRecording() async {
    if (recording) return;
    recording = true;

    // GPS permission
    final perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) return;

    _posStream = Geolocator.getPositionStream(
      locationSettings:
          const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 1),
    );

    _posSub = _posStream!.listen((pos) {
      velocity = pos.speed; // m/s
      _updateEfficiency();
    });

    notifyListeners();
  }

  void stopRecording() {
    recording = false;
    _posSub?.cancel();
    notifyListeners();
  }

  void setHr(int value) {
    hr = value;
    _updateEfficiency();
  }

  void _updateEfficiency() {
    if (!recording || hr <= 0) return;

    efficiency = velocity / hr;
    final promptNow = shiftMessage;

    recentEff.add({
      "velocity": velocity,
      "efficiency": efficiency,
      "prompt": promptNow,
    });
    if (recentEff.length > windowSize) recentEff.removeAt(0);

    if (efficiency > 0) {
      _effBox.add(EffSample(DateTime.now(), efficiency, velocity.round(), promptNow));
    }

    optimalVelocity = _computeOptimalVelocity();
    notifyListeners();
  }

  // ---------- Compute Optimal Efficiency Zone ----------
  double _computeOptimalVelocity() {
    final short = _shortTermBestVelocity();
    final monthly = _monthlyBestVelocity();

    if (short == null && monthly == null) return 3.0;
    if (short == null) return monthly!;
    if (monthly == null) return short;

    // Blend 60% short-term, 40% monthly
    return (short * 0.6) + (monthly * 0.4);
  }

  double? _shortTermBestVelocity() {
    if (recentEff.isEmpty) return null;
    final buckets = <int, List<double>>{};
    for (final e in recentEff) {
      final v = e["velocity"].round();
      final eff = e["efficiency"] as double;
      buckets.putIfAbsent(v, () => []).add(eff);
    }

    int? bestV;
    double bestEff = -1;
    buckets.forEach((v, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        bestV = v;
      }
    });
    return bestV?.toDouble();
  }

  double? _monthlyBestVelocity() {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    final samples = _effBox.values.where((e) => e.time.isAfter(cutoff)).toList();
    if (samples.isEmpty) return null;

    final buckets = <int, List<double>>{};
    for (final s in samples) {
      buckets.putIfAbsent(s.cadence, () => []).add(s.efficiency);
    }

    int? bestV;
    double bestEff = -1;
    buckets.forEach((v, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        bestV = v;
      }
    });
    return bestV?.toDouble();
  }

  List<EffSample> get last30DaySamples {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    return _effBox.values
        .where((e) => e.time.isAfter(cutoff))
        .toList()
      ..sort((a, b) => a.time.compareTo(b.time));
  }

  // ---------- Prompt Logic ----------
  String get shiftMessage {
    final diff = velocity - optimalVelocity;
    if (diff.abs() < 0.2) return "Rhythm Optimal";
    return diff > 0 ? "Ease Rhythm" : "Increase Rhythm";
  }

  Color get alertColor {
    final diff = velocity - optimalVelocity;
    if (diff.abs() < 0.2) return Colors.green;
    return diff > 0 ? Colors.redAccent : Colors.orange;
  }
}

// -----------------------------------------------------------
// BLE HR Manager
// -----------------------------------------------------------
class BleManager {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final Uuid heartRateService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid heartRateMeasurement =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  Stream<List<DiscoveredDevice>> scan() {
    final devices = <DiscoveredDevice>[];
    return _ble.scanForDevices(withServices: []).map((d) {
      if (!devices.any((x) => x.id == d.id)) devices.add(d);
      return devices;
    });
  }

  Future<void> connect(String deviceId, RideState ride) async {
    _ble.connectToDevice(id: deviceId).listen((update) {
      if (update.connectionState == DeviceConnectionState.connected) {
        final hrChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: heartRateService,
          characteristicId: heartRateMeasurement,
        );
        _ble.subscribeToCharacteristic(hrChar).listen((data) {
          if (data.length > 1) ride.setHr(data[1]);
        });
      }
    });
  }
}

// -----------------------------------------------------------
// Ride Dashboard
// -----------------------------------------------------------
class RideDashboard extends StatelessWidget {
  const RideDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Physiological Optimiser"),
        actions: [
          IconButton(
            icon: const Icon(Icons.show_chart),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const MonthlyEfficiencyPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.bluetooth_searching),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BleScannerPage()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 2,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    ride.shiftMessage,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: ride.alertColor,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text("Velocity: ${ride.velocity.toStringAsFixed(2)} m/s"),
                  Text("Heart Rate: ${ride.hr} BPM"),
                  Text("Efficiency: ${ride.efficiency.toStringAsFixed(3)} v/BPM"),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed:
                        ride.recording ? ride.stopRecording : ride.startRecording,
                    child: Text(ride.recording ? "Stop" : "Start Workout"),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: EfficiencyGraph(ride: ride),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------
// Graph of Recent Efficiency
// -----------------------------------------------------------
class EfficiencyGraph extends StatelessWidget {
  final RideState ride;
  const EfficiencyGraph({super.key, required this.ride});

  @override
  Widget build(BuildContext context) {
    final eff = ride.recentEff;
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: eff.isEmpty ? 1 : eff.length.toDouble(),
          minY: 0,
          maxY: eff.isEmpty
              ? 2
              : eff.map((e) => e["efficiency"] as double).reduce((a, b) => a > b ? a : b) + 1,
          lineBarsData: [
            LineChartBarData(
              spots: eff
                  .asMap()
                  .entries
                  .map((e) => FlSpot(e.key.toDouble(), e.value["efficiency"]))
                  .toList(),
              isCurved: true,
              color: Colors.green,
              barWidth: 3,
              dotData: FlDotData(show: false),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------
// BLE Scanner Page
// -----------------------------------------------------------
class BleScannerPage extends StatefulWidget {
  const BleScannerPage({super.key});
  @override
  State<BleScannerPage> createState() => _BleScannerPageState();
}

class _BleScannerPageState extends State<BleScannerPage> {
  late Stream<List<DiscoveredDevice>> scanStream;

  @override
  void initState() {
    super.initState();
    final ble = context.read<BleManager>();
    scanStream = ble.scan();
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.read<BleManager>();
    final ride = context.read<RideState>();
    return Scaffold(
      appBar: AppBar(title: const Text("Scan & Connect")),
      body: StreamBuilder<List<DiscoveredDevice>>(
        stream: scanStream,
        builder: (context, snapshot) {
          final devices = snapshot.data ?? [];
          return ListView.builder(
            itemCount: devices.length,
            itemBuilder: (context, index) {
              final d = devices[index];
              return ListTile(
                title: Text(d.name.isEmpty ? "Unknown" : d.name),
                subtitle: Text(d.id),
                onTap: () {
                  ble.connect(d.id, ride);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Connecting to ${d.name}")),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

// -----------------------------------------------------------
// 30-day Efficiency Graph
// -----------------------------------------------------------
class MonthlyEfficiencyPage extends StatelessWidget {
  const MonthlyEfficiencyPage({super.key});
  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();
    final samples = ride.last30DaySamples;

    return Scaffold(
      appBar: AppBar(title: const Text("30-Day Efficiency")),
      body: samples.isEmpty
          ? const Center(
              child: Text("No data yet. Do some workouts first!"),
            )
          : Padding(
              padding: const EdgeInsets.all(8.0),
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: (samples.length - 1).toDouble(),
                  minY: 0,
                  maxY: samples
                          .map((e) => e.efficiency)
                          .reduce((a, b) => a > b ? a : b) +
                      1,
                  lineBarsData: [
                    LineChartBarData(
                      spots: samples
                          .asMap()
                          .entries
                          .map((e) => FlSpot(
                              e.key.toDouble(), e.value.efficiency))
                          .toList(),
                      isCurved: true,
                      color: Colors.blue,
                      barWidth: 3,
                      dotData: FlDotData(show: false),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
