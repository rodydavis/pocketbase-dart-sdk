import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;
import "package:sqlite3/common.dart";

import "auth_store.dart";
import "client_exception.dart";
import "dtos/record_model.dart";
import "multipart_request.dart";
import "services/admin_service.dart";
import "services/backup_service.dart";
import "services/collection_service.dart";
import "services/file_service.dart";
import "services/health_service.dart";
import "services/log_service.dart";
import "services/realtime_service.dart";
import "services/record_service.dart";
import "services/settings_service.dart";

const bool isWeb = bool.fromEnvironment("dart.library.js_util");

/// The main PocketBase API client.
class PocketBase {
  /// The PocketBase backend base url address (eg. 'http://127.0.0.1:8090').
  String baseUrl;

  /// Optional language code (default to `en-US`) that will be sent
  /// with the requests to the server as `Accept-Language` header.
  String lang;

  /// SQLite database used for offline storage and sync
  CommonDatabase database;

  /// Simple flag to enable/disable offline mode.
  bool offline = false;

  /// An instance of the local [AuthStore] service.
  late final AuthStore authStore;

  /// An instance of the service that handles the **Admin APIs**.
  late final AdminService admins;

  /// An instance of the service that handles the **Collection APIs**.
  late final CollectionService collections;

  /// An instance of the service that handles the **File APIs**.
  late final FileService files;

  /// An instance of the service that handles the **Realtime APIs**.
  ///
  /// This service is usually used with custom realtime actions.
  /// For records realtime subscriptions you can use the subscribe/unsubscribe
  /// methods available in the `collection()` RecordService.
  late final RealtimeService realtime;

  /// An instance of the service that handles the **Settings APIs**.
  late final SettingsService settings;

  /// An instance of the service that handles the **Log APIs**.
  late final LogService logs;

  /// An instance of the service that handles the **Health APIs**.
  late final HealthService health;

  /// The service that handles the **Backup and restore APIs**.
  late final BackupService backups;

  /// The underlying http client that will be used to send the request.
  /// This is used primarily for the unit tests.
  late final http.Client Function() httpClientFactory;

  /// Cache of all created RecordService instances.
  final _recordServices = <String, RecordService>{};

  PocketBase(
    this.baseUrl,
    this.database, {
    this.lang = "en-US",
    AuthStore? authStore,
    // used primarily for the unit tests
    http.Client Function()? httpClientFactory,
  }) {
    this.authStore = authStore ?? AuthStore();
    this.httpClientFactory = httpClientFactory ?? http.Client.new;

    admins = AdminService(this);
    collections = CollectionService(this);
    files = FileService(this);
    realtime = RealtimeService(this);
    settings = SettingsService(this);
    logs = LogService(this);
    health = HealthService(this);
    backups = BackupService(this);

    database
      ..execute("""CREATE TABLE IF NOT EXISTS changes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        `table` TEXT NOT NULL,
        column TEXT NOT NULL,
        row_id TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        user_id TEXT,
        value TEXT
      )""")
      ..execute("""CREATE TABLE IF NOT EXISTS records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        row_id TEXT NOT NULL,
        data TEXT NOT NULL,
        collection TEXT NOT NULL,
        deleted INTEGER,
        created TEXT NOT NULL,
        updated TEXT NOT NULL
      )""")
      ..execute("""CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        data,
        url TEXT NOT NULL,
        created TEXT NOT NULL,
        updated TEXT NOT NULL
      )""");
  }

  Future<void> sync({String? user, int limit = 1000}) async {
    final client = httpClientFactory();
    final syncUrl = buildUrl("/api/sync");

    final changes = database
        .select("SELECT * FROM changes")
        .toList()
        .map((e) => {
              "table": e["table"],
              "column": e["column"],
              "row_id": e["row_id"],
              "timestamp": e["timestamp"],
              "user_id": e["user_id"],
              "value": e["value"],
            })
        .toList();
    final oldest = changes.isEmpty
        ? null
        : changes.map((e) => DateTime.parse(e["timestamp"] as String)).reduce(
              (value, element) =>
                  value.compareTo(element) < 0 ? value : element,
            );

    // Push changes
    final pushRes = await client.post(
      syncUrl,
      headers: {
        "Content-Type": "application/json",
      },
      body: jsonEncode({"changes": changes}),
    );
    if (pushRes.statusCode != 200) {
      throw Exception("Failed to push changes");
    }
    // Delete pushed changes
    database.execute("DELETE FROM changes");

    // Pull changes
    var uri = syncUrl.toString();
    final query = {
      if (oldest != null)
        "timestamp": oldest.toUtc().toLocal().toIso8601String(),
      "compress": true,
      "user": user,
      "limit": limit,
    };
    if (query.isNotEmpty) {
      uri += "?${query.entries.map((e) => "${e.key}=${e.value}").join("&")}";
    }
    final pullRes = await client.get(Uri.parse(uri));
    if (pullRes.statusCode != 200) {
      throw Exception("Failed to pull changes");
    }
    final pullData = jsonDecode(pullRes.body) as Map<String, dynamic>;
    final pullChanges = pullData["changes"] as List<dynamic>;
    for (final change in pullChanges) {
      final map = change as Map<String, dynamic>;
      _applyCrdt(map);
    }
  }

  void _applyCrdt(Map<String, dynamic> val) {
    final rowId = val["row_id"] as String;
    final collection = val["table"] as String;
    final column = val["column"] as String;
    final value = val["value"];
    final data = {column: value};

    // Check for existing
    final existing = database.select(
      """
      SELECT * FROM records
      WHERE row_id = ?
      AND collection = ?
      """,
      [rowId, collection],
    );
    if (existing.isNotEmpty) {
      // Replace record
      final raw = existing.first["data"] as String;
      final original = jsonDecode(raw) as Map<String, dynamic>;
      final merged = {...original, ...data};

      database.execute(
        """
        UPDATE records
        SET data = ?, updated = ?
        WHERE row_id = ?
        AND collection = ?
        """,
        [
          jsonEncode(merged),
          DateTime.now().toUtc().toIso8601String(),
          rowId,
          collection,
        ],
      );
    } else {
      // Insert record
      database.execute(
        """
        INSERT INTO records (row_id, data, collection, deleted, created, updated)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        [
          rowId,
          jsonEncode(data),
          collection,
          0,
          DateTime.now().toUtc().toIso8601String(),
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
    }
  }

  /// Returns the RecordService associated to the specified collection.
  RecordService collection(String collectionIdOrName) {
    var service = _recordServices[collectionIdOrName];

    if (service == null) {
      // create and cache the service
      service = RecordService(this, collectionIdOrName);
      _recordServices[collectionIdOrName] = service;
    }

    return service;
  }

  /// Legacy alias of `pb.files.getUrl()`.
  Uri getFileUrl(
    RecordModel record,
    String filename, {
    String? thumb,
    String? token,
    Map<String, dynamic> query = const {},
  }) {
    return files.getUrl(
      record,
      filename,
      thumb: thumb,
      token: token,
      query: query,
    );
  }

  /// Builds and returns a full request url by safely concatenating
  /// the provided path to the base url.
  Uri buildUrl(String path, [Map<String, dynamic> queryParameters = const {}]) {
    var url = baseUrl + (baseUrl.endsWith("/") ? "" : "/");

    if (path.isNotEmpty) {
      url += path.startsWith("/") ? path.substring(1) : path;
    }

    final query = _normalizeQueryParameters(queryParameters);

    return Uri.parse(url).replace(
      queryParameters: query.isNotEmpty ? query : null,
    );
  }

  /// Sends a single HTTP request built with the current client configuration
  /// and the provided options.
  ///
  /// All response errors are normalized and wrapped in [ClientException].
  Future<dynamic> send(
    String path, {
    String method = "GET",
    Map<String, String> headers = const {},
    Map<String, dynamic> query = const {},
    Map<String, dynamic> body = const {},
    List<http.MultipartFile> files = const [],
  }) async {
    http.BaseRequest request;

    final url = buildUrl(path, query);

    if (files.isEmpty) {
      request = _jsonRequest(method, url, headers: headers, body: body);
    } else {
      request = _multipartRequest(
        method,
        url,
        headers: headers,
        body: body,
        files: files,
      );
    }

    if (!headers.containsKey("Authorization") && authStore.isValid) {
      request.headers["Authorization"] = authStore.token;
    }

    if (!headers.containsKey("Accept-Language")) {
      request.headers["Accept-Language"] = lang;
    }

    // ensures that keepalive on web is disabled for now
    //
    // it is ignored anyway when using the default http.Cient on web
    // and it causing issues with the alternative fetch_client package
    // (see https://github.com/Zekfad/fetch_client/issues/6#issuecomment-1615936365)
    if (isWeb) {
      request.persistentConnection = false;
    }

    final requestClient = httpClientFactory();

    try {
      final response = await requestClient.send(request);
      final responseStr = await response.stream.bytesToString();

      dynamic responseData;
      try {
        responseData = responseStr.isNotEmpty ? jsonDecode(responseStr) : null;
      } catch (_) {
        // custom non-json response
        responseData = responseStr;
      }

      if (response.statusCode >= 400) {
        throw ClientException(
          url: url,
          statusCode: response.statusCode,
          response: responseData is Map<String, dynamic> ? responseData : {},
        );
      }

      return responseData;
    } catch (e) {
      // PocketBase API exception
      if (e is ClientException) {
        rethrow;
      }

      // http client exception (eg. connection abort)
      if (e is http.ClientException) {
        throw ClientException(
          url: e.uri,
          originalError: e,
          // @todo will need to be redefined once cancellation support is added
          isAbort: true,
        );
      }

      // anything else
      throw ClientException(url: url, originalError: e);
    } finally {
      requestClient.close();
    }
  }

  http.Request _jsonRequest(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Map<String, dynamic> body = const {},
  }) {
    final request = http.Request(method, url);

    if (body.isNotEmpty) {
      request.body = jsonEncode(body);
    }

    if (headers.isNotEmpty) {
      request.headers.addAll(headers);
    }

    if (!headers.containsKey("Content-Type")) {
      request.headers["Content-Type"] = "application/json";
    }

    return request;
  }

  MultipartRequest _multipartRequest(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Map<String, dynamic> body = const {},
    List<http.MultipartFile> files = const [],
  }) {
    final request = MultipartRequest(method, url)
      ..files.addAll(files)
      ..headers.addAll(headers);

    body.forEach((key, value) {
      final entries = <String>[];
      // @todo consider adding a note in the docs that for `json` fields
      // the value may need to be `jsonEncode()`-ed
      // (and more specifically for null and <String>[])
      if (value is Iterable) {
        try {
          final casted = value.cast<String>();
          if (casted.isEmpty) {
            // empty list -> resolve as empty entry
            entries.add("");
          } else {
            // strings lists -> add each item as new entry
            for (final v in casted) {
              entries.add(v);
            }
          }
        } catch (_) {
          // non-strings lists -> json encode
          entries.add(jsonEncode(value));
        }
      } else if (value is Map) {
        entries.add(jsonEncode(value));
      } else {
        entries.add(value?.toString() ?? "");
      }

      request.fields[key] = entries;
    });

    return request;
  }

  Map<String, dynamic> _normalizeQueryParameters(
    Map<String, dynamic> parameters,
  ) {
    final result = <String, dynamic>{};

    parameters.forEach((key, value) {
      final normalizedValue = <String>[];

      // convert to List to normalize access
      if (value is! Iterable) {
        value = [value];
      }

      for (dynamic v in value) {
        if (v == null) {
          continue; // skip null query params
        }

        normalizedValue.add(v.toString());
      }

      if (normalizedValue.isNotEmpty) {
        result[key] = normalizedValue;
      }
    });

    return result;
  }
}
