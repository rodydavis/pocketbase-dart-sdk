onModelAfterCreate((e) => {
  function addChange(id, table, hlc, user_id, column, value) {
    const dao = $app.dao().withoutHooks();
    const collection = dao.findCollectionByNameOrId("changes");
    const record = new Record(collection, {
      table,
      column,
      user_id,
      timestamp: hlc,
      row_id: id,
      value,
    });
    dao.saveRecord(record);
  }

  function isSystem(key) {
    const values = [
      "id",
      "hlc",
      "deleted",
      "created",
      "updated",
      "collectionId",
      "collectionName",
    ];
    for (const value of values) {
      if (key === value) return true;
    }
    return false;
  }

  const tbl = e.model.tableName();
  if (tbl === "changes" || tbl === "_collections") return;
  const data = JSON.parse(JSON.stringify(e.model));
  const { id, updated, user_id } = data;
  for (const key in data) {
    if (isSystem(key)) continue;
    const value = data[key];
    addChange(id, tbl, updated, user_id, key, value);
  }
});

onModelBeforeUpdate((e) => {
  const dao = $app.dao().withoutHooks();

  function addChange(id, table, hlc, user_id, column, value) {
    const collection = dao.findCollectionByNameOrId("changes");
    const record = new Record(collection, {
      table,
      column,
      user_id,
      timestamp: hlc,
      row_id: id,
      value,
    });
    dao.saveRecord(record);
  }

  function isSystem(key) {
    const values = [
      "id",
      "hlc",
      "deleted",
      "created",
      "updated",
      "collectionId",
      "collectionName",
    ];
    for (const value of values) {
      if (key === value) return true;
    }
    return false;
  }

  const tbl = e.model.tableName();
  if (tbl === "changes" || tbl === "_collections") return;

  const data = JSON.parse(JSON.stringify(e.model));
  const { id, updated, user_id } = data;

  const currentRecord = dao.findRecordById(tbl, id);
  const currentData = JSON.parse(JSON.stringify(currentRecord));

  for (const key in data) {
    if (isSystem(key)) continue;
    const value = data[key];
    const currentValue = currentData[key];
    if (value === currentValue) continue;
    addChange(id, tbl, updated, user_id, key, value);
  }
});

onModelAfterDelete((e) => {
  function addChange(id, table, hlc, user_id, column, value) {
    const dao = $app.dao().withoutHooks();
    const collection = dao.findCollectionByNameOrId("changes");
    const record = new Record(collection, {
      table,
      column,
      user_id,
      timestamp: hlc,
      row_id: id,
      value,
    });
    dao.saveRecord(record);
  }

  const tbl = e.model.tableName();
  if (tbl === "changes" || tbl === "_collections") return;
  const data = JSON.parse(JSON.stringify(e.model));
  const { id, updated, user_id } = data;
  addChange(id, tbl, updated, user_id, "deleted", true);
});

routerAdd("POST", "/api/sync", (c) => {
  const body = $apis.requestInfo(c).data;
  const dao = $app.dao();

  const changes = body.changes;
  if (!changes) {
    return c.json(400, { message: "changes field required" });
  }

  let compressed = [];
  if (c.queryParam("compress") === "true") {
    // Group by table and row_id
    const grouped = {};
    for (const change of changes) {
      const { table, row_id, column, value, timestamp, user_id } = change;
      const key = `${table}:${row_id}`;
      if (!grouped[key]) grouped[key] = [];
      grouped[key].push({ column, value, timestamp, user_id });
    }

    // Compress based on highest timestamp
    function parseDate(val) {
      if (!val) return null;
      return Date.parse(val.toString().replace(" ", "T"));
    }

    for (const key in grouped) {
      const changes = grouped[key];
      const sorted = changes.sort((a, b) => {
        if (parseDate(a.timestamp) < parseDate(b.timestamp)) return -1;
        if (parseDate(a.timestamp) > parseDate(b.timestamp)) return 1;
        return 0;
      });
      const last = sorted[sorted.length - 1];
      compressed.push({
        table: key.split(":")[0],
        row_id: key.split(":")[1],
        column: last.column,
        value: last.value,
        user_id: last.user_id,
      });
    }
  } else {
    compressed = changes;
  }

  const merged = {};
  for (const change of compressed) {
    const { table, row_id, column, value } = change;
    const key = `${table}:${row_id}`;
    if (!merged[key]) merged[key] = {};
    merged[key][column] = value;
  }

  // Apply changes to each table
  for (const key in merged) {
    const [table, row_id] = key.split(":");
    const data = merged[key];
    try {
      const record = dao.findRecordById(table, row_id);
      for (const column in data) {
        const value = data[column];
        record.set(column, value);
      }
      dao.saveRecord(record);
    } catch (err) {
      const tbl = dao.findCollectionByNameOrId(table);
      const record = new Record(tbl, { id: row_id });
      for (const column in data) {
        const value = data[column];
        record.set(column, value);
      }
      dao.saveRecord(record);
    }
  }

  return c.json(200, { message: "success" });
});

routerAdd("GET", "/api/sync", (c) => {
  const userId = c.queryParam("user");
  const timestamp = c.queryParam("timestamp");
  const limit = c.queryParam("limit") || "100";
  const page = c.queryParam("page") || "0";
  const compress = c.queryParam("compress") === "true";

  if (!userId) {
    return c.json(400, { message: "user is required" });
  }

  const dao = $app.dao().withoutHooks();
  let filter = "user_id = {:user} || user_id = ''";
  if (timestamp !== "") {
    filter = `(${filter}) && timestamp >= {:timestamp}`;
  }
  const changes = dao.findRecordsByFilter(
    "changes",
    filter,
    "-updated",
    parseInt(limit),
    parseInt(page),
    {
      user: userId,
      timestamp,
    }
  );

  function parseDate(val) {
    if (!val) return null;
    return Date.parse(val.toString().replace(" ", "T"));
  }

  if (compress) {
    const compressed = [];

    // Compress based on latest timestamps
    const grouped = {};
    for (const change of changes) {
      const data = JSON.parse(JSON.stringify(change));
      const { table, row_id, column, value, timestamp, user_id } = data;
      const key = `${table}:${row_id}`;
      if (!grouped[key]) grouped[key] = [];
      const item = { column, value, timestamp, user_id };
      // Check for existing item with same column
      const existing = grouped[key].find((i) => i.column === column);
      if (existing) {
        // Compare timestamps
        if (parseDate(existing.timestamp) < parseDate(timestamp)) {
          // Replace existing item with new item
          grouped[key] = grouped[key].filter((i) => i.column !== column);
          grouped[key].push(item);
        }
      } else {
        grouped[key].push(item);
      }
    }

    for (const key in grouped) {
      const changes = grouped[key];
      const [table, row_id] = key.split(":");
      for (const change of changes) {
        const { column, value, timestamp, user_id } = change;
        compressed.push({
          table,
          row_id,
          column,
          value,
          timestamp,
          user_id,
        });
      }
    }

    return c.json(200, {
      changes: compressed,
      count: compressed.length,
      compress: true,
    });
  }

  return c.json(200, {
    changes,
    count: changes.length,
    compress: false,
  });
});
