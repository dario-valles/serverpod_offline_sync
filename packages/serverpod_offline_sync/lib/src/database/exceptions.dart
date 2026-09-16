/// A caller tried to author a unique text value reserved for sync projection.
class OfflineSyncReservedValueException implements Exception {
  /// Creates an exception identifying the rejected field and value.
  const OfflineSyncReservedValueException({
    required this.tableName,
    required this.columnName,
    required this.value,
  });

  /// The synchronized table containing the unique column.
  final String tableName;

  /// The unique text column being authored.
  final String columnName;

  /// The value ending in a reserved generated suffix.
  final String value;

  @override
  String toString() =>
      'Reserved generated unique value for $tableName.$columnName: $value';
}
