final flutterBlue = FlutterBluePlus.instance; // ✅ correct singleton
BluetoothDevice? connectedDevice;

void _startBluetoothScan() async {
  await flutterBlue.startScan(timeout: const Duration(seconds: 5));

  flutterBlue.scanResults.listen((results) async {
    for (ScanResult r in results) {
      if (connectedDevice == null) {
        connectedDevice = r.device;
        await connectedDevice!.connect(
          timeout: const Duration(seconds: 10),
        );
        await flutterBlue.stopScan();
      }
    }
  });
}


