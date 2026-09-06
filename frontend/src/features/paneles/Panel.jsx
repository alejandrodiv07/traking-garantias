/**
 * Panel provisional, uno por rol.
 *
 * Existe para cerrar el ciclo de hoy: entrar, ver quién eres y qué rol te
 * concedió la BASE DE DATOS (no el formulario), y salir. Las pantallas reales
 * de garantías van encima de esto.
 *
 * El bloque de diagnóstico no es decorativo: es la prueba visual de que el
 * rol viene de `profiles` bajo RLS. Si alguien se registrara mandando
 * `{"role":"ADMIN"}` en el metadata, aquí seguiría leyéndose TECNICO.
 */
import { useAuth } from "../auth/AuthContext.jsx";

const ETIQUETA = {
  ADMIN: "Administración",
  JEFE_SERVICIO: "Jefatura de servicio",
  TECNICO: "Taller",
  RECEPCION: "Recepción",
};

export default function Panel({ titulo }) {
  const { perfil, rol, salir, sesion } = useAuth();

  return (
    <div style={estilos.pagina}>
      <header style={estilos.cabecera}>
        <div>
          <p style={estilos.kicker}>Prime Telecom · Track Garantía</p>
          <h1 style={estilos.titulo}>{titulo ?? ETIQUETA[rol] ?? "Panel"}</h1>
        </div>
        <button type="button" onClick={salir} style={estilos.boton}>
          Cerrar sesión
        </button>
      </header>

      <section style={estilos.tarjeta}>
        <Dato etiqueta="Nombre" valor={perfil?.full_name} />
        <Dato etiqueta="Correo" valor={perfil?.email} />
        <Dato etiqueta="Rol (leído de profiles, no del formulario)" valor={rol} />
        <Dato
          etiqueta="Sesión expira"
          valor={
            sesion?.expires_at
              ? new Date(sesion.expires_at * 1000).toLocaleString("es-VE")
              : "—"
          }
        />
      </section>

      <p style={estilos.nota}>
        Módulo de garantías pendiente. Esta pantalla confirma que la
        autenticación y la resolución de rol funcionan de extremo a extremo.
      </p>
    </div>
  );
}

function Dato({ etiqueta, valor }) {
  return (
    <div style={estilos.fila}>
      <span style={estilos.etiqueta}>{etiqueta}</span>
      <span style={estilos.valor}>{valor ?? "—"}</span>
    </div>
  );
}

const estilos = {
  pagina: {
    minHeight: "100dvh",
    background: "#f7f5f0",
    padding: "40px 24px",
    font: "400 15px/1.6 'Plus Jakarta Sans', system-ui, -apple-system, sans-serif",
    color: "#0f172a",
  },
  cabecera: {
    maxWidth: 720,
    margin: "0 auto 24px",
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 16,
    flexWrap: "wrap",
  },
  kicker: {
    margin: 0,
    fontSize: 12.5,
    letterSpacing: "0.08em",
    textTransform: "uppercase",
    color: "#b45309",
    fontWeight: 600,
  },
  titulo: { margin: "4px 0 0", fontSize: 26, fontWeight: 700, letterSpacing: "-0.02em" },
  boton: {
    border: "1px solid #d6d3cc",
    background: "#fff",
    borderRadius: 10,
    padding: "9px 16px",
    font: "600 14px/1 inherit",
    cursor: "pointer",
    color: "#0f172a",
  },
  tarjeta: {
    maxWidth: 720,
    margin: "0 auto",
    background: "#fff",
    border: "1px solid #e7e4dd",
    borderRadius: 20,
    padding: 8,
  },
  fila: {
    display: "flex",
    justifyContent: "space-between",
    gap: 16,
    padding: "14px 16px",
    borderBottom: "1px solid #f1efe9",
  },
  etiqueta: { color: "#64748b", fontSize: 14 },
  valor: { fontWeight: 600, textAlign: "right", wordBreak: "break-word" },
  nota: {
    maxWidth: 720,
    margin: "20px auto 0",
    color: "#64748b",
    fontSize: 13.5,
  },
};
