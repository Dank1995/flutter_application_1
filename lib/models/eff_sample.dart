import 'package:hive/hive.dart';

part 'eff_sample.g.dart';

@HiveType(typeId: 1)
class EffSample {
  @HiveField(0)
  DateTime time;

  @HiveField(1)
  double efficiency;

  @HiveField(2)
  int rhythm; // <-- NOT cadence, NOT bucket

  @HiveField(3)
  String prompt; // “up”, “down”, “optimal”

  EffSample(this.time, this.efficiency, this.rhythm, this.prompt);
}
