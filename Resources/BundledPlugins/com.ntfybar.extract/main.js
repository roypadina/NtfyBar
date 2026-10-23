// Extract: find a piece of a message with a regular expression, then copy it or open it in a link.

function match(ctx, params) {
  if (!params.pattern) return null;
  var text = params.field === "title" ? ctx.message.title || "" : ctx.message.message || "";
  var re;
  try {
    re = new RegExp(params.pattern);
  } catch (e) {
    throw new Error("invalid regular expression");
  }
  var m = re.exec(text.slice(0, 8192));
  if (!m) return null;
  var g = params.group === undefined || params.group === "" ? (m.length > 1 ? 1 : 0) : Math.floor(Number(params.group));
  return m[g] === undefined ? null : String(m[g]);
}

function copyMatch(ctx, params) {
  var v = match(ctx, params);
  if (v !== null && ntfy.copy) ntfy.copy(v);
  return undefined;
}

function openMatch(ctx, params) {
  var v = match(ctx, params);
  if (v === null || !params.template || !ntfy.openURL) return undefined;
  ntfy.openURL(String(params.template).split("{match}").join(encodeURIComponent(v)));
  return undefined;
}
