// Production (connect.premortem.tech). Both values are public by design: the
// publishable key only reaches what RLS and the scan function allow.
// Local dev: web/serve.py serves config.local.js instead when it exists.
window.CONNECT_CONFIG = {
  supabaseUrl: "https://pbysiqjwfptmyfbjhhao.supabase.co",
  anonKey: "sb_publishable_c-iJBGAcj_oEXNWc1z9Atw_OhlNpPVx",
  // Tried in order when the one above doesn't know a tag or trip: the demo
  // server behind connect-api.premortem.tech, which the phones' builds use.
  backends: [
    { supabaseUrl: "https://pbysiqjwfptmyfbjhhao.supabase.co", anonKey: "sb_publishable_c-iJBGAcj_oEXNWc1z9Atw_OhlNpPVx" },
    { supabaseUrl: "https://connect-api.premortem.tech", anonKey: "sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH" },
  ],
};
