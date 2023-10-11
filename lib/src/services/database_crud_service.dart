import "dart:async";
import "dart:convert";
import "dart:math";

import "package:http/http.dart" show MultipartFile;

import "../dtos/jsonable.dart";
import "../dtos/record_model.dart";
import "../dtos/result_list.dart";
import "base_crud_service.dart";

abstract class DatabaseCrudService<M extends Jsonable>
    extends BaseCrudService<M> {
  DatabaseCrudService(super.client, this._collectionIdOrName);

  final String _collectionIdOrName;

  void _crdt(String id, Map<String, dynamic> data) {
    for (final entry in data.entries) {
      const systemKeys = [
        "id",
        "created",
        "updated",
        "timestamp",
        "expand",
      ];
      if (systemKeys.contains(entry.key)) continue;
      dynamic value = entry.value;
      if (value is Map) {
        value = jsonEncode(value);
      }
      client.database.execute(
        """
        INSERT INTO changes (`table`, column, row_id, timestamp, user_id, value)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [
          _collectionIdOrName,
          entry.key,
          id,
          DateTime.now().toUtc().toIso8601String(),
          _userId(data),
          value,
        ],
      );
    }
  }

  void _save(
    String id,
    Map<String, dynamic> data, {
    bool crdt = true,
  }) {
    // Check for existing
    final existing = client.database.select(
      """
      SELECT * FROM records
      WHERE row_id = ?
      AND collection = ?
      """,
      [id, _collectionIdOrName],
    );
    if (existing.isNotEmpty) {
      // Replace record
      final raw = existing.first["data"] as String;
      final original = jsonDecode(raw) as Map<String, dynamic>;
      final merged = {...original, ...data};
      client.database.execute(
        """
        UPDATE records
        SET data = ?, updated = ?
        WHERE row_id = ?
        AND collection = ?
        """,
        [
          jsonEncode(merged),
          DateTime.now().toUtc().toIso8601String(),
          id,
          _collectionIdOrName,
        ],
      );
      if (crdt) _crdt(id, merged);
    } else {
      // Insert record
      if (crdt) _crdt(id, data);
      client.database.execute(
        """
        INSERT INTO records (row_id, data, collection, deleted, created, updated)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [
          id,
          jsonEncode(data),
          _collectionIdOrName,
          0,
          DateTime.now().toUtc().toIso8601String(),
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
    }
  }

  String _newId() {
    // Generate random 13 digit string
    final random = Random();
    final id = List.generate(13, (_) => random.nextInt(10)).join();
    return id;
  }

  String _userId(Map<String, dynamic> data) {
    if (data["user_id"] is String) {
      return data["user_id"] as String;
    }
    if (client.authStore.model is RecordModel) {
      return (client.authStore.model as RecordModel).id;
    }
    return "";
  }

  @override
  Future<M> create({
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
    List<MultipartFile> files = const [],
    Map<String, String> headers = const {},
    String? expand,
    String? fields,
  }) {
    final id = (body.containsKey("id") ? body["id"] : _newId()) as String;
    _save(id, body);
    if (client.offline) throw Exception("Offline");
    return super.create(
      body: body,
      query: query,
      files: files,
      headers: headers,
      expand: expand,
      fields: fields,
    );
  }

  @override
  Future<M> update(
    String id, {
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
    List<MultipartFile> files = const [],
    Map<String, String> headers = const {},
    String? expand,
    String? fields,
  }) {
    _save(id, body);
    if (client.offline) throw Exception("Offline");
    return super.update(
      id,
      body: body,
      query: query,
      files: files,
      headers: headers,
      expand: expand,
      fields: fields,
    );
  }

  @override
  Future<void> delete(
    String id, {
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) {
    _save(id, {"deleted": 1});
    if (client.offline) throw Exception("Offline");
    return super.delete(
      id,
      body: body,
      query: query,
      headers: headers,
    );
  }

  @override
  Future<M> getOne(
    String id, {
    String? expand,
    String? fields,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) async {
    if (client.offline) throw Exception("Offline");
    final result = await super.getOne(
      id,
      expand: expand,
      fields: fields,
      query: query,
      headers: headers,
    );
    _save(id, result.toJson(), crdt: false);
    return result;
  }

  @override
  Future<ResultList<M>> getList({
    int page = 1,
    int perPage = 30,
    bool skipTotal = false,
    String? expand,
    String? filter,
    String? sort,
    String? fields,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) async {
    if (client.offline) throw Exception("Offline");
    final result = await super.getList(
      page: page,
      perPage: perPage,
      skipTotal: skipTotal,
      expand: expand,
      filter: filter,
      sort: sort,
      fields: fields,
      query: query,
      headers: headers,
    );
    for (final item in result.items) {
      final data = item.toJson();
      if (data.containsKey("id")) {
        final id = data["id"] as String;
        _save(id, data, crdt: false);
      }
    }
    return result;
  }

  M? getOneOffline(
    String id, {
    String? expand,
    String? fields,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) {
    final result = client.database.select(
      """
      SELECT * FROM records
      WHERE row_id = ?
      AND collection = ?
      """,
      [id, _collectionIdOrName],
    );
    if (result.isEmpty) return null;
    final raw = result.first["data"] as String;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return itemFactoryFunc(data);
  }

  ResultList<M> getListOffline({
    int? page,
    int? perPage,
    bool skipTotal = false,
    String? expand,
    String? filter,
    String? sort,
    String? fields,
    String? userId,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) {
    var query = """
    SELECT * FROM records
    WHERE collection = ?
    """;
    if (userId != null) {
      query += "AND user_id = ?\n";
    }
    if (perPage != null) {
      query += "LIMIT ?\n";
    }
    if (page != null) {
      query += "OFFSET ?\n";
    }
    query += "ORDER BY created DESC";
    final result = client.database.select(
      query,
      [
        _collectionIdOrName,
        if (userId != null) userId,
        if (perPage != null) perPage,
        if (page != null) (page - 1) * perPage!,
      ],
    );
    final items = result.map((e) {
      final raw = e["data"] as String;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return itemFactoryFunc(data);
    }).toList();
    return ResultList<M>(
      items: items,
      page: page ?? 1,
      perPage: perPage ?? items.length,
      totalPages: 1,
      totalItems: items.length,
    );
  }

  StreamSubscription<dynamic> watchOffline(
    String target,
    void Function(M item) callback,
  ) {
    return client.database.updates.listen((event) {
      if (event.tableName == "records") {
        final id = event.rowId;
        final result = client.database.select(
          "SELECT * FROM records WHERE id = ?",
          [id],
        );
        if (result.isNotEmpty) {
          final row = result.first;
          final collection = row["collection"] as String;
          final rowId = row["row_id"] as String;
          if (collection == _collectionIdOrName &&
              (target == rowId || target == "*")) {
            final raw = row["data"] as String;
            final data = jsonDecode(raw) as Map<String, dynamic>;
            callback(itemFactoryFunc(data));
          }
        }
      }
    });
  }
}
