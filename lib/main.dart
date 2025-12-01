import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fl_chart/fl_chart.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationDocumentsDirectory();
  await Hive.initFlutter(dir.path);
  await Hive.openBox('sessions');
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

// -----------------------------
// App
// -----------------------------
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
// Ride State with historical efficiency
// -----------------------------
class RideState extends ChangeNotifier {
  int cadence = 0; // RPM
  int power = 0; // Watts
  int hr = 0; // BPM
  double efficiency = 0;

  int optimalCadence = 90;

  final int windowSize = 5;
  final List<Map<String, dynamic>> recentEff = [];

  final Box sessions = Hive.box('sessions');

  void setHr(int value) {
    hr = value;
    _updateEfficiency();
  }

  void setCadence(int value) {
    cadence = value;
    _updateEfficiency();
  }

  void setPower(int value) {
    power = value;
    _updateEfficiency();
  }

  void _updateEfficiency() {
    if (hr > 0) {
      efficiency = power / hr;

      recentEff.add({"cadence": cadence, "efficiency": efficiency});
      if (recentEff.length > windowSize) recentEff.removeAt(0);

      _storeSession();
      optimalCadence = _predictOptimalCadence();
    }
    notifyListeners();
  }

  void _storeSession() {
    final list = sessions.get('all_sessions', defaultValue: <Map<String, dynamic>>[])!.cast<Map<String, dynamic>>();
    list.add({"cadence": cadence, "power": power, "hr": hr, "efficiency": efficiency, "time": DateTime.now().toIso8601String()});
    sessions.put('all_sessions', list);
  }

  int _predictOptimalCadence() {
    final allSessions = sessions.get('all_sessions', defaultValue: <Map<String, dynamic>>[])!.cast<Map<String, dynamic>>();
    if (allSessions.isEmpty) return 90;

    // Bucket cadence to efficiencies
    final Map<int, List<double>> cadEff = {};
    for (var s in allSessions) {
      final c = s['cadence'] as int;
      final e = s['efficiency'] as double;
      cadEff.putIfAbsent(c, () => []).add(e);
    }

    int bestCad = cadEff.entries
        .map((e) => MapEntry(e.key, e.value.reduce((a, b) => a + b) / e.value.length))
        .reduce((a, b) => a.value > b.value ? a : b)
        .key;
    return bestCad;
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

  Color get alertColor =>
      (cadence - optimalCadence).abs() > 5 ? Colors.red : Colors.green;

  List<FlSpot> getEfficiencySpots() {
    final allSessions = sessions.get('all_sessions', defaultValue: <Map<String, dynamic>>[])!.cast<Map<String, dynamic>>();
    return List.generate(allSessions.length, (i) => FlSpot(i.toDouble(), allSessions[i]['efficiency'] as double));
  }
}

// -----------------------------
// BLE Manager
// -----------------------------
class BleManager {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  final Uuid heartRateService = Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid heartRateMeasurement = Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");
  final Uuid rscService = Uuid.parse("00001814-0000-1000-8000-00805F9B34FB");
  final Uuid rscMeasurement = Uuid.parse("00002A53-0000-1000-8000-00805F9B34FB");
  final Uuid cyclingPowerService = Uuid.parse("00001818-0000-1000-8000-00805F9B34FB");
  final Uuid powerMeasurement = Uuid.parse("00002A63-0000-1000-8000-00805F9B34FB");

  Stream<List<DiscoveredDevice>> scan() {
    final devices = <DiscoveredDevice>[];
    return _ble.scanForDevices(withServices: []).map((d) {
      if (!devices.any((x) => x.id == d.id)) devices.add(d);
      return devices;
    });
  }

  int _u16(List<int> b, int offset) => (b[offset] & 0xFF) | ((b[offset + 1] & 0xFF) << 8);
  int _i16(List<int> b, int offset) {
    final v = _u16(b, offset);
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  Future<void> connect(String deviceId, RideState ride) async {
    _ble.connectToDevice(id: deviceId).listen((update) {
      if (update.connectionState == DeviceConnectionState.connected) {
        // HR
        final hrChar = QualifiedCharacteristic(deviceId: deviceId, serviceId: heartRateService, characteristicId: heartRateMeasurement);
        _ble.subscribeToCharacteristic(hrChar).listen((data) {
          if (data.length > 1) ride.setHr(data[1]);
        });

        // Power
        final powerChar = QualifiedCharacteristic(deviceId: deviceId, serviceId: cyclingPowerService, characteristicId: powerMeasurement);
        _ble.subscribeToCharacteristic(powerChar).listen((data) {
          if (data.length >= 4) ride.setPower(_i16(data, 2));
        });

        // Cadence
        final rscChar = QualifiedCharacteristic(deviceId: deviceId, serviceId: rscService, characteristicId: rscMeasurement);
        _ble.subscribeToCharacteristic(rscChar).listen((data) {
          if (data.isEmpty) return;
          final bytes = List<int>.from(data);
          int cadenceFromRsc = bytes.length > 1 ? bytes[1] : 0;
          if (cadenceFromRsc > 0) ride.setCadence(cadenceFromRsc);
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
    await Permission.locationWhenInUse.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
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
                Navigator.push(context, MaterialPageRoute(builder: (_) => BleScannerPage()));
              }),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(ride.shiftMessage, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: ride.alertColor)),
                  const SizedBox(height: 12),
                  Text("Cadence: ${ride.cadence} RPM"),
                  Text("Power: ${ride.power} W"),
                  Text("Heart Rate: ${ride.hr} BPM"),
                  Text("Efficiency: ${ride.efficiency.toStringAsFixed(2)} W/BPM"),
                ],
              ),
            ),
          ),
          SizedBox(
            height: 200,
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: LineChart(
                LineChartData(
                  minY: 0,
                  lineBarsData: [
                    LineChartBarData(
                      spots: ride.getEfficiencySpots(),
                      isCurved: true,
                      color: Colors.green,
                      barWidth: 3,
                      dotData: FlDotData(show: false),
                    ),
                  ],
                  titlesData: FlTitlesData(show: true, bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)), leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true))),
                  gridData: FlGridData(show: true),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -----------------------------
// BLE Scanner Page
// -----------------------------
class BleScannerPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final ble = context.read<BleManager>();
    final ride = context.read<RideState>();

    return Scaffold(
      appBar: AppBar(title: const Text("Scan & Connect")),
      body: StreamBuilder<List<DiscoveredDevice>>(
        stream: ble.scan(),
        builder: (context, snapshot) {
          final devices = snapshot.data ?? [];
          return ListView.builder(
            itemCount: devices.length,
            itemBuilder: (context, index) {
              final d = devices[index];
              return ListTile(
                title: Text(d.name.isNotEmpty ? d.name : "Unknown"),
                subtitle: Text(d.id),
                onTap: () {
                  ble.connect(d.id, ride);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Connecting to ${d.name}")));
                },
              );
            },
          );
        },
      ),
    );
  }
}
