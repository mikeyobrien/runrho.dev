// Catch-all for /claim/:token paths.
// Serves the claim SPA's index.html so the React router can handle the token.
// Static assets under /claim/assets/* are served directly via ASSETS binding.

export async function onRequest(context) {
  const url = new URL(context.request.url);

  // Serve actual static assets directly from the asset binding
  if (url.pathname.startsWith('/claim/assets/') || url.pathname === '/claim/vite.svg') {
    return context.env.ASSETS.fetch(context.request);
  }

  // Everything else gets the SPA index.html
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
