import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:intl/intl.dart';

void main() {
  runApp(CadenceCoachApp());
}

class CadenceCoachApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cadence Coach',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: CadenceHomePage(),
    );
  }
}

class CadenceHomePage extends StatefulWidget {
  @override
  _CadenceHomePageState createState() => _CadenceHomePageState();
}

class _CadenceHomePageState extends State<CadenceHomePage> {
  final FlutterBluePlus flutterBlue = FlutterBluePlus.instance;
  StreamSubscription? scanSubscription;
  BluetoothDevice? connectedDevice;
  List<BluetoothDevice> devicesList = [];
  Position? currentPosition;

  @override
  void initState() {
    super.initState();
    _initLocation();
    _startBluetoothScan();
  }

  @override
  void dispose() {
    scanSubscription?.cancel();
    connectedDevice?.disconnect();
    super.dispose();
  }

  Future<void> _initLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('Location services are disabled.');
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }

    currentPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
  }

  void _startBluetoothScan() async {
    scanSubscription = flutterBlue.scan(timeout: const Duration(seconds: 5)).listen(
      (scanResult) async {
        if (!devicesList.contains(scanResult.device)) {
          setState(() => devicesList.add(scanResult.device));
        }

        // Auto-connect to first available device
        if (connectedDevice == null) {
          connectedDevice = scanResult.device;
          try {
            await connectedDevice!.connect(
              autoConnect: false,
              timeout: const Duration(seconds: 10),
            );
            await scanSubscription?.cancel();
          } catch (e) {
            print('Connection error: $e');
          }
        }
      },
      onDone: () => print('Scan completed'),
      onError: (e) => print('Scan error: $e'),
    );
  }

  Future<void> logRideData() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = '${directory.path}/ride_log.csv';
    final file = File(path);

    final now = DateTime.now();
    final formattedDate = DateFormat('yyyy-MM-dd HH:mm:ss').format(now);
    final latitude = currentPosition?.latitude ?? 0.0;
    final longitude = currentPosition?.longitude ?? 0.0;

    final line = '$formattedDate,$latitude,$longitude\n';
    await file.writeAsString(line, mode: FileMode.append);
    print('Logged: $line');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Cadence Coach')),
      body: Column(
        children: [
          ElevatedButton(
            onPressed: _startBluetoothScan,
            child: Text('Scan Bluetooth Devices'),
          ),
          ElevatedButton(
            onPressed: logRideData,
            child: Text('Log Ride Data'),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: devicesList.length,
              itemBuilder: (context, index) {
                final device = devicesList[index];
                return ListTile(
                  title: Text(device.name.isEmpty ? 'Unknown Device' : device.name),
                  subtitle: Text(device.id.id),
                  trailing: connectedDevice?.id == device.id
                      ? Icon(Icons.bluetooth_connected)
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
