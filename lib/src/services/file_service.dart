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
}
