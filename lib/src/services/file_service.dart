import "../client.dart";
import "../dtos/record_model.dart";
import "base_service.dart";

/// The service that handles the **File APIs**.
///
/// Usually shouldn't be initialized manually and instead
/// [PocketBase.files] should be used.
class FileService extends BaseService {
  FileService(PocketBase client) : super(client);

  /// Builds and returns an absolute record file url.
  Uri getUrl(
    RecordModel record,
    String filename, {
    String? thumb,
    String? token,
    bool? download,
    Map<String, dynamic> query = const {},
  }) {
    if (filename.isEmpty || record.id.isEmpty) {
      return Uri(); // blank Uri
    }

    final params = Map<String, dynamic>.of(query);
    params["thumb"] ??= thumb;
    params["token"] ??= token;
    if (download != null && download) {
      params["download"] = "";
    }

    return client.buildUrl(
      "/api/files/${Uri.encodeComponent(record.collectionId)}/${Uri.encodeComponent(record.id)}/${Uri.encodeComponent(filename)}",
      params,
    );
  }

  /// Requests a new private file access token for the current auth model.
  Future<String> getToken({
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) {
    return client
        .send(
          "/api/files/token",
          method: "POST",
          body: body,
          query: query,
          headers: headers,
        )
        .then(
            (data) => (data as Map<String, dynamic>? ?? {})["token"] as String);
  }

  void saveFile(Uri url, List<int> bytes) {
    // Check for existing
    final existing = client.database.select(
      "SELECT * FROM files WHERE url = ?",
      [url.toString()],
    );
    if (existing.isNotEmpty) {
      // Replace record
      client.database.execute(
        "UPDATE files SET data = ?, updated = ? WHERE url = ?",
        [
          bytes,
          DateTime.now().toUtc().toIso8601String(),
          url.toString(),
        ],
      );
    } else {
      // Insert record
      client.database.execute(
        "INSERT INTO files (data, url, created, updated) VALUES (?, ?, ?, ?)",
        [
          bytes,
          url.toString(),
          DateTime.now().toUtc().toIso8601String(),
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
    }
  }

  List<int>? getFile(Uri url) {
    final existing = client.database.select(
      "SELECT * FROM files WHERE url = ?",
      [url.toString()],
    );
    if (existing.isNotEmpty) {
      return existing.first["data"] as List<int>?;
    }
    return null;
  }

  void deleteFile(Uri url) {
    client.database.execute(
      "DELETE FROM files WHERE url = ?",
      [url.toString()],
    );
  }

  Future<List<int>?> downloadFile(
    Uri url, {
    DateTime? stale,
  }) async {
    final existing = client.database.select(
      "SELECT * FROM files WHERE url = ?",
      [url.toString()],
    );
    if (existing.isNotEmpty) {
      final raw = existing.first["data"] as List<int>?;
      final updated = DateTime.parse(existing.first["updated"] as String);
      if (raw != null && (stale == null || updated.isAfter(stale))) {
        return raw;
      }
    }
    final httpClient = client.httpClientFactory();
    final response = await httpClient.get(url);
    if (response.statusCode == 200) {
      final bytes = response.bodyBytes;
      saveFile(url, bytes);
      return bytes;
    }
    return null;
  }
}
