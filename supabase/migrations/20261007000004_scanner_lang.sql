-- The language the person at the car chose on the scan page. The owner's app
-- uses it to send quick replies in that language, so the stranger reads the
-- answer in their own language without any machine translation.
alter table public.alerts
  add column scanner_lang text not null default 'en'
  check (scanner_lang in ('en', 'hi', 'kn', 'ta'));
