import 'package:dart_mappable/dart_mappable.dart';

part 'protocol_type.mapper.dart';

@MappableEnum(defaultValue: ProtocolType.https)
enum ProtocolType { http, https }
