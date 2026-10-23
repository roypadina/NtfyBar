// JSON Fields: a condition on a JSON field's value, and a popup that shows a JSON message as a
// table together with the previous value of one field (from this topic's history).

function parse(text) {
  try {
    var v = JSON.parse(text);
    return v && typeof v === "object" ? v : null;
  } catch (e) {
    return null;
  }
}

function pick(obj, path) {
  var parts = String(path || "").split(".");
  var cur = obj;
  for (var i = 0; i < parts.length; i++) {
    if (cur === null || typeof cur !== "object" || !(parts[i] in cur)) return undefined;
    cur = cur[parts[i]];
  }
  return cur;
}

function show(v) {
  return typeof v === "string" ? v : JSON.stringify(v);
}

function fieldEquals(ctx, params) {
  var obj = parse(ctx.message.message);
  if (!obj || !params.field) return false;
  var v = pick(obj, params.field);
  if (v === undefined) return false;
  return show(v) === String(params.value === undefined ? "" : params.value);
}

function showTable(ctx, params) {
  var obj = parse(ctx.message.message);
  if (!obj) return undefined;
  var rows = [];
  var keys = Object.keys(obj).slice(0, 40);
  for (var i = 0; i < keys.length; i++) rows.push([keys[i], show(obj[keys[i]]).slice(0, 300)]);
  var blocks = [{ kv: rows }];
  if (params.field) {
    var now = pick(obj, params.field);
    var previous;
    // ntfy.history only exists while the history.read permission is granted.
    var earlier = ntfy.history ? ntfy.history({ limit: 50 }) : [];
    for (var j = 0; j < earlier.length && previous === undefined; j++) {
      if (earlier[j].id === ctx.message.id) continue;
      var o = parse(earlier[j].message);
      if (o) previous = pick(o, params.field);
    }
    blocks.push({ kv: [
      [params.field + " now", now === undefined ? "—" : show(now)],
      [params.field + " before", previous === undefined ? "—" : show(previous)]
    ] });
  }
  return { popup: { title: ctx.message.title || ctx.topic.label, icon: "curlybraces", accent: "info", blocks: blocks } };
}
