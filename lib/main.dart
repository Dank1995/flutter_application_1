import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';

void main() {
  runApp(const MyApp());
}

// -----------------------------
// Cadence Optimizer
// -----------------------------
class CadenceOptimizer {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;
  Map<int, Map<int, List<double>>> efficiencyMap = {};

  void update(int cadence, int power, int hr) {
    currentCadence = cadence;
    currentPower = power;
    currentHR = hr;
    final eff = calculateEfficiency();
    learnCadence(power, cadence, eff);
  }

  double calculateEfficiency() {
    if (currentHR == 0) return 0;
    return currentPower / currentHR;
  }

  void learnCadence(int power, int cadence, double eff) {
    final powerBucket = (power / 10).round() * 10;
    final cadenceBucket = (cadence / 2).round() * 2;
    efficiencyMap.putIfAbsent(powerBucket, () => {});
    efficiencyMap[powerBucket]!.putIfAbsent(cadenceBucket, () => []);
    efficiencyMap[powerBucket]![cadenceBucket]!.add(eff);
  }

  int predictOptimalCadence() {
    final powerBucket = (currentPower / 10).round() * 10;
    final cadences = efficiencyMap[powerBucket];
    if (cadences == null || cadences.isEmpty) return 90;
    final avgEff = <int, double>{};
    cadences.forEach((c, e) {
      avgEff[c] = e.reduce((a, b) => a + b) / e.length;
    });
    final optimal = avgEff.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    return optimal;
  }

  Future<void> logRide(int timeSec) async {
    final optimal = predictOptimalCadence();
    final directory = await getApplicationDocumentsDirectory();
    final path = "${directory.path}/ride_data.csv";
    final file = File(path);
    final exists = await file.exists();
    final csvData = [
      [timeSec, currentCadence, currentPower, currentHR, calculateEfficiency(), optimal]
    ];
    final csvString = const ListToCsvConverter().convert(csvData);
    if (!exists) {
      await file.writeAsString("Time,Cadence,Power,HR,Efficiency,OptimalCadence\n");
    }
    await file.writeAsString(csvString + "\n", mode: FileMode.append);
  }
}

// -----------------------------
// Flutter App
// -----------------------------
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Cadence Optimizer',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const Dashboard(),
    );
  }
}

// -----------------------------
// Dashboard Widget
// -----------------------------
class Dashboard extends StatefulWidget {
  const Dashboard({super.key});
  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final optimizer = CadenceOptimizer();
  final FlutterBluePlus flutterBlue = FlutterBluePlus.instance;
  StreamSubscription? scanSub;
  int cadence = 0;
  int power = 0;
  int hr = 0;
  String prompt = "";

  @override
  void initState() {
    super.initState();
    startScan();
    Timer.periodic(const Duration(seconds: 1), (timer) {
      optimizer.update(cadence, power, hr);
      optimizer.logRide(DateTime.now().millisecondsSinceEpoch ~/ 1000);
      final optimal = optimizer.predictOptimalCadence();
      setState(() {
        prompt = cadence > optimal + 5
            ? "Shift up to $optimal RPM"
            : cadence < optimal - 5
                ? "Shift down to $optimal RPM"
                : "Cadence optimal $optimal RPM";
      });
    });
  }

  void startScan() {
    scanSub = flutterBlue.scan(timeout: const Duration(seconds: 5)).listen((result) async {
      // Fake demo values, replace with real parsing if your BLE device provides structured data
      cadence = 80 + (result.rssi % 10);
      power = 150 + (result.rssi % 20);
      hr = 120 + (result.rssi % 15);
    });
  }

  @override
  void dispose() {
    scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("BLE Cadence Optimizer v1.0.49+49")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text("Cadence: $cadence RPM", style: const TextStyle(fontSize: 24)),
            Text("Power: $power W", style: const TextStyle(fontSize: 24)),
            Text("Heart Rate: $hr BPM", style: const TextStyle(fontSize: 24)),
            const SizedBox(height: 20),
            Text(prompt, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
