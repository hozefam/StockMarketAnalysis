// Gateway: the browser only ever talks to this frontend. Requests to /api/* are forwarded server-side to the
// backend over the private network. In Azure the backend has internal-only ingress, so this is the only way in.
// BACKEND_URL is read at request time (set by the Container App); locally it defaults to the dev backend.
export const dynamic = "force-dynamic";

const BACKEND = () => (process.env.BACKEND_URL || "http://localhost:8000").replace(/\/$/, "");

export async function GET(req, { params }) {
  const url = new URL(req.url);
  const target = `${BACKEND()}/api/${params.path.map(encodeURIComponent).join("/")}${url.search}`;
  try {
    const res = await fetch(target, { cache: "no-store", signal: AbortSignal.timeout(120000) });
    return new Response(res.body, {
      status: res.status,
      headers: { "content-type": res.headers.get("content-type") || "application/json" },
    });
  } catch (e) {
    return Response.json({ ok: false, error: "Backend unreachable" }, { status: 502 });
  }
}
