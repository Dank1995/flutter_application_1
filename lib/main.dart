import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';

void main() {
  runApp(GoldilocksAIApp());
}

class GoldilocksAIApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GoldilocksAI',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: RideDashboard(),
    );
  }
}

class RideDashboard extends StatefulWidget {
  @override
  _RideDashboardState createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  FlutterBluePlus flutterBlue = FlutterBluePlus.instance;
  StreamSubscription<ScanResult>? scanSub;
  List<ScanResult> devices = [];

  double currentCadence = 0;
  double currentBpm = 0;
  double currentEfficiency = 0;

  @override
  void initState() {
    super.initState();
    startBleScan();
  }

  @override
  void dispose() {
    scanSub?.cancel();
    super.dispose();
  }

  void startBleScan() {
    scanSub = flutterBlue.scan(timeout: Duration(seconds: 5)).listen((scanResult) {
      if (!devices.any((d) => d.device.id == scanResult.device.id)) {
        setState(() {
          devices.add(scanResult);
        });
      }
    }, onDone: () {
      scanSub?.cancel();
    });
  }

  void stopBleScan() async {
    await scanSub?.cancel();
  }

  Color getEfficiencyColor(double eff) {
    if (eff < 50) return Colors.red;
    if (eff < 80) return Colors.orange;
    return Colors.green;
  }

  // Dummy logic: in real app, read BLE sensor data
  void updateMetrics() {
    setState(() {
      currentCadence = 80 + (10 * (0.5 - 0.5));
      currentBpm = 120 + (10 * (0.5 - 0.5));
      currentEfficiency = (currentCadence / 100 + currentBpm / 200) * 100;
    });
  }

  @override
  Widget build(BuildContext context) {
    List<FlSpot> cadenceSpots = List.generate(10, (i) => FlSpot(i.toDouble(), currentCadence));
    List<FlSpot> bpmSpots = List.generate(10, (i) => FlSpot(i.toDouble(), currentBpm));

    return Scaffold(
      appBar: AppBar(title: Text("GoldilocksAI Ride Dashboard")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text("Cadence: ${currentCadence.toStringAsFixed(1)} rpm"),
            SizedBox(height: 8),
            Text("Heart Rate: ${currentBpm.toStringAsFixed(0)} bpm"),
            SizedBox(height: 8),
            Text(
              "Efficiency Score: ${currentEfficiency.toStringAsFixed(1)}",
              style: TextStyle(color: getEfficiencyColor(currentEfficiency), fontSize: 20),
            ),
            SizedBox(height: 16),
            Expanded(
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: 9,
                  minY: 0,
                  maxY: 200,
                  lineBarsData: [
                    LineChartBarData(
                      spots: cadenceSpots,
                      color: Colors.blue,
                      isCurved: true,
                      barWidth: 3,
                      dotData: FlDotData(show: false),
                    ),
                    LineChartBarData(
                      spots: bpmSpots,
                      color: Colors.green,
                      isCurved: true,
                      barWidth: 3,
                      dotData: FlDotData(show: false),
                    ),
                  ],
                  titlesData: FlTitlesData(
                    leftTitles: SideTitles(showTitles: true),
                    bottomTitles: SideTitles(showTitles: true),
                  ),
                ),
              ),
            ),
            SizedBox(height: 16),
            ElevatedButton(
              onPressed: updateMetrics,
              child: Text("Update Metrics"),
            ),
          ],
        ),
      ),
    );
  }
}
