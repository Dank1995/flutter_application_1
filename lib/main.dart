import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';

void main() {
  runApp(const MyApp());
}

// -----------------------------
// App Scaffold
// -----------------------------
class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cadence Coach',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const MyHomePage(),
    );
  }
}

// -----------------------------
// Home Page
// -----------------------------
class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});
  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final FlutterBluePlus flutterBlue = FlutterBluePlus.instance;

  StreamSubscription<List<ScanResult>>? scanSub;
  BluetoothDevice? cadenceDevice;
  BluetoothDevice? hrDevice;

  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;
  double currentEfficiency = 0;

  String shiftMessage = "Cadence optimal";
  bool shiftAlert = false;

  final List<List<dynamic>> csvData = [
    ["Time", "Cadence", "Power", "HR", "Efficiency", "OptimalCadence"]
  ];

  final CadenceOptimizerAI optimizer = CadenceOptimizerAI();
  final Random random = Random();
  int timeSec = 0;
  Timer? timer;

  @override
  void dispose() {
    scanSub?.cancel();
    timer?.cancel();
    super.dispose();
  }

  // -----------------------------
  // Start BLE scan
  // -----------------------------
  void startScanning() {
    flutterBlue.startScan(timeout: const Duration(seconds: 5));

    scanSub = flutterBlue.scanResults.listen((results) {
      for (var r in results) {
        // You can filter devices by name or UUID here
        if (r.device.name.contains("Cadence")) {
          cadenceDevice ??= r.device;
        }
        if (r.device.name.contains("HR")) {
          hrDevice ??= r.device;
        }

        int cadence = 70 + random.nextInt(40);
        int power = 100 + random.nextInt(150);
        int hr = 120 + random.nextInt(40);
        updateMetrics(cadence, power, hr);
      }
    });

    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      logRide();
      timeSec++;
    });
  }

  // -----------------------------
  // Stop BLE scan
  // -----------------------------
  void stopScanning() async {
    await flutterBlue.stopScan();
    await scanSub?.cancel();
    timer?.cancel();
  }

  // -----------------------------
  // Connect to devices
  // -----------------------------
  Future<void> connectDevices() async {
    if (cadenceDevice != null) {
      await cadenceDevice!.connect(license: ''); // required parameter
    }
    if (hrDevice != null) {
      await hrDevice!.connect(license: '');
    }
  }

  // -----------------------------
  // Update metrics
  // -----------------------------
  void updateMetrics(int cadence, int power, int hr) {
    optimizer.updateSensors(cadence, power, hr);
    var result = optimizer.shiftPrompt();

    setState(() {
      currentCadence = cadence;
      currentPower = power;
      currentHR = hr;
      currentEfficiency = optimizer.currentEfficiency;
      shiftMessage = result["message"];
      shiftAlert = result["alert"];
    });
  }

  // -----------------------------
  // Log ride data
  // -----------------------------
  Future<void> logRide() async {
    csvData.add([
      timeSec,
      currentCadence,
      currentPower,
      currentHR,
      currentEfficiency.toStringAsFixed(2),
      optimizer.predictOptimalCadence()
    ]);
  }

  // -----------------------------
  // Export CSV
  // -----------------------------
  Future<void> exportCsv() async {
    final csvString = const ListToCsvConverter().convert(csvData);
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/cadence_data.csv';
    final file = File(path);
    await file.writeAsString(csvString);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('CSV saved at $path')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cadence Coach')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Cadence: $currentCadence rpm'),
            Text('Power: $currentPower W'),
            Text('Heart Rate: $currentHR bpm'),
            Text('Efficiency: ${currentEfficiency.toStringAsFixed(2)}'),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: shiftAlert ? Colors.redAccent : Colors.greenAccent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                shiftMessage,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: startScanning, child: const Text('Start Scan')),
            ElevatedButton(onPressed: stopScanning, child: const Text('Stop Scan')),
            ElevatedButton(onPressed: exportCsv, child: const Text('Export CSV')),
            ElevatedButton(onPressed: connectDevices, child: const Text('Connect Devices')),
          ],
        ),
      ),
    );
  }
}

// -----------------------------
// Cadence Optimizer AI
// -----------------------------
class CadenceOptimizerAI {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;
  double currentEfficiency = 0.0;
  Map<int, Map<int, List<double>>> efficiencyMap = {};

  void updateSensors(int cadence, int power, int hr) {
    currentCadence = cadence;
    currentPower = power;
    currentHR = hr;
    currentEfficiency = hr == 0 ? 0 : power / hr;
    learnCadence(power, cadence, currentEfficiency);
  }

  void learnCadence(int power, int cadence, double efficiency) {
    int powerBucket = (power / 10).round() * 10;
    int cadenceBucket = (cadence / 2).round() * 2;
    efficiencyMap.putIfAbsent(powerBucket, () => {});
    efficiencyMap[powerBucket]!.putIfAbsent(cadenceBucket, () => []);
    efficiencyMap[powerBucket]![cadenceBucket]!.add(efficiency);
  }

  int predictOptimalCadence() {
    int powerBucket = (currentPower / 10).round() * 10;
    var cadences = efficiencyMap[powerBucket];
    if (cadences == null || cadences.isEmpty) return 90;
    var avgEff = cadences.map((k, v) => MapEntry(k, v.reduce((a, b) => a + b) / v.length));
    int optimal = avgEff.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    return optimal;
  }

  Map<String, dynamic> shiftPrompt() {
    int optimal = predictOptimalCadence();
    int diff = currentCadence - optimal;
    bool alert = false;
    String msg = "Cadence optimal ($optimal RPM)";
    if (diff.abs() > 5) {
      alert = true;
      msg = diff > 0
          ? "Shift to higher gear ($optimal RPM)"
          : "Shift to lower gear ($optimal RPM)";
    }
    return {"message": msg, "alert": alert};
  }
}
