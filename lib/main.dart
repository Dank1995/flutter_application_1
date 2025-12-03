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

  int rhythmTarget = 0;

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

    _effBox.add(EffSample(DateTime.now(), efficiency, velocity.round()));
    rhythmTarget = _computeOptimalRhythm();
    notifyListeners();
  }

  int _computeOptimalRhythm() {
    final now = DateTime.now();
    final samples =
        _effBox.values.where((e) => e.time.isAfter(now.subtract(const Duration(days: 30)))).toList();
    if (samples.isEmpty) return 0;

    final Map<int, List<double>> buckets = {};
    for (final s in samples) {
      buckets.putIfAbsent(s.cadence, () => []).add(s.efficiency);
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

  String get rhythmAdvice {
    if (!recording) return "Tap ▶ to start workout";
    if (rhythmTarget == 0) return "Learning your rhythm...";
    final diff = velocity - rhythmTarget;
    if (diff.abs() < 0.5) return "Optimal rhythm";
    return diff > 0 ? "Ease rhythm" : "Increase rhythm";
  }

  Color get rhythmColor {
    if (!recording) return Colors.grey;
    final diff = velocity - rhythmTarget;
    return diff.abs() < 0.5 ? Colors.green : Colors.orange;
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
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 1,
      ),
    ).listen((pos) {
      final opt = context.read<OptimiserState>();
      if (_lastPosition != null) {
        final dt = pos.timestamp!.difference(_lastPosition!.timestamp!).inMilliseconds / 1000;
        if (dt > 0) {
          final dist = Geolocator.distanceBetween(
            _lastPosition!.latitude, _lastPosition!.longitude,
            pos.latitude, pos.longitude);
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
}

class EfficiencyGraph extends StatelessWidget {
  final OptimiserState opt;
  const EfficiencyGraph({super.key, required this.opt});
  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: opt.recentEff.isEmpty ? 1 : opt.recentEff.length.toDouble(),
        minY: 0,
        maxY: opt.recentEff.isEmpty
            ? 1
            : opt.recentEff.map((e) => e["eff"] as double).reduce((a, b) => a > b ? a : b) + 1,
        lineBarsData: [
          LineChartBarData(
            spots: opt.recentEff.asMap().entries
                .map((e) => FlSpot(e.key.toDouble(), e.value["eff"] as double))
                .toList(),
            isCurved: true,
            color: Colors.blue,
            barWidth: 3,
            dotData: FlDotData(show: false),
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
    final samples = opt.last30Days;
    return Scaffold(
      appBar: AppBar(title: const Text("30-Day Efficiency")),
      body: samples.isEmpty
          ? const Center(child: Text("No data yet — start a workout!"))
          : Padding(
              padding: const EdgeInsets.all(8),
              child: LineChart(LineChartData(
                minX: 0,
                maxX: (samples.length - 1).toDouble(),
                minY: 0,
                maxY: samples.map((e) => e.efficiency).reduce((a, b) => a > b ? a : b) + 1,
                lineBarsData: [
                  LineChartBarData(
                    spots: samples.asMap().entries
                        .map((e) => FlSpot(e.key.toDouble(), e.value.efficiency))
                        .toList(),
                    isCurved: true,
                    color: Colors.orange,
                    barWidth: 3,
                    dotData: FlDotData(show: false),
                  ),
                ],
              )),
            ),
    );
  }
}
