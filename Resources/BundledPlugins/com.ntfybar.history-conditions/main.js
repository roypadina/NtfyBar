// Repeat & Burst: conditions that look at the topic's recent history.
// "Not seen recently" lets a rule fire only on the first of a series of identical alerts;
// "Burst" fires when many messages arrive close together.

function num(v, fallback) {
  var n = Number(v);
  return v === undefined || v === "" || !isFinite(n) || n <= 0 ? fallback : n;
}

function same(a, b, matchOn) {
  if (matchOn === "anything") return true;
  if (matchOn === "message") return (a.message || "") === (b.message || "");
  return (a.title || "") === (b.title || "");
}

// Messages of this topic in the window before (and including) the current one, without it.
function recent(ctx, minutes) {
  if (!ntfy.history) return [];
  var m = ctx.message;
  return ntfy.history({ after: m.time - Math.floor(minutes * 60) - 1, limit: 200 }).filter(function (x) {
    return x.id !== m.id && x.time <= m.time;
  });
}

function quietFor(ctx, params) {
  var minutes = num(params.minutes, 30);
  var matchOn = params.matchOn || "title";
  return !recent(ctx, minutes).some(function (x) { return same(x, ctx.message, matchOn); });
}

function burst(ctx, params) {
  var count = Math.floor(num(params.count, 5));
  var minutes = num(params.minutes, 10);
  var matchOn = params.matchOn || "anything";
  var n = 1 + recent(ctx, minutes).filter(function (x) { return same(x, ctx.message, matchOn); }).length;
  return n >= count;
}
