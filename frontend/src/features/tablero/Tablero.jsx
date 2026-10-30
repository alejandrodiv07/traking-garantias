/**
 * Tablero del taller — pantalla de aterrizaje de TODOS los roles internos
 * (Tarea 20 del plan; spec §7.3). Los datos vienen de la vista `v_tablero`
 * (urgencia combinada de vigencia y SLA); ya no hay datos de demostración.
 */
import { useCallback, useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { LogOut, Plus, Search, X } from "lucide-react";
import { useAuth } from "../auth/AuthContext.jsx";
import BarraLateral from "./componentes/BarraLateral.jsx";
import TablaRegistros from "./componentes/TablaRegistros.jsx";
import PanelVencimientos from "./componentes/PanelVencimientos.jsx";
import DetalleRegistro from "./componentes/DetalleRegistro.jsx";
import { estaAbierta } from "./dominio.js";
import { listarTablero } from "./tableroService.js";
import "./Tablero.css";

/** Iniciales para el avatar. "María Pérez" -> "MP"; un solo nombre -> "MA". */
function iniciales(nombre) {
  const partes = String(nombre ?? "").trim().split(/\s+/).filter(Boolean);
  if (partes.length === 0) return "··";
  if (partes.length === 1) return partes[0].slice(0, 2).toUpperCase();
  return (partes[0][0] + partes[partes.length - 1][0]).toUpperCase();
}

const NIVELES = ["", "VENCIDA", "HOY", "CRITICA", "PRONTO", "NORMAL"];

export default function Tablero() {
  const { perfil, rol, salir } = useAuth();
  const navigate = useNavigate();
  const [busqueda, setBusqueda] = useState("");
  const [estadoFiltro, setEstadoFiltro] = useState("");
  const [urgenciaFiltro, setUrgenciaFiltro] = useState("");
  const [filas, setFilas] = useState([]);
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState(null);
  const [detalle, setDetalle] = useState(null);

  const cargar = useCallback(async () => {
    setCargando(true);
    setError(null);
    const r = await listarTablero({
      busqueda,
      estado: estadoFiltro || undefined,
      urgencia: urgenciaFiltro || undefined,
    });
    if (r.ok) setFilas(r.filas);
    else setError(r);
    setCargando(false);
  }, [busqueda, estadoFiltro, urgenciaFiltro]);

  // La búsqueda de la vista es del lado de la base: con 250 ms de pausa,
  // como el serial del asistente. Enter también dispara.
  useEffect(() => {
    const t = setTimeout(cargar, 250);
    return () => clearTimeout(t);
  }, [cargar]);

  const usuario = {
    nombre: perfil?.full_name ?? "…",
    iniciales: iniciales(perfil?.full_name ?? ""),
    rol: "Administración",
  };

  const abiertas = filas.filter((f) => estaAbierta(f.estado)).length;
  const porVencer = useMemo(
    () =>
      filas
        .filter((f) => f.abierto && f.vence_el && f.dias_restantes !== null && f.dias_restantes <= 30)
        .sort((a, b) => a.dias_restantes - b.dias_restantes)
        .slice(0, 5)
        .map((f) => ({
          id: f.orden_id,
          venceEl: f.vence_el,
          cliente: f.cliente,
          serie: f.serial,
          equipo: f.producto,
        })),
    [filas],
  );

  return (
    <div className="tg">
      <BarraLateral actual="tablero" usuario={usuario} onIr={() => {}} />

      <div className="tg-main">
        <header className="tg-topbar">
          <p className="tg-ruta">
            Taller / <strong>Tablero</strong>
          </p>
          <div className="tg-topbar-acciones">
            <button
              type="button"
              className="tg-btn tg-btn--suave"
              onClick={salir}
            >
              <LogOut size={16} strokeWidth={1.8} aria-hidden="true" />
              Cerrar sesión
            </button>
            <span className="tg-avatar" title={`${usuario.nombre} · ${usuario.rol}`}>
              <span aria-hidden="true">{usuario.iniciales}</span>
              <span className="tg-sr">
                Sesión de {usuario.nombre}, {usuario.rol}
              </span>
            </span>
          </div>
        </header>

        <main className="tg-contenido">
          <div className="tg-encabezado">
            <div>
              <h1 className="tg-titulo">Tablero del taller</h1>
              <p className="tg-subtitulo">
                {abiertas} registros abiertos, ordenados por urgencia
              </p>
            </div>
            <button
              type="button"
              className="tg-btn tg-btn--principal"
              onClick={() => navigate("/garantias/consulta")}
            >
              <Plus size={17} strokeWidth={2.4} aria-hidden="true" />
              Nueva orden
            </button>
          </div>

          <div className="tg-cuerpo">
            <section aria-label="Registros del taller">
              <div className="tg-buscador">
                <label className="tg-sr" htmlFor="tg-busqueda">
                  Buscar por serial, titular, cédula, factura o número de registro
                </label>
                <Search
                  className="tg-buscador-icono"
                  size={18}
                  strokeWidth={1.8}
                  aria-hidden="true"
                />
                <input
                  id="tg-busqueda"
                  className="tg-input"
                  type="search"
                  autoComplete="off"
                  value={busqueda}
                  onChange={(e) => setBusqueda(e.target.value)}
                  placeholder="Buscar por serial, cédula/RIF, titular, factura o REG-…"
                />
                {busqueda ? (
                  <button
                    type="button"
                    className="tg-buscador-limpiar"
                    aria-label="Borrar la búsqueda"
                    onClick={() => setBusqueda("")}
                  >
                    <X size={16} strokeWidth={2} aria-hidden="true" />
                  </button>
                ) : null}
              </div>

              <div className="tg-chips" role="group" aria-label="Filtrar por estado">
                <label htmlFor="tg-estado">Estado</label>
                <select
                  id="tg-estado"
                  value={estadoFiltro}
                  onChange={(e) => setEstadoFiltro(e.target.value)}
                >
                  <option value="">Todos</option>
                  {["RECIBIDO", "EN_DIAGNOSTICO", "EN_REPARACION", "REPARADO", "ENTREGADO", "ANULADO"].map(
                    (e) => (
                      <option key={e} value={e}>{e}</option>
                    ),
                  )}
                </select>
                <label htmlFor="tg-urgencia">Urgencia</label>
                <select
                  id="tg-urgencia"
                  value={urgenciaFiltro}
                  onChange={(e) => setUrgenciaFiltro(e.target.value)}
                >
                  <option value="">Cualquiera</option>
                  {NIVELES.filter(Boolean).map((n) => (
                    <option key={n} value={n}>{n}</option>
                  ))}
                </select>
              </div>

              <p className="tg-sr" role="status" aria-live="polite">
                {cargando ? "Cargando registros…" : `${filas.length} registros visibles`}
              </p>

              {cargando ? (
                <p role="status">Cargando registros…</p>
              ) : error ? (
                <div role="alert">
                  <p>{error.mensaje ?? "No se pudo cargar el Tablero."}</p>
                  <button type="button" onClick={cargar}>
                    Reintentar
                  </button>
                </div>
              ) : (
                <TablaRegistros
                  filas={filas}
                  rol={rol}
                  onRevisar={setDetalle}
                />
              )}
            </section>

            <PanelVencimientos items={porVencer} hoy={new Date()} onRecordatorios={() => {}} />
          </div>
        </main>
      </div>

      {detalle && (
        <DetalleRegistro
          fila={detalle}
          rol={rol}
          onCerrar={() => setDetalle(null)}
          // Guardar una revisión puede cambiar la cobertura: el listado se
          // recarga. El botón "Revisar" solo existe para rol ≠ RECEPCION,
          // TablaRegistros ya lo filtra.
          onRegistrada={cargar}
        />
      )}
    </div>
  );
}