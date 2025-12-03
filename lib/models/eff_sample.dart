import 'package:hive/hive.dart';

part 'eff_sample.g.dart';

@HiveType(typeId: 1)
class EffSample {
  @HiveField(0)
  DateTime time;

  @HiveField(1)
  double efficiency;

  @HiveField(2)
  int rhythm; // renamed from cadence — stores rhythm bucket

  @HiveField(3)
  String prompt; // what feedback was given (“up”, “down”, “optimal”)

  EffSample(this.time, this.efficiency, this.rhythm, this.prompt);
}
