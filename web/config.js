// Production (connect.example.com). Both values are public by design: the
// publishable key only reaches what RLS and the scan function allow.
// Local dev: web/serve.py serves config.local.js instead when it exists.
window.CONNECT_CONFIG = {
  supabaseUrl: "https://YOUR-PROJECT-REF.supabase.co",
  anonKey: "YOUR-PUBLISHABLE-KEY",
};
