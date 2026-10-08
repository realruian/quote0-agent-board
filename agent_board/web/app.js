// Settings console for the Quote/0 agent status board. No build step, no dependencies.

const token = document.querySelector('meta[name="board-token"]').content;
const version = document.querySelector('meta[name="board-version"]').content;

// ---- helpers -------------------------------------------------------------

async function api(path, body) {
  const options = { headers: { "X-Board-Token": token } };
  if (body !== undefined) {
    options.method = "POST";
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  let response;
  try {
    response = await fetch(path, options);
  } catch {
    throw new Error("连不上后台进程，它可能正在重启");
  }
  if (response.status === 403 && !sessionStorage.getItem("reloaded")) {
    sessionStorage.setItem("reloaded", "1"); // the daemon restarted and issued a new token
    location.reload();
    throw new Error("页面已过期，正在刷新");
  }
  if ((response.headers.get("Content-Type") || "").startsWith("image/")) return response.blob();
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || "请求失败");
  sessionStorage.removeItem("reloaded");
  return data;
}

function h(tag, props, ...children) {
  const el = document.createElement(tag);
  for (const [key, value] of Object.entries(props || {})) {
    if (value == null || value === false) continue;
    if (key === "class") el.className = value;
    else if (key.startsWith("on")) el.addEventListener(key.slice(2), value);
    else if (key in el) el[key] = value;
    else el.setAttribute(key, value);
  }
  for (const child of children.flat(Infinity)) if (child != null && child !== false) el.append(child);
  return el;
}

let toastTimer;
function toast(message, isError = false) {
  const el = document.getElementById("toast");
  el.textContent = message;
  el.className = `toast show${isError ? " error" : ""}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.className = "toast"), isError ? 4500 : 1600);
}

const clock = (ts) => new Date(ts * 1000).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false });

function ago(ts) {
  const seconds = Math.max(0, Math.round(Date.now() / 1000 - ts));
  if (seconds < 60) return "刚刚";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时前`;
  return `${Math.floor(seconds / 86400)} 天前`;
}

function debounce(fn, ms) {
  let timer;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), ms);
  };
}

// Settings save themselves shortly after a change. Changes made in quick
// succession go out together instead of the last one replacing the others.
function makeSaver() {
  let pending = {};
  const flush = debounce(async () => {
    const patch = pending;
    pending = {};
    try {
      await api("/api/settings", patch);
      toast("已保存");
    } catch (error) {
      toast(error.message, true);
    }
  }, 350);
  return (patch) => {
    for (const [key, value] of Object.entries(patch)) {
      pending[key] = key === "takeover" || key === "quiet_hours" ? { ...pending[key], ...value } : value;
    }
    flush();
  };
}

// ---- small components ----------------------------------------------------

const SVG = (paths) => {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  for (const [name, value] of Object.entries({ fill: "none", stroke: "currentColor", "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true" })) svg.setAttribute(name, value);
  svg.innerHTML = paths; // constant strings from ICONS only
  return svg;
};

const ICONS = {
  overview: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  display: '<rect x="3" y="5" width="18" height="12" rx="2"/><path d="M8 21h8M12 17v4"/>',
  alerts: '<path d="M6 16v-5a6 6 0 1 1 12 0v5l1.5 2h-15z"/><path d="M10 21a2 2 0 0 0 4 0"/>',
  refresh: '<path d="M20 11a8 8 0 0 0-14.5-4M4 13a8 8 0 0 0 14.5 4"/><path d="M5 3v4h4M19 21v-4h-4"/>',
  integrations: '<path d="M9 3v5M15 3v5M7 8h10v3a5 5 0 0 1-10 0zM12 16v5"/>',
  device: '<path d="M3 9a14 14 0 0 1 18 0M6 12.5a9.5 9.5 0 0 1 12 0M9 16a5 5 0 0 1 6 0"/><circle cx="12" cy="19.5" r="0.8"/>',
  diagnostics: '<path d="M3 12h4l2-6 4 12 2-6h6"/>',
  about: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.2"/>',
};

const card = (...rows) => h("div", { class: "card" }, rows);

function row(label, sub, ...controls) {
  return h("div", { class: "row" },
    h("div", { class: "label" }, label, sub && h("div", { class: "sub" }, sub)),
    h("div", { class: "controls" }, controls));
}

const info = (label, value) =>
  h("div", { class: "row" }, h("div", { class: "label" }, label), h("div", { class: "value" }, value));

function toggle(checked, onChange, label) {
  const input = h("input", { type: "checkbox", checked, "aria-label": label, onchange: () => onChange(input.checked, input) });
  return h("label", { class: "switch" }, input, h("span"));
}

function numberField(value, min, max, unit, onChange) {
  const input = h("input", {
    class: "field num", type: "number", value, min, max, step: 1,
    onchange: () => {
      const n = Math.round(Number(input.value));
      if (!Number.isFinite(n) || n < min || n > max) {
        toast(`请填 ${min} 到 ${max} 之间的整数`, true);
        input.value = value;
        return;
      }
      value = n;
      onChange(n);
    },
  });
  return [input, h("span", { class: "unit" }, unit)];
}

const timeField = (value, onChange) => {
  const input = h("input", { class: "field time", type: "time", value, onchange: () => input.value && onChange(input.value) });
  return input;
};

const button = (label, onClick, extra = "") => h("button", { class: `btn ${extra}`, type: "button", onclick: onClick }, label);

function segmented(options, value, onChange) {
  const buttons = options.map(([id, label]) =>
    h("button", { type: "button", "aria-pressed": String(id === value), onclick: () => {
      buttons.forEach((b, i) => b.setAttribute("aria-pressed", String(options[i][0] === id)));
      onChange(id);
    } }, label));
  return h("div", { class: "segmented", role: "group" }, buttons);
}

function select(options, value, onChange, label) {
  const el = h("select", { class: "field", "aria-label": label, onchange: () => onChange(el.value) },
    options.map(([id, text]) => h("option", { value: id, selected: id === value }, text)));
  return el;
}

const pill = (text, kind) => h("span", { class: `pill ${kind}` }, text);
const dot = (kind) => h("span", { class: `dot ${kind}` });
const section = (title) => h("div", { class: "section-title" }, title);
const hint = (...content) => h("p", { class: "hint" }, content);
const link = (text, target) => h("a", { href: `#${target}` }, text);

// A row other pages can point at: "#refresh/battery" opens the page and highlights the row.
function anchored(name, el) {
  el.dataset.anchor = name;
  return el;
}

function screen(caption) {
  const img = h("img", { alt: "墨水屏画面预览", width: 592, height: 304 });
  const text = h("div", { class: "screen-caption" }, caption || "");
  return { el: h("div", { class: "screen-wrap" }, h("div", { class: "screen" }, img), text), img, caption: text };
}

async function busy(btn, work) {
  btn.disabled = true;
  try {
    await work();
  } catch (error) {
    toast(error.message, true);
  } finally {
    btn.disabled = false;
  }
}

const WAIT_LABEL = { permission: "等你批准", question: "等你回答", plan: "等你看计划" };
const AGENT = { claude: "Claude", codex: "Codex" };

function statePill(session) {
  if (session.state === "waiting") return pill(WAIT_LABEL[session.wait_kind] || "等你处理", "warn");
  if (session.state === "running") return pill("运行中", "info");
  if (session.state === "error") return pill("出错", "bad");
  return pill("已完成", "ok");
}

// ---- pages ---------------------------------------------------------------

async function overviewPage(mount, onLeave) {
  const view = screen();
  const lines = h("div", { class: "status-lines" });
  const deviceLine = h("div", null, dot(""), "正在检查设备…");
  const sessions = h("div", { class: "card" });
  const quota = h("div", { class: "card" });
  const banner = h("div");
  let frameVersion = null;
  let device = null;
  let lastPush = {};
  let dryRun = false;
  let needsSetup = false;

  // A sleeping device keeps its old frame: say so, or the stale screen looks like a fault.
  function drawBanner() {
    const missed = lastPush.ok && lastPush.delivered === false;
    const since = device && device.last_render ? `，屏幕停在 ${device.last_render} 的画面` : "";
    banner.replaceChildren(
      dryRun ? h("div", { class: "banner" }, "空跑模式：画面只在本机生成，不会发到屏幕上。") : "",
      needsSetup ? h("div", { class: "banner" }, "还没有连接设备，画面发不到屏幕上。 ", link("连接设备", "setup")) : "",
      missed && !needsSetup ? h("div", { class: "banner" }, `设备休眠或离线，最新画面没有显示出来${since}。接上电源后会自动补上；用电池时要等它下次醒来。`,
        link("更改刷新间隔", "refresh/battery")) : "");
  }

  const WINDOW = { five_hour: "5 小时", seven_day: "本周" };
  const QUOTA_NEEDS = { Claude: "需要在终端里登录过 Claude Code", Codex: "Codex 回复一次后就有" }; // what a first reading takes
  function quotaRow(name, reading) {
    const windows = (reading && reading.windows) || {};
    const parts = Object.keys(WINDOW).filter((k) => windows[k]).map((k) => `${WINDOW[k]}剩 ${windows[k].left}%`);
    let text = parts.join(" · ");
    if (!parts.length) text = reading && reading.observed_at ? `上次读数已过期（${ago(reading.observed_at)}），等下一次读取` : `还没有数据，${QUOTA_NEEDS[name]}`;
    else text += ` · ${ago(reading.observed_at)}更新`;
    return info(h("span", null, dot(parts.length ? "ok" : "warn"), name), text);
  }

  const refreshBtn = button("刷新屏幕", () => busy(refreshBtn, async () => {
    await api("/api/refresh", {});
    toast("正在刷新屏幕");
  }));
  const testBtn = button("发送测试画面", () => busy(testBtn, async () => {
    await api("/api/test-frame", {});
    toast("测试画面已发出，15 秒后自动恢复");
  }));

  mount.append(banner, view.el,
    h("div", { class: "card" }, h("div", { class: "split" }, h("div", { class: "status-lines" }, lines, deviceLine),
      h("div", { class: "btn-row" }, refreshBtn, testBtn))),
    section("剩余额度"), quota,
    section("当前对话"), sessions);

  api("/api/device").then((d) => {
    const s = d.status || {};
    device = d;
    drawBanner();
    if (d.needs_setup) deviceLine.replaceChildren(dot("warn"), "还没有连接设备 ", link("去连接", "setup"));
    else if (!d.ok) deviceLine.replaceChildren(dot("bad"), `连不上设备：${d.error || "未知原因"}`);
    else if ((s.battery || "").includes("已连接电源")) deviceLine.replaceChildren(dot("ok"), "设备已接电源，有变化就刷新");
    else deviceLine.replaceChildren(dot(d.asleep ? "warn" : "ok"),
      `设备：${[s.current, s.battery].filter(Boolean).join(" · ")}，用电池时每 ${d.battery_minutes} 分钟刷新一次 `, link("更改", "refresh/battery"));
  }).catch((error) => deviceLine.replaceChildren(dot("bad"), `连不上设备：${error.message}`));

  async function resume(event) {
    event.preventDefault();
    try {
      await api("/api/settings", { paused: false });
      toast("已恢复");
      tick();
    } catch (error) {
      toast(error.message, true);
    }
  }

  async function tick() {
    let data;
    try {
      data = await api("/api/overview");
    } catch (error) {
      lines.replaceChildren(h("div", null, dot("bad"), error.message));
      return;
    }
    const push = data.last_push || {};
    const missed = push.ok && push.delivered === false;
    lastPush = push;
    dryRun = data.dry_run;
    needsSetup = data.needs_setup;
    drawBanner();
    const pushedAt = push.at || 0;
    if (pushedAt !== frameVersion) {
      frameVersion = pushedAt;
      view.img.src = `/api/frame.png?v=${pushedAt}`;
    }
    view.caption.textContent = !push.at ? "还没有刷新过屏幕"
      : missed ? `最新画面，还没显示到屏幕上 · ${ago(push.at)}发出（${clock(push.at)}）`
      : `屏幕当前画面 · ${ago(push.at)}刷新（${clock(push.at)}）`;
    const quiet = data.view_kind === "quiet";
    // Say one thing when all is well, and name the broken link only when there is one.
    const notes = [
      push.at && !push.ok && h("div", null, dot("bad"), `最近一次刷新失败：${push.message}`),
      missed && h("div", null, dot("warn"), "最新画面还没显示：设备休眠或离线"),
      data.paused && h("div", null, dot("warn"), "已暂停，屏幕不再更新 ", h("a", { href: "#overview", onclick: resume }, "恢复")),
      quiet && !data.paused && h("div", null, dot("warn"), "夜间免打扰中，屏幕暂不刷新"),
    ].filter(Boolean);
    if (!notes.length && !data.dry_run && !data.needs_setup) notes.push(h("div", null, dot(push.at ? "ok" : ""), push.at ? "屏幕已是最新" : "还没有刷新过屏幕"));
    lines.replaceChildren(...notes);
    quota.replaceChildren(quotaRow("Claude", data.usage.claude), quotaRow("Codex", data.usage.codex));
    sessions.replaceChildren(...(data.sessions.length
      ? data.sessions.map((s) => h("div", { class: "row" },
          h("div", { class: "label" }, s.title || s.alias || s.project,
            h("div", { class: "sub" }, [AGENT[s.source] || s.source, s.title && (s.alias || s.project), s.alias && `原名 ${s.project}`, s.hidden && "已隐藏，不上屏",
              s.since && `${clock(s.since)} ${s.state === "done" || s.state === "error" ? "结束" : "起"}`].filter(Boolean).join(" · "))),
          h("div", { class: "controls" }, statePill(s))))
      : [h("div", { class: "empty" }, "现在没有对话。在 Claude Code 或 Codex 里开始一个，就会出现在这里。")]));
  }

  await tick();
  const timer = setInterval(tick, 2000);
  onLeave(() => clearInterval(timer));
}

async function displayPage(mount) {
  const { config, known_projects: known, fonts } = await api("/api/settings");
  const view = screen("预览，不会发到屏幕上");
  let sample = "list";
  let lastUrl;

  const preview = debounce(async () => {
    try {
      const blob = await api("/api/preview", { config: draft(), sample });
      if (lastUrl) URL.revokeObjectURL(lastUrl);
      view.img.src = lastUrl = URL.createObjectURL(blob);
    } catch (error) {
      toast(error.message, true);
    }
  }, 120);

  const draft = () => ({
    font: config.font, show_titles: config.show_titles, show_detail: config.show_detail, show_usage: config.show_usage,
    max_rows: config.max_rows, idle_show_last: config.idle_show_last,
    aliases: config.aliases, hidden_projects: config.hidden_projects, done_ttl_minutes: config.done_ttl_minutes,
  });

  const save = makeSaver();

  function change(key, value) {
    config[key] = value;
    preview();
    save({ [key]: value });
  }

  const projects = h("div", { class: "card" });
  function drawProjects() {
    const names = [...new Set([...known, ...Object.keys(config.aliases), ...config.hidden_projects])].sort((a, b) => a.localeCompare(b, "zh-CN"));
    const rows = names.map((name) => {
      const alias = h("input", {
        class: "field name", type: "text", value: config.aliases[name] || "", placeholder: "别名", maxLength: 60, "aria-label": `${name} 的别名`,
        onchange: () => {
          const next = { ...config.aliases };
          if (alias.value.trim()) next[name] = alias.value.trim();
          else delete next[name];
          change("aliases", next);
        },
      });
      const hide = toggle(config.hidden_projects.includes(name), (on) => {
        change("hidden_projects", on ? [...config.hidden_projects, name] : config.hidden_projects.filter((p) => p !== name));
      }, `隐藏 ${name}`);
      return h("div", { class: "row" }, h("div", { class: "label" }, name), h("div", { class: "controls" }, alias, h("span", { class: "unit" }, "隐藏"), hide));
    });
    const input = h("input", { class: "field name", type: "text", placeholder: "文件夹名", maxLength: 60, "aria-label": "要添加的项目文件夹名" });
    const add = button("添加", () => {
      const name = input.value.trim();
      if (!name) return toast("先填项目的文件夹名", true);
      if (!known.includes(name)) known.push(name);
      drawProjects();
    });
    projects.replaceChildren(...rows, h("div", { class: "row" }, h("div", { class: "label" }, "添加项目", h("div", { class: "sub" }, "项目名是对话所在文件夹的名字")), h("div", { class: "controls" }, input, add)));
  }
  drawProjects();

  mount.append(view.el,
    h("div", { class: "preview-tools" }, segmented([["list", "运行中"], ["wait", "等你批准"], ["idle", "空闲"], ["live", "实际状态"]], sample, (id) => {
      sample = id;
      preview();
    })),
    card(
      row("字体", "屏幕只有黑白两色，不同字体的笔画粗细会有差别", select(fonts.map((f) => [f.key, f.label]), config.font, (v) => change("font", v), "字体")),
      row("显示对话名称", "和 Claude、Codex 侧边栏里的名称一致；新对话先用你发的第一句话", toggle(config.show_titles, (on) => change("show_titles", on), "显示对话名称")),
      row("等批准时显示工具名", "例如 Bash、Edit", toggle(config.show_detail, (on) => change("show_detail", on), "等批准时显示工具名")),
      row("显示剩余额度", "有 Agent 在运行时显示在顶栏，空闲时显示完整的额度条", toggle(config.show_usage, (on) => change("show_usage", on), "显示剩余额度")),
      row("最多行数", "对话更多时，优先显示等你处理的和最近有动静的", numberField(config.max_rows, 1, 4, "行", (n) => change("max_rows", n))),
      row("空闲时显示上次完成的项目", null, toggle(config.idle_show_last, (on) => change("idle_show_last", on), "空闲时显示上次完成的项目"))),
    section("对话保留"),
    card(
      row("完成后保留", "对话结束后在屏幕上停留的时间", numberField(config.done_ttl_minutes, 1, 720, "分钟", (n) => change("done_ttl_minutes", n))),
      row("无响应后移除", "被中断的对话不会自己结束，超过这个时间自动移除", numberField(config.stale_running_minutes, 5, 1440, "分钟", (n) => save({ stale_running_minutes: n })))),
    section("项目别名和隐藏"), projects,
    hint("别名会替换屏幕上的项目名。隐藏的项目不显示在屏幕上，也不触发整屏提醒。"),
    hint("示例画面里的项目和额度是演示用的，选“实际状态”可以看到真实效果。画面会经过 MindReset 的服务器发到设备。"));
  preview();
}

async function alertsPage(mount) {
  const { config } = await api("/api/settings");
  const save = makeSaver();

  const takeover = (kind, label, sub) => row(label, sub, toggle(config.takeover[kind], (on) => {
    config.takeover[kind] = on;
    save({ takeover: { [kind]: on } });
  }, label));

  mount.append(
    section("整屏提醒"),
    card(
      takeover("permission", "等你批准时", "Agent 要执行需要授权的操作"),
      takeover("question", "等你回答时", "Agent 向你提问"),
      takeover("plan", "等你看计划时", "Agent 写好计划等你确认")),
    hint("整屏反色显示，并立即刷新。关闭的情况只在列表里显示成一行。"),
    hint(link("夜间免打扰", "refresh/quiet"), "可以让屏幕在夜间停止刷新。"));
}

// Everything that decides when the screen changes, whether the daemon or the device holds the setting.
async function refreshPage(mount) {
  const body = h("div");
  mount.append(body);

  // `d` is missing while the device is still being asked; what the daemon holds can be changed meanwhile.
  function draw(config, d) {
    const ready = d && d.ok;
    const save = makeSaver();
    const quiet = (patch) => {
      Object.assign(config.quiet_hours, patch);
      save({ quiet_hours: patch });
    };
    const apply = async (patch, done) => {
      try {
        draw(config, await api("/api/device", patch));
        toast(done);
      } catch (error) {
        toast(error.message, true);
        load();
      }
    };
    const WAKE = [[1, "1 分钟"], [5, "5 分钟"], [10, "10 分钟"], [15, "15 分钟"], [30, "30 分钟"], [60, "1 小时"], [180, "3 小时"], [360, "6 小时"], [720, "12 小时"]];
    const wakeOptions = () => (WAKE.some(([m]) => m === d.battery_minutes) ? WAKE : [...WAKE, [d.battery_minutes, `${d.battery_minutes} 分钟`]])
      .sort((a, b) => a[0] - b[0]).map(([m, text]) => [String(m), text]);
    const sleep = { ...(d && d.sleep) };
    const saveSleep = (patch) => apply({ sleep: Object.assign(sleep, patch) }, "已保存");

    body.replaceChildren(...[
      d && !d.ok && h("div", { class: "banner" }, `连不上设备：${d.error}。存在设备上的几项设置暂时改不了。 `, h("a", { href: "#", onclick: (e) => { e.preventDefault(); load(); } }, "重试")),
      section("刷新间隔"),
      card(
        row("插电时的最小间隔", "有变化就刷新，两次之间至少隔这么久。整屏提醒不受限制",
          numberField(config.min_push_interval_seconds, 3, 600, "秒", (n) => {
            config.min_push_interval_seconds = n;
            save({ min_push_interval_seconds: n });
          })),
        ready && anchored("battery", row("用电池时的刷新间隔", "设备平时休眠，每隔这么久醒来刷新一次。间隔越短越耗电",
          select(wakeOptions(), String(d.battery_minutes), (v) => apply({ battery_minutes: Number(v) }, "已保存"), "用电池时的刷新间隔")))),
      ready && card(
        row("始终显示状态牌", "设备循环列表里的其他内容不会替换状态牌",
          toggle(d.keep, (on) => {
            config.keep_on_screen = on;
            apply({ keep: on }, on ? "已开启" : "已关闭");
          }, "始终显示状态牌"))),
      section("夜间"),
      anchored("quiet", card(
        row("夜间免打扰", "时段内屏幕显示“夜间免打扰”，停止刷新", toggle(config.quiet_hours.enabled, (on) => quiet({ enabled: on }), "夜间免打扰")),
        row("开始时间", null, timeField(config.quiet_hours.start, (v) => quiet({ start: v }))),
        row("结束时间", null, timeField(config.quiet_hours.end, (v) => quiet({ end: v }))))),
      ready && card(
        row("定时休眠", "时段内设备整机休眠，循环列表里的其他内容也不刷新", toggle(!!sleep.enabled, (on) => saveSleep({ enabled: on }), "定时休眠")),
        row("开始时间", null, timeField(sleep.start || "23:00", (v) => saveSleep({ start: v }))),
        row("结束时间", null, timeField(sleep.end || "07:00", (v) => saveSleep({ end: v })))),
      ready && hint(`定时休眠按设备的时区（${d.timezone || "未知"}）计算。`),
      !d && hint("正在读取存在设备上的设置…"),
    ].filter(Boolean));
  }

  async function load() {
    const device = api("/api/device").catch((error) => ({ ok: false, error: error.message }));
    const { config } = await api("/api/settings");
    draw(config);
    draw(config, await device);
  }
  await load();
}

async function integrationsPage(mount) {
  const body = h("div");
  mount.append(body);

  function draw(data) {
    const agentCard = (id, name, note) => {
      const st = data[id];
      const on = st.installed > 0;
      const full = st.installed === st.expected;
      let status;
      if (!st.exists) status = "没有找到它的配置文件，可能没装";
      else if (st.error) status = st.error;
      else if (full) status = "已连接";
      else if (on) status = `连接不完整（${st.installed}/${st.expected}），关掉再打开可以修复`;
      else status = "未连接";
      const sw = toggle(on, async (checked, input) => {
        input.disabled = true;
        try {
          draw(await api("/api/integrations", { agent: id, enabled: checked }));
          toast(checked ? `${name} 已连接` : `${name} 已断开`);
        } catch (error) {
          toast(error.message, true);
          input.checked = !checked;
          input.disabled = false;
        }
      }, `连接 ${name}`);
      if (!st.exists) sw.querySelector("input").disabled = true;
      return card(
        row(h("span", null, dot(!st.exists ? "" : full ? "ok" : on ? "warn" : ""), name), status, sw),
        info("配置文件", st.path),
        st.vibe_island ? info("Vibe Island", `检测到它的 ${st.vibe_island} 个钩子，互不影响`) : null,
        note ? h("div", { class: "row" }, h("div", { class: "sub" }, note)) : null);
    };
    body.replaceChildren(
      data.hook_installed ? "" : h("div", { class: "banner" }, "没有找到钩子脚本，请重新运行安装命令。"),
      agentCard("claude", "Claude Code"),
      agentCard("codex", "Codex", "连接后，Codex 下次启动会要求你确认信任新钩子，确认后才生效。"),
      hint("开关会修改对应 Agent 的全局配置文件，修改前会备份，不改动其他工具的配置。只对之后新开的对话生效。"));
  }
  draw(await api("/api/integrations"));
}

async function devicePage(mount) {
  const body = h("div");
  mount.append(body);

  function draw(d) {
    if (d.needs_setup) {
      body.replaceChildren(h("div", { class: "banner" }, "还没有连接设备。 ", link("连接设备", "setup")));
      return;
    }
    if (!d.ok) {
      body.replaceChildren(
        h("div", { class: "banner" }, `连不上设备：${d.error} `, link("更换密钥或设备", "setup")),
        card(info("设备序列号", d.device_id), info("API 密钥", d.key.looks_valid ? "格式正确" : d.key.present ? "内容不像 Dot 密钥" : "没有找到密钥文件")),
        h("div", { class: "btn-row", style: "margin-top:12px" }, button("重试", load)));
      return;
    }
    const s = d.status;
    const apply = async (patch, done) => {
      try {
        draw(await api("/api/device", patch));
        toast(done);
      } catch (error) {
        toast(error.message, true);
        load();
      }
    };
    const alias = h("input", { class: "field name", type: "text", value: d.alias, placeholder: "未命名", maxLength: 100, "aria-label": "设备名称" });

    body.replaceChildren(
      d.image_slot ? "" : h("div", { class: "banner" }, "设备的循环列表里没有“图像 API”，状态牌显示不出来。请在 Dot. App 的内容工坊里添加。"),
      d.asleep ? h("div", { class: "banner" }, `设备休眠中，每 ${d.battery_minutes} 分钟醒来刷新一次。接上电源后有变化就刷新。 `, link("更改刷新间隔", "refresh/battery")) : "",
      card(
        info("当前状态", h("span", null, dot(d.asleep ? "warn" : "ok"), s.current || "未知")),
        info("供电", s.battery || "未知"),
        info("Wi-Fi 信号", s.wifi || "未知"),
        info("上次刷新", d.last_render || "未知"),
        info("固件版本", s.version || "未知"),
        info("时区", d.timezone || "未知"),
        info("设备序列号", d.device_id),
        info("API 密钥", d.key.looks_valid ? "有效" : "格式不对")),
      section("名称"),
      card(
        row("设备名称", "显示在 Dot. App 里", alias, button("保存", () => apply({ alias: alias.value }, "已保存")))),
      hint("刷新间隔和休眠时段在", link("刷新", "refresh"), "里。更换密钥或设备在", link("连接设备", "setup"), "里。"));
  }

  async function load() {
    body.replaceChildren(h("div", { class: "empty" }, "正在读取设备信息…"));
    try {
      draw(await api("/api/device"));
    } catch (error) {
      body.replaceChildren(h("div", { class: "banner" }, error.message));
    }
  }
  await load();
}

// Connecting a device: the key, then the device it is for, then whether that device can show the board.
async function setupPage(mount) {
  const MODEL = { quote_0: "Quote/0" };
  const body = h("div");
  mount.append(body);
  let changingKey = false;

  async function send(patch, done) {
    const state = await api("/api/setup", patch);
    changingKey = false;
    draw(state);
    toast(done);
  }

  function keyCard(state) {
    if (state.key.present && !state.error && !changingKey) {
      return card(row("API 密钥", `已保存，能访问 ${state.devices.length} 台设备`, button("更换", () => {
        changingKey = true;
        draw(state);
      })));
    }
    const input = h("input", { class: "field key", type: "password", autocomplete: "off", placeholder: "dot_app_…", "aria-label": "API 密钥" });
    const save = button("保存", () => busy(save, async () => {
      if (!input.value.trim()) throw new Error("先把密钥粘贴进来");
      await send({ key: input.value }, "密钥已保存");
    }));
    input.addEventListener("keydown", (event) => event.key === "Enter" && save.click());
    return card(row("API 密钥", ["在 Dot. App 的「更多」→「API 密钥」里创建并复制，粘贴到这里。",
      h("a", { href: "https://dot.mindreset.tech/docs/service/open/get_api", target: "_blank", rel: "noreferrer" }, "官方说明")], input, save));
  }

  function deviceCard(state) {
    if (!state.devices.length) return card(h("div", { class: "empty" }, "这个密钥下还没有设备。先在 Dot. App 里绑定一台 Quote/0，再回来刷新这个页面。"));
    return card(state.devices.map((d) => {
      const use = button("使用这台", () => busy(use, () => send({ device_id: d.id }, "设备已连接")));
      return row(d.alias || MODEL[d.model] || d.model || "设备", [d.alias && (MODEL[d.model] || d.model), `序列号 ${d.id}`].filter(Boolean).join(" · "),
        d.id === state.device_id ? pill("正在使用", "ok") : use);
    }));
  }

  function screenCard() {
    const slot = h("div");
    const check = async () => {
      slot.replaceChildren(h("div", { class: "empty" }, "正在检查设备…"));
      let d;
      try {
        d = await api("/api/device");
      } catch (error) {
        d = { ok: false, error: error.message };
      }
      const again = button("重新检查", check);
      if (!d.ok) {
        slot.replaceChildren(row(h("span", null, dot("bad"), "连不上设备"), d.error, again));
        return;
      }
      const s = d.status || {};
      const test = button("发送测试画面", () => busy(test, async () => {
        await api("/api/test-frame", {});
        toast("测试画面已发出，15 秒后自动恢复");
      }));
      slot.replaceChildren(
        d.image_slot
          ? row(h("span", null, dot("ok"), "图像 API"), "已在设备的循环列表里，状态牌显示在这一项", test)
          : row(h("span", null, dot("bad"), "图像 API"), "循环列表里还没有。打开 Dot. App 的内容工坊，把「图像 API」加进这台设备的循环列表，再点重新检查", again),
        row(h("span", null, dot((s.battery || "").includes("已连接电源") ? "ok" : "warn"), "供电"),
          (s.battery || "").includes("已连接电源") ? "已接电源，有变化就刷新" : `${s.battery || "未知"}。用电池时设备会休眠，隔一段时间才刷新一次，建议一直插着电`));
    };
    check();
    return h("div", { class: "card" }, slot);
  }

  function draw(state) {
    body.replaceChildren(...[
      state.error && h("div", { class: "banner" }, `用保存的密钥连不上 MindReset 服务：${state.error}。可以重新填一次密钥。`),
      section("第 1 步 · API 密钥"), keyCard(state),
      hint("密钥只保存在这台电脑上，只发给 MindReset 的服务。"),
      state.key.present && !state.error && section("第 2 步 · 设备"),
      state.key.present && !state.error && deviceCard(state),
      state.ready && section("第 3 步 · 屏幕"),
      state.ready && screenCard(),
      state.ready && h("div", { class: "btn-row", style: "margin-top:12px" }, button("完成", () => (location.hash = "overview"))),
      state.ready && hint("哪些 Agent 的状态显示在屏幕上，在", link("Agent", "integrations"), "里。"),
    ].filter(Boolean));
  }

  draw(await api("/api/setup"));
}

async function diagnosticsPage(mount) {
  const results = h("div", { class: "card" }, h("div", { class: "empty" }, "点“开始自检”，从钩子到屏幕逐项检查。"));
  const logBox = h("pre", { class: "log", tabIndex: 0 });

  const checkBtn = button("开始自检", () => busy(checkBtn, async () => {
    results.replaceChildren(h("div", { class: "empty" }, "检查中…"));
    const data = await api("/api/check", {});
    results.replaceChildren(...data.results.map((r) =>
      h("div", { class: "row" }, h("div", { class: "label" }, h("span", null, dot(r.ok === true ? "ok" : r.ok === false ? "bad" : "warn"), r.name)), h("div", { class: "value" }, r.detail))));
  }));

  async function loadLog() {
    const data = await api("/api/log");
    logBox.textContent = data.lines.length ? data.lines.join("\n") : "日志是空的。";
    logBox.scrollTop = logBox.scrollHeight;
  }
  const logBtn = button("刷新日志", () => busy(logBtn, loadLog));

  const restartBtn = button("重启后台进程", () => busy(restartBtn, async () => {
    if (!confirm("重启后台进程？大约 10 秒后恢复，期间状态牌不更新。")) return;
    await api("/api/restart", {});
    toast("正在重启，约 10 秒后页面会自动恢复");
    setTimeout(() => location.reload(), 13000);
  }), "danger");

  mount.append(
    h("div", { class: "btn-row", style: "margin-bottom:12px" }, checkBtn), results,
    section("日志"), h("div", { class: "card" }, logBox),
    h("div", { class: "btn-row", style: "margin-top:12px" }, logBtn, restartBtn));
  await loadLog();
}

async function aboutPage(mount) {
  const a = await api("/api/about");
  mount.append(
    card(
      info("版本", a.version),
      info("设备序列号", a.device_id),
      info("设置页地址", `http://127.0.0.1:${a.port}`),
      info("运行环境", a.runtime || `Python ${a.python} · Pillow ${a.pillow}`)),
    section("文件位置"),
    card(info("运行目录", a.home), info("配置", a.config), info("日志", a.log), info("配置文件备份", a.backups)),
    section("卸载"),
    card(h("div", { class: "row" }, h("div", { class: "label" }, a.uninstall || ["在项目文件夹里运行下面的命令，会移除钩子和后台进程，并恢复设备的循环间隔。",
      h("code", { class: "cmd", style: "margin-top:8px" }, "python3 install.py --uninstall")]))),
    section("参考"),
    card(
      info("开放 API 文档", h("a", { href: "https://dot.mindreset.tech/docs/service/open", target: "_blank", rel: "noreferrer" }, "dot.mindreset.tech")),
      info("灵感来源", h("a", { href: "https://vibeisland.app/zh/", target: "_blank", rel: "noreferrer" }, "Vibe Island"))));
}

// ---- shell ---------------------------------------------------------------

const PAGES = [
  { id: "overview", label: "总览", color: "t-blue", render: overviewPage },
  { id: "display", label: "画面", color: "t-purple", render: displayPage },
  { id: "refresh", label: "刷新", color: "t-cyan", render: refreshPage },
  { id: "alerts", label: "提醒", color: "t-red", render: alertsPage },
  { id: "integrations", label: "Agent", color: "t-green", render: integrationsPage },
  { id: "device", label: "设备", color: "t-orange", render: devicePage },
  { id: "setup", label: "连接设备", color: "t-orange", icon: "device", hidden: true, render: setupPage },  // reached from links, not the sidebar
  { id: "diagnostics", label: "诊断", color: "t-teal", group: "高级", render: diagnosticsPage },
  { id: "about", label: "关于", color: "t-gray", render: aboutPage },
];

let leave = [];
let visit = 0;

async function show() {
  const [id, anchor] = location.hash.slice(1).split("/");
  const page = PAGES.find((p) => p.id === id) || PAGES[0];
  const mine = ++visit;
  leave.forEach((fn) => fn());
  leave = [];
  document.querySelectorAll(".nav").forEach((el) => {
    if (el.dataset.page === page.id) el.setAttribute("aria-current", "page");
    else el.removeAttribute("aria-current");
  });
  document.getElementById("page-title").textContent = page.label;
  const tile = document.getElementById("page-tile");
  tile.className = `tile ${page.color}`;
  tile.replaceChildren(SVG(ICONS[page.icon || page.id]));
  document.title = `${page.label} · Agent 状态牌`;

  const mount = h("div");
  document.getElementById("page").replaceChildren(mount);
  try {
    await page.render(mount, (fn) => (mine === visit ? leave.push(fn) : fn()));
    const target = anchor && mine === visit && mount.querySelector(`[data-anchor="${CSS.escape(anchor)}"]`);
    if (target) {
      target.scrollIntoView({ block: "center" });
      target.classList.add("pointed");
    }
  } catch (error) {
    mount.replaceChildren(h("div", { class: "banner" }, error.message));
  }
}

function buildSidebar() {
  const sidebar = document.getElementById("sidebar");
  for (const page of PAGES.filter((p) => !p.hidden)) {
    if (page.group) sidebar.append(h("h2", null, page.group));
    sidebar.append(h("button", { class: "nav", type: "button", "data-page": page.id, onclick: () => (location.hash = page.id) },
      h("span", { class: `tile ${page.color}` }, SVG(ICONS[page.id])), page.label));
  }
  sidebar.append(h("h2", null, `v${version}`));
}

async function start() {
  buildSidebar();
  addEventListener("hashchange", show);
  if (!location.hash) {
    try {  // nothing can be shown until a device is connected, so begin there
      if ((await api("/api/overview")).needs_setup) history.replaceState(null, "", "#setup");
    } catch {
      // the page that opens says what is wrong
    }
  }
  show();
}

start();
