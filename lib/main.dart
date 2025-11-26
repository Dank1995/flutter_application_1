import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:charts_flutter/flutter.dart' as charts;

void main() => runApp(GoldilocksApp());

class GoldilocksApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoldilocksAI',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: RideDashboard(),
    );
  }
}

// -----------------------------
// Sensor & Optimizer Logic
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
    currentEfficiency = hr > 0 ? power / hr : 0.0;
    _learnCadence(power, cadence, currentEfficiency);
  }

  void _learnCadence(int power, int cadence, double efficiency) {
    int p = (power / 10).round() * 10;
    int c = (cadence / 2).round() * 2;
    efficiencyMap[p] ??= {};
    efficiencyMap[p]![c] ??= [];
    efficiencyMap[p]![c]!.add(efficiency);
  }

  int predictOptimalCadence() {
    int p = (currentPower / 10).round() * 10;
    if (!efficiencyMap.containsKey(p)) return 90;
    var cadences = efficiencyMap[p]!;
    var avgEff = cadences.map((c, e) => MapEntry(c, e.reduce((a,b)=>a+b)/e.length));
    int optimal = avgEff.entries.reduce((a,b) => a.value > b.value ? a : b).key;
    return optimal;
  }

  String shiftPrompt() {
    int optimal = predictOptimalCadence();
    int diff = currentCadence - optimal;
    if (diff.abs() > 5) {
      return diff > 0 ? "Shift to higher gear ($optimal RPM)" : "Shift to lower gear ($optimal RPM)";
    }
    return "Cadence optimal ($optimal RPM)";
  }

  bool isOptimal() => (currentCadence - predictOptimalCadence()).abs() <= 5;
}

// -----------------------------
// Dashboard & BLE
// -----------------------------
class RideDashboard extends StatefulWidget {
  @override
  _RideDashboardState createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  final CadenceOptimizerAI optimizer = CadenceOptimizerAI();
  final FlutterBluePlus flutterBlue = FlutterBluePlus.instance;

  StreamSubscription? scanSub;
  List<BluetoothDevice> devices = [];

  int cadence = 0;
  int power = 0;
  int hr = 0;

  List<int> cadenceHistory = [];
  List<int> optimalHistory = [];
  List<double> efficiencyHistory = [];

  @override
  void initState() {
    super.initState();
    _startScan();
    Timer.periodic(Duration(seconds: 1), (_) => _updateReadings());
  }

  void _startScan() {
    scanSub = flutterBlue.scan(timeout: Duration(seconds: 5)).listen((scanResult) {
      if (!devices.contains(scanResult.device)) {
        devices.add(scanResult.device);
      }
    }, onDone: () => scanSub?.cancel());
  }

  void _updateReadings() {
    // Mock BLE readings if no device
    if (devices.isEmpty) {
      cadence = 70 + (DateTime.now().second % 30);
      power = 120 + (DateTime.now().second % 100);
      hr = 120 + (DateTime.now().second % 40);
    }
    optimizer.updateSensors(cadence, power, hr);
    setState(() {
      cadenceHistory.add(cadence);
      optimalHistory.add(optimizer.predictOptimalCadence());
      efficiencyHistory.add(optimizer.currentEfficiency);
      if (cadenceHistory.length > 15) {
        cadenceHistory.removeAt(0);
        optimalHistory.removeAt(0);
        efficiencyHistory.removeAt(0);
      }
    });
  }

  @override
  void dispose() {
    scanSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool optimal = optimizer.isOptimal();
    return Scaffold(
      appBar: AppBar(title: Text('GoldilocksAI Dashboard')),
      body: Column(
        children: [
          Container(
            color: optimal ? Colors.green[200] : Colors.red[200],
            padding: EdgeInsets.all(16),
            child: Column(
              children: [
                Text('Cadence: $cadence RPM', style: TextStyle(fontSize: 22)),
                Text('Power: $power W', style: TextStyle(fontSize: 22)),
                Text('HR: $hr BPM', style: TextStyle(fontSize: 22)),
                Text('Efficiency: ${optimizer.currentEfficiency.toStringAsFixed(2)}', style: TextStyle(fontSize: 22)),
                Text('Shift Prompt: ${optimizer.shiftPrompt()}', style: TextStyle(fontSize: 18)),
              ],
            ),
          ),
          Expanded(
            child: charts.LineChart([
              charts.Series<int, int>(
                id: 'Cadence',
                domainFn: (int idx, _) => idx,
                measureFn: (int val, _) => val,
                data: cadenceHistory,
                colorFn: (_, __) => charts.MaterialPalette.blue.shadeDefault,
              ),
              charts.Series<int, int>(
                id: 'Optimal',
                domainFn: (int idx, _) => idx,
                measureFn: (int val, _) => val,
                data: optimalHistory,
                colorFn: (_, __) => charts.MaterialPalette.green.shadeDefault,
              ),
            ], animate: true),
          ),
        ],
      ),
    );
  }
}
