/// A caller tried to author a unique value reserved for sync projection.
class OfflineSyncReservedValueException implements Exception {
  /// Creates an exception identifying the rejected field and value.
  const OfflineSyncReservedValueException({
    required this.tableName,
    required this.columnName,
    required this.value,
  });

  /// The synchronized table containing the unique column.
  final String tableName;

  /// The unique column being authored.
  final String columnName;

  /// The rejected text or UUID value, rendered as a string.
  final String value;

  @override
  String toString() =>
      'Reserved generated unique value for $tableName.$columnName: $value';
}
