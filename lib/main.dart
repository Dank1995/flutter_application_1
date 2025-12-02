// lib/main.dart
import 'dart:async';
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

// -----------------------------
// App
// -----------------------------
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

// -----------------------------
// Ride State: GPS + HR + Optimiser
// -----------------------------
class RideState extends ChangeNotifier {
  RideState() : _effBox = Hive.box<EffSample>('efficiencyBox');

  // Physiological + mechanical inputs
  int hr = 0; // BPM
  double speedMps = 0.0; // m/s
  double efficiency = 0.0; // m/s per BPM (velocity / HR)

  // Optimiser state
  final int windowSize = 10;
  final List<Map<String, dynamic>> recentEff = [];
  int optimalCadence = 90; // recommended cadence
  bool isWorkoutActive = false;

  final Box<EffSample> _effBox;

  // -------- Derived metrics ----------
  double get speedKmh => speedMps * 3.6;

  String get paceLabel {
    if (speedMps <= 0) return "--";
    final secondsPerKm = 1000.0 / speedMps;
    final minutes = secondsPerKm ~/ 60;
    final seconds = (secondsPerKm % 60).round();
    return "${minutes.toString().padLeft(1, '0')}:${seconds.toString().padLeft(2, '0')} /km";
  }

  String get efficiencyLabel =>
      (efficiency > 0) ? efficiency.toStringAsFixed(3) : "--";

  String get cadenceMessage => "Aim for ~${optimalCadence} RPM";

  Color get cadenceColor => Colors.green;

  // -------- Workout control ----------
  void startWorkout() {
    isWorkoutActive = true;
    recentEff.clear();
    notifyListeners();
  }

  void stopWorkout() {
    isWorkoutActive = false;
    speedMps = 0;
    efficiency = 0;
    notifyListeners();
  }

  // -------- Setters from sensors ----------
  void setHr(int value) {
    hr = value;
    _updateEfficiency();
  }

  void setSpeed(double mps) {
    speedMps = mps;
    _updateEfficiency();
  }

  // -------- Efficiency + learning ----------
  void _updateEfficiency() {
    if (!isWorkoutActive) {
      efficiency = 0;
      notifyListeners();
      return;
    }

    if (hr > 0 && speedMps > 0) {
      efficiency = speedMps / hr;

      // Short-term rolling window
      recentEff.add({
        "cadence": optimalCadence,
        "efficiency": efficiency,
      });
      if (recentEff.length > windowSize) recentEff.removeAt(0);

      // Store to Hive (monthly learning)
      _effBox.add(
        EffSample(DateTime.now(), efficiency, optimalCadence),
      );

      // Recompute optimal cadence from short-term + monthly
      optimalCadence = _computeOptimalCadence();
    }

    notifyListeners();
  }

  int _computeOptimalCadence() {
    final shortTerm = _shortTermBestCadence();
    final monthly = _monthlyBestCadence();

    if (shortTerm == null && monthly == null) return 90;
    if (monthly == null) return shortTerm!;
    if (shortTerm == null) return monthly;

    // 60% weight short-term (fast response), 40% monthly (deep physiology)
    return ((shortTerm * 0.6) + (monthly * 0.4)).round();
  }

  int? _shortTermBestCadence() {
    if (recentEff.isEmpty) return null;

    final Map<int, List<double>> buckets = {};
    for (var e in recentEff) {
      final cad = e["cadence"] as int;
      final eff = e["efficiency"] as double;
      buckets.putIfAbsent(cad, () => []).add(eff);
    }

    int? bestCad;
    double bestEff = -1;
    buckets.forEach((cad, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        bestCad = cad;
      }
    });

    return bestCad;
  }

  int? _monthlyBestCadence() {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 30));
    final samples =
        _effBox.values.where((e) => e.time.isAfter(cutoff)).toList();
    if (samples.isEmpty) return null;

    final Map<int, List<double>> byCadence = {};
    for (final s in samples) {
      byCadence.putIfAbsent(s.cadence, () => []).add(s.efficiency);
    }

    int? bestCad;
    double bestEff = -1;
    byCadence.forEach((cad, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        bestCad = cad;
      }
    });

    return bestCad;
  }

  // expose last 30 days for graph
  List<EffSample> get last30DaySamples {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 30));
    final list =
        _effBox.values.where((e) => e.time.isAfter(cutoff)).toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    return list;
  }
}

// -----------------------------
// BLE Manager: HR strap only
// -----------------------------
class BleManager {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final Uuid heartRateService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid heartRateMeasurement =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  Stream<List<DiscoveredDevice>> scan() {
    final devices = <DiscoveredDevice>[];
    // Scan all; HR straps will appear here too
    return _ble.scanForDevices(withServices: []).map((d) {
      if (!devices.any((x) => x.id == d.id)) devices.add(d);
      return devices;
    });
  }

  Future<void> connectHr(String deviceId, RideState ride) async {
    _ble.connectToDevice(id: deviceId).listen((update) {
      if (update.connectionState == DeviceConnectionState.connected) {
        final hrChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: heartRateService,
          characteristicId: heartRateMeasurement,
        );

        _ble.subscribeToCharacteristic(hrChar).listen((data) {
          if (data.length <= 1) return;
          // Standard BLE HR format: flags in byte 0
          final flags = data[0];
          final hrIsUInt16 = (flags & 0x01) != 0;
          int hr;
          if (hrIsUInt16 && data.length > 2) {
            hr = (data[1] & 0xFF) | ((data[2] & 0xFF) << 8);
          } else {
            hr = data[1] & 0xFF;
          }
          ride.setHr(hr);
        });
      }
    }, onError: (e) {
      debugPrint("HR connection error: $e");
    });
  }
}

// -----------------------------
// Ride Dashboard
// -----------------------------
class RideDashboard extends StatefulWidget {
  const RideDashboard({super.key});
  @override
  State<RideDashboard> createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  StreamSubscription<Position>? _positionSub;
  Position? _lastPosition;

  @override
  void initState() {
    super.initState();
    _ensurePermissions();
  }

  Future<void> _ensurePermissions() async {
    await Permission.locationWhenInUse.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint("Location services are disabled.");
    }
  }

  Future<void> _startLocation(RideState ride) async {
    final permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      debugPrint("Location permission denied");
      return;
    }

    _positionSub?.cancel();
    _lastPosition = null;

    _positionSub = Geolocator.getPositionStream(
      desiredAccuracy: LocationAccuracy.best,
      distanceFilter: 5,
    ).listen((position) {
      double speed = position.speed; // m/s from OS
      if (speed <= 0 && _lastPosition != null && position.timestamp != null) {
        final last = _lastPosition!;
        if (last.timestamp != null) {
          final dt = position.timestamp!
                  .difference(last.timestamp!)
                  .inMilliseconds /
              1000.0;
          if (dt > 0) {
            final dist = Geolocator.distanceBetween(
              last.latitude,
              last.longitude,
              position.latitude,
              position.longitude,
            );
            speed = dist / dt;
          }
        }
      }
      _lastPosition = position;
      if (speed > 0) {
        ride.setSpeed(speed);
      }
    });
  }

  void _stopLocation(RideState ride) {
    _positionSub?.cancel();
    _positionSub = null;
    _lastPosition = null;
    ride.setSpeed(0);
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Physiological Optimiser"),
        actions: [
          IconButton(
            icon: const Icon(Icons.heart_broken),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BleScannerPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.show_chart),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const MonthlyEfficiencyPage()),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          final ride = context.read<RideState>();
          if (ride.isWorkoutActive) {
            ride.stopWorkout();
            _stopLocation(ride);
          } else {
            ride.startWorkout();
            _startLocation(ride);
          }
        },
        child: Icon(
          ride.isWorkoutActive ? Icons.stop : Icons.play_arrow,
        ),
      ),
      body: Column(
        children: [
          // Top: guidance + live metrics
          Expanded(
            flex: 2,
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    ride.cadenceMessage,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: ride.cadenceColor,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text("Heart Rate: ${ride.hr} BPM"),
                  Text("Speed: ${ride.speedKmh.toStringAsFixed(1)} km/h"),
                  Text("Pace: ${ride.paceLabel}"),
                  Text("Efficiency: ${ride.efficiencyLabel} (m/s per BPM)"),
                  const SizedBox(height: 8),
                  Text(
                    ride.isWorkoutActive
                        ? "Workout: ACTIVE"
                        : "Workout: NOT STARTED",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: ride.isWorkoutActive ? Colors.green : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Bottom: recent efficiency graph
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: ride.recentEff.isEmpty
                      ? 1
                      : (ride.recentEff.length - 1).toDouble(),
                  minY: 0,
                  maxY: ride.recentEff.isEmpty
                      ? 2
                      : ride.recentEff
                              .map((e) => e["efficiency"] as double)
                              .fold(0.0, (p, e) => e > p ? e : p) +
                          0.5,
                  lineBarsData: [
                    LineChartBarData(
                      spots: ride.recentEff
                          .asMap()
                          .entries
                          .map(
                            (e) => FlSpot(
                              e.key.toDouble(),
                              e.value["efficiency"] as double,
                            ),
                          )
                          .toList(),
                      isCurved: true,
                      barWidth: 3,
                      dotData: FlDotData(show: false),
                    ),
                  ],
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------
// BLE Scanner Page (HR straps)
// -----------------------------
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
      appBar: AppBar(title: const Text("Scan HR Monitors")),
      body: StreamBuilder<List<DiscoveredDevice>>(
        stream: scanStream,
        builder: (context, snapshot) {
          final devices = snapshot.data ?? [];
          if (devices.isEmpty) {
            return const Center(
              child: Text("Scanning...\nMove your HR strap to wake it up."),
            );
          }
          return ListView.builder(
            itemCount: devices.length,
            itemBuilder: (context, index) {
              final d = devices[index];
              final name = d.name.isNotEmpty ? d.name : "Unknown";
              return ListTile(
                title: Text(name),
                subtitle: Text(d.id),
                onTap: () {
                  ble.connectHr(d.id, ride);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Connecting to $name")),
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

// -----------------------------
// Monthly Efficiency Page
// -----------------------------
class MonthlyEfficiencyPage extends StatelessWidget {
  const MonthlyEfficiencyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();
    final samples = ride.last30DaySamples;

    return Scaffold(
      appBar: AppBar(title: const Text("Last 30 Days Efficiency")),
      body: samples.isEmpty
          ? const Center(
              child: Text(
                "No efficiency data yet.\nDo some workouts and come back!",
                textAlign: TextAlign.center,
              ),
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
                          .fold<double>(0, (p, e) => e > p ? e : p) +
                      0.5,
                  lineBarsData: [
                    LineChartBarData(
                      spots: samples
                          .asMap()
                          .entries
                          .map(
                            (e) => FlSpot(
                              e.key.toDouble(),
                              e.value.efficiency,
                            ),
                          )
                          .toList(),
                      isCurved: true,
                      barWidth: 3,
                      dotData: FlDotData(show: false),
                    ),
                  ],
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
