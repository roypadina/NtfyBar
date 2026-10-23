// Alert Card: a big card for the alerts that matter. Acknowledge closes it; Snooze sends the same
// alert to its topic again after N minutes (scheduled by the ntfy server), so it comes back even if
// you quit NtfyBar. Urgent (priority 5) cards never close on their own.

var WORDS = ["", "Min", "Low", "Default", "High", "Urgent"];

function pad(n) { return (n < 10 ? "0" : "") + n; }

function today(t) {
  var d = new Date(t * 1000);
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
}

// How many times an alert with this title arrived today (stored per day; older days are dropped).
function countToday(m) {
  if (!ntfy.storage) return 0;
  var day = today(m.time);
  var counts = ntfy.storage.get("counts") || {};
  if (counts.day !== day) counts = { day: day, seen: {}, byTitle: {} };
  var key = m.title || m.message || "";
  if (!counts.seen[m.id]) {
    counts.seen[m.id] = true;
    counts.byTitle[key] = (counts.byTitle[key] || 0) + 1;
    ntfy.storage.set("counts", counts);
  }
  return counts.byTitle[key];
}

function ordinal(n) {
  var s = n % 100 >= 11 && n % 100 <= 13 ? "th" : ["th", "st", "nd", "rd"][n % 10] || "th";
  return n + s;
}

function showCard(ctx, params) {
  var m = ctx.message;
  var p = m.priority || 3;
  var blocks = [];
  if (m.message) blocks.push({ text: m.message });
  if ((m.tags || []).indexOf("ntfybar-snoozed") >= 0) blocks.push({ badge: "Snoozed" });
  if (params.countToday) {
    var n = countToday(m);
    if (n > 1) blocks.push({ badge: ordinal(n) + " time today" });
  }
  var d = new Date(m.time * 1000);
  blocks.push({ kv: [["Priority", WORDS[p] || "Default"], ["Time", pad(d.getHours()) + ":" + pad(d.getMinutes())], ["Topic", ctx.topic.label]] });

  var snoozeMin = params.snoozeMin === undefined || params.snoozeMin === "" ? 10 : Math.floor(Number(params.snoozeMin) || 0);
  var buttons = [{ id: "ack", label: "Acknowledge", style: "prominent" }];
  if (snoozeMin > 0 && ntfy.publish) buttons.push({ id: "snooze", label: "Snooze " + snoozeMin + " min" });

  var popup = {
    title: m.title || ctx.topic.label,
    icon: p >= 5 ? "exclamationmark.triangle.fill" : p >= 4 ? "exclamationmark.circle.fill" : "bell.fill",
    accent: p >= 5 ? "critical" : p >= 4 ? "warning" : "info",
    timeoutSec: p >= 5 ? 0 : Math.max(0, Math.min(600, Math.floor(Number(params.timeoutSec) || 0))),
    blocks: blocks,
    buttons: buttons,
    state: { snoozeMin: snoozeMin }
  };
  if (params.position) popup.position = params.position;
  if (params.level) popup.level = params.level;
  return { popup: popup };
}

function onPopupAction(ctx, buttonId, state) {
  if (buttonId === "snooze" && ntfy.publish) {
    var m = ctx.message;
    var tags = (m.tags || []).filter(function (t) { return t !== "ntfybar-snoozed"; }).concat(["ntfybar-snoozed"]);
    ntfy.publish({
      topicId: ctx.topic.id,
      title: m.title,
      message: m.message || m.title || "Snoozed alert",
      priority: m.priority || 3,
      tags: tags,
      click: m.click,
      delay: Math.max(1, state.snoozeMin || 10) * 60
    });
  }
  return { close: true };
}
