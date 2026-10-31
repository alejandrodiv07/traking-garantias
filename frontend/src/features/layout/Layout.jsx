/**
 * Layout de las pantallas (maqueta 01): barra lateral oscura con siete
 * destinos (`NavLink`, URL real), plegable a iconos y en cajón en móvil; barra
 * superior con migas, tema claro/oscuro, notificaciones y avatar.
 */
import { useEffect, useState } from "react";
import { Link, NavLink, Outlet, useLocation } from "react-router-dom";
import {
  Bell,
  FileText,
  LogOut,
  Menu,
  Moon,
  Package,
  PanelLeftClose,
  PanelLeftOpen,
  ShieldCheck,
  Sun,
  Truck,
  Users,
  Wrench,
  X,
} from "lucide-react";
import { useAuth } from "../auth/AuthContext.jsx";
import { aplicarTema, temaGuardado } from "./tema.js";
import logo from "../../assets/logo-prime.png";
import logoIcono from "../../assets/logo-prime-icono.png";
import "./layout.css";

const DESTINOS = [
  { a: "/garantias", etiqueta: "Garantías", Icono: ShieldCheck },
  { a: "/taller", etiqueta: "Taller", Icono: Wrench },
  { a: "/entregas", etiqueta: "Entregas", Icono: Truck },
  { a: "/inventario", etiqueta: "Inventario", Icono: Package },
  { a: "/reportes", etiqueta: "Reportes", Icono: FileText },
  { a: "/clientes", etiqueta: "Clientes", Icono: Users },
  { a: "/notificaciones", etiqueta: "Notificaciones", Icono: Bell },
];

// Pantallas que no tienen destino en la barra lateral pero sí merecen título propio.
const TITULOS_FUERA_DEL_MENU = { "/ventas/importar": "Importar ventas" };

const iniciales = (correo = "") => correo.slice(0, 2).toUpperCase() || "PT";

export default function Layout() {
  const { perfil, salir } = useAuth();
  const { pathname } = useLocation();
  const [plegada, setPlegada] = useState(() => {
    try {
      return localStorage.getItem("pt.plegada") === "1";
    } catch {
      return false;
    }
  });
  const [abierta, setAbierta] = useState(false);
  const [tema, setTema] = useState(temaGuardado);

  useEffect(() => {
    const alTeclear = (e) => e.key === "Escape" && setAbierta(false);
    document.addEventListener("keydown", alTeclear);
    return () => document.removeEventListener("keydown", alTeclear);
  }, []);

  function plegar() {
    const v = !plegada;
    setPlegada(v);
    try {
      localStorage.setItem("pt.plegada", v ? "1" : "0");
    } catch {
      // sin almacenamiento: vale solo para esta visita
    }
  }

  function alternarTema() {
    const t = tema === "dark" ? "light" : "dark";
    aplicarTema(t);
    setTema(t);
  }

  const actual = DESTINOS.find((d) => pathname === d.a || pathname.startsWith(`${d.a}/`));

  useEffect(() => {
    document.title = `${actual?.etiqueta ?? TITULOS_FUERA_DEL_MENU[pathname] ?? "Inicio"} | Prime Telecom`;
  }, [actual, pathname]);

  // Las subpáginas (consulta, nueva, detalle) traen su propia miga con el enlace de vuelta.
  const esSubpagina = pathname.split("/").filter(Boolean).length > 1;
  const miga = (
    <p className="ruta">
      Prime Telecom / <strong>{actual?.etiqueta ?? "Inicio"}</strong>
    </p>
  );

  return (
    <div className={plegada ? "app plegada" : "app"}>
      <aside className={abierta ? "side abierta" : "side"} aria-label="Menú principal">
        <div className="side-cab">
          <Link to="/garantias" className="logo" aria-label="Prime Telecom, ir al inicio">
            <img className="logo-completo" src={logo} alt="Prime Telecom" width="720" height="136" />
            <img className="logo-icono" src={logoIcono} alt="" width="160" height="160" />
          </Link>
          <button
            type="button"
            className="ibtn plegar"
            aria-label={plegada ? "Expandir menú" : "Contraer menú"}
            aria-pressed={plegada}
            onClick={plegar}
          >
            {plegada ? <PanelLeftOpen size={18} aria-hidden="true" /> : <PanelLeftClose size={18} aria-hidden="true" />}
          </button>
          <button type="button" className="ibtn cerrar" aria-label="Cerrar menú" onClick={() => setAbierta(false)}>
            <X size={18} aria-hidden="true" />
          </button>
        </div>
        <nav className="nav" aria-label="Módulos">
          <ul>
            {DESTINOS.map(({ a, etiqueta, Icono }) => (
              <li key={a}>
                <NavLink to={a} className="enlace" title={etiqueta} onClick={() => setAbierta(false)}>
                  <Icono size={20} strokeWidth={1.8} aria-hidden="true" />
                  <span className="etq">{etiqueta}</span>
                </NavLink>
              </li>
            ))}
          </ul>
        </nav>
        <div className="pie">
          <p className="email" title={perfil?.email}>{perfil?.email}</p>
          <button type="button" className="enlace" title="Cerrar sesión" onClick={salir}>
            <LogOut size={18} strokeWidth={1.8} aria-hidden="true" />
            <span className="etq">Cerrar sesión</span>
          </button>
        </div>
      </aside>
      <div className={abierta ? "velo on" : "velo"} onClick={() => setAbierta(false)} aria-hidden="true" />

      <div className="cuerpo">
        <header className="barra">
          <button type="button" className="ibtn" aria-label="Abrir menú" aria-expanded={abierta} onClick={() => setAbierta(true)}>
            <Menu size={20} aria-hidden="true" />
          </button>
          {!esSubpagina && miga}
        </header>

        <main className="main" id="contenido">
          <div className="topline">
            {esSubpagina ? <span className="ruta" /> : miga}
            <div className="perfil">
              <button
                type="button"
                className="campana"
                aria-label={tema === "dark" ? "Cambiar a tema claro" : "Cambiar a tema oscuro"}
                onClick={alternarTema}
              >
                {tema === "dark" ? <Sun size={20} aria-hidden="true" /> : <Moon size={20} aria-hidden="true" />}
              </button>
              <Link to="/notificaciones" className="campana" aria-label="Ver notificaciones">
                <Bell size={20} aria-hidden="true" />
              </Link>
              <span className="avatar" title={perfil?.email}>{iniciales(perfil?.email)}</span>
            </div>
          </div>
          <Outlet />
        </main>
      </div>
    </div>
  );
}
