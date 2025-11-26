import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:charts_flutter/flutter.dart' as charts;

void main() => runApp(const GoldilocksApp());

class GoldilocksApp extends StatelessWidget {
  const GoldilocksApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoldilocksAI',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const RideDashboard(),
    );
  }
}

class RideDashboard extends StatefulWidget {
  const RideDashboard({super.key});

  @override
  State<RideDashboard> createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  final FlutterBluePlus flutterBlue = FlutterBluePlus.instance;

  int currentCadence = 0;
  int currentPower = 0;
  int currentHR = 0;
  double currentEfficiency = 0.0;
  int optimalCadence = 90;

  List<int> cadenceHistory = [];
  List<int> optimalHistory = [];
  List<double> efficiencyHistory = [];

  StreamSubscription<List<ScanResult>>? scanSub;

  @override
  void initState() {
    super.initState();
    _startScan();
    _timerLoop();
  }

  void _startScan() {
    flutterBlue.startScan(timeout: const Duration(seconds: 5));
    scanSub = flutterBlue.scanResults.listen((results) {
      // Find cadence/power/HR device if needed
      // For simplicity, this demo simulates reading values
      // Replace with device connection logic for your sensors
    });
  }

  void _timerLoop() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      _readSensors();
      _calculateEfficiency();
      _updateOptimalCadence();
      _logHistory();
      setState(() {});
    });
  }

  void _readSensors() {
    // TODO: replace with real BLE readings
    currentCadence = 70 + (10 * (DateTime.now().second % 3));
    currentPower = 150 + (10 * (DateTime.now().second % 5));
    currentHR = 120 + (5 * (DateTime.now().second % 4));
  }

  void _calculateEfficiency() {
    if (currentHR == 0) {
      currentEfficiency = 0;
    } else {
      currentEfficiency = currentPower / currentHR;
    }
  }

  void _updateOptimalCadence() {
    // Dummy logic: keep optimal cadence around 90
    optimalCadence = 85 + (DateTime.now().second % 11);
  }

  void _logHistory() {
    cadenceHistory.add(currentCadence);
    optimalHistory.add(optimalCadence);
    efficiencyHistory.add(currentEfficiency);
    if (cadenceHistory.length > 15) cadenceHistory.removeAt(0);
    if (optimalHistory.length > 15) optimalHistory.removeAt(0);
    if (efficiencyHistory.length > 15) efficiencyHistory.removeAt(0);
  }

  @override
  void dispose() {
    scanSub?.cancel();
    flutterBlue.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isOptimal =
        (currentCadence - optimalCadence).abs() <= 5;

    return Scaffold(
      appBar: AppBar(title: const Text('GoldilocksAI Ride Dashboard')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(children: [
          // Current readings
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _metricBox('Cadence', '$currentCadence RPM', isOptimal),
              _metricBox('Power', '$currentPower W', true),
              _metricBox('HR', '$currentHR BPM', true),
              _metricBox(
                  'Efficiency', currentEfficiency.toStringAsFixed(2), true),
            ],
          ),
          const SizedBox(height: 20),

          // Shift prompt
          Text(
            isOptimal
                ? 'Cadence Optimal ($optimalCadence RPM)'
                : (currentCadence > optimalCadence
                    ? 'Shift to higher gear ($optimalCadence RPM)'
                    : 'Shift to lower gear ($optimalCadence RPM)'),
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isOptimal ? Colors.green : Colors.red),
          ),
          const SizedBox(height: 20),

          // Chart
          Expanded(
            child: charts.LineChart([
              charts.Series<int, int>(
                id: 'Cadence',
                data: cadenceHistory,
                domainFn: (val, idx) => idx!,
                measureFn: (val, _) => val,
                colorFn: (_, __) => charts.MaterialPalette.blue.shadeDefault,
              ),
              charts.Series<int, int>(
                id: 'OptimalCadence',
                data: optimalHistory,
                domainFn: (val, idx) => idx!,
                measureFn: (val, _) => val,
                colorFn: (_, __) => charts.MaterialPalette.green.shadeDefault,
              ),
            ], animate: true),
          ),
        ]),
      ),
    );
  }

  Widget _metricBox(String label, String value, bool active) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: active ? Colors.grey[200] : Colors.grey[400],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(value, style: const TextStyle(fontSize: 16)),
        ],
      ),
    );
  }
}
