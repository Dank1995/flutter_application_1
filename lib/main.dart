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

  BluetoothDevice? cadenceDevice;
  BluetoothDevice? hrDevice;
  BluetoothCharacteristic? cadenceChar;
  BluetoothCharacteristic? hrChar;

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
  int timeSec = 0;
  Timer? timer;

  @override
  void dispose() {
    cadenceDevice?.disconnect();
    hrDevice?.disconnect();
    timer?.cancel();
    super.dispose();
  }

  Future<void> startScanning() async {
    // Start scanning for BLE devices
    flutterBlue.startScan(timeout: const Duration(seconds: 5));

    flutterBlue.scanResults.listen((results) async {
      for (var r in results) {
        // Example: filter by name (replace with your sensor name)
        if (r.device.name.contains("CadenceSensor") && cadenceDevice == null) {
          cadenceDevice = r.device;
          await cadenceDevice!.connect();
          await discoverCadenceService();
        }
        if (r.device.name.contains("HeartRate") && hrDevice == null) {
          hrDevice = r.device;
          await hrDevice!.connect();
          await discoverHRService();
        }
      }
    });

    // Start CSV timer
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      logRide();
      timeSec++;
    });
  }

  Future<void> discoverCadenceService() async {
    if (cadenceDevice == null) return;
    var services = await cadenceDevice!.discoverServices();
    for (var s in services) {
      for (var c in s.characteristics) {
        // Replace with actual cadence characteristic UUID
        if (c.uuid.toString() == "00002a5b-0000-1000-8000-00805f9b34fb") {
          cadenceChar = c;
          await cadenceChar!.setNotifyValue(true);
          cadenceChar!.value.listen((data) {
            // Convert bytes to cadence value
            if (data.isNotEmpty) {
              int cadence = data[0];
              updateMetrics(cadence: cadence);
            }
          });
        }
      }
    }
  }

  Future<void> discoverHRService() async {
    if (hrDevice == null) return;
    var services = await hrDevice!.discoverServices();
    for (var s in services) {
      for (var c in s.characteristics) {
        // Heart rate characteristic UUID
        if (c.uuid.toString() == "00002a37-0000-1000-8000-00805f9b34fb") {
          hrChar = c;
          await hrChar!.setNotifyValue(true);
          hrChar!.value.listen((data) {
            if (data.isNotEmpty) {
              int hr = data[1]; // first byte may be flags
              updateMetrics(hr: hr);
            }
          });
        }
      }
    }
  }

  void updateMetrics({int? cadence, int? hr, int? power}) {
    int newCadence = cadence ?? currentCadence;
    int newHR = hr ?? currentHR;
    int newPower = power ?? currentPower;

    optimizer.updateSensors(newCadence, newPower, newHR);
    var result = optimizer.shiftPrompt();

    setState(() {
      currentCadence = newCadence;
      currentHR = newHR;
      currentPower = newPower;
      currentEfficiency = optimizer.currentEfficiency;
      shiftMessage = result["message"];
      shiftAlert = result["alert"];
    });
  }

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
            ElevatedButton(
                onPressed: () {
                  cadenceDevice?.disconnect();
                  hrDevice?.disconnect();
                  timer?.cancel();
                },
                child: const Text('Stop Scan')),
            ElevatedButton(onPressed: exportCsv, child: const Text('Export CSV')),
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
