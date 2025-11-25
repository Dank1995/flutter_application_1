import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cadence Coach',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late StreamSubscription<List<ScanResult>> scanSub;
  int cadence = 0;
  int power = 0;
  int hr = 0;

  final List<List<dynamic>> csvData = [
    ["Timestamp", "Cadence", "Power", "HR"]
  ];

  @override
  void dispose() {
    scanSub.cancel();
    super.dispose();
  }

  void startScanning() {
    // Listen to static scanResults stream
    scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (var result in results) {
        setState(() {
          cadence = 80 + (result.rssi % 10).toInt();
          power = 150 + (result.rssi % 20).toInt();
          hr = 120 + (result.rssi % 15).toInt();

          csvData.add([
            DateTime.now().toIso8601String(),
            cadence,
            power,
            hr
          ]);
        });
      }
    });

    // Start scanning (static method)
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
  }

  void stopScanning() async {
    await FlutterBluePlus.stopScan();
    await scanSub.cancel();
  }

  Future<void> exportCsv() async {
    final csvString = const ListToCsvConverter().convert(csvData);
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/cadence_data.csv';
    final file = File(path);
    await file.writeAsString(csvString);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('CSV saved at $path')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cadence Coach'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Cadence: $cadence rpm'),
            Text('Power: $power W'),
            Text('Heart Rate: $hr bpm'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: startScanning,
              child: const Text('Start Scan'),
            ),
            ElevatedButton(
              onPressed: stopScanning,
              child: const Text('Stop Scan'),
            ),
            ElevatedButton(
              onPressed: exportCsv,
              child: const Text('Export CSV'),
            ),
          ],
        ),
      ),
    );
  }
}
