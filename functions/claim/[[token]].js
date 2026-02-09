// Catch-all for /claim/:token paths.
// Serves the claim SPA's index.html so the React router can handle the token.
// Static assets under /claim/assets/* are served directly by Pages (no function invoked).

export async function onRequest(context) {
  const url = new URL(context.request.url);

  // Don't intercept actual static assets
  if (url.pathname.startsWith('/claim/assets/')) {
    return context.next();
  }

  // Fetch the claim SPA index.html from the static assets
  const spaUrl = new URL('/claim/index.html', url.origin);
  const response = await context.env.ASSETS.fetch(spaUrl);

  return new Response(response.body, {
    status: 200,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Frame-Options': 'DENY',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
    },
  });
}
