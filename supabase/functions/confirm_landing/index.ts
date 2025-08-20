const html = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Account confirmed</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark light">
  <meta name="theme-color" content="#0F1311">
  <meta name="robots" content="noindex">
  <meta name="description" content="Your Shudo account email has been confirmed.">
  <style>
    :root{
      --paper:#0F1311; --ink:#FFFFFF; --muted:#9BA39E; --rule:rgba(255,255,255,.10);
      --glass:rgba(255,255,255,.06); --accent:#2B8A6E; --radius:14px; --xl:24px; --l:16px; --m:14px; --s:10px;
    }
    *{box-sizing:border-box}
    html,body{height:100%}
    body{
      margin:0; background:var(--paper); color:var(--ink);
      font-family:ui-sans-serif,system-ui,Segoe UI,Roboto,Helvetica,Arial,sans-serif;
      -webkit-font-smoothing:antialiased; -moz-osx-font-smoothing:grayscale;
    }
    .wrap{max-width:680px;margin:10vh auto;padding:0 var(--l)}
    .brand{font-weight:800; letter-spacing:-0.02em; font-size:28px; margin:0 0 var(--m);}
    .card{
      padding:var(--xl);
      border-radius:var(--radius);
      background:var(--glass);
      border:1px solid var(--rule);
      backdrop-filter: saturate(140%) blur(6px);
    }
    h1{font-size:22px;margin:0 0 var(--s);font-weight:700}
    p{color:var(--muted);line-height:1.6;margin:0}
    .actions{margin-top:var(--l)}
    .btn{display:inline-block;padding:10px 14px;border-radius:12px;background:var(--accent);color:#fff;text-decoration:none}
    .subtle{display:block;margin-top:10px;color:var(--muted);font-size:13px;text-decoration:none}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <div class="brand">shudo</div>
      <h1>You're all set</h1>
      <p>Your email has been confirmed. You can return to the app and sign in.</p>
      <div class="actions">
        <a class="btn" href="#" onclick="history.back();return false;">Return</a>
        <a class="subtle" href="#" onclick="navigator.userAgent.includes('iPhone')?window.close():history.back();return false;">Or just close this tab</a>
      </div>
    </div>
  </div>
  
</body>
</html>`;

export default {
  async fetch(_req: Request): Promise<Response> {
    return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
  },
};


