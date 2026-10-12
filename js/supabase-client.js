// Shared Supabase client + auth-email tagging for MeraShare.
// rotry_event project is shared with other apps (trust-analysis, tiecon-match) —
// tag every auth email with +merashare so auth.users rows never collide across apps.

const SUPABASE_URL = 'https://wrzpgultvahxbrgooibn.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndyenBndWx0dmFoeGJyZ29vaWJuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1Mzc2MTcsImV4cCI6MjA5MzExMzYxN30.sZM4GQiwom34d7TjeK_Jc_n8KYoC8VhI48jfq71dwb8';
const APP_TAG = 'merashare';

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

function tagAuthEmail(email) {
  const at = (email || '').indexOf('@');
  if (at === -1) return email;
  return email.slice(0, at) + '+' + APP_TAG + email.slice(at);
}

function untagAuthEmail(email) {
  if (!email) return email;
  return email.replace('+' + APP_TAG + '@', '@');
}

async function requireSession(redirectTo) {
  const { data } = await supabaseClient.auth.getSession();
  if (!data.session) {
    window.location.href = redirectTo || 'login.html';
    return null;
  }
  return data.session;
}

function showError(el, err) {
  if (!el) return;
  el.textContent = (err && err.message) ? err.message : String(err);
  el.style.display = 'block';
}

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  });
}
