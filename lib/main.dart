import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:charts_flutter/flutter.dart' as charts;

void main() {
  runApp(const GoldilocksAIApp());
}

class GoldilocksAIApp extends StatelessWidget {
  const GoldilocksAIApp({super.key});
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
  StreamSubscription? scanSub;

  int cadence = 0;
  int power = 0;
  int hr = 0;
  int optimalCadence = 90;
  double efficiency = 0.0;

  final List<int> cadenceHistory = [];
  final List<int> optimalHistory = [];
  final List<double> efficiencyHistory = [];

  @override
  void initState() {
    super.initState();
    startScan();
    Timer.periodic(const Duration(seconds: 1), (_) => updateDashboard());
  }

  void startScan() async {
    await flutterBlue.startScan(timeout: const Duration(seconds: 5));

    scanSub = flutterBlue.scanResults.listen((results) {
      for (var r in results) {
        // For demo: if device name contains "Cadence", read its data
        if ((r.device.name ?? "").contains("Cadence")) {
          // In real app, connect & subscribe to characteristics
          // Here we simulate:
          setState(() {
            cadence = Random().nextInt(60) + 60; // 60-120 RPM
            power = Random().nextInt(150) + 100; // 100-250 W
            hr = Random().nextInt(40) + 120; // 120-160 bpm
          });
        }
      }
    });
  }

  @override
  void dispose() {
    scanSub?.cancel();
    flutterBlue.stopScan();
    super.dispose();
  }

  void updateDashboard() {
    // Efficiency calculation
    if (hr != 0) efficiency = power / hr;

    // Simple optimizer: pick cadence giving max efficiency (demo)
    optimalCadence = cadence < 90 ? cadence + 5 : cadence - 5;

    setState(() {
      cadenceHistory.add(cadence);
      optimalHistory.add(optimalCadence);
      efficiencyHistory.add(efficiency);
      if (cadenceHistory.length > 20) {
        cadenceHistory.removeAt(0);
        optimalHistory.removeAt(0);
        efficiencyHistory.removeAt(0);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool isOptimal = (cadence - optimalCadence).abs() <= 5;

    return Scaffold(
      appBar: AppBar(title: const Text("GoldilocksAI Dashboard")),
      body: Column(
        children: [
          Container(
            color: isOptimal ? Colors.green[300] : Colors.red[300],
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text("Cadence: $cadence RPM", style: const TextStyle(fontSize: 20)),
                Text("Optimal: $optimalCadence RPM", style: const TextStyle(fontSize: 20)),
                Text("Efficiency: ${efficiency.toStringAsFixed(2)} W/bpm", style: const TextStyle(fontSize: 20)),
              ],
            ),
          ),
          Expanded(
            child: charts.LineChart(
              [
                charts.Series<int, int>(
                  id: 'Cadence',
                  colorFn: (_, __) => charts.MaterialPalette.blue.shadeDefault,
                  domainFn: (i, idx) => idx!,
                  measureFn: (i, _) => cadenceHistory[_],
                  data: List.generate(cadenceHistory.length, (i) => i),
                ),
                charts.Series<int, int>(
                  id: 'Optimal',
                  colorFn: (_, __) => charts.MaterialPalette.green.shadeDefault,
                  domainFn: (i, idx) => idx!,
                  measureFn: (i, _) => optimalHistory[_],
                  data: List.generate(optimalHistory.length, (i) => i),
                ),
              ],
              animate: true,
              primaryMeasureAxis: charts.NumericAxisSpec(
                viewport: charts.NumericExtents(50, 200),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
