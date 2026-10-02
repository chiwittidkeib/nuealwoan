/* ชั้นเชื่อมต่อฐานข้อมูล: ให้แอปเรียกใช้แบบ doc / collection / onSnapshot บน Supabase */
(function () {
  "use strict";
  const FIELD_COL = { status: "status", paidAt: "ts", at: "ts" };
  const OPS = { "==": "eq", "!=": "neq", ">=": "gte", ">": "gt", "<=": "lte", "<": "lt" };

  function wrapErr(e) {
    if (!e) return { code: "unavailable", message: "unknown" };
    const msg = String(e.message || e);
    if (e.code === "42501" || /row-level security|permission denied/i.test(msg)) return { code: "invalid_argument", message: msg };
    if (/not_found/.test(msg)) return { code: "not_found", message: msg };
    if (e.code && /^(23|22|P0)/.test(e.code)) return { code: "invalid_argument", message: msg };
    return { code: "unavailable", message: msg };
  }
  const chk = ({ error }) => { if (error) throw wrapErr(error); };
  const newId = () => (window.crypto && crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now().toString(36));
  const snapDoc = (id, data) => ({ id, exists: data !== undefined && data !== null, data: () => data || undefined });
  const cmp = (a, op, b) => op === "==" ? a === b : op === "!=" ? a !== b : op === ">=" ? a >= b : op === ">" ? a > b : op === "<=" ? a <= b : op === "<" ? a < b : true;

  window.makeDb = function (sb) {
    const listeners = new Set();
    let chan = null;
    function kickAll(col) { listeners.forEach(l => { if (!col || l.col === col) l.kick(); }); }
    function ensureChan() {
      if (chan) return;
      chan = sb.channel("docs-live")
        .on("postgres_changes", { event: "*", schema: "public", table: "docs" }, p => {
          const col = (p.new && p.new.collection) || (p.old && p.old.collection);
          kickAll(col);
        })
        .subscribe();
    }
    document.addEventListener("visibilitychange", () => { if (!document.hidden) kickAll(); });
    window.addEventListener("online", () => kickAll());
    setInterval(() => { if (!document.hidden) kickAll(); }, 30000);

    function listen(col, fetcher, next, err) {
      let t = null, alive = true, running = false, again = false;
      const run = async () => {
        if (running) { again = true; return; }
        running = true;
        try { const r = await fetcher(); if (alive) next(r); }
        catch (e) { if (alive && err) err(e.code ? e : wrapErr(e)); }
        running = false;
        if (again && alive) { again = false; run(); }
      };
      const l = { col, kick: () => { clearTimeout(t); t = setTimeout(run, 120); } };
      listeners.add(l); ensureChan(); run();
      return () => { alive = false; listeners.delete(l); };
    }

    function docRef(col, id) {
      const get = async () => {
        const { data, error } = await sb.from("docs").select("data").eq("collection", col).eq("id", id).maybeSingle();
        if (error) throw wrapErr(error);
        return snapDoc(id, data ? data.data : undefined);
      };
      return {
        id, path: col + "/" + id, get,
        set: data => sb.from("docs").upsert({ collection: col, id, data }).then(chk),
        update: patch => sb.rpc("doc_merge", { p_col: col, p_id: id, p_patch: patch }).then(chk),
        delete: () => sb.from("docs").delete().eq("collection", col).eq("id", id).then(chk),
        // อ่านค่าล่าสุด -> คำนวณ -> เขียนเฉพาะเมื่อไม่มีใครแก้แทรก (ลองซ้ำได้ 4 ครั้ง)
        transform: async fn => {
          for (let i = 0; i < 4; i++) {
            const { data, error } = await sb.from("docs").select("data,version").eq("collection", col).eq("id", id).maybeSingle();
            if (error) throw wrapErr(error);
            if (!data) throw { code: "not_found", message: "not_found" };
            const patch = fn(JSON.parse(JSON.stringify(data.data)));
            if (!patch) return null;
            const r = await sb.rpc("doc_cas", { p_col: col, p_id: id, p_patch: patch, p_version: data.version });
            if (r.error) throw wrapErr(r.error);
            if (r.data === true) return patch;
          }
          throw { code: "resource_exhausted", message: "conflict" };
        },
        onSnapshot: (next, err) => listen(col, get, next, err),
        collection: sub => collection(col + "/" + id + "/" + sub)
      };
    }

    function query(col, filters) {
      const get = async () => {
        let q = sb.from("docs").select("id,data").eq("collection", col);
        const local = [];
        filters.forEach(([f, op, v]) => {
          const c = FIELD_COL[f], m = OPS[op];
          if (c && m) q = q[m](c, v); else local.push([f, op, v]);
        });
        const { data, error } = await q.limit(1000);
        if (error) throw wrapErr(error);
        let rows = data || [];
        local.forEach(([f, op, v]) => { rows = rows.filter(r => cmp(r.data && r.data[f], op, v)); });
        const docs = rows.map(r => snapDoc(r.id, r.data));
        return { docs, size: docs.length, empty: !docs.length };
      };
      return {
        where: (f, op, v) => query(col, filters.concat([[f, op, v]])),
        get,
        onSnapshot: (next, err) => listen(col, get, next, err)
      };
    }
    function collection(col) {
      return Object.assign(query(col, []), {
        path: col,
        doc: id => docRef(col, id || newId()),
        add: async data => { const r = docRef(col, newId()); await r.set(data); return r; }
      });
    }
    return {
      doc: path => { const i = path.lastIndexOf("/"); return docRef(path.slice(0, i), path.slice(i + 1)); },
      collection
    };
  };
})();
