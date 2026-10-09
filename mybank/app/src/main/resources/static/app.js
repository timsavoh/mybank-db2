"use strict";

// ---------- helpers ----------

const view = document.getElementById("view");
let pollTimer = null;
let tickTimer = null;
let pageGen = 0; // bumped on every navigation so a poll loop from an earlier page stops

const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json", "X-Channel": "BRN", "X-Operator": "BACKOFFICE" },
    ...opts,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) {
    const err = new Error(data?.error || `Request failed (${res.status})`);
    err.sqlState = data?.sqlState;
    throw err;
  }
  return data;
}

const MONEY_COL = /(BALANCE|AMOUNT|NET|TOTAL|SPEND|LIMIT|_IN$|_OUT$|^IN$|^OUT$|DIFFERENCE|EXPECTED|ACTUAL|INTEREST|PRINCIPAL|PAYMENT|OUTSTANDING|ARREARS|FEE|VALUE)/i;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function money(v) {
  if (v === null || v === undefined || v === "") return "";
  const n = Number(v);
  const s = Math.abs(n).toLocaleString("en-GB", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  return n < 0 ? `<span class="debit">-${s}</span>` : s;
}

function fmtDate(v) {
  if (!v) return "";
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}):(\d{2}))?/.exec(v);
  if (!m) return esc(v);
  const d = `${Number(m[3])} ${MONTHS[Number(m[2]) - 1]} ${m[1]}`;
  return m[4] ? `${d}, ${m[4]}:${m[5]}:${m[6]}` : d;
}

const ACRONYMS = { eod: "EOD", gl: "GL", mqts: "MQTs", dd: "DD", kyc: "KYC", ni: "NI", id: "ID", mcc: "MCC", od: "OD" };

function humanize(col) {
  const s = String(col).replace(/_/g, " ").toLowerCase().trim()
    .split(" ").map((w) => ACRONYMS[w] || w).join(" ");
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function cell(col, v) {
  if (typeof v === "number" && MONEY_COL.test(col)) return { html: money(v), num: true };
  if (typeof v === "number") return { html: v.toLocaleString("en-GB"), num: true };
  if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}/.test(v)) return { html: fmtDate(v), num: false };
  if (col.toUpperCase() === "SORT_CODE" && /^\d{6}$/.test(v)) return { html: `${v.slice(0, 2)}-${v.slice(2, 4)}-${v.slice(4)}`, num: false };
  return { html: esc(v), num: false };
}

function table(rows, { onRow, empty = "Nothing to show." } = {}) {
  if (!rows || rows.length === 0) return `<p class="empty">${esc(empty)}</p>`;
  const cols = Object.keys(rows[0]);
  const numCols = new Set(cols.filter((c) => rows.some((r) => typeof r[c] === "number")));
  const head = cols.map((c) => `<th class="${numCols.has(c) ? "num" : ""}">${esc(humanize(c))}</th>`).join("");
  const body = rows.map((r, i) => {
    const tds = cols.map((c) => {
      const { html, num } = cell(c, r[c]);
      return `<td class="${num ? "num" : ""}">${html}</td>`;
    }).join("");
    return `<tr${onRow ? ` class="clickable" data-row="${i}" tabindex="0"` : ""}>${tds}</tr>`;
  }).join("");
  return `<div class="tablewrap"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
}

function bindRows(container, rows, onRow) {
  container.querySelectorAll("tr[data-row]").forEach((tr) => {
    const go = () => onRow(rows[Number(tr.dataset.row)]);
    tr.addEventListener("click", go);
    tr.addEventListener("keydown", (e) => { if (e.key === "Enter") go(); });
  });
}

function notice(el, message, kind = "") {
  el.innerHTML = message ? `<div class="notice ${kind}">${esc(message)}</div>` : "";
}

function duration(seconds) {
  const s = Math.max(0, Math.round(seconds));
  return s >= 60 ? `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, "0")}s` : `${s}s`;
}

// ---------- routing ----------

function route() {
  clearTimeout(pollTimer);
  clearInterval(tickTimer);
  pageGen++;
  const [section, id] = location.hash.replace(/^#\/?/, "").split("/");
  const page = section || "ops";
  document.querySelectorAll("[data-nav]").forEach((a) => {
    if (a.dataset.nav === page) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
  });
  if (page === "customers") return id ? customer360(id) : customers();
  if (page === "reports") return reports(id);
  return ops();
}
window.addEventListener("hashchange", route);

// ---------- operations ----------

const TXN_TYPES = {
  CARD: "Card payments", FPO: "Faster Payments out", FPI: "Payments in", XFR: "Transfers",
  DD: "Direct debits", SO: "Standing orders", CASH: "Cash", FEE: "Fees", INT: "Interest",
  LOAN: "Loan repayments", ADJ: "Adjustments", CHQ: "Cheques",
};
const AUTH_CODES = {
  "00": "Approved", "05": "Do not honour", "14": "Invalid card", "43": "Stolen card",
  "51": "Insufficient funds", "54": "Expired card", "59": "Suspected fraud", "61": "Over daily limit",
};
const SCENARIOS = [
  ["velocity", "Card used 20 times in a minute"],
  ["gambling", "Heavy gambling spend"],
  ["new_payee_large", "Large payment to a new payee"],
  ["declines", "Burst of declined cards"],
];
let lastBusinessDate = null;
let dayClock = null;   // last control row, plus a local anchor so the countdown ticks between polls
let lastValues = {};   // figures from the previous poll, to highlight the ones that moved

function ops() {
  view.innerHTML = `
    <section class="dayband">
      <div id="today" class="today">
        <span class="weekday">&nbsp;</span>
        <span class="bigdate">&nbsp;</span>
        <span class="prev">&nbsp;</span>
      </div>
      <div>
        <div id="daytext" class="daytext">Connecting to MyBank&hellip;</div>
        <div class="dayprogress" aria-hidden="true"><div id="dayprogress" style="width:0"></div></div>
        <div class="actions">
          <button id="run-eod">Run end of day now</button>
          <button id="force-me" class="secondary">Force month-end</button>
          <div class="daylength"><span id="daylen-label">Day length</span>
            <div id="daylen" class="segmented" role="group" aria-labelledby="daylen-label">
              ${[2, 3, 5, 10, 15].map((m) => `<button type="button" data-minutes="${m}" aria-pressed="false">${m} min</button>`).join("")}
            </div>
          </div>
        </div>
        <div id="ops-msg"></div>
      </div>
    </section>
    <div class="grid ops">
      <div class="stack">
        <section class="sheet"><h2>End-of-day chain</h2><div id="chain"></div></section>
        <section class="sheet"><h2>Intraday jobs</h2><div id="intraday"></div>
          <h3>Scheduled inside Db2</h3><div id="db2tasks"></div></section>
      </div>
      <div class="stack">
        <section class="sheet">
          <h2>Traffic</h2>
          <div id="loadgen"></div>
        </section>
        <section class="sheet"><h2>Today&rsquo;s postings</h2><div id="activity"></div>
          <h3>Card authorisations</h3><div id="auths"></div></section>
        <section class="sheet"><h2>Ledger checks</h2><div id="ledger"></div></section>
        <section class="sheet"><h2>Recent errors</h2><div id="errors"></div></section>
      </div>
    </div>`;

  const msg = view.querySelector("#ops-msg");
  view.querySelector("#run-eod").onclick = async () => {
    try { await api("/api/ops/run-eod-now", { method: "POST" }); notice(msg, "End of day will start at the scheduler's next check."); }
    catch (e) { notice(msg, e.message, "error"); }
  };
  view.querySelector("#force-me").onclick = async () => {
    try { await api("/api/ops/force-month-end", { method: "POST" }); notice(msg, "Month-end jobs will run at the next end of day."); }
    catch (e) { notice(msg, e.message, "error"); }
  };
  view.querySelectorAll("#daylen button").forEach((b) => b.onclick = async () => {
    setDayLength(Number(b.dataset.minutes));
    try { await api("/api/ops/day-length", { method: "POST", body: { minutes: Number(b.dataset.minutes) } }); }
    catch (err) { notice(msg, err.message, "error"); }
  });

  renderLoadgenShell();
  dayClock = null;
  lastValues = {};
  refreshOps(pageGen);
  tickTimer = setInterval(renderDay, 250);
}

// Poll once a second, starting the next request only when the last one is back. Slower in a hidden tab.
async function refreshOps(gen) {
  const next = (ms) => { if (gen === pageGen) pollTimer = setTimeout(() => refreshOps(gen), ms); };
  let s;
  try { s = await api("/api/ops/status"); }
  catch (e) {
    if (gen !== pageGen) return;
    dayClock = null;
    document.getElementById("daytext").textContent = `Can't reach the bank: ${e.message}`;
    return next(3000);
  }
  if (gen !== pageGen) return;
  next(document.hidden ? 5000 : 1000);

  const c = s.control;
  const today = document.getElementById("today");
  const d = new Date(`${c.businessDate}T12:00:00`);
  today.querySelector(".weekday").textContent =
    c.dayStatus === "C" ? "End of day running" : d.toLocaleDateString("en-GB", { weekday: "long" });
  const big = today.querySelector(".bigdate");
  big.textContent = d.toLocaleDateString("en-GB", { day: "numeric", month: "long", year: "numeric" });
  today.querySelector(".prev").textContent = c.previousBusinessDate
    ? `Business date. Previous: ${fmtDate(c.previousBusinessDate)}` : "Business date";
  today.classList.toggle("eod", c.dayStatus === "C");
  if (lastBusinessDate && lastBusinessDate !== c.businessDate) {
    big.classList.remove("rolled"); void big.offsetWidth; big.classList.add("rolled");
  }
  lastBusinessDate = c.businessDate;

  // secondsOpen is truncated to whole seconds, so only re-anchor the local clock when the
  // server disagrees by more than that; otherwise the countdown would stutter back a second.
  const now = performance.now();
  const sameDay = dayClock && dayClock.control.businessDate === c.businessDate && dayClock.control.dayStatus === c.dayStatus;
  const reported = c.secondsOpen + 0.5;
  dayClock = sameDay && Math.abs(secondsOpenAt(now) - reported) <= 1.5
    ? { ...dayClock, control: c }
    : { control: c, openAt: reported, at: now };
  renderDay();
  setDayLength(c.minutesPerDay);

  const jobRows = (types) => s.jobs.filter((j) => types.includes(j.type));
  document.getElementById("chain").innerHTML = jobTable(jobRows(["EOD", "NIGHTLY", "MONTHEND"]), true);
  document.getElementById("intraday").innerHTML = jobTable(jobRows(["INTRADAY"]), false);
  document.getElementById("db2tasks").innerHTML = jobTable(jobRows(["DB2TASK"]), false);

  document.getElementById("activity").innerHTML = s.activity.length === 0
    ? `<p class="empty">No postings yet today.</p>`
    : `<table><thead><tr><th>Type</th><th class="num">Count</th><th class="num">Net</th></tr></thead><tbody>
       ${s.activity.map((a) => `<tr><td>${esc(TXN_TYPES[a.type] || a.type)}</td>
         <td class="num" data-k="txn-count-${esc(a.type)}">${Number(a.count).toLocaleString("en-GB")}</td>
         <td class="num" data-k="txn-net-${esc(a.type)}">${money(a.net)}</td></tr>`).join("")}
       </tbody></table>`;

  const totalAuths = s.cardAuths.reduce((t, a) => t + Number(a.count), 0);
  document.getElementById("auths").innerHTML = totalAuths === 0
    ? `<p class="empty">No card authorisations yet today.</p>`
    : `<table><tbody>${s.cardAuths.map((a) => `<tr><td>${esc(AUTH_CODES[a.code] || a.code)}
        <span class="muted small">${esc(a.code)}</span></td>
        <td class="num" data-k="auth-${esc(a.code)}">${Number(a.count).toLocaleString("en-GB")}</td>
        <td class="num muted">${((a.count / totalAuths) * 100).toFixed(1)}%</td></tr>`).join("")}</tbody></table>
       <p class="small muted"><span data-k="alerts">${Number(s.openAlerts).toLocaleString("en-GB")}</span> fraud alerts waiting for review.</p>`;

  document.getElementById("ledger").innerHTML = `<table><tbody>${s.ledger.map((l) => {
      const zero = Number(l.difference) === 0;
      return `<tr><td>${esc(l.check)}</td><td class="num ${zero ? "check-ok" : "check-bad"}">
        ${zero ? "Balances" : money(l.difference)}</td></tr>`;
    }).join("")}</tbody></table>
    <p class="small muted">Live figures read without locks, so a posting in flight can show for a moment.
    ${s.reconBreaks.length ? `Last end-of-day break: ${esc(s.reconBreaks[0].check)} on ${fmtDate(s.reconBreaks[0].businessDate)}.` : "No end-of-day reconciliation breaks."}</p>`;

  document.getElementById("errors").innerHTML = s.errors.length === 0
    ? `<p class="empty">No errors logged.</p>`
    : `<table><tbody>${s.errors.map((e) => `<tr><td class="small muted">${fmtDate(e.at)}</td>
        <td><strong>${esc(e.proc)}</strong> <span class="muted small">${esc(e.sqlState)}</span><br>${esc(e.message)}</td></tr>`).join("")}</tbody></table>`;

  updateLoadgen(s.loadgen);
  highlightChanges();
}

function secondsOpenAt(now) {
  return dayClock.openAt + (now - dayClock.at) / 1000;
}

// Runs every 250ms so the countdown turns over close to the real second.
function renderDay() {
  const text = document.getElementById("daytext");
  if (!dayClock || !text) return;
  const c = dayClock.control;
  const dayLen = c.minutesPerDay * 60;
  const open = c.dayStatus === "C" ? c.secondsOpen : secondsOpenAt(performance.now());
  const remaining = Math.ceil(dayLen - open);
  const monthEnd = c.isMonthEnd === "Y" || c.forceMonthEnd === "Y";
  const html = c.dayStatus === "C"
    ? `<strong>End of day is running</strong> for ${fmtDate(c.businessDate)}.${monthEnd ? " Month-end jobs are included." : ""}`
    : remaining > 0
      ? `Business day open. End of day starts in <strong>${duration(remaining)}</strong>.${monthEnd ? " Tonight is month-end." : ""}`
      : `Business day complete. End of day is waiting for the scheduler.`;
  if (text.innerHTML !== html) text.innerHTML = html;
  document.getElementById("dayprogress").style.width = `${Math.min(100, (open / dayLen) * 100)}%`;
}

function highlightChanges() {
  const seen = {};
  view.querySelectorAll("[data-k]").forEach((el) => {
    const k = el.dataset.k;
    seen[k] = el.textContent;
    if (k in lastValues && lastValues[k] !== seen[k]) el.classList.add("bump");
  });
  lastValues = seen;
}

function setDayLength(minutes) {
  document.querySelectorAll("#daylen button").forEach((b) =>
    b.setAttribute("aria-pressed", String(Number(b.dataset.minutes) === minutes)));
}

function jobTable(jobs, sequenced) {
  if (jobs.length === 0) return `<p class="empty">No jobs defined.</p>`;
  const mark = { S: "&#10003; Done", F: "&#10007; Failed", R: "Running" };
  return `<table><thead><tr>${sequenced ? "<th>Step</th>" : ""}<th>Job</th><th>Last business day</th>
    <th class="num">Time</th><th class="num">Rows</th><th>Result</th></tr></thead><tbody>
    ${jobs.map((j) => `<tr>
      ${sequenced ? `<td class="seq">${esc(j.seq)}</td>` : ""}
      <td>${esc(humanize(j.job))}${j.type === "MONTHEND" ? '<span class="tag">month-end</span>' : ""}${j.type === "NIGHTLY" ? '<span class="tag">housekeeping</span>' : ""}</td>
      <td>${fmtDate(j.businessDate) || '<span class="muted">Not run</span>'}</td>
      <td class="num">${j.ms != null ? (j.ms >= 1000 ? `${(j.ms / 1000).toFixed(1)}s` : `${j.ms}ms`) : ""}</td>
      <td class="num">${j.rows != null ? Number(j.rows).toLocaleString("en-GB") : ""}</td>
      <td><span class="mark ${esc(j.status)}" title="${esc(j.message)}">${mark[j.status] || ""}</span></td>
    </tr>`).join("")}</tbody></table>`;
}

function renderLoadgenShell() {
  document.getElementById("loadgen").innerHTML = `
    <div class="rate"><output id="tps">0</output><span class="muted">transactions a second</span></div>
    <input id="tps-range" type="range" min="0" max="200" step="1" aria-label="Transactions per second">
    <h3>Try a fraud pattern</h3>
    <div class="actions">${SCENARIOS.map(([k, label]) =>
      `<button class="secondary" data-scenario="${k}">${esc(label)}</button>`).join("")}</div>
    <p id="loadgen-msg" class="small muted"></p>`;
  const range = document.getElementById("tps-range");
  let t;
  range.oninput = () => {
    document.getElementById("tps").textContent = range.value;
    clearTimeout(t);
    t = setTimeout(() => api("/api/ops/loadgen/rate", { method: "POST", body: { tps: Number(range.value) } }), 250);
  };
  document.querySelectorAll("[data-scenario]").forEach((b) => b.onclick = async () => {
    await api(`/api/ops/loadgen/scenario/${b.dataset.scenario}`, { method: "POST" });
    document.getElementById("loadgen-msg").textContent =
      `Sent "${b.textContent}". Fraud rules pick it up at end of day; the authorisation fraud score may catch it sooner.`;
  });
}

function updateLoadgen(lg) {
  const range = document.getElementById("tps-range");
  const msg = document.getElementById("loadgen-msg");
  if (!range) return;
  if (!lg || lg.unavailable) {
    range.disabled = true;
    range.value = 0;
    document.getElementById("tps").textContent = "0";
    msg.textContent = "The load generator isn't running. Start it with docker compose up loadgen.";
    return;
  }
  range.disabled = false;
  if (document.activeElement !== range) {
    range.value = lg.targetTps;
    document.getElementById("tps").textContent = Math.round(lg.targetTps);
  }
}

// ---------- customers ----------

const CUSTOMER_PAGE = 50;

// The full list, paged. Filling in any filter switches to CUST.SEARCH_CUSTOMERS, which needs at least one.
function customers() {
  view.innerHTML = `
    <div class="pagehead"><h1>Customers</h1></div>
    <section class="sheet">
      <form id="search" class="form">
        <label>Surname<input name="lastName" autocomplete="off"></label>
        <label>First name<input name="firstName" autocomplete="off"></label>
        <label>Postcode<input name="postcode" size="9" autocomplete="off"></label>
        <label>Customer number<input name="customerNo" size="10" autocomplete="off"></label>
        <button type="submit">Search</button>
        <button type="button" id="show-all" class="secondary">Show all</button>
      </form>
      <div id="results" style="margin-top: 16px"><p class="empty">Loading customers&hellip;</p></div>
    </section>`;
  const form = view.querySelector("#search");
  const results = view.querySelector("#results");
  const saved = new URLSearchParams(sessionStorage.getItem("customerSearch") || "");
  let page = Number(saved.get("page")) || 1;
  saved.forEach((v, k) => { if (form.elements[k]) form.elements[k].value = v; });
  let latest = 0;

  const load = async () => {
    const q = new URLSearchParams([...new FormData(form)].filter(([, v]) => v));
    const filtered = [...q.keys()].length > 0;
    sessionStorage.setItem("customerSearch", `${q}&page=${page}`);
    const req = ++latest;
    results.setAttribute("aria-busy", "true");
    let r;
    try { r = await api(`${filtered ? `/api/customers/search?${q}&` : "/api/customers?"}page=${page}&pageSize=${CUSTOMER_PAGE}`); }
    catch (err) { if (req === latest) notice(results, err.message, "error"); return; }
    finally { if (req === latest) results.removeAttribute("aria-busy"); }
    if (req !== latest) return;

    const rows = r.customers.map(({ ROW_NO, ...c }) => c);
    const total = Number(r.totalRows);
    const pages = Math.max(1, Math.ceil(total / CUSTOMER_PAGE));
    const first = (page - 1) * CUSTOMER_PAGE + 1;
    const range = rows.length ? `Showing ${first.toLocaleString("en-GB")}&ndash;${(first + rows.length - 1).toLocaleString("en-GB")} of ` : "";
    const pager = pages > 1 ? `<div class="pager">
        <button type="button" class="secondary" data-page="${page - 1}" ${page <= 1 ? "disabled" : ""}>Previous</button>
        <span class="small muted">Page ${page.toLocaleString("en-GB")} of ${pages.toLocaleString("en-GB")}</span>
        <button type="button" class="secondary" data-page="${page + 1}" ${page >= pages ? "disabled" : ""}>Next</button>
      </div>` : "";
    results.innerHTML = `<p class="small muted">${range}${total.toLocaleString("en-GB")} ${filtered ? "matching customers" : "customers"}.</p>`
      + table(rows, { onRow: true, empty: "No customers match that search." }) + pager;
    bindRows(results, rows, (row) => { location.hash = `#/customers/${row.CUSTOMER_ID}`; });
    results.querySelectorAll("[data-page]").forEach((b) => b.onclick = () => {
      page = Number(b.dataset.page);
      load();
      results.scrollIntoView({ block: "start", behavior: "smooth" });
    });
  };

  form.onsubmit = (e) => { e.preventDefault(); page = 1; load(); };
  view.querySelector("#show-all").onclick = () => { form.reset(); page = 1; load(); };
  load();
}

async function customer360(id) {
  view.innerHTML = `<p class="empty">Loading customer&hellip;</p>`;
  let r;
  try { r = await api(`/api/customers/${id}`); }
  catch (e) { view.innerHTML = `<div class="notice error">${esc(e.message)}</div><a href="#/customers">Back to search</a>`; return; }
  const c = r.customer || {};
  const name = c.FULL_NAME || [c.TITLE, c.FIRST_NAME, c.LAST_NAME].filter(Boolean).join(" ");
  const skip = new Set(["FULL_NAME", "TITLE", "FIRST_NAME", "LAST_NAME", "CUSTOMER_ID"]);
  const facts = Object.entries(c).filter(([k, v]) => !skip.has(k) && v !== null && v !== "").slice(0, 12);
  view.innerHTML = `
    <div class="pagehead"><div><a href="#/customers" class="small">Customers</a><h1>${esc(name)}</h1></div></div>
    <div class="facts">${facts.map(([k, v]) => `<div><span>${esc(humanize(k))}</span><strong>${cell(k, v).html}</strong></div>`).join("")}</div>
    <div class="grid ops">
      <div class="stack">
        <section class="sheet"><h2>Accounts</h2><div id="accts"></div></section>
        <section class="sheet"><h2 id="txn-title">Recent transactions</h2><div id="txns"></div></section>
      </div>
      <div class="stack">
        <section class="sheet">
          <h2>Move money</h2>
          <form id="xfer" class="form">
            <label>From account<select name="from">${r.accounts.map((a) =>
              `<option value="${esc(a.ACCOUNT_ID)}">${esc(a.ACCOUNT_NO)} ${esc(a.PRODUCT_NAME || a.PRODUCT_CODE || "")}</option>`).join("")}</select></label>
            <label>To account id<input name="to" inputmode="numeric" size="8" required></label>
            <label>Amount<input name="amount" inputmode="decimal" size="8" required></label>
            <button type="submit">Transfer</button>
          </form>
          <div id="xfer-msg" style="margin-top: 12px"></div>
        </section>
        <section class="sheet">
          <h2>Account controls</h2>
          <p class="small muted">Select an account on the left first.</p>
          <div class="actions">
            <button id="freeze" class="danger" disabled>Freeze account</button>
            <button id="unfreeze" class="secondary" disabled>Unfreeze</button>
          </div>
          <div id="ctl-msg" style="margin-top: 12px"></div>
        </section>
      </div>
    </div>`;
  const accts = view.querySelector("#accts");
  accts.innerHTML = table(r.accounts, { onRow: true, empty: "This customer has no accounts." });
  view.querySelector("#txns").innerHTML = table(r.recentTransactions, { empty: "No recent transactions." });
  let selected = null;
  bindRows(accts, r.accounts, async (a) => {
    selected = a;
    view.querySelector("#freeze").disabled = false;
    view.querySelector("#unfreeze").disabled = false;
    view.querySelector("#txn-title").textContent = `Transactions on ${a.ACCOUNT_NO}`;
    const t = await api(`/api/accounts/${a.ACCOUNT_ID}/transactions?pageSize=30`);
    view.querySelector("#txns").innerHTML = table(t.transactions, { empty: "No transactions in this period." });
  });
  const ctl = view.querySelector("#ctl-msg");
  const freeze = (action) => async () => {
    try {
      await api(`/api/accounts/${selected.ACCOUNT_ID}/freeze`, { method: "POST", body: { action, reason: "Back office" } });
      notice(ctl, action === "FREEZE" ? `Froze ${selected.ACCOUNT_NO}.` : `Unfroze ${selected.ACCOUNT_NO}.`);
    } catch (e) { notice(ctl, e.message, "error"); }
  };
  view.querySelector("#freeze").onclick = freeze("FREEZE");
  view.querySelector("#unfreeze").onclick = freeze("UNFREEZE");
  view.querySelector("#xfer").onsubmit = async (e) => {
    e.preventDefault();
    const f = e.target.elements;
    const out = view.querySelector("#xfer-msg");
    try {
      const x = await api("/api/transfers", { method: "POST", body: {
        fromAccountId: Number(f.from.value), toAccountId: Number(f.to.value), amount: f.amount.value, reference: "BACK OFFICE" } });
      notice(out, `Transferred ${Number(f.amount.value).toFixed(2)}. Balance now ${Number(x.fromBalance).toFixed(2)}.`);
    } catch (err) { notice(out, err.message, "error"); }
  };
}

// ---------- reports ----------

let reportCatalogue = null;

async function reports(id) {
  if (!reportCatalogue) reportCatalogue = await api("/api/reports");
  const current = reportCatalogue.find((r) => r.id === id) || reportCatalogue[0];
  view.innerHTML = `
    <div class="pagehead"><h1>Reports</h1></div>
    <div class="split">
      <nav class="reportlist">${reportCatalogue.map((r) =>
        `<a href="#/reports/${r.id}" ${r.id === current.id ? 'aria-current="page"' : ""}>${esc(r.title)}<small>${esc(r.description)}</small></a>`).join("")}</nav>
      <section class="sheet">
        <h2>${esc(current.title)}</h2>
        <form id="params" class="form">
          ${current.params.map((p) => `<label>${esc(p.label)}<input name="${p.name}" type="${p.type === "date" ? "date" : "text"}"
            placeholder="${p.defaultValue ?? ""}" size="${p.type === "date" ? 12 : 8}"></label>`).join("")}
          <button type="submit">Run report</button>
        </form>
        <div id="report-out" style="margin-top: 16px"></div>
      </section>
    </div>`;
  const form = view.querySelector("#params");
  const out = view.querySelector("#report-out");
  form.onsubmit = async (e) => {
    e.preventDefault();
    const q = new URLSearchParams([...new FormData(form)].filter(([, v]) => v));
    out.innerHTML = `<p class="empty">Running&hellip;</p>`;
    try {
      const r = await api(`/api/reports/${current.id}?${q}`);
      out.innerHTML = `<p class="small muted">Ran in ${r.elapsedMs} ms.</p>`
        + r.resultSets.map((rs, i) => (r.resultSets.length > 1 ? `<h3>Part ${i + 1} of ${r.resultSets.length}</h3>` : "")
          + table(rs, { empty: "No rows for these filters." })).join("");
    } catch (err) { notice(out, err.message, "error"); }
  };
  form.requestSubmit();
}

route();
