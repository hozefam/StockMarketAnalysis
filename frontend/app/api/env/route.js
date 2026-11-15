// Tells the UI which environment it is running in (APP_ENV is set by the Container App; "local" otherwise).
// This static route takes precedence over the /api/* gateway proxy.
export const dynamic = "force-dynamic";

export function GET() {
  return Response.json({ env: process.env.APP_ENV || "local" });
}
