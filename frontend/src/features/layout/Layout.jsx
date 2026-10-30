/**
 * Layout de las pantallas de la fase 2a: barra lateral con `NavLink` (URL real,
 * no estado local) y el contenido de la ruta en `<Outlet />`. Solo lista los
 * destinos que ya existen; los demás se suman cuando haya pantalla.
 */
import { NavLink, Outlet } from "react-router-dom";
import { LogOut, ShieldCheck, Wrench } from "lucide-react";
import { useAuth } from "../auth/AuthContext.jsx";
import "./layout.css";

const DESTINOS = [
  { a: "/garantias", etiqueta: "Garantías", Icono: ShieldCheck },
  { a: "/taller", etiqueta: "Taller", Icono: Wrench },
];

export default function Layout() {
  const { perfil, salir } = useAuth();
  return (
    <div className="lay">
      <nav className="lay-lateral" aria-label="Navegación principal">
        <p className="lay-marca">Prime Telecom</p>
        <ul className="lay-lista">
          {DESTINOS.map(({ a, etiqueta, Icono }) => (
            <li key={a}>
              <NavLink to={a} className="lay-destino">
                <Icono size={18} strokeWidth={1.8} aria-hidden="true" />
                {etiqueta}
              </NavLink>
            </li>
          ))}
        </ul>
        <div className="lay-pie">
          <span className="lay-correo">{perfil?.email}</span>
          <button type="button" className="lay-salir" onClick={salir}>
            <LogOut size={16} strokeWidth={1.8} aria-hidden="true" />
            Cerrar sesión
          </button>
        </div>
      </nav>
      <main className="lay-contenido">
        <Outlet />
      </main>
    </div>
  );
}
