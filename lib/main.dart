import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => RideState(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PhysiologicalOptimiser',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const RideDashboard(),
    );
  }
}

// -----------------------------
// Ride State / Optimizer (dummy values for now)
// -----------------------------
class RideState extends ChangeNotifier {
  int cadence = 80;
  int power = 200;
  int hr = 140;
  int optimalCadence = 90;
  double efficiency = 1.4;

  void _updateEfficiency() {
    efficiency = power / hr;
    notifyListeners();
  }

  String get shiftMessage {
    final diff = cadence - optimalCadence;
    if (diff.abs() > 5) {
      return diff > 0
          ? "Shift to higher gear ($optimalCadence RPM)"
          : "Shift to lower gear ($optimalCadence RPM)";
    }
    return "Cadence optimal ($optimalCadence RPM)";
  }

  Color get alertColor {
    final diff = cadence - optimalCadence;
    if (diff.abs() > 5) return Colors.red;
    return Colors.green;
  }
}

// -----------------------------
// Ride Dashboard
// -----------------------------
class RideDashboard extends StatelessWidget {
  const RideDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final ride = Provider.of<RideState>(context);

    return Scaffold(
      appBar: AppBar(title: const Text("Ride Dashboard")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              ride.shiftMessage,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: ride.alertColor,
              ),
            ),
            const SizedBox(height: 20),
            Text("Cadence: ${ride.cadence} RPM"),
            Text("Power: ${ride.power} W"),
            Text("Heart Rate: ${ride.hr} BPM"),
            Text("Efficiency: ${ride.efficiency.toStringAsFixed(2)} W/BPM"),
            const SizedBox(height: 20),
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  lineBarsData: [
                    LineChartBarData(
                      spots: [
                        FlSpot(0, ride.cadence.toDouble()),
                        FlSpot(1, ride.power.toDouble()),
                        FlSpot(2, ride.hr.toDouble()),
                      ],
                      isCurved: true,
                      color: ride.alertColor,
                      dotData: FlDotData(show: false),
                    ),
                  ],
                  titlesData: FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
