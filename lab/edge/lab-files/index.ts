// GAM CLINIC — Лаборатория: подписанные ссылки на файлы и очистка места.
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const BUCKET = "lab-files";
const MAX = 50 * 1024 * 1024;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });

function safeName(n: string) {
  const ext = (n.match(/\.[A-Za-z0-9]{1,8}$/) || [""])[0].toLowerCase();
  return crypto.randomUUID().slice(0, 8) + ext;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const b = await req.json();
    const { data: s } = await sb.from("lab_sessions")
      .select("user_id, expires_at, lab_users(role, lab_id, active)")
      .eq("token", b.token).maybeSingle();
    // deno-lint-ignore no-explicit-any
    const u: any = s && s.lab_users;
    if (!s || !u || !u.active || new Date(s.expires_at) < new Date()) return json({ error: "AUTH" }, 401);

    const access = new Map<number, boolean>();
    async function can(id: number) {
      if (!Number.isInteger(id)) return false;
      if (access.has(id)) return access.get(id)!;
      const { data } = await sb.from("lab_orders").select("lab_id").eq("id", id).maybeSingle();
      const ok = !!data && (u.role !== "lab" || data.lab_id === u.lab_id);
      access.set(id, ok);
      return ok;
    }

    if (b.action === "upload") {
      const id = Number(b.order_id);
      if (!(await can(id))) return json({ error: "FORBIDDEN" }, 403);
      if (!(Number(b.size) > 0) || Number(b.size) > MAX) return json({ error: "TOOBIG" }, 400);
      const path = `${id}/${Date.now()}-${safeName(String(b.name || "file"))}`;
      const { data, error } = await sb.storage.from(BUCKET).createSignedUploadUrl(path);
      if (error) return json({ error: error.message }, 500);
      return json({ path, url: data.signedUrl });
    }

    if (b.action === "urls") {
      const paths: string[] = (Array.isArray(b.paths) ? b.paths : []).slice(0, 200);
      const ok: string[] = [];
      for (const p of paths) if (await can(Number(String(p).split("/")[0]))) ok.push(p);
      if (!ok.length) return json({ urls: {} });
      const { data, error } = await sb.storage.from(BUCKET).createSignedUrls(ok, 3600);
      if (error) return json({ error: error.message }, 500);
      const urls: Record<string, string> = {};
      for (const d of data || []) if (d.signedUrl && d.path) urls[d.path] = d.signedUrl;
      return json({ urls });
    }

    if (b.action === "cleanup") {
      if (u.role !== "super") return json({ error: "FORBIDDEN" }, 403);
      const ids: number[] = (Array.isArray(b.order_ids) ? b.order_ids : []).map(Number).filter(Number.isInteger);
      let freed = 0, count = 0;
      for (const id of ids) {
        const { data: o } = await sb.from("lab_orders").select("status").eq("id", id).maybeSingle();
        if (!o || !["delivered", "cancelled"].includes(o.status)) continue;
        const { data: files } = await sb.from("lab_files").select("id, path, size").eq("order_id", id).is("deleted_at", null);
        if (!files || !files.length) continue;
        const { error } = await sb.storage.from(BUCKET).remove(files.map((f) => f.path));
        if (error) return json({ error: error.message, freed, count }, 500);
        await sb.from("lab_files").update({ deleted_at: new Date().toISOString() }).in("id", files.map((f) => f.id));
        const sz = files.reduce((a, f) => a + Number(f.size || 0), 0);
        freed += sz; count += files.length;
        await sb.from("lab_msgs").insert({
          order_id: id, user_id: s.user_id, kind: "event",
          text: `Файлы удалены для освобождения места (${files.length} шт., ${(sz / 1048576).toFixed(1)} МБ)`,
        });
      }
      return json({ freed, count });
    }

    return json({ error: "BADACTION" }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
