/**
 * Barra de navegación del módulo.
 *
 * En escritorio es una columna de 64 px a la izquierda; por debajo de 900 px
 * la misma lista se convierte en barra inferior (ver `Tablero.css`, §6). Es el
 * mismo DOM en los dos casos: cambiar el marcado por tamaño de pantalla obliga
 * a mantener dos árboles y a que el foco salte de sitio al rotar el móvil.
 *
 * Los iconos NO llevan texto visible, así que cada botón lleva `aria-label`
 * con el destino. El "tooltip" es puramente decorativo: lo que lee el lector
 * de pantalla es la etiqueta, no ese `<span>`.
 *
 * Ninguno navega todavía. Cuando existan las rutas, `onIr` se sustituye por
 * `<NavLink>` y desaparece el estado local.
 */
import {
  Bell,
  LayoutDashboard,
  Settings,
  ShieldCheck,
  Users,
  Wrench,
} from "lucide-react";

const DESTINOS = [
  { clave: "tablero", etiqueta: "Tablero", Icono: LayoutDashboard },
  { clave: "garantias", etiqueta: "Ventas y garantías", Icono: ShieldCheck },
  { clave: "taller", etiqueta: "Taller", Icono: Wrench },
  { clave: "clientes", etiqueta: "Clientes", Icono: Users },
  { clave: "notificaciones", etiqueta: "Notificaciones", Icono: Bell },
];

export default function BarraLateral({ actual = "tablero", usuario, onIr }) {
  return (
    <nav className="tg-rail" aria-label="Navegación principal">
      <span className="tg-marca" aria-hidden="true">
        P
      </span>

      <ul className="tg-rail-nav">
        {DESTINOS.map(({ clave, etiqueta, Icono }) => {
          const activo = clave === actual;
          return (
            <li className="tg-ic" key={clave}>
              {activo ? <span className="tg-ic-barra" aria-hidden="true" /> : null}
              <button
                type="button"
                className="tg-ic-btn"
                aria-label={etiqueta}
                aria-current={activo ? "page" : undefined}
                onClick={() => onIr?.(clave, etiqueta)}
              >
                <Icono size={22} strokeWidth={1.8} aria-hidden="true" />
              </button>
              <span className="tg-tip" aria-hidden="true">
                {etiqueta}
              </span>
            </li>
          );
        })}
      </ul>

      <div className="tg-rail-pie">
        <div className="tg-ic tg-ic--secundario">
          <button
            type="button"
            className="tg-ic-btn"
            aria-label="Ajustes"
            onClick={() => onIr?.("ajustes", "Ajustes")}
          >
            <Settings size={22} strokeWidth={1.8} aria-hidden="true" />
          </button>
          <span className="tg-tip" aria-hidden="true">
            Ajustes
          </span>
        </div>
        <div className="tg-ic tg-ic--secundario">
          <span className="tg-avatar tg-avatar--rail" aria-hidden="true">
            {usuario?.iniciales}
          </span>
          <span className="tg-tip" aria-hidden="true">
            {usuario?.nombre} · {usuario?.rol}
          </span>
        </div>
      </div>
    </nav>
  );
}
