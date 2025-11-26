import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
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
      home: const DeviceSelectionScreen(),
    );
  }
}

// -----------------------------
// Bluetooth Device Selection
// -----------------------------
class DeviceSelectionScreen extends StatelessWidget {
  const DeviceSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Select Sensor")),
      body: StreamBuilder<List<ScanResult>>(
        stream: FlutterBluePlus.scanResults,   // ✅ use scanResults stream
        initialData: const [],
        builder: (context, snapshot) {
          final results = snapshot.data ?? [];
          return ListView(
            children: results.map((r) => ListTile(
              title: Text(r.device.name.isEmpty ? r.device.remoteId.toString() : r.device.name),
              subtitle: Text(r.device.remoteId.toString()),
              onTap: () async {
                await Provider.of<RideState>(context, listen: false)
                    .connectToDevice(r.device);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const RideDashboard()),
                );
              },
            )).toList(),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.refresh),
        onPressed: () => FlutterBluePlus.startScan(timeout: const Duration(seconds: 4)), // ✅ updated API
      ),
    );
  }
}

// -----------------------------
// Ride State / Optimizer
// -----------------------------
class RideState extends ChangeNotifier {
  int cadence = 0;
  int power = 0;
  int hr = 0;
  int optimalCadence = 90;
  double efficiency = 0;

  BluetoothDevice? device;
  StreamSubscription<List<int>>? characteristicSub;

  final Map<int, Map<int, List<double>>> efficiencyMap = {};

  Future<void> connectToDevice(BluetoothDevice d) async {
    device = d;
    await device!.connect(
      autoConnect: false,
      license: License.bsd,   // ✅ required parameter
    );

    final services = await device!.discoverServices();
    for (var service in services) {
      for (var char in service.characteristics) {
        if (char.properties.notify) {
          await char.setNotifyValue(true);
          characteristicSub = char.lastValueStream.listen((data) {
            if (data.length >= 3) {
              cadence = data[0];
              power = data[1];
              hr = data[2];
              _updateEfficiency();
              notifyListeners();
            }
          });
        }
      }
    }
  }

  void _updateEfficiency() {
    if (hr > 0) {
      efficiency = power / hr;
      final powerBucket = (power / 10).round() * 10;
      final cadenceBucket = (cadence / 2).round() * 2;
      efficiencyMap.putIfAbsent(powerBucket, () => {});
      efficiencyMap[powerBucket]!.putIfAbsent(cadenceBucket, () => []);
      efficiencyMap[powerBucket]![cadenceBucket]!.add(efficiency);

      final cadences = efficiencyMap[powerBucket]!;
      if (cadences.isNotEmpty) {
        final avgEff = cadences.map((c, eList) => MapEntry(c, eList.reduce((a, b) => a + b)/eList.length));
        optimalCadence = avgEff.entries.reduce((a,b) => a.value > b.value ? a : b).key;
      }
    }
  }

  String get shiftMessage {
    final diff = cadence - optimalCadence;
    if (diff.abs() > 5) {
      return diff > 0 ? "Shift to higher gear ($optimalCadence RPM)" : "Shift to lower gear ($optimalCadence RPM)";
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


