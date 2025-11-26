import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => RideState()),
        Provider(create: (_) => BleManager()),
      ],
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
// Ride State
// -----------------------------
class RideState extends ChangeNotifier {
  int cadence = 0;
  int power = 0;
  int hr = 0;
  int optimalCadence = 90;
  double efficiency = 0;

  void setHr(int value) {
    hr = value;
    _updateEfficiency();
  }

  void setCadence(int value) {
    cadence = value;
    notifyListeners();
  }

  void setPower(int value) {
    power = value;
    _updateEfficiency();
  }

  void _updateEfficiency() {
    if (hr > 0) efficiency = power / hr;
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

  Color get alertColor => (cadence - optimalCadence).abs() > 5 ? Colors.red : Colors.green;
}

// -----------------------------
// BLE Manager
// -----------------------------
class BleManager {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final Uuid heartRateService = Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid heartRateMeasurement = Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  final Uuid cscService = Uuid.parse("00001816-0000-1000-8000-00805F9B34FB");
  final Uuid cscMeasurement = Uuid.parse("00002A5B-0000-1000-8000-00805F9B34FB");

  final Uuid cyclingPowerService = Uuid.parse("00001818-0000-1000-8000-00805F9B34FB");
  final Uuid cyclingPowerMeasurement = Uuid.parse("00002A63-0000-1000-8000-00805F9B34FB");

  Stream<List<DiscoveredDevice>> scan() {
    final devices = <DiscoveredDevice>[];
    return _ble.scanForDevices(withServices: []).map((d) {
      if (!devices.any((x) => x.id == d.id)) devices.add(d);
      return devices;
    });
  }

  Future<void> connect(String deviceId, RideState ride) async {
    _ble.connectToDevice(id: deviceId).listen((update) {
      if (update.connectionState == DeviceConnectionState.connected) {
        // Subscribe to HR
        final hrChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: heartRateService,
          characteristicId: heartRateMeasurement,
        );
        _ble.subscribeToCharacteristic(hrChar).listen((data) {
          if (data.length > 1) ride.setHr(data[1]);
        });

        // Subscribe to cadence (CSC)
        final cscChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: cscService,
          characteristicId: cscMeasurement,
        );
        _ble.subscribeToCharacteristic(cscChar).listen((data) {
          if (data.length > 3) {
            final revs = (data[1] | (data[2] << 8));
            final time = (data[3] | (data[4] << 8));
            // Simplified cadence calculation
            ride.setCadence(revs % 120);
          }
        });

        // Subscribe to power
        final powerChar = QualifiedCharacteristic(
          deviceId: deviceId,
          serviceId: cyclingPowerService,
          characteristicId: cyclingPowerMeasurement,
        );
        _ble.subscribeToCharacteristic(powerChar).listen((data) {
          if (data.length > 3) {
            final watts = (data[2] | (data[3] << 8));
            ride.setPower(watts);
          }
        });
      }
    });
  }
}

// -----------------------------
// Ride Dashboard
// -----------------------------
class RideDashboard extends StatefulWidget {
  const RideDashboard({super.key});
  @override
  State<RideDashboard> createState() => _RideDashboardState();
}

class _RideDashboardState extends State<RideDashboard> {
  @override
  void initState() {
    super.initState();
    _ensurePermissions();
  }

  Future<void> _ensurePermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  @override
  Widget build(BuildContext context) {
    final ride = Provider.of<RideState>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text("Ride Dashboard"),
        actions: [
          IconButton(
            icon: const Icon(Icons.bluetooth_searching),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BleScannerPage()),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(ride.shiftMessage,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: ride.alertColor)),
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
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

//