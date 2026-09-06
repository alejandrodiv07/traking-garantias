import { useEffect, useId, useRef, useState } from "react";

/**
 * Login — Prime Telecom (RMA / Garantias)
 * Fase 1: Identity. Pantalla de acceso B2B cerrada, sin registro publico.
 *
 * Implementacion 1:1 del artboard `Login.dc.html` del canvas
 * "Prime Telecom — Garantias". Cada valor (tipografia, radios, alturas,
 * colores, duraciones) viene del artboard, no de una aproximacion.
 *
 * Paleta: alineada 1:1 con los tokens `--om-*` del sistema de diseño
 * (canvas "Prime Telecom — Garantias" / design system Omelette): fondo
 * cálido neutro, texto casi negro sobre base cálida, un único acento
 * terracota reservado para focos/enlaces, y un CTA sólido casi negro
 * para máximo contraste y una lectura seria (no "naranja de demo IA").
 *
 * Tipografia: IBM Plex Sans (Google Fonts). Reemplaza Plus Jakarta Sans
 * a pedido: IBM Plex es una familia de ingenieria con herencia
 * corporativa real, se lee "software serio" en vez de "plantilla IA".
 *
 * Estilos: CSS scopeado con prefijo `pt-` inyectado por el propio componente.
 * No depende de la config de Tailwind del proyecto, asi los valores
 * arbitrarios del diseno (46px, 12.5px, 20px radius) no se pierden
 * si el purge o el theme cambian. Tambien resetea explicitamente
 * `text-align`/`font` para no heredar el boilerplate global de
 * index.css (plantilla Vite) que no está pensado para esta pantalla.
 *
 * Props:
 *   onSubmit({ email, password, remember }) -> Promise
 *      Resuelve  -> login OK. Si resuelve { scope: false } se muestra el
 *                   estado "Sesion valida, sin alcance".
 *      Rechaza   -> se muestra "Credenciales incorrectas" (mensaje generico
 *                   a proposito: decir cual de los dos fallo confirmaria
 *                   que cuentas existen).
 *   onForgotPassword(), onContactAdmin()  -> handlers opcionales.
 */

const LOGO_ICON = "data:image/png;base64,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";

const MIN_PASSWORD = 10;

const CSS = `
.pt-login,.pt-login *{box-sizing:border-box}
.pt-login{
  /* --- paleta: tokens del sistema (canvas "Prime Telecom — Garantias"),
     un unico acento (terracota) reservado para foco/enlaces; el CTA
     principal usa el casi-negro para maxima seriedad y contraste. --- */
  --pt-bg-app:#faf9f5;
  --pt-bg-surface:#ffffff;
  --pt-border-subtle:rgba(15,12,8,.08);
  --pt-border-card:rgba(15,12,8,.12);
  --pt-border-strong:rgba(15,12,8,.22);
  --pt-border-focus:rgba(15,12,8,.36);
  --pt-text-primary:rgba(15,12,8,.92);
  --pt-text-secondary:rgba(15,12,8,.64);
  --pt-text-tertiary:rgba(15,12,8,.6);
  --pt-text-inverse:#faf9f5;
  --pt-accent:#d97757;
  --pt-accent-hover:#c46a4d;
  --pt-accent-active:#b05e43;
  --pt-accent-bg:rgba(217,119,87,.12);
  --pt-accent-tint:rgba(217,119,87,.04);
  --pt-cta:#191915;
  --pt-cta-hover:#2b2b26;
  --pt-cta-active:#0f0c08;
  --pt-error:#a63244;
  --pt-error-bg:rgba(166,50,68,.05);
  --pt-info:#2a78d6;
  --pt-info-bg:rgba(42,120,214,.1);
  --pt-shadow-sm:0 1px 3px rgba(20,20,19,.06);
  --pt-shadow-card:0 18px 44px rgba(20,20,19,.1),0 3px 10px rgba(20,20,19,.05);
  --pt-ease:cubic-bezier(.23,1,.32,1);

  min-height:100vh;min-height:100dvh;width:100%;
  display:flex;align-items:center;justify-content:center;
  padding:40px 16px;
  background:var(--pt-bg-app);
  font-family:'IBM Plex Sans',system-ui,-apple-system,'Segoe UI',sans-serif;
  color:var(--pt-text-primary);
  text-align:left;
  -webkit-font-smoothing:antialiased;
}
.pt-shell{width:100%;max-width:380px;display:flex;flex-direction:column;align-items:center}

/* ---- tarjeta ---- */
.pt-card{
  width:100%;background:var(--pt-bg-surface);
  border:1px solid var(--pt-border-card);border-radius:20px;
  box-shadow:var(--pt-shadow-card);
  padding:36px 32px 32px;
}
.pt-head{display:flex;flex-direction:column;align-items:center;margin-bottom:22px}
.pt-logo{width:52px;height:52px;border-radius:14px;margin-bottom:18px;display:block}
.pt-title{margin:0 0 6px;font-size:20px;font-weight:500;letter-spacing:-.2px;color:var(--pt-text-primary);text-align:center}
.pt-sub{margin:0;font-size:12.5px;color:var(--pt-text-tertiary);text-align:center;line-height:1.5;max-width:280px}

/* ---- cabecera de campo (garantiza el mismo nivel/alto para ambas
   etiquetas, tengan o no un enlace a la derecha) ---- */
.pt-fieldhead{display:flex;align-items:center;justify-content:space-between;gap:12px;min-height:20px;margin-bottom:6px}
.pt-label{display:block;font-size:13px;font-weight:600;color:#334155;margin:0;line-height:20px}

/* ---- campos ---- */
.pt-fldwrap{position:relative}
.pt-fldicon{
  position:absolute;left:14px;top:50%;transform:translateY(-50%);
  color:#a8a29a;pointer-events:none;transition:color .18s var(--pt-ease);
}
.pt-fldwrap:focus-within .pt-fldicon{color:var(--pt-accent)}
.pt-fld{
  font-family:inherit;font-size:14px;
  border:1px solid #e5e2da;border-radius:10px;height:46px;
  padding:0 14px 0 40px;width:100%;
  background:#fbfaf7;color:var(--pt-text-primary);
  transition:border-color .18s var(--pt-ease),background-color .18s var(--pt-ease),box-shadow .18s var(--pt-ease);
}
.pt-fld::placeholder{color:#a8a29a}
.pt-fld:hover{border-color:#d6d2c6}
.pt-fld:focus{outline:none;border-color:var(--pt-accent);background:#fff;box-shadow:0 0 0 3px var(--pt-accent-bg)}
.pt-fld:disabled{opacity:.6;cursor:not-allowed}
.pt-fld.pt-haspwtoggle{padding-right:64px}
.pt-fld[aria-invalid="true"]{border-color:#d99b96}
.pt-fld[aria-invalid="true"]:focus{border-color:var(--pt-error);box-shadow:0 0 0 3px var(--pt-error-bg)}

.pt-pwtoggle{
  position:absolute;right:14px;top:50%;transform:translateY(-50%);
  font-size:12px;font-weight:600;color:var(--pt-accent);
  background:none;border:none;cursor:pointer;font-family:inherit;
  padding:4px 2px;transition:color .18s var(--pt-ease);
}
.pt-pwtoggle:hover{color:var(--pt-accent-hover)}
.pt-pwtoggle:focus-visible{outline:none;box-shadow:0 0 0 2px var(--pt-accent-bg);border-radius:4px}

.pt-helper{font-size:11.5px;color:#94a3b8;margin-top:6px;line-height:1.4}
.pt-helper.pt-helper-err{color:var(--pt-error)}

.pt-link{
  color:var(--pt-accent);text-decoration:none;background:none;border:none;padding:0;
  font-family:inherit;cursor:pointer;transition:color .18s var(--pt-ease);
  font-size:12px;font-weight:600;line-height:20px;
}
.pt-link:hover{color:var(--pt-accent-hover)}
.pt-link:focus-visible{outline:none;box-shadow:0 0 0 2px var(--pt-accent-bg);border-radius:4px}

.pt-remember{display:flex;align-items:center;gap:8px;margin:16px 0 20px}
.pt-remember input[type="checkbox"]{width:16px;height:16px;margin:0;accent-color:var(--pt-accent);cursor:pointer;flex:none}
.pt-remember label{font-size:13px;color:var(--pt-text-secondary);cursor:pointer}

.pt-btn{
  width:100%;height:46px;border:none;border-radius:10px;
  background:var(--pt-cta);color:var(--pt-text-inverse);
  font-family:inherit;font-size:14px;font-weight:600;cursor:pointer;
  display:flex;align-items:center;justify-content:center;gap:8px;
  transition:background-color .18s var(--pt-ease),transform .16s var(--pt-ease);
}
.pt-btn:hover:not(:disabled){background:var(--pt-cta-hover)}
.pt-btn:active:not(:disabled){background:var(--pt-cta-active);transform:scale(.97)}
.pt-btn:focus-visible{outline:none;box-shadow:0 0 0 3px var(--pt-accent-bg)}
.pt-btn:disabled{cursor:progress;opacity:.7}

.pt-spinner{
  width:14px;height:14px;flex:none;border-radius:50%;
  border:2px solid rgba(250,249,245,.35);border-top-color:var(--pt-text-inverse);
  animation:pt-spin .6s linear infinite;
}
@keyframes pt-spin{to{transform:rotate(360deg)}}

/* ---- caja de soporte ---- */
.pt-support{
  width:100%;margin-top:14px;background:#fdfcfa;
  border:1px solid var(--pt-border-subtle);border-radius:14px;
  padding:14px 18px;text-align:center;
}
.pt-support>span{font-size:12.5px;color:var(--pt-text-secondary);line-height:1.55}

/* ---- estados ---- */
.pt-states{width:100%;margin-top:14px;display:flex;gap:10px}
.pt-statebox{border-radius:12px;padding:14px 16px;text-align:left;flex:1;min-width:0}
.pt-statebox .pt-stitle{display:flex;align-items:center;gap:6px;font-size:12.5px;font-weight:700;margin-bottom:4px}
.pt-statebox .pt-stitle svg{flex:none}
.pt-statebox .pt-sbody{font-size:12px;line-height:1.5}
.pt-statebox.pt-err{background:var(--pt-error-bg);border:1px solid rgba(166,50,68,.14)}
.pt-statebox.pt-err .pt-stitle,.pt-statebox.pt-err svg{color:var(--pt-error)}
.pt-statebox.pt-err .pt-sbody{color:var(--pt-error);opacity:.85}
.pt-statebox.pt-info{background:var(--pt-info-bg);border:1px solid rgba(42,120,214,.14)}
.pt-statebox.pt-info .pt-stitle,.pt-statebox.pt-info svg{color:var(--pt-info)}
.pt-statebox.pt-info .pt-sbody{color:var(--pt-info);opacity:.85}
.pt-statebox:focus{outline:none}

.pt-sr{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}

@media (max-width:420px){
  .pt-card{padding:28px 22px 26px}
  .pt-states{flex-direction:column}
  /* iOS Safari hace zoom al enfocar un input de menos de 16px. El artboard es
     un lienzo de 1440 y no cubre movil; esta regla solo aplica bajo 420px y
     no toca el render de escritorio. Borrala si prefieres 14px en todas las
     resoluciones. */
  .pt-fld{font-size:16px}
}

@media (prefers-reduced-motion:reduce){
  .pt-login *,.pt-login *::before,.pt-login *::after{
    transition-duration:.01ms !important;animation-duration:.01ms !important;animation-iteration-count:1 !important;
  }
  .pt-btn:active:not(:disabled){transform:none}
}
`;

const FONT_HREF =
  "https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&display=swap";

/** Inyecta la fuente y el CSS una sola vez, sea cual sea el bundler. */
function useLoginStyles() {
  useEffect(() => {
    if (typeof document === "undefined") return;
    if (!document.getElementById("pt-login-font")) {
      const link = document.createElement("link");
      link.id = "pt-login-font";
      link.rel = "stylesheet";
      link.href = FONT_HREF;
      document.head.appendChild(link);
    }
    if (!document.getElementById("pt-login-css")) {
      const style = document.createElement("style");
      style.id = "pt-login-css";
      style.textContent = CSS;
      document.head.appendChild(style);
    }
  }, []);
}

const IconUser = () => (
  <svg className="pt-fldicon" width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
    <circle cx="8" cy="5.2" r="2.7" stroke="currentColor" strokeWidth="1.3" />
    <path d="M2.6 13.4c.7-2.6 2.9-4 5.4-4s4.7 1.4 5.4 4" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
  </svg>
);

const IconLock = () => (
  <svg className="pt-fldicon" width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
    <rect x="3.4" y="7.2" width="9.2" height="6.4" rx="1.4" stroke="currentColor" strokeWidth="1.3" />
    <path d="M5.4 7.2V5.4a2.6 2.6 0 0 1 5.2 0v1.8" stroke="currentColor" strokeWidth="1.3" />
  </svg>
);

const IconAlert = () => (
  <svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true">
    <circle cx="8" cy="8" r="6.4" stroke="currentColor" strokeWidth="1.3" />
    <path d="M8 5.2v3.4M8 10.8h.01" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
  </svg>
);

export default function Login({ onSubmit, onForgotPassword, onContactAdmin }) {
  useLoginStyles();

  const uid = useId();
  const userId = `login-user-${uid}`;
  const passId = `login-pass-${uid}`;
  const helpId = `login-help-${uid}`;

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [remember, setRemember] = useState(false);
  const [pending, setPending] = useState(false);
  // null | 'credentials' | 'scope' | 'form'
  const [status, setStatus] = useState(null);

  const userRef = useRef(null);
  const stateRef = useRef(null);

  // El foco entra en el primer campo; el lector de pantalla anuncia el estado.
  useEffect(() => {
    if (status && stateRef.current) stateRef.current.focus();
  }, [status]);

  const invalidUser = status === "form" && email.trim() === "";
  const invalidPass = status === "form" && password.length < MIN_PASSWORD;

  async function handleSubmit(e) {
    e.preventDefault();
    if (pending) return;

    if (email.trim() === "" || password.length < MIN_PASSWORD) {
      setStatus("form");
      (email.trim() === "" ? userRef.current : null)?.focus();
      return;
    }

    setStatus(null);
    setPending(true);
    try {
      const result = await onSubmit?.({ email: email.trim(), password, remember });
      if (result && result.scope === false) setStatus("scope");
    } catch {
      // Mensaje generico a proposito: no revelamos cual de los dos fallo.
      setStatus("credentials");
      setPassword("");
    } finally {
      setPending(false);
    }
  }

  return (
    <div className="pt-login">
      <div className="pt-shell">
        <div className="pt-card">
          <div className="pt-head">
            <img className="pt-logo" src={LOGO_ICON} alt="Prime Telecom" width="52" height="52" />
            <h1 className="pt-title">Acceso al sistema en Prime Telecom</h1>
            <p className="pt-sub">
              Sistema integral de Registro y Gestión de garantías.
              Ingresa tus credenciales para acceder al sistema.
            </p>
          </div>

          <form autoComplete="on" onSubmit={handleSubmit} noValidate>
            <div className="pt-fieldhead">
              <label htmlFor={userId} className="pt-label">
                Correo corporativo
              </label>
            </div>
            <div className="pt-fldwrap" style={{ marginBottom: 16 }}>
              <IconUser />
              <input
                id={userId}
                ref={userRef}
                name="email"
                type="email"
                className="pt-fld"
                autoComplete="email"
                autoFocus
                disabled={pending}
                aria-invalid={invalidUser || undefined}
                placeholder="j.rivera@primetelecom.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
            </div>

            <div className="pt-fieldhead">
              <label htmlFor={passId} className="pt-label">
                Contraseña
              </label>
              <button
                type="button"
                className="pt-link"
                onClick={onForgotPassword}
              >
                ¿Olvidaste tu contraseña?
              </button>
            </div>

            <div className="pt-fldwrap" style={{ marginBottom: 8 }}>
              <IconLock />
              <input
                id={passId}
                name="password"
                type={showPassword ? "text" : "password"}
                className="pt-fld pt-haspwtoggle"
                autoComplete="current-password"
                disabled={pending}
                aria-invalid={invalidPass || undefined}
                aria-describedby={helpId}
                placeholder="••••••••••"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
              />
              <button
                type="button"
                className="pt-pwtoggle"
                aria-label={showPassword ? "Ocultar contraseña" : "Mostrar contraseña"}
                aria-pressed={showPassword}
                aria-controls={passId}
                onClick={() => setShowPassword((v) => !v)}
              >
                {showPassword ? "Ocultar" : "Mostrar"}
              </button>
            </div>
            <div className="pt-remember">
              <input
                type="checkbox"
                id={`remember-${uid}`}
                checked={remember}
                disabled={pending}
                onChange={(e) => setRemember(e.target.checked)}
              />
              <label htmlFor={`remember-${uid}`}>Mantener la sesión 12 h en este equipo</label>
            </div>

            <button type="submit" className="pt-btn" disabled={pending} aria-busy={pending}>
              {pending && <span className="pt-spinner" aria-hidden="true" />}
              {pending ? "Verificando…" : "Ingresar"}
            </button>
          </form>
        </div>

        <div className="pt-support">
          <span>
            Solo acceso autorizado. ¿Problemas para ingresar?{" "}
            <button type="button" className="pt-link" onClick={onContactAdmin}>
              Contacta al administrador
            </button>
            .
          </span>
        </div>

        {/* Estados: mismo diseno del artboard, renderizados solo cuando ocurren. */}
        {status && (
          <div className="pt-states">
            {(status === "credentials" || status === "form") && (
              <div
                className="pt-statebox pt-err"
                role="alert"
                tabIndex={-1}
                ref={stateRef}
              >
                <div className="pt-stitle">
                  <IconAlert />
                  {status === "form" ? "Faltan datos" : "Credenciales incorrectas"}
                </div>
                <div className="pt-sbody">
                  {status === "form"
                    ? `Escribe tu correo corporativo y una contraseña de al menos ${MIN_PASSWORD} caracteres.`
                    : "No indicamos cuál de los dos falló."}
                </div>
              </div>
            )}

            {status === "scope" && (
              <div className="pt-statebox pt-info" role="status" tabIndex={-1} ref={stateRef}>
                <div className="pt-stitle">
                  <IconAlert />
                  Sesión válida, sin alcance
                </div>
                <div className="pt-sbody">
                  Autenticado, pero sin garantías visibles: falta tu asignación en user_scope.
                </div>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
