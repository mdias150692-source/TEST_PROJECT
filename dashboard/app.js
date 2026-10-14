// Renders the Vega-Lite specs from specs/*.json and two HTML tables from data/*.json.
// Data is inserted with textContent only (no innerHTML), so file contents can't inject markup.
"use strict";

const SPECS = [
  "kpi",
  "ratios_dynamics",
  "portfolio_bridge",
  "breakdown_sector",
  "breakdown_program",
  "dpd_migration",
  "top_groups",
];

const css = getComputedStyle(document.documentElement);
const token = (name) => css.getPropertyValue(name).trim();
const isDark = () => css.colorScheme === "dark";

// Chart chrome comes from CSS tokens, so light/dark are both "selected" palettes.
const config = {
  background: null,
  font: token("--font"),
  view: { stroke: null },
  text: { color: token("--ink") },
  title: { color: token("--ink"), subtitleColor: token("--ink-2"), fontSize: 15, fontWeight: 600, subtitleFontSize: 12, offset: 12 },
  axis: {
    labelColor: token("--ink-2"), titleColor: token("--ink-2"), labelFontSize: 11, titleFontSize: 11, titleFontWeight: 500,
    gridColor: token("--grid"), domainColor: token("--axis"), tickColor: token("--axis"),
  },
  legend: { labelColor: token("--ink-2"), titleColor: token("--ink-2"), labelFontSize: 11, titleFontSize: 11, symbolType: "circle" },
  bar: { stroke: token("--surface"), strokeWidth: 2 },
  rule: { color: token("--ink-2") },
};

// Russian number format: 1 234,5 ; minus sign; ₸ as currency suffix.
const formatLocale = { decimal: ",", thousands: " ", grouping: [3], currency: ["", " ₸"], minus: "−", percent: "%" };

const embedOptions = {
  renderer: "svg",
  config,
  formatLocale,
  // "Open in editor" would post the spec to an external site — disabled.
  actions: { export: true, source: false, compiled: false, editor: false },
  tooltip: { theme: isDark() ? "dark" : "light" },
};

function showError(el, err) {
  const p = document.createElement("p");
  p.className = "error";
  p.textContent = "Не удалось построить график: " + err.message +
    " (откройте страницу через http-сервер: python -m http.server --bind 127.0.0.1 --directory dashboard 8000)";
  el.replaceChildren(p);
  console.error(err);
}

const fmtDate = (iso) => iso.split("-").reverse().join(".");
const nf = (opts) => new Intl.NumberFormat("ru-RU", opts);
function fmtValue(unit, v) {
  if (v === null || v === undefined) return "—";
  if (unit === "kzt") return nf({ maximumFractionDigits: 0 }).format(v) + " ₸";
  if (unit === "ratio") return nf({ style: "percent", minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(v);
  return nf({ maximumFractionDigits: 0 }).format(v);
}
function fmtChange(unit, abs, rel) {
  if (unit === "ratio") return nf({ signDisplay: "exceptZero", minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(abs * 100) + " п.п.";
  const a = nf({ signDisplay: "exceptZero", maximumFractionDigits: 0 }).format(abs);
  return rel === null ? a : a + " (" + nf({ style: "percent", signDisplay: "exceptZero", maximumFractionDigits: 1 }).format(rel) + ")";
}
function cell(tr, text, cls) {
  const td = document.createElement("td");
  td.textContent = text;
  if (cls) td.className = cls;
  tr.appendChild(td);
}

async function renderTables() {
  const [metrics, dq] = await Promise.all([
    fetch("data/metrics.json").then((r) => r.json()),
    fetch("data/data_quality.json").then((r) => r.json()),
  ]);
  const dates = [...new Set(metrics.map((m) => m.report_date))].sort();
  const [d0, d1] = [dates[0], dates[dates.length - 1]];
  document.getElementById("dates").textContent = dates.map(fmtDate).join(" и ");
  document.querySelector('#metrics-table th[data-col="d0"]').textContent = fmtDate(d0);
  document.querySelector('#metrics-table th[data-col="d1"]').textContent = fmtDate(d1);

  const tbody = document.querySelector("#metrics-table tbody");
  const byMetric = new Map();
  for (const m of metrics) {
    if (!byMetric.has(m.metric)) byMetric.set(m.metric, {});
    byMetric.get(m.metric)[m.report_date] = m;
  }
  [...byMetric.values()]
    .sort((a, b) => a[d0].sort_order - b[d0].sort_order)
    .forEach((row) => {
      const a = row[d0], b = row[d1];
      const tr = document.createElement("tr");
      cell(tr, a.label);
      cell(tr, fmtValue(a.unit, a.value), "num");
      cell(tr, fmtValue(b.unit, b.value), "num");
      cell(tr, fmtChange(b.unit, b.change_abs, b.change_rel), "num");
      tbody.appendChild(tr);
    });

  const dqBody = document.querySelector("#dq-table tbody");
  for (const r of dq) {
    const tr = document.createElement("tr");
    cell(tr, r.description);
    cell(tr, nf({}).format(r.value), "num");
    dqBody.appendChild(tr);
  }
}

window.addEventListener("DOMContentLoaded", () => {
  const charts = SPECS.map((name) => {
    const el = document.getElementById(name);
    return vegaEmbed(el, "specs/" + name + ".json", embedOptions).catch((err) => showError(el, err));
  });
  const tables = renderTables().catch((err) => showError(document.getElementById("metrics-table"), err));
  // Signal for headless screenshots: everything has rendered.
  Promise.allSettled([...charts, tables]).then(() => document.body.setAttribute("data-ready", "1"));
});
