import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:health/health.dart';
import 'package:charts_flutter/flutter.dart' as charts;

void main() {
  runApp(GoldilocksApp());
}

class GoldilocksApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoldilocksAI',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: RideDashboard(),
    );
  }
}

class RideDashboard extends StatefulWidget {
  @override
  _RideDashboardState createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  HealthFactory health = HealthFactory();
  int currentCadence = 0;
  int currentHR = 0;
  int currentPower = 0;
  double currentEfficiency = 0;

  List<int> cadenceHistory = [];
  List<int> optimalHistory = [];
  List<int> hrHistory = [];
  List<int> powerHistory = [];

  int historyLength = 15;

  Timer? timer;

  @override
  void initState() {
    super.initState();
    requestHealthPermissions();
    timer = Timer.periodic(Duration(seconds: 1), (_) => updateMetrics());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> requestHealthPermissions() async {
    final types = [
      HealthDataType.HEART_RATE,
      HealthDataType.CADENCE,
      HealthDataType.POWER
    ];

    await health.requestAuthorization(types);
  }

  void updateMetrics() async {
    // Simulated fallback if HealthKit not ready
    int cadence = await getHealthValue(HealthDataType.CADENCE, 70, 100);
    int hr = await getHealthValue(HealthDataType.HEART_RATE, 120, 160);
    int power = await getHealthValue(HealthDataType.POWER, 100, 250);

    setState(() {
      currentCadence = cadence;
      currentHR = hr;
      currentPower = power;
      currentEfficiency = hr != 0 ? power / hr : 0;

      // Update history
      cadenceHistory.add(cadence);
      optimalHistory.add(predictOptimalCadence(power));
      hrHistory.add(hr);
      powerHistory.add(power);

      if (cadenceHistory.length > historyLength) cadenceHistory.removeAt(0);
      if (optimalHistory.length > historyLength) optimalHistory.removeAt(0);
      if (hrHistory.length > historyLength) hrHistory.removeAt(0);
      if (powerHistory.length > historyLength) powerHistory.removeAt(0);
    });
  }

  Future<int> getHealthValue(
      HealthDataType type, int minFallback, int maxFallback) async {
    try {
      final now = DateTime.now();
      final data = await health.getHealthDataFromTypes(
          now.subtract(Duration(seconds: 5)), now, [type]);
      if (data.isNotEmpty) {
        return data.last.value?.toInt() ?? Random().nextInt(maxFallback - minFallback) + minFallback;
      }
    } catch (_) {}
    return Random().nextInt(maxFallback - minFallback) + minFallback;
  }

  int predictOptimalCadence(int power) {
    // Simple logic: target cadence based on power
    if (power < 120) return 80;
    if (power < 180) return 90;
    return 95;
  }

  @override
  Widget build(BuildContext context) {
    String shiftPrompt = "";
    Color cadenceColor = Colors.green;

    int optimalCadence = predictOptimalCadence(currentPower);
    if ((currentCadence - optimalCadence).abs() > 5) {
      cadenceColor = Colors.red;
      shiftPrompt = currentCadence > optimalCadence
          ? "Shift to higher gear ($optimalCadence RPM)"
          : "Shift to lower gear ($optimalCadence RPM)";
    } else {
      shiftPrompt = "Cadence optimal ($optimalCadence RPM)";
    }

    return Scaffold(
      appBar: AppBar(title: Text("GoldilocksAI Dashboard")),
      body: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          children: [
            Text(
              "Current Efficiency: ${currentEfficiency.toStringAsFixed(2)} W/BPM",
              style: TextStyle(fontSize: 20),
            ),
            SizedBox(height: 8),
            Text(
              shiftPrompt,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: cadenceColor),
            ),
            SizedBox(height: 16),
            Expanded(
              child: charts.LineChart(
                [
                  charts.Series<int, int>(
                    id: 'Cadence',
                    data: cadenceHistory,
                    domainFn: (value, index) => index!,
                    measureFn: (value, _) => value,
                    colorFn: (_, __) => charts.MaterialPalette.blue.shadeDefault,
                  ),
                  charts.Series<int, int>(
                    id: 'Optimal',
                    data: optimalHistory,
                    domainFn: (value, index) => index!,
                    measureFn: (value, _) => value,
                    colorFn: (_, __) => charts.MaterialPalette.green.shadeDefault,
                  ),
                ],
                animate: true,
                primaryMeasureAxis: charts.NumericAxisSpec(
                    viewport: charts.NumericExtents(50, 200)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
