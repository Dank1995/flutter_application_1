import 'dart:async'; // 👈 Fixes StreamSubscription error
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

  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => OptimiserState()),
      Provider(create: (_) => BleManager()),
    ],
    child: const MyApp(),
  ));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Physiological Optimiser',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const OptimiserDashboard(),
    );
  }
}

class OptimiserState extends ChangeNotifier {
  double hr = 0;
  double velocity = 0;
  double efficiency = 0;
  bool recording = false;

  final Box<EffSample> _effBox = Hive.box<EffSample>('efficiencyBox');
  final List<Map<String, dynamic>> recentEff = [];

  int rhythmTargetBucket = 0;
  String? rhythmTargetPrompt;

  void toggleRecording() {
    recording = !recording;
    notifyListeners();
  }

  void setHr(double bpm) {
    hr = bpm;
    _updateEfficiency();
  }

  void setVelocity(double mps) {
    velocity = mps * 3.6; // convert to km/h
    _updateEfficiency();
  }

  void _updateEfficiency() {
    if (!recording || hr <= 0 || velocity <= 0) return;

    efficiency = velocity / hr;
    recentEff.add({"eff": efficiency, "vel": velocity, "time": DateTime.now()});
    if (recentEff.length > 15) recentEff.removeAt(0);

    final bucket = (efficiency * 100).round();
    final currentPrompt = rhythmAdvice;

    _effBox.add(EffSample(DateTime.now(), efficiency, bucket, currentPrompt));

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
      buckets.putIfAbsent(s.bucket, () => []).add(s.efficiency);
    }

    int? best;
    double bestEff = -1;
    buckets.forEach((v, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        best = v;
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

    final Map<String, List<double>> buckets = {};
    for (final s in samples) {
      buckets.putIfAbsent(s.prompt, () => []).add(s.efficiency);
    }

    String? bestPrompt;
    double bestEff = -1;
    buckets.forEach((prompt, list) {
      final avg = list.reduce((a, b) => a + b) / list.length;
      if (avg > bestEff) {
        bestEff = avg;
        bestPrompt = prompt;
      }
    });

    return bestPrompt;
  }

  String get rhythmAdvice {
    if (!recording) return "Tap ▶ to start workout";
    if (efficiency <= 0) return "Learning your rhythm...";
    if (rhythmTargetPrompt != null) return rhythmTargetPrompt!;

    final diff = velocity - rhythmTargetBucket;
    if (diff.abs() < 0.5) return "Optimal rhythm";
    return diff > 0 ? "Ease rhythm" : "Increase rhythm";
  }

  Color get rhythmColor {
    if (!recording) return Colors.grey;
    if (rhythmAdvice == "Optimal rhythm") return Colors.green;
    return Colors.orange;
  }

  List<EffSample> get last30Days {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    return _effBox.values.where((e) => e.time.isAfter(cutoff)).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
  }
}

class BleManager {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  final Uuid hrService = Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid hrMeasurement = Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  Future<void> connect(String id, OptimiserState opt) async {
    _ble.connectToDevice(id: id).listen((event) {
      if (event.connectionState == DeviceConnectionState.connected) {
        final hrChar = QualifiedCharacteristic(
          deviceId: id,
          serviceId: hrService,
          characteristicId: hrMeasurement,
        );
        _ble.subscribeToCharacteristic(hrChar).listen((data) {
          if (data.length > 1) opt.setHr(data[1].toDouble());
        });
      }
    });
  }

  Stream<List<DiscoveredDevice>> scan() {
    final devices = <DiscoveredDevice>[];
    return _ble.scanForDevices(withServices: []).map((d) {
      if (!devices.any((x) => x.id == d.id)) devices.add(d);
      return devices;
    });
  }
}

class OptimiserDashboard extends StatefulWidget {
  const OptimiserDashboard({super.key});
  @override
  State<OptimiserDashboard> createState() => _OptimiserDashboardState();
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
      if (_lastPosition != null) {
        final dt = pos.timestamp!
                .difference(_lastPosition!.timestamp!)
                .inMilliseconds /
            1000;
        if (dt > 0) {
          final dist = Geolocator.distanceBetween(
              _lastPosition!.latitude,
              _lastPosition!.longitude,
              pos.latitude,
              pos.longitude);
          opt.setVelocity(dist / dt);
        }
      }
      _lastPosition = pos;
    });
  }

  @override
  Widget build(BuildContext context) {
    final opt = context.watch<OptimiserState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text("Physiological Optimiser"),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const EfficiencyHistory()));
            },
          ),
        ],
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(opt.rhythmAdvice,
              style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: opt.rhythmColor)),
          const SizedBox(height: 10),
          Text("HR: ${opt.hr.toStringAsFixed(0)} bpm"),
          Text("Velocity: ${opt.velocity.toStringAsFixed(2)} km/h"),
          Text("Efficiency: ${opt.efficiency.toStringAsFixed(3)} km/h per bpm"),
          const SizedBox(height: 20),
          SizedBox(height: 200, child: EfficiencyGraph(opt: opt)),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: opt.recording ? Colors.red : Colors.green,
        child: Icon(opt.recording ? Icons.stop : Icons.play_arrow),
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

class EfficiencyGraph extends StatelessWidget {
  final OptimiserState opt;
  const EfficiencyGraph({super.key, required this.opt});

  @override
  Widget build(BuildContext context) {
    final points = opt.recentEff
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value["eff"]))
        .toList();

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: points.isEmpty ? 1 : points.length.toDouble(),
        minY: 0,
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: true,
            dotData: FlDotData(show: false),
            belowBarData:
                BarAreaData(show: true, color: Colors.blue.withOpacity(0.2)),
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
        .map((e) => FlSpot(e.key.toDouble(), e.value.efficiency))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text("30-Day Efficiency History")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: LineChart(
          LineChartData(
            minX: 0,
            maxX: points.isEmpty ? 1 : points.length.toDouble(),
            minY: 0,
            lineBarsData: [
              LineChartBarData(
                spots: points,
                isCurved: true,
                color: Colors.orange,
                belowBarData: BarAreaData(
                    show: true, color: Colors.orange.withOpacity(0.2)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
