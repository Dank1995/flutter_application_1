import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:hive_flutter/hive_flutter.dart';

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

//
// RIDE STATE — OPTIMISER + GPS + HR + HISTORY
//
class RideState extends ChangeNotifier {
  int hr = 0;
  double velocity = 0; // m/s
  double efficiency = 0;

  bool workoutActive = false;

  final List<Map<String, dynamic>> recentEff = [];
  final int windowSize = 10;

  // Learned optimal velocity efficiency zone (proxy for cadence)
  double optimalVelocity = 3.0; // m/s default (~10.8 km/h running)

  final List<String> gpsLog = [];
  final List<String> hrLog = [];

  Stream<Position>? gpsStream;

  final Box<EffSample> _effBox = Hive.box<EffSample>('efficiencyBox');

  void startWorkout() {
    workoutActive = true;
    gpsLog.clear();
    hrLog.clear();
    listenToGPS();
    notifyListeners();
  }

  void stopWorkout() {
    workoutActive = false;
    gpsStream = null;
    notifyListeners();
  }

  void setHr(int value) {
    hr = value;
    hrLog.add("$value BPM");
    _updateEfficiency();
  }

  void setVelocity(double v) {
    velocity = v;
    gpsLog.add("${v.toStringAsFixed(2)} m/s");
    _updateEfficiency();
  }

  void _updateEfficiency() {
    if (hr > 0 && velocity > 0) {
      efficiency = velocity / hr;

      recentEff.add({"v": velocity, "eff": efficiency});
      if (recentEff.length > windowSize) recentEff.removeAt(0);

      // Save monthly history
      _effBox.add(
        EffSample(DateTime.now(), efficiency, velocity.round()),
      );

      optimalVelocity = _computeOptimalVelocity();
    }
    notifyListeners();
  }

  double _computeOptimalVelocity() {
    final shortTerm = _shortTermBestVelocity();
    final monthly = _monthlyBestVelocity();

    if (shortTerm == null && monthly == null) return 3.0;
    if (shortTerm == null) return monthly!;
    if (monthly == null) return shortTerm;

    return (shortTerm * 0.6 + monthly * 0.4);
  }

  double? _shortTermBestVelocity() {
    if (recentEff.isEmpty) return null;

    final Map<int, List<double>> buckets = {};
    for (var e in recentEff) {
      int vBucket = e["v"].round();
      buckets.putIfAbsent(vBucket, () => []).add(e["eff"]);
    }

    double bestEff = -1;
    int? bestV;

    buckets.forEach((v, list) {
      double avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        bestV = v;
      }
    });

    return bestV?.toDouble();
  }

  double? _monthlyBestVelocity() {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    final samples =
        _effBox.values.where((e) => e.time.isAfter(cutoff)).toList();

    if (samples.isEmpty) return null;

    final Map<int, List<double>> buckets = {};
    for (final s in samples) {
      buckets.putIfAbsent(s.cadence, () => []).add(s.efficiency);
    }

    double bestEff = -1;
    int? bestV;

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

  String get guidance {
    final diff = velocity - optimalVelocity;

    if (diff.abs() > 0.5) {
      return diff > 0
          ? "Slow slightly → Target ${optimalVelocity.toStringAsFixed(1)} m/s"
          : "Speed up → Target ${optimalVelocity.toStringAsFixed(1)} m/s";
    }
    return "Velocity optimal ✔";
  }

  void listenToGPS() async {
    final perm = await Permission.locationWhenInUse.request();
    if (!perm.isGranted) return;

    gpsStream = Geolocator.getPositionStream();
    gpsStream?.listen((pos) {
      if (!workoutActive) return;
      setVelocity(pos.speed); // m/s
    });
  }
}

//
// BLE HEART RATE ONLY
//
class BleManager {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final Uuid hrService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid hrMeasurement =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  Stream<List<DiscoveredDevice>> scan() {
    final devices = <DiscoveredDevice>[];
    return _ble.scanForDevices(withServices: []).map((d) {
      if (!devices.any((x) => x.id == d.id)) devices.add(d);
      return devices;
    });
  }

  Future<void> connect(String id, RideState ride) async {
    _ble.connectToDevice(id: id).listen((update) {
      if (update.connectionState == DeviceConnectionState.connected) {
        final hrChar = QualifiedCharacteristic(
          deviceId: id,
          serviceId: hrService,
          characteristicId: hrMeasurement,
        );

        _ble.subscribeToCharacteristic(hrChar).listen((data) {
          if (data.length > 1) {
            ride.setHr(data[1]);
          }
        });
      }
    });
  }
}

//
// UI
//
class RideDashboard extends StatefulWidget {
  const RideDashboard({super.key});
  @override
  State<RideDashboard> createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  @override
  void initState() {
    super.initState();
    Permission.locationWhenInUse.request();
    Permission.bluetoothConnect.request();
    Permission.bluetoothScan.request();
  }

  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Optimiser Dashboard"),
        actions: [
          IconButton(
            icon: const Icon(Icons.list),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const WorkoutHistoryPage()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.bluetooth_searching),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BleScannerPage()),
              );
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: ride.workoutActive ? Colors.red : Colors.green,
        child: Icon(ride.workoutActive ? Icons.stop : Icons.play_arrow),
        onPressed: () {
          ride.workoutActive ? ride.stopWorkout() : ride.startWorkout();
        },
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
                    ride.guidance,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text("Velocity: ${ride.velocity.toStringAsFixed(2)} m/s"),
                  Text("HR: ${ride.hr} BPM"),
                  Text("Efficiency: ${ride.efficiency.toStringAsFixed(3)}"),
                ],
              ),
            ),
          ),

          Expanded(
            flex: 1,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: ride.recentEff.length.toDouble(),
                minY: 0,
                maxY: ride.recentEff.isEmpty
                    ? 1
                    : ride.recentEff
                            .map((e) => e["eff"] as double)
                            .reduce((a, b) => a > b ? a : b) +
                        0.5,
                lineBarsData: [
                  LineChartBarData(
                    spots: ride.recentEff
                        .asMap()
                        .entries
                        .map((e) => FlSpot(
                              e.key.toDouble(),
                              e.value["eff"],
                            ))
                        .toList(),
                    isCurved: true,
                    color: Colors.green,
                    barWidth: 3,
                    dotData: FlDotData(show: false),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

//
// BLE SCANNER
//
class BleScannerPage extends StatefulWidget {
  const BleScannerPage({super.key});
  @override
  State<BleScannerPage> createState() => _BleScannerPageState();
}

class _BleScannerPageState extends State<BleScannerPage> {
  @override
  Widget build(BuildContext context) {
    final ble = context.read<BleManager>();
    final ride = context.read<RideState>();

    return Scaffold(
      appBar: AppBar(title: const Text("Scan for HR Straps")),
      body: StreamBuilder<List<DiscoveredDevice>>(
        stream: ble.scan(),
        builder: (context, snapshot) {
          final list = snapshot.data ?? [];
          return ListView.builder(
            itemCount: list.length,
            itemBuilder: (_, i) {
              final d = list[i];
              return ListTile(
                title: Text(d.name.isNotEmpty ? d.name : "Unknown"),
                subtitle: Text(d.id),
                onTap: () {
                  ble.connect(d.id, ride);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text("Connecting to ${d.name}"),
                    ),
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

//
// WORKOUT HISTORY (GPS + HR logs)
//
class WorkoutHistoryPage extends StatelessWidget {
  const WorkoutHistoryPage({super.key});
  @override
  Widget build(BuildContext context) {
    final ride = context.watch<RideState>();

    return Scaffold(
      appBar: AppBar(title: const Text("Workout Logs")),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text("GPS Log:", style: TextStyle(fontSize: 18)),
          ),
          ...ride.gpsLog.map((e) => ListTile(title: Text(e))),

          const Padding(
            padding: EdgeInsets.all(8),
            child: Text("HR Log:", style: TextStyle(fontSize: 18)),
          ),
          ...ride.hrLog.map((e) => ListTile(title: Text(e))),
        ],
      ),
    );
  }
}
