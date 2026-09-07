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
import "./Panel.css";

const ETIQUETA = {
  ADMIN: "Administración",
  JEFE_SERVICIO: "Jefatura de servicio",
  TECNICO: "Taller",
  RECEPCION: "Recepción",
};

export default function Panel({ titulo }) {
  const { perfil, rol, salir, sesion } = useAuth();

  return (
    <div className="pn-pagina">
      <header className="pn-cabecera">
        <div>
          <p className="pn-kicker">Prime Telecom · Track Garantía</p>
          <h1 className="pn-titulo">{titulo ?? ETIQUETA[rol] ?? "Panel"}</h1>
        </div>
        <button type="button" onClick={salir} className="pn-boton">
          Cerrar sesión
        </button>
      </header>

      <section className="pn-tarjeta">
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

      <p className="pn-nota">
        Módulo de garantías pendiente. Esta pantalla confirma que la
        autenticación y la resolución de rol funcionan de extremo a extremo.
      </p>
    </div>
  );
}

function Dato({ etiqueta, valor }) {
  return (
    <div className="pn-fila">
      <span className="pn-etiqueta">{etiqueta}</span>
      <span className="pn-valor">{valor ?? "—"}</span>
    </div>
  );
}
