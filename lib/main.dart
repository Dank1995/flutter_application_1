import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter_tts/flutter_tts.dart';

// ------------------------------------------------------------
// Entry point
// ------------------------------------------------------------
void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final opt = OptimiserState();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => opt),
        ChangeNotifierProvider(create: (_) => BleManager()),
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
      title: 'Physiological Optimiser',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        appBarTheme: const AppBarTheme(centerTitle: true),
      ),
      home: const OptimiserDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ============================================================
// FEEDBACK MODES
// ============================================================

enum FeedbackMode { haptic, voice }

// ============================================================
// HR-ONLY OPTIMISER — WITH HAPTIC / VOICE FEEDBACK
// ============================================================

class OptimiserState extends ChangeNotifier {
  // ---------- Core HR state ----------
  double hr = 0;
  bool recording = false;

  // HR graph data
  final List<double> hrHistory = [];

  void _addHr(double bpm) {
    hrHistory.add(bpm);
    if (hrHistory.length > 60) hrHistory.removeAt(0);
  }

  // ---------- Sensitivity (1–5 bpm) ----------
  double sensitivity = 3.0;
  void setSensitivity(double value) {
    sensitivity = value;
    notifyListeners();
  }

  // ---------- Feedback mode ----------
  FeedbackMode feedbackMode = FeedbackMode.haptic;
  void setFeedbackMode(FeedbackMode m) {
    feedbackMode = m;
    notifyListeners();
  }

  // ---------- Text-to-speech (procedural audio) ----------
  final FlutterTts _tts = FlutterTts();
  bool _ttsInitialised = false;

  OptimiserState() {
    _initTts();
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage('en-US');
      await _tts.setSpeechRate(0.7); // a bit slower than normal
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      _ttsInitialised = true;
    } catch (_) {
      _ttsInitialised = false;
    }
  }

  Future<void> _voiceUp() async {
    if (!_ttsInitialised) return;
    await _tts.stop();
    // Short, clear cue
    await _tts.speak("Increase rhythm");
  }

  Future<void> _voiceDown() async {
    if (!_ttsInitialised) return;
    await _tts.stop();
    await _tts.speak("Ease rhythm");
  }

  // ---------- Combined signalling ----------
  void _signalUp() {
    if (feedbackMode == FeedbackMode.haptic) {
      _vibrateUp();
    } else {
      _voiceUp();
    }
  }

  void _signalDown() {
    if (feedbackMode == FeedbackMode.haptic) {
      _vibrateDown();
    } else {
      _voiceDown();
    }
  }

  // ---------- Gradient loop ----------
  Timer? _loopTimer;

  DateTime? _lastTestTime;
  bool _testInProgress = false;
  DateTime? _testStartTime;
  String? _direction; // "up" or "down"

  double? _hrBeforeTest;

  bool _plateau = false;
  double? _plateauHr;

  double _avgUp = 0;
  double _avgDown = 0;
  int _upN = 0;
  int _downN = 0;

  String _advice = "Tap ▶ to start workout";

  // ---------- Recording toggle ----------
  void toggleRecording() {
    recording = !recording;

    if (recording) {
      _reset();
      _startLoop();
      _advice = "Learning rhythm...";
    } else {
      _stopLoop();
      _advice = "Tap ▶ to start workout";
      _tts.stop();
    }
    notifyListeners();
  }

  void _reset() {
    _plateau = false;
    _plateauHr = null;
    _lastTestTime = null;
    _testInProgress = false;
    _testStartTime = null;
    _direction = null;
    _hrBeforeTest = null;

    _avgUp = 0;
    _avgDown = 0;
    _upN = 0;
    _downN = 0;
  }

  void _startLoop() {
    _loopTimer?.cancel();
    _loopTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _stopLoop() {
    _loopTimer?.cancel();
    _loopTimer = null;
  }

  // ---------- HR input ----------
  void setHr(double bpm) {
    if (bpm <= 0 || bpm.isNaN) return;
    hr = bpm;
    _addHr(bpm);
    notifyListeners();
  }

  // ============================================================
  // HR-ONLY GRADIENT TICK
  // ============================================================
  void _tick() {
    if (!recording || hr <= 0) return;

    final now = DateTime.now();
    const int interval = 15; // seconds between tests
    const int delay = 15; // wait after cue to evaluate

    if (_testInProgress) {
      if (_testStartTime != null &&
          now.difference(_testStartTime!).inSeconds >= delay) {
        _evaluateTest();
      }
      return;
    }

    if (_lastTestTime != null &&
        now.difference(_lastTestTime!).inSeconds < interval) {
      return;
    }

    // Plateau detection
    if (_plateau && _plateauHr != null) {
      if ((hr - _plateauHr!).abs() < sensitivity) {
        _advice = "Optimal rhythm";
        notifyListeners();
        return;
      }
      _plateau = false;
    }

    // Decide direction
    String dir;
    const double eps = 0.2; // difference between up/down means

    if (_upN + _downN < 2) {
      dir = (_direction == "up") ? "down" : "up";
    } else {
      if (_avgUp < _avgDown - eps) {
        dir = "up";
      } else if (_avgDown < _avgUp - eps) {
        dir = "down";
      } else {
        dir = (_direction == "up") ? "down" : "up";
      }
    }

    _startTest(dir);
  }

  void _startTest(String dir) {
    _testInProgress = true;
    _direction = dir;
    _testStartTime = DateTime.now();
    _lastTestTime = _testStartTime;

    _hrBeforeTest = hr;

    if (dir == "up") {
      _advice = "Increase rhythm";
      _signalUp();
    } else {
      _advice = "Ease rhythm";
      _signalDown();
    }

    notifyListeners();
  }

  void _evaluateTest() {
    _testInProgress = false;

    if (_hrBeforeTest == null) return;

    final delta = hr - _hrBeforeTest!;
    final double plate = sensitivity;

    // Plateau
    if (delta.abs() < plate) {
      _plateau = true;
      _plateauHr = hr;
      _advice = "Optimal rhythm";
      notifyListeners();
      return;
    }

    if (_direction == "up") {
      _upN++;
      _avgUp = ((_avgUp * (_upN - 1)) + delta) / _upN;
    } else {
      _downN++;
      _avgDown =
          ((_avgDown * (_downN - 1)) + delta) / _downN;
    }

    notifyListeners();
  }

  // ============================================================
  // HAPTICS
  // ============================================================
  void _vibrateUp() async {
    final hasVib = await Vibration.hasVibrator() ?? false;
    if (!hasVib) return;

    // Attempt a more noticeable pattern
    Vibration.vibrate(
      pattern: [0, 250, 150, 250],
      intensities: [128, 255, 255, 255],
    );
  }

  void _vibrateDown() async {
    final hasVib = await Vibration.hasVibrator() ?? false;
    if (!hasVib) return;

    Vibration.vibrate(duration: 150);
  }

  // ============================================================
  // Public getters
  // ============================================================

  String get rhythmAdvice => recording ? _advice : "Tap ▶ to start workout";

  Color get rhythmColor {
    if (!recording) return Colors.grey;
    if (_advice == "Optimal rhythm") return Colors.green;
    if (_advice == "Learning rhythm...") return Colors.grey;
    return Colors.orange;
  }
}

// ============================================================
// BLE MANAGER
// ============================================================

class BleManager extends ChangeNotifier {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  final Uuid hrService =
      Uuid.parse("0000180D-0000-1000-8000-00805F9B34FB");
  final Uuid hrMeasurement =
      Uuid.parse("00002A37-0000-1000-8000-00805F9B34FB");

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _hrSub;

  String? connectedId;
  String? connectedName;
  bool scanning = false;

  Future<void> ensurePermissions() async {
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.locationWhenInUse.request();
  }

  Future<List<DiscoveredDevice>> scanDevices(
      {Duration timeout = const Duration(seconds: 5)}) async {
    await ensurePermissions();
    final List<DiscoveredDevice> devices = [];
    scanning = true;
    notifyListeners();

    final completer = Completer<List<DiscoveredDevice>>();

    _scanSub = _ble.scanForDevices(withServices: []).listen((d) {
      if (!devices.any((x) => x.id == d.id)) {
        devices.add(d);
        notifyListeners();
      }
    }, onError: (_) {
      if (!completer.isCompleted) completer.complete(devices);
    });

    Future.delayed(timeout, () async {
      await _scanSub?.cancel();
      scanning = false;
      notifyListeners();
      if (!completer.isCompleted) completer.complete(devices);
    });

    return completer.future;
  }

  Future<void> connect(String id, String name, OptimiserState opt) async {
    _connSub?.cancel();
    _hrSub?.cancel();

    _connSub = _ble.connectToDevice(id: id).listen((event) {
      if (event.connectionState ==
          DeviceConnectionState.connected) {
        connectedId = id;
        connectedName = name.isEmpty ? "(unknown)" : name;
        notifyListeners();

        final hrChar = QualifiedCharacteristic(
          deviceId: id,
          serviceId: hrService,
          characteristicId: hrMeasurement,
        );

        _hrSub =
            _ble.subscribeToCharacteristic(hrChar).listen((data) {
          if (data.length > 1) {
            opt.setHr(data[1].toDouble());
          }
        });
      } else if (event.connectionState ==
          DeviceConnectionState.disconnected) {
        connectedId = null;
        connectedName = null;
        notifyListeners();
      }
    }, onError: (_) {
      connectedId = null;
      connectedName = null;
      notifyListeners();
    });
  }

  Future<void> disconnect() async {
    await _hrSub?.cancel();
    await _connSub?.cancel();
    connectedId = null;
    connectedName = null;
    notifyListeners();
  }
}

// ============================================================
// UI DASHBOARD
// ============================================================

class OptimiserDashboard extends StatelessWidget {
  const OptimiserDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final opt = context.watch<OptimiserState>();
    final ble = context.watch<BleManager>();

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            ble.connectedId == null
                ? Icons.bluetooth
                : Icons.bluetooth_connected,
          ),
          tooltip: ble.connectedName == null
              ? 'Bluetooth devices'
              : 'Connected: ${ble.connectedName}',
          onPressed: () => _openBleSheet(context),
        ),
        title: const Text("Physiological Optimiser"),
      ),
      body: Column(
        children: [
          const SizedBox(height: 20),
          Text(
            opt.rhythmAdvice,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: opt.rhythmColor,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text("HR: ${opt.hr.toStringAsFixed(0)} bpm"),

          // Sensitivity dropdown
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Sensitivity: "),
              DropdownButton<double>(
                value: opt.sensitivity,
                items: const [
                  DropdownMenuItem(value: 1.0, child: Text("1 bpm")),
                  DropdownMenuItem(value: 2.0, child: Text("2 bpm")),
                  DropdownMenuItem(value: 3.0, child: Text("3 bpm")),
                  DropdownMenuItem(value: 4.0, child: Text("4 bpm")),
                  DropdownMenuItem(value: 5.0, child: Text("5 bpm")),
                ],
                onChanged: (v) {
                  if (v != null) opt.setSensitivity(v);
                },
              ),
            ],
          ),

          // Feedback mode selector
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Feedback: "),
              DropdownButton<FeedbackMode>(
                value: opt.feedbackMode,
                items: const [
                  DropdownMenuItem(
                    value: FeedbackMode.haptic,
                    child: Text("Haptic"),
                  ),
                  DropdownMenuItem(
                    value: FeedbackMode.voice,
                    child: Text("Voice"),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) opt.setFeedbackMode(v);
                },
              ),
            ],
          ),

          const SizedBox(height: 10),
          SizedBox(height: 200, child: HrGraph(opt: opt)),
          const SizedBox(height: 10),
          if (ble.connectedName != null)
            Text(
              "Connected to: ${ble.connectedName}",
              style: const TextStyle(color: Colors.black54),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: opt.recording ? Colors.red : Colors.green,
        child: Icon(opt.recording ? Icons.stop : Icons.play_arrow),
        onPressed: () => opt.toggleRecording(),
      ),
    );
  }

  void _openBleSheet(BuildContext ctx) {
    final ble = ctx.read<BleManager>();
    showModalBottomSheet(
      context: ctx,
      builder: (_) => ChangeNotifierProvider.value(
        value: ble,
        child: const _BleBottomSheet(),
      ),
    );
  }
}

// ============================================================
// BLE DEVICE PICKER
// ============================================================

class _BleBottomSheet extends StatefulWidget {
  const _BleBottomSheet();

  @override
  State<_BleBottomSheet> createState() => _BleBottomSheetState();
}

class _BleBottomSheetState extends State<_BleBottomSheet> {
  List<DiscoveredDevice> devices = [];

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    final ble = context.read<BleManager>();
    devices = await ble.scanDevices();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleManager>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.bluetooth),
                const SizedBox(width: 8),
                Text(
                  ble.scanning ? "Scanning…" : "Bluetooth Devices",
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (ble.connectedId != null)
                  IconButton(
                    icon: const Icon(Icons.link_off),
                    tooltip: "Disconnect",
                    onPressed: () => ble.disconnect(),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: devices.isEmpty
                  ? const Text(
                      "No devices found.\nEnsure HR strap is on.",
                      textAlign: TextAlign.center,
                    )
                  : ListView.separated(
                      itemCount: devices.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final d = devices[i];
                        final name =
                            d.name.isNotEmpty ? d.name : "(unknown)";
                        return ListTile(
                          leading: const Icon(Icons.watch),
                          title: Text(name),
                          subtitle: Text(d.id),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            final opt =
                                context.read<OptimiserState>();
                            await ble.connect(d.id, name, opt);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        );
                      },
                    ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _startScan,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Rescan"),
                ),
                const Spacer(),
                TextButton(
                  child: const Text("Close"),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// HR GRAPH
// ============================================================

class HrGraph extends StatelessWidget {
  final OptimiserState opt;
  const HrGraph({super.key, required this.opt});

  @override
  Widget build(BuildContext context) {
    final points = opt.hrHistory
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value))
        .toList();

    double minY = 50;
    double maxY = 180;

    if (points.isNotEmpty) {
      final vals = points.map((e) => e.y).toList();
      minY = (vals.reduce((a, b) => a < b ? a : b) - 5).clamp(40, 200);
      maxY = (vals.reduce((a, b) => a > b ? a : b) + 5).clamp(50, 220);
    }

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: points.isEmpty ? 1 : points.length.toDouble(),
        minY: minY,
        maxY: maxY,
        lineBarsData: [
          LineChartBarData(
            spots: points,
            isCurved: true,
            barWidth: 3,
            color: Colors.green,
            dotData: FlDotData(show: false),
          )
        ],
        titlesData: FlTitlesData(show: false),
        gridData: FlGridData(show: false),
        borderData: FlBorderData(show: false),
      ),
    );
  }
}
