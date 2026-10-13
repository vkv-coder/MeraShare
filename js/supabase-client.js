// Shared Supabase client + auth-email tagging for MeraShare.
// rotry_event project is shared with other apps (trust-analysis, tiecon-match) —
// tag every auth email with +merashare so auth.users rows never collide across apps.

const SUPABASE_URL = 'https://wrzpgultvahxbrgooibn.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndyenBndWx0dmFoeGJyZ29vaWJuIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc1Mzc2MTcsImV4cCI6MjA5MzExMzYxN30.sZM4GQiwom34d7TjeK_Jc_n8KYoC8VhI48jfq71dwb8';
const APP_TAG = 'merashare';

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Each group settles in its own base_currency (e.g. an overseas group visiting
// India still settles in EUR/USD, converting their INR spends back to it) --
// never assume ₹ globally. CURRENCY_OPTIONS doubles as the add-expense/
// create-group dropdown list.
const CURRENCY_SYMBOLS = { INR: '₹', EUR: '€', USD: '$', GBP: '£', AED: 'AED ', SGD: 'S$', THB: '฿', NPR: 'Rs ' };
const CURRENCY_OPTIONS = [
  { code: 'INR', label: '₹ INR — Indian Rupee' },
  { code: 'EUR', label: '€ EUR — Euro' },
  { code: 'USD', label: '$ USD — US Dollar' },
  { code: 'GBP', label: '£ GBP — British Pound' },
  { code: 'AED', label: 'AED — UAE Dirham' },
  { code: 'SGD', label: 'SGD — Singapore Dollar' },
  { code: 'THB', label: 'THB — Thai Baht' },
  { code: 'NPR', label: 'NPR — Nepalese Rupee' }
];

function currencySymbol(code) {
  return CURRENCY_SYMBOLS[code] || ((code || 'INR') + ' ');
}

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
  await enforceBiometricLock();
  return data.session;
}

// --- Biometric app-lock -----------------------------------------------
// Local convenience gate only: the real identity check is still the
// Supabase session above. This just re-asks for a fingerprint/Face ID
// (via WebAuthn's platform authenticator) once per fresh app open,
// instead of re-typing a password. Opt-in, toggled from account.html.

const BIOMETRIC_ENABLED_KEY = 'ms_biometric_enabled';
const BIOMETRIC_CREDENTIAL_KEY = 'ms_biometric_credential_id';
const BIOMETRIC_UNLOCKED_KEY = 'ms_biometric_unlocked';

function bufToBase64(buf) {
  return btoa(String.fromCharCode(...new Uint8Array(buf)));
}

function base64ToBuf(b64) {
  const bin = atob(b64);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

async function biometricAvailable() {
  return !!(window.PublicKeyCredential &&
    PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable &&
    await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable());
}

function biometricIsEnabled() {
  return localStorage.getItem(BIOMETRIC_ENABLED_KEY) === 'true' && !!localStorage.getItem(BIOMETRIC_CREDENTIAL_KEY);
}

async function biometricRegister(userEmail, userName) {
  const challenge = crypto.getRandomValues(new Uint8Array(32));
  const userId = crypto.getRandomValues(new Uint8Array(16));
  const cred = await navigator.credentials.create({
    publicKey: {
      challenge,
      rp: { name: 'MeraShare' },
      user: { id: userId, name: userEmail, displayName: userName || userEmail },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
      authenticatorSelection: { authenticatorAttachment: 'platform', userVerification: 'required' },
      timeout: 60000
    }
  });
  if (!cred) throw new Error('Could not register biometric credential');
  localStorage.setItem(BIOMETRIC_CREDENTIAL_KEY, bufToBase64(cred.rawId));
  localStorage.setItem(BIOMETRIC_ENABLED_KEY, 'true');
  sessionStorage.setItem(BIOMETRIC_UNLOCKED_KEY, 'true');
}

function biometricDisable() {
  localStorage.removeItem(BIOMETRIC_CREDENTIAL_KEY);
  localStorage.setItem(BIOMETRIC_ENABLED_KEY, 'false');
  sessionStorage.removeItem(BIOMETRIC_UNLOCKED_KEY);
}

async function biometricVerify() {
  const credId = localStorage.getItem(BIOMETRIC_CREDENTIAL_KEY);
  if (!credId) throw new Error('No biometric credential registered on this device');
  const challenge = crypto.getRandomValues(new Uint8Array(32));
  await navigator.credentials.get({
    publicKey: {
      challenge,
      allowCredentials: [{ type: 'public-key', id: base64ToBuf(credId) }],
      userVerification: 'required',
      timeout: 60000
    }
  });
  sessionStorage.setItem(BIOMETRIC_UNLOCKED_KEY, 'true');
}

function enforceBiometricLock() {
  if (!biometricIsEnabled()) return Promise.resolve();
  if (sessionStorage.getItem(BIOMETRIC_UNLOCKED_KEY) === 'true') return Promise.resolve();

  return new Promise((resolve) => {
    const overlay = document.createElement('div');
    overlay.id = 'biometricLockOverlay';
    overlay.style.cssText = 'position:fixed;inset:0;background:#0f766e;color:#fff;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:16px;z-index:9999;padding:24px;text-align:center;';
    overlay.innerHTML =
      '<div style="font-size:3rem;">🔒</div>' +
      '<div style="font-size:1.1rem;font-weight:600;">MeraShare is locked</div>' +
      '<button id="biometricUnlockBtn" style="background:#fff;color:#0f766e;border:none;padding:12px 24px;border-radius:8px;font-size:1rem;font-weight:600;cursor:pointer;">Unlock with biometrics</button>' +
      '<div id="biometricError" style="color:#fecaca;font-size:0.85rem;display:none;"></div>' +
      '<a href="#" id="biometricLogoutLink" style="color:#d1fae5;font-size:0.85rem;text-decoration:underline;margin-top:12px;">Log out instead</a>';
    document.body.appendChild(overlay);

    document.getElementById('biometricUnlockBtn').addEventListener('click', async () => {
      const errEl = document.getElementById('biometricError');
      errEl.style.display = 'none';
      try {
        await biometricVerify();
        overlay.remove();
        resolve();
      } catch (e) {
        errEl.textContent = 'Could not verify. Try again.';
        errEl.style.display = 'block';
      }
    });

    document.getElementById('biometricLogoutLink').addEventListener('click', async (e) => {
      e.preventDefault();
      biometricDisable();
      await supabaseClient.auth.signOut();
      window.location.href = 'index.html';
    });
  });
}

function wireLogoutLink(elId) {
  const el = document.getElementById(elId || 'logoutLink');
  if (!el) return;
  el.addEventListener('click', async (e) => {
    e.preventDefault();
    await supabaseClient.auth.signOut();
    window.location.href = 'index.html';
  });
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

const DEMO_ACCOUNT_EMAIL = 'demo+merashare@merashare.in';

async function markDemoBadge() {
  const { data } = await supabaseClient.auth.getUser();
  if (!data || !data.user || data.user.email !== DEMO_ACCOUNT_EMAIL) return;
  const brand = document.querySelector('.topbar .brand');
  if (brand && !brand.querySelector('.demo-badge')) {
    const badge = document.createElement('strong');
    badge.className = 'demo-badge';
    badge.textContent = 'DEMO';
    brand.appendChild(badge);
  }
}

document.addEventListener('DOMContentLoaded', markDemoBadge);
