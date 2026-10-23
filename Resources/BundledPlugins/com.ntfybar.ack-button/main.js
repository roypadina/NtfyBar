// ACK Button: a popup with an ACK button. Pressing it publishes a short reply to the same topic.
// Replies are tagged "ntfybar-ack" and this plugin ignores messages with that tag, so it never
// answers its own replies.

function showAck(ctx, params) {
  var m = ctx.message;
  if ((m.tags || []).indexOf("ntfybar-ack") >= 0) return undefined;
  // Each ntfy.* method only exists while its permission is granted.
  var acked = (ntfy.storage && ntfy.storage.get("acked")) || [];
  var already = acked.indexOf(m.id) >= 0;
  var blocks = [];
  if (m.message) blocks.push({ text: m.message });
  if (already) blocks.push({ badge: "Already acknowledged" });
  return {
    popup: {
      title: m.title || ctx.topic.label,
      icon: "checkmark.seal",
      accent: m.priority >= 5 ? "critical" : m.priority >= 4 ? "warning" : "info",
      blocks: blocks,
      buttons: already ? [] : [{ id: "ack", label: "ACK", style: "prominent" }],
      state: { reply: params.reply || "ACK {title}" }
    }
  };
}

function onPopupAction(ctx, buttonId, state) {
  if (buttonId !== "ack") return { close: true };
  var m = ctx.message;
  var reply = String(state.reply || "ACK {title}")
    .split("{title}").join(m.title || "")
    .split("{message}").join(m.message || "")
    .split("{id}").join(m.id);
  if (!ntfy.publish) return { close: true };
  ntfy.publish({
    topicId: ctx.topic.id,
    title: "ACK",
    message: reply,
    priority: 2,
    tags: ["white_check_mark", "ntfybar-ack"]
  });
  if (ntfy.storage) {
    var acked = ntfy.storage.get("acked") || [];
    acked.push(m.id);
    ntfy.storage.set("acked", acked.slice(-200));
  }
  return { close: true };
}
