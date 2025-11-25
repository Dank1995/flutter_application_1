import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Cadence Coach Optimizer',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const Dashboard(),
    );
  }
}

class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> {
  final FlutterBluePlus flutterBlue = FlutterBluePlus.instance;
  StreamSubscription? scanSub;

  int cadence = 0;
  int power = 0;
  int hr = 0;

  List<List<dynamic>> csvData = [
    ['Timestamp', 'Cadence', 'Power', 'HR']
  ];

  Timer? _optimizerTimer;

  @override
  void initState() {
    super.initState();
    startScan();
    _optimizerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      applyOptimizer();
    });
  }

  void startScan() {
    scanSub = flutterBlue.scan(timeout: const Duration(seconds: 5)).listen((result) {
      setState(() {
        // Convert RSSI to raw int values for demo purposes
        cadence = 80 + (result.rssi % 10).toInt();
        power = 150 + (result.rssi % 20).toInt();
        hr = 120 + (result.rssi % 15).toInt();
      });

      // Save to CSV
      csvData.add([DateTime.now().toIso8601String(), cadence, power, hr]);
    });
  }

  void stopScan() {
    scanSub?.cancel();
  }

  void applyOptimizer() {
    setState(() {
      // Simple smoothing: moving average of last 3 entries
      if (csvData.length > 3) {
        int last = csvData.length - 1;
        cadence = ((csvData[last][1] + csvData[last-1][1] + csvData[last-2][1]) ~/ 3).toInt();
        power = ((csvData[last][2] + csvData[last-1][2] + csvData[last-2][2]) ~/ 3).toInt();
        hr = ((csvData[last][3] + csvData[last-1][3] + csvData[last-2][3]) ~/ 3).toInt();
      }
    });
  }

  Future<void> exportCsv() async {
    String csvString = const ListToCsvConverter().convert(csvData);
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/session_${DateTime.now().millisecondsSinceEpoch}.csv';
    final file = File(path);
    await file.writeAsString(csvString);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('CSV exported: $path')));
  }

  @override
  void dispose() {
    scanSub?.cancel();
    _optimizerTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BLE Cadence Coach Optimizer')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Cadence: $cadence rpm', style: const TextStyle(fontSize: 22)),
            Text('Power: $power W', style: const TextStyle(fontSize: 22)),
            Text('Heart Rate: $hr bpm', style: const TextStyle(fontSize: 22)),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: exportCsv, child: const Text('Export CSV')),
          ],
        ),
      ),
    );
  }
}
