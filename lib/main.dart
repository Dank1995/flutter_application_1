import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:audioplayers/audioplayers.dart';

// -----------------------------
// Optimizer
// -----------------------------
class CadenceOptimizerAI {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHr = 0;
  double currentEfficiency = 0.0;
  final Map<int, Map<int, List<double>>> efficiencyMap = {};

  void updateSensors({required int cadence, required int power, required int hr}) {
    currentCadence = cadence;
    currentPower = power;
    currentHr = hr;
    currentEfficiency = calculateEfficiency();
    learnCadence(currentPower, currentCadence, currentEfficiency);
  }

  double calculateEfficiency() {
    if (currentHr <= 0) return 0.0;
    return currentPower / currentHr;
  }

  void learnCadence(int power, int cadence, double efficiency) {
    final pBucket = (power / 10).round() * 10;
    final cBucket = (cadence / 2).round() * 2;
    efficiencyMap.putIfAbsent(pBucket, () => {});
    efficiencyMap[pBucket]!.putIfAbsent(cBucket, () => []);
    efficiencyMap[pBucket]![cBucket]!.add(efficiency);
  }

  int predictOptimalCadence() {
    final pBucket = (currentPower / 10).round() * 10;
    final cadences = efficiencyMap[pBucket];
    if (cadences == null || cadences.isEmpty) return 90;
    double bestEff = double.negativeInfinity;
    int bestCad = 90;
    cadences.forEach((c, effs) {
      final avg = effs.reduce((a, b) => a + b) / effs.length;
      if (avg > bestEff) {
        bestEff = avg;
        bestCad = c;
      }
    });
    return bestCad;
  }

  (String, bool) shiftPrompt() {
    final optimal = predictOptimalCadence();
    final diff = currentCadence - optimal;
    if (diff.abs() > 5) {
      return diff > 0
          ? ("Shift to lower gear ($optimal RPM)", true)
          : ("Shift to higher gear ($optimal RPM)", true);
    }
    return ("Cadence optimal ($optimal RPM)", false);
  }
}

// -----------------------------
// Logger
// -----------------------------
class RideLogger {
  late final File _file;
  bool _ready = false;

  Future<void> init() async {
    final dir = await getApplicationDocumentsDirectory();
    _file = File("${dir.path}/ride_data.csv");
    if (!await _file.exists()) {
      await _file.create(recursive: true);
      await _file.writeAsString("Time,Cadence,Power,HR,Efficiency,OptimalCadence\n");
    }
    _ready = true;
  }

  Future<void> log(int timeSec, int cadence, int power, int hr, double eff, int optimal) async {
    if (!_ready) return;
    final row = "$timeSec,$cadence,$power,$hr,${eff.toStringAsFixed(2)},$optimal\n";
    await _file.writeAsString(row, mode: FileMode.append, flush: true);
  }
}

// -----------------------------
// GPS Pace
// -----------------------------
class PaceTracker {
  Position? _last;
  double _distanceMeters = 0.0;
  DateTime? _start;

  Future<void> start() async {
    _start = DateTime.now();
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
  }

  double update(Position p) {
    if (_last != null) {
      _distanceMeters += Geolocator.distanceBetween(
          _last!.latitude, _last!.longitude, p.latitude, p.longitude);
    }
    _last = p;
    final elapsed = DateTime.now().difference(_start!).inSeconds.toDouble();
    if (_distanceMeters < 1) return 0.0;
    return elapsed / (_distanceMeters / 1000.0);
  }

  double get distanceKm => _distanceMeters / 1000.0;
}

// -----------------------------
// App
// -----------------------------
void main() {
  runApp(const CadenceCoachApp());
}

class CadenceCoachApp extends StatelessWidget {
  const CadenceCoachApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: 'Cadence Coach', theme: ThemeData.dark(), home: const WorkoutScreen());
  }
}

class WorkoutScreen extends StatefulWidget {
  const WorkoutScreen({super.key});
  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  final optimizer = CadenceOptimizerAI();
  final logger = RideLogger();
  final pace = PaceTracker();
  final audio = AudioPlayer();
  final flutterBlue = FlutterBluePlus.instance;

  List<BluetoothDevice> devices = [];
  BluetoothDevice? connectedDevice;

  int cadence = 0, power = 0, hr = 0, optimal = 90;
  double efficiency = 0.0, paceSecPerKm = 0.0, distanceKm = 0.0;
  String prompt = "Waiting for sensors...";

  @override
  void initState() {
    super.initState();
    logger.init();
    pace.start();
    Geolocator.getPositionStream().listen((pos) {
      paceSecPerKm = pace.update(pos);
      distanceKm = pace.distanceKm;
      setState(() {});
    });
  }

  void _scanDevices() {
    devices.clear();
    flutterBlue.startScan(timeout: const Duration(seconds: 5));
    flutterBlue.scanResults.listen((results) {
      setState(() => devices = results.map((r) => r.device).toList());
    });
  }

  Future<void> _connect(BluetoothDevice d) async {
    await d.connect();
    final services = await d.discoverServices();
    for (final s in services) {
      for (final c in s.characteristics) {
        if (c.properties.notify) {
          await c.setNotifyValue(true);
          c.value.listen((data) {
            if (s.uuid.toString().contains("180d")) hr = data[1];
            if (s.uuid.toString().contains("1818")) {
              power = data[1];
              cadence = data.length > 3 ? data[3] : cadence;
            }
            _updateOptimizer();
          });
        }
      }
    }
    setState(() => connectedDevice = d);
  }

  void _updateOptimizer() {
    optimizer.updateSensors(cadence: cadence, power: power, hr: hr);
    final (msg, alert) = optimizer.shiftPrompt();
    optimal = optimizer.predictOptimalCadence();
    efficiency = optimizer.currentEfficiency;
    prompt = msg;
    logger.log(DateTime.now().second, cadence, power, hr, efficiency, optimal);
    if (alert) audio.play(AssetSource('alert.mp3'));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final df = NumberFormat("0.00");
    return Scaffold(
      appBar: AppBar(title: const Text("Cadence Coach")),
      body: Column(children: [
        ElevatedButton(onPressed: _scanDevices, child: const Text("Scan for devices")),
        Expanded(
          child: ListView.builder(
            itemCount: devices.length,
            itemBuilder: (c, i) {
              final d = devices[i];
              return ListTile(
                title: Text(d.name.isNotEmpty ? d.name : d.id.toString()),
                trailing: ElevatedButton(
                  onPressed: () => _connect(d),
                  child: const Text("Connect"),
                ),
              );
            },
          ),
        ),
        Text("Cadence: $cadence rpm"),
        Text("Power: $power W"),
        Text("HR: $hr bpm"),
        Text("Efficiency: ${df.format(efficiency)}"),
        Text("Optimal Cadence: $optimal rpm"),
        Text("Pace: ${paceSecPerKm > 0 ? (paceSecPerKm ~/ 60).toString() : '--'} /km"),
        Text("Distance: ${df.format(distanceKm)} km"),
        Card(child: Padding(padding: const EdgeInsets.all(8), child: Text(prompt))),
      ]),
    );
  }
}