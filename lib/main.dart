import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:async';

void main() {
  runApp(GoldilocksApp());
}

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

class RideDashboard extends StatefulWidget {
  @override
  _RideDashboardState createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  final FlutterBluePlus flutterBlue = FlutterBluePlus.instance;
  StreamSubscription? scanSub;
  List<BluetoothDevice> devices = [];
  List<double> efficiencyData = [];
  double currentEfficiency = 0;

  @override
  void initState() {
    super.initState();
    startScan();
  }

  void startScan() {
    flutterBlue.startScan(timeout: Duration(seconds: 5));
    scanSub = flutterBlue.scanResults.listen((results) {
      setState(() {
        devices = results.map((r) => r.device).toList();
      });
    });
  }

  void stopScan() async {
    await flutterBlue.stopScan();
    scanSub?.cancel();
  }

  void updateEfficiency(double bpm, double pacePerKm) {
    // Example: efficiency = pace per bpm ratio
    double efficiency = pacePerKm / bpm * 100;
    setState(() {
      currentEfficiency = efficiency;
      efficiencyData.add(efficiency);
      if (efficiencyData.length > 50) efficiencyData.removeAt(0);
    });
  }

  Color getEfficiencyColor(double value) {
    if (value > 70) return Colors.green;
    if (value < 40) return Colors.red;
    return Colors.orange;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('GoldilocksAI Ride Dashboard')),
      body: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              'Current Efficiency: ${currentEfficiency.toStringAsFixed(1)}',
              style: TextStyle(
                  fontSize: 22, color: getEfficiencyColor(currentEfficiency)),
            ),
            SizedBox(height: 20),
            Expanded(
              child: LineChart(
                LineChartData(
                  minY: 0,
                  maxY: 120,
                  lineBarsData: [
                    LineChartBarData(
                      spots: efficiencyData
                          .asMap()
                          .entries
                          .map((e) => FlSpot(e.key.toDouble(), e.value))
                          .toList(),
                      isCurved: true,
                      colors: [getEfficiencyColor(currentEfficiency)],
                      barWidth: 3,
                    ),
                  ],
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true),
                    ),
                  ),
                  gridData: FlGridData(show: true),
                  borderData: FlBorderData(show: true),
                ),
              ),
            ),
            SizedBox(height: 20),
            ElevatedButton(
                onPressed: () => updateEfficiency(100, 5.2),
                child: Text('Simulate Update')),
            ElevatedButton(
                onPressed: startScan, child: Text('Start BLE Scan')),
            ElevatedButton(
                onPressed: stopScan, child: Text('Stop BLE Scan')),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    scanSub?.cancel();
    super.dispose();
  }
}
