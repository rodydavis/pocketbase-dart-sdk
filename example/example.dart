// ignore_for_file: unnecessary_lambdas

import "dart:async";

import "package:pocketbase/pocketbase.dart";
import "package:sqlite3/sqlite3.dart";

void main() {
  final pb = PocketBase("http://127.0.0.1:8090", sqlite3.openInMemory());

  // fetch a paginated list with "example" records
  pb.collection("example").getList(page: 1, perPage: 10).then((result) {
    // success...
    print("Result: $result");
  }).catchError((dynamic error) {
    // error...
    print("Error: $error");
  });

  // listen to realtime connect/reconnect events
  pb.realtime.subscribe("PB_CONNECT", (e) {
    print("Connected: $e");
  });

  // subscribe to realtime changes in the "example" collection
  pb.collection("example").subscribe("*", (e) {
    print(e.action); // create, update, delete
    print(e.record); // the changed record
  });

  // unsubsribe from all "example" realtime subscriptions after 10 seconds
  Timer(const Duration(seconds: 10), () {
    pb.realtime.unsubscribe(); // unsubscribe from all realtime events
  });
}
