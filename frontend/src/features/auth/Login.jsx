import { useCallback, useEffect, useId, useRef, useState } from "react";
import "./login.css";

/**
 * Login — Prime Telecom (RMA / Garantias)
 * Fase 1: Identity. Pantalla de acceso B2B cerrada, sin registro publico.
 * Fase 1b: segundo factor por correo (OTP de 6 digitos).
 *
 * Implementacion 1:1 del artboard `Login.dc.html` del canvas
 * "Prime Telecom — Garantias". Cada valor (tipografia, radios, alturas,
 * colores, duraciones) viene del artboard, no de una aproximacion.
 *
 * EL PASO 2 VIVE EN ESTE MISMO COMPONENTE, Y NO EN UNO NUEVO, POR UNA RAZON
 * DE DISENO: es la MISMA tarjeta. Cambia su contenido, no su marco. El logo,
 * el ancho (380px), el radio (20px), la sombra y la caja de soporte no se
 * mueven ni un pixel entre los dos pasos, asi que el usuario percibe una
 * continuacion y no un salto a otra pantalla. Un componente aparte tendria
 * que duplicar ese marco -y con el, la deriva visual del primer retoque.
 *
 * Paleta: alineada 1:1 con los tokens `--om-*` del sistema de diseño
 * (canvas "Prime Telecom — Garantias" / design system Omelette): fondo
 * cálido neutro, texto casi negro sobre base cálida, un único acento
 * terracota reservado para focos/enlaces, y un CTA sólido casi negro
 * para máximo contraste y una lectura seria (no "naranja de demo IA").
 *
 * Tipografia: Inter, empaquetada localmente via @fontsource (sin CDN: la
 * CSP prohibe origenes externos). El campo del codigo usa `font-variant-
 * numeric: tabular-nums`: con cifras de ancho variable, los seis huecos
 * bailan al teclear.
 *
 * Estilos: CSS scopeado con prefijo `pt-` en `login.css`, empaquetado por
 * Vite. Cero `style={{}}`: los valores del paso 2 son tokens del mismo
 * sistema que el paso 1, y viven donde viven los demas.
 *
 * ---------------------------------------------------------------------------
 * Contrato (el contenedor es `LoginPage.jsx`)
 * ---------------------------------------------------------------------------
 *   onSubmit({ email, password, remember }) -> Promise
 *      resuelve { mfa: true, expiraEn }  -> contraseña OK, pasa al paso 2
 *      resuelve { scope: false }         -> "Sesion valida, sin alcance"
 *      resuelve cualquier otra cosa      -> acceso concedido (sin 2FA)
 *      rechaza                           -> "Credenciales incorrectas"
 *
 *   onVerify(codigo) -> Promise
 *      resuelve { scope: false }         -> mismo estado de alcance
 *      resuelve                          -> acceso concedido
 *      rechaza(Error)                    -> "Codigo incorrecto o vencido"
 *
 *   onResend() -> Promise<{ expiraEn }>   -> emite otro codigo
 *   onCancel() -> vuelve al paso 1 (el contenedor cierra la sesion a medias)
 *   onForgotPassword(), onContactAdmin()  -> handlers opcionales
 *
 * Nota de seguridad, para que no se pierda: este componente NO decide nada.
 * Cuando `signInWithPassword` responde, el JWT ya existe y ya es valido;
 * ocultar campos en React no protege ni un byte. Lo que hace real al segundo
 * factor es que `mi_rol()` en Postgres exige `mfa_ok()` (migracion
 * ...0003_mfa_email, §6): sin codigo verificado, ninguna consulta devuelve
 * una sola garantia, se salte esta pantalla quien se la salte.
 */

const LOGO_ICON = "data:image/png;base64,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";

// 12 por CSO-07 (ver docs/deuda-seguridad.md). Debe coincidir con
// `minimum_password_length` de supabase/config.toml: si el login exigiera
// más que la política de alta, una contraseña válida sería irrechazable
// aquí y el usuario quedaría fuera sin explicación.
const MIN_PASSWORD = 9;
const LARGO_CODIGO = 6;
/** Segundos de espera antes de poder reenviar. Anti-mailbomb del lado UI;
 *  el techo de verdad (5 por 15 min) lo aplica `generate_mfa_code()`. */
const ESPERA_REENVIO = 45;


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

/** Sello del paso 2: un sobre. Mismo trazo de 1.3 que el resto de iconos. */
const IconMail = () => (
  <svg className="pt-seal" width="22" height="22" viewBox="0 0 24 24" fill="none" aria-hidden="true">
    <rect x="2.8" y="5.4" width="18.4" height="13.2" rx="2.2" stroke="currentColor" strokeWidth="1.4" />
    <path d="M3.6 7.2 12 13l8.4-5.8" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
  </svg>
);

/** j.rivera@primetelecom.com -> j.r•••@primetelecom.com
 *  El usuario acaba de escribir su correo, asi que enmascararlo no oculta
 *  nada que no sepa; sirve para que reconozca la cuenta de un vistazo sin
 *  dejar la direccion completa en una captura de pantalla. */
function enmascarar(correo) {
  const [local = "", dominio = ""] = String(correo).split("@");
  if (!dominio) return correo;
  const visible = local.slice(0, Math.min(3, local.length));
  return `${visible}${"•".repeat(3)}@${dominio}`;
}

function mmss(segundos) {
  const s = Math.max(0, segundos);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

export default function Login({
  onSubmit,
  onVerify,
  onResend,
  onCancel,
  onForgotPassword,
  onContactAdmin,
}) {

  const uid = useId();
  const userId = `login-user-${uid}`;
  const passId = `login-pass-${uid}`;
  const helpId = `login-help-${uid}`;
  const codeId = `login-code-${uid}`;
  const codeHelpId = `login-codehelp-${uid}`;

  // 1 = credenciales, 2 = codigo de verificacion.
  const [step, setStep] = useState(1);

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [remember, setRemember] = useState(false);
  const [pending, setPending] = useState(false);
  // null | 'credentials' | 'scope' | 'form' | 'code' | 'cuota'
  const [status, setStatus] = useState(null);

  const [code, setCode] = useState("");
  // Segundos que le quedan de vida al codigo, y de espera al reenvio.
  const [restante, setRestante] = useState(0);
  const [espera, setEspera] = useState(0);

  const userRef = useRef(null);
  const codeRef = useRef(null);
  const stateRef = useRef(null);
  // Evita que el auto-envio al sexto digito dispare dos veces el mismo codigo
  // (teclear el sexto, y volver a teclearlo tras un fallo).
  const enviado = useRef("");

  // El foco entra en el primer campo; el lector de pantalla anuncia el estado.
  useEffect(() => {
    if (status && stateRef.current) stateRef.current.focus();
  }, [status]);

  // Al entrar al paso 2 el foco va al campo del codigo. Sin esto el usuario
  // llega de un submit y el foco se queda en un boton que ya no existe.
  useEffect(() => {
    if (step === 2) codeRef.current?.focus();
  }, [step]);

  // Un solo intervalo para los dos contadores: el del codigo y el del
  // reenvio. Dos `setInterval` para dos numeros que bajan a la vez es un
  // temporizador de mas que limpiar.
  useEffect(() => {
    if (step !== 2) return undefined;
    const t = setInterval(() => {
      setRestante((v) => (v > 0 ? v - 1 : 0));
      setEspera((v) => (v > 0 ? v - 1 : 0));
    }, 1000);
    return () => clearInterval(t);
  }, [step]);

  const invalidUser = status === "form" && email.trim() === "";
  const invalidPass = status === "form" && password.length < MIN_PASSWORD;
  const caducado = step === 2 && restante === 0;

  /** Arranca el paso 2 con la caducidad que devuelve la base de datos. */
  const abrirPaso2 = useCallback((expiraEn) => {
    const ms = expiraEn ? new Date(expiraEn).getTime() - Date.now() : 5 * 60_000;
    setRestante(Math.max(0, Math.round(ms / 1000)));
    setEspera(ESPERA_REENVIO);
    setCode("");
    enviado.current = "";
    setStep(2);
  }, []);

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
      else if (result && result.mfa) abrirPaso2(result.expiraEn);
    } catch {
      // Mensaje generico a proposito: no revelamos cual de los dos fallo.
      setStatus("credentials");
      setPassword("");
    } finally {
      setPending(false);
    }
  }

  const verificar = useCallback(
    async (valor) => {
      if (pending || valor.length !== LARGO_CODIGO) return;
      enviado.current = valor;
      setStatus(null);
      setPending(true);
      try {
        const result = await onVerify?.(valor);
        if (result && result.scope === false) setStatus("scope");
      } catch {
        // Igual que en el paso 1: un solo mensaje. Distinguir "codigo
        // erroneo" de "codigo vencido" le dice al atacante si sigue dentro
        // de la ventana de 5 minutos, y no le sirve de nada al usuario.
        setStatus("code");
        setCode("");
        codeRef.current?.focus();
      } finally {
        setPending(false);
      }
    },
    [onVerify, pending]
  );

  function handleCodeChange(e) {
    // Solo digitos: pegar "123 456" o "codigo: 123456" deja 123456.
    const valor = e.target.value.replace(/\D/g, "").slice(0, LARGO_CODIGO);
    setCode(valor);
    // Auto-envio al sexto digito, como GitHub. Ahorra un clic en el 100% de
    // los casos y no quita el boton: sin JS o con lector de pantalla, el
    // usuario sigue pulsando "Verificar".
    if (valor.length === LARGO_CODIGO && valor !== enviado.current && !caducado) {
      verificar(valor);
    }
  }

  async function handleResend() {
    if (pending || espera > 0) return;
    setStatus(null);
    setPending(true);
    try {
      const r = await onResend?.();
      setRestante(
        r?.expiraEn ? Math.max(0, Math.round((new Date(r.expiraEn).getTime() - Date.now()) / 1000)) : 300
      );
      setEspera(ESPERA_REENVIO);
      setCode("");
      enviado.current = "";
      codeRef.current?.focus();
    } catch (err) {
      // La RPC lanza 54000 al sexto codigo en 15 minutos.
      setStatus(err?.code === "54000" || err?.cuota ? "cuota" : "code");
    } finally {
      setPending(false);
    }
  }

  function volver() {
    setStep(1);
    setCode("");
    setPassword("");
    setStatus(null);
    onCancel?.();
  }

  return (
    <div className="pt-login">
      <div className="pt-shell">
        <div className="pt-card">
          {step === 1 ? (
            <div className="pt-head">
              <img className="pt-logo" src={LOGO_ICON} alt="Prime Telecom" width="52" height="52" />
              <h1 className="pt-title">Acceso al sistema en Prime Telecom</h1>
              <p className="pt-sub">
                Sistema integral de Registro y Gestión de garantías.
                Ingresa tus credenciales para acceder al sistema.
              </p>
            </div>
          ) : (
            <div className="pt-head">
              <img className="pt-logo" src={LOGO_ICON} alt="Prime Telecom" width="52" height="52" />
              <div className="pt-sealwrap" aria-hidden="true">
                <IconMail />
              </div>
              <h1 className="pt-title">Verificación en dos pasos</h1>
              <p className="pt-sub">
                Escribe el código de {LARGO_CODIGO} dígitos que enviamos a{" "}
                <span className="pt-mailmark">{enmascarar(email)}</span>
              </p>
            </div>
          )}

          {step === 1 && (
          <form autoComplete="on" onSubmit={handleSubmit} noValidate>
            <div className="pt-fieldhead">
              <label htmlFor={userId} className="pt-label">
                Correo corporativo
              </label>
            </div>
            <div className="pt-fldwrap pt-fldwrap--gap-lg">
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

            <div className="pt-fldwrap pt-fldwrap--gap-sm">
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
            {/* HALLAZGO CORREGIDO: el input apuntaba con aria-describedby a
                este id, pero el elemento nunca se renderizaba. Un lector de
                pantalla resolvía la referencia contra la nada: la ayuda no
                se anunciaba nunca. Ahora existe, y dobla como mensaje de
                error inline cuando la contraseña no llega al minimo. */}
            <p
              id={helpId}
              className={`pt-helper${invalidPass ? " pt-helper-err" : ""}`}
            >
              {invalidPass
                ? `Escribe al menos ${MIN_PASSWORD} caracteres.`
                : `Mínimo ${MIN_PASSWORD} caracteres.`}
            </p>
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
          )}

          {step === 2 && (
          <form
            className="pt-step2"
            autoComplete="on"
            noValidate
            onSubmit={(e) => {
              e.preventDefault();
              verificar(code);
            }}
          >
            <label htmlFor={codeId} className="pt-label pt-label--center">
              Código de verificación
            </label>

            <input
              id={codeId}
              ref={codeRef}
              name="one-time-code"
              className="pt-otp"
              type="text"
              /* UN campo y no seis cajitas: `one-time-code` deja que iOS,
                 Android y los gestores de contraseñas rellenen el codigo de
                 un toque, y pegar desde el correo funciona sin trucos. Seis
                 inputs obligan a repartir el pegado a mano, rompen el
                 autorrelleno y multiplican por seis las paradas del tabulador
                 para quien navega con teclado. El aspecto segmentado se
                 consigue con `letter-spacing`, que no cuesta accesibilidad. */
              autoComplete="one-time-code"
              inputMode="numeric"
              pattern="[0-9]*"
              maxLength={LARGO_CODIGO}
              disabled={pending}
              aria-invalid={status === "code" || undefined}
              aria-describedby={codeHelpId}
              placeholder="••••••"
              value={code}
              onChange={handleCodeChange}
            />

            <p
              id={codeHelpId}
              className={`pt-helper pt-helper--center${caducado ? " pt-helper-err" : ""}`}
              role="status"
            >
              {caducado
                ? "El código caducó. Pide uno nuevo."
                : `Caduca en ${mmss(restante)}.`}
            </p>

            <button
              type="submit"
              className="pt-btn"
              disabled={pending || code.length !== LARGO_CODIGO || caducado}
              aria-busy={pending}
            >
              {pending && <span className="pt-spinner" aria-hidden="true" />}
              {pending ? "Verificando…" : "Verificar"}
            </button>

            <div className="pt-resend">
              <button
                type="button"
                className="pt-link"
                onClick={handleResend}
                disabled={pending || espera > 0}
              >
                {espera > 0 ? `Reenviar código en ${espera} s` : "Reenviar código"}
              </button>
              <span className="pt-sep" aria-hidden="true">·</span>
              <button type="button" className="pt-link" onClick={volver}>
                Usar otra cuenta
              </button>
            </div>
          </form>
          )}
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
            {(status === "credentials" || status === "form" || status === "code") && (
              <div
                className="pt-statebox pt-err"
                role="alert"
                tabIndex={-1}
                ref={stateRef}
              >
                <div className="pt-stitle">
                  <IconAlert />
                  {status === "form"
                    ? "Faltan datos"
                    : status === "code"
                      ? "Código incorrecto o vencido"
                      : "Credenciales incorrectas"}
                </div>
                <div className="pt-sbody">
                  {status === "form"
                    ? `Escribe tu correo corporativo y una contraseña de al menos ${MIN_PASSWORD} caracteres.`
                    : status === "code"
                      ? "Revisa el último correo o pide un código nuevo."
                      : "No indicamos cuál de los dos falló."}
                </div>
              </div>
            )}

            {status === "cuota" && (
              <div className="pt-statebox pt-info" role="status" tabIndex={-1} ref={stateRef}>
                <div className="pt-stitle">
                  <IconAlert />
                  Demasiados códigos
                </div>
                <div className="pt-sbody">
                  Espera unos minutos antes de pedir otro. Si no llega ninguno,
                  contacta al administrador.
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
