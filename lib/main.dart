import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cadence Optimizer v1.0.48',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: Dashboard(),
    );
  }
}

// -----------------------------
// Cadence Optimizer
// -----------------------------
class CadenceOptimizer {
  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;
  double currentEfficiency = 0;
  Map<int, Map<int, List<double>>> efficiencyMap = {};
  late File rideFile;

  CadenceOptimizer() {
    _initLogFile();
  }

  Future<void> _initLogFile() async {
    Directory docDir = await getApplicationDocumentsDirectory();
    rideFile = File('${docDir.path}/ride_data.csv');
    if (!await rideFile.exists()) {
      await rideFile.writeAsString(
        const ListToCsvConverter().convert([
          ["Time", "Cadence", "Power", "HR", "Efficiency", "OptimalCadence", "W/BPM"]
        ]) + '\n',
      );
    }
  }

  void updateSensors(int cadence, int power, int hr) {
    currentCadence = cadence;
    currentPower = power;
    currentHR = hr;
    currentEfficiency = calculateEfficiency();
    learnCadence(currentPower, currentCadence, currentEfficiency);
  }

  double calculateEfficiency() {
    if (currentHR == 0) return 0;
    return currentPower / currentHR;
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
    if (!efficiencyMap.containsKey(powerBucket) || efficiencyMap[powerBucket]!.isEmpty) {
      return 90;
    }
    Map<int, double> avgEff = {};
    efficiencyMap[powerBucket]!.forEach((c, effs) {
      avgEff[c] = effs.reduce((a, b) => a + b) / effs.length;
    });
    return avgEff.entries.reduce((a, b) => a.value > b.value ? a : b).key;
  }

  String shiftPrompt() {
    int optimal = predictOptimalCadence();
    int diff = currentCadence - optimal;
    if (diff.abs() > 5) {
      if (diff > 0) return "Shift to higher gear ($optimal RPM)";
      return "Shift to lower gear ($optimal RPM)";
    }
    return "Cadence optimal ($optimal RPM)";
  }

  Future<void> logRide(int timeSec) async {
    int optimal = predictOptimalCadence();
    await rideFile.writeAsString(
      ListToCsvConverter().convert([
            [timeSec, currentCadence, currentPower, currentHR, currentEfficiency.toStringAsFixed(2), optimal, currentEfficiency.toStringAsFixed(2)]
          ]) +
          '\n',
      mode: FileMode.append,
    );
  }
}

// -----------------------------
// Dashboard
// -----------------------------
class Dashboard extends StatefulWidget {
  @override
  _DashboardState createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final CadenceOptimizer optimizer = CadenceOptimizer();
  final FlutterBluePlus flutterBlue = FlutterBluePlus.instance;
  StreamSubscription? scanSub;
  BluetoothDevice? connectedDevice;

  int cadence = 0;
  int power = 0;
  int hr = 0;
  String prompt = '';

  @override
  void initState() {
    super.initState();
    startScan();
    Timer.periodic(Duration(seconds: 1), (timer) async {
      // Update optimizer
      optimizer.updateSensors(cadence, power, hr);
      await optimizer.logRide(DateTime.now().millisecondsSinceEpoch ~/ 1000);
      setState(() {
        prompt = optimizer.shiftPrompt();
      });
    });
  }

  void startScan() {
    scanSub = flutterBlue.scan(timeout: Duration(seconds: 5)).listen((scanResult) async {
      if (scanResult.device.name.contains("HRM") || scanResult.device.name.contains("RS200")) {
        scanSub?.cancel();
        await scanResult.device.connect(autoConnect: false, timeout: Duration(seconds: 10));
        connectedDevice = scanResult.device;
        // Start notifications if characteristics known
      }
    });
  }

  @override
  void dispose() {
    scanSub?.cancel();
    connectedDevice?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Cadence Optimizer v1.0.48'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text('Cadence: $cadence RPM', style: TextStyle(fontSize: 24)),
            Text('Power: $power W', style: TextStyle(fontSize: 24)),
            Text('Heart Rate: $hr BPM', style: TextStyle(fontSize: 24)),
            SizedBox(height: 20),
            Text('Prompt:', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            Text(prompt, style: TextStyle(fontSize: 28, color: Colors.red)),
          ],
        ),
      ),
    );
  }
}
