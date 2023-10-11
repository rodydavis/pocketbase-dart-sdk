import 'package:flutter/material.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:sqlite3/sqlite3.dart';

final pb = PocketBase("http://127.0.0.1:8090", sqlite3.openInMemory());

void main() async {
  final user = await pb
      .collection('users')
      .authWithPassword('gates@microsoft.com', 'Gates2023!');
  runApp(MyApp(user: user));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.user});

  final RecordAuth user;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: Example(user: user),
    );
  }
}

typedef Todo = ({
  String id,
  String name,
});

class Example extends StatefulWidget {
  const Example({super.key, required this.user});

  final RecordAuth user;

  @override
  State<Example> createState() => _ExampleState();
}

class _ExampleState extends State<Example> {
  var todos = <Todo>[];
  late final collection = pb.collection('todos');

  @override
  void initState() {
    super.initState();
    collection.getFullList().then((items) {
      setState(() {
        todos = items
            .map((e) => (
                  id: e.id,
                  name: e.data['name'] as String,
                ))
            .toList();
      });
    });

    collection.watchOffline("*", (item) {
      final idx = todos.indexWhere((el) => el.id == item.id);
      if (idx != -1) {
        final data = item.toJson();
        setState(() {
          todos[idx] = (
            id: data['id'] as String,
            name: data['name'] as String,
          );
        });
      } else {
        final data = item.toJson();
        setState(() {
          todos.add(
            (
              id: data['id'] as String,
              name: data['name'] as String,
            ),
          );
        });
      }
    });
    collection.subscribe('*', (e) {
      if (pb.offline) return;
      final idx = todos.indexWhere((el) => el.id == e.record?.id);
      if (idx != -1) {
        final data = e.record!.toJson();
        setState(() {
          if (e.action == 'delete') {
            todos.removeAt(idx);
          } else {
            todos[idx] = (
              id: data['id'] as String,
              name: data['name'] as String,
            );
          }
        });
      } else {
        final data = e.record!.toJson();
        setState(() {
          todos.add(
            (
              id: data['id'] as String,
              name: data['name'] as String,
            ),
          );
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Todos'),
        centerTitle: false,
        actions: [
          const Text('Offline:'),
          Switch(
            value: pb.offline,
            onChanged: (value) => setState(() => pb.offline = value),
          ),
          IconButton(
            tooltip: 'Sync',
            onPressed: () => pb.sync(user: widget.user.record!.id),
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: todos.isEmpty
          ? const Center(child: Text('No Items Found'))
          : ListView.builder(
              itemCount: todos.length,
              itemBuilder: (context, index) {
                final todo = todos[index];
                return ListTile(
                  title: Text(todo.name),
                  onTap: () => edit(context, todo),
                  trailing: IconButton(
                    tooltip: 'Delete',
                    onPressed: () => collection.delete(todo.id),
                    icon: const Icon(Icons.delete),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add',
        onPressed: () => edit(context, null),
        child: const Icon(Icons.add),
      ),
    );
  }

  void edit(BuildContext context, Todo? todo) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController(text: todo?.name);
        return AlertDialog(
          title: const Text('Add Todo'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Name',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
    if (name != null) {
      if (todo == null) {
        await collection.create(body: {
          'name': name,
          'user_id': widget.user.record?.id,
        });
      } else {
        await collection.update(todo.id, body: {
          'name': name,
          'user_id': widget.user.record?.id,
        });
      }
    }
  }
}
