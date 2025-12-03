// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'eff_sample.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class EffSampleAdapter extends TypeAdapter<EffSample> {
  @override
  final int typeId = 1;

  @override
  EffSample read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return EffSample(
      fields[0] as DateTime,
      fields[1] as double,
      fields[2] as int,
      fields[3] as String,
    );
  }

  @override
  void write(BinaryWriter writer, EffSample obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.time)
      ..writeByte(1)
      ..write(obj.efficiency)
      ..writeByte(2)
      ..write(obj.rhythm)
      ..writeByte(3)
      ..write(obj.prompt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EffSampleAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
