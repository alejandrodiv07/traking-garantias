/**
 * Tablero del taller — pantalla de aterrizaje de ADMIN.
 *
 * ===========================================================================
 * ESTADO ACTUAL: SOLO INTERFAZ. NINGÚN DATO SALE DE LA BASE.
 * ===========================================================================
 * Todo lo que se ve viene de `datosDemo.js`. Es deliberado: primero se decide
 * qué información quiere ver quien abre esta pantalla y cómo se ordena, y
 * después se escriben las consultas. Al revés se acaba con una pantalla que
 * enseña lo que la consulta devolvía y no lo que hacía falta.
 *
 * Cuando se conecte:
 *   - `ORDENES`, `KPIS` y `POR_VENCER` se cambian por hooks de datos.
 *   - El filtrado y la búsqueda pasan a la consulta (§8 de la migración tiene
 *     los índices parciales exactos que necesitan); aquí se hacen en memoria
 *     porque sobre ocho filas es gratis y hace la pantalla revisable.
 *   - Los tres botones sin acción (`avisar(...)`) reciben su destino.
 * Ningún componente hijo cambia: todos reciben datos por props.
 * ===========================================================================
 */
import { useEffect, useMemo, useState } from "react";
import { Bell, LogOut, Plus, Search, X } from "lucide-react";
import { useAuth } from "../auth/AuthContext.jsx";
import BarraLateral from "./componentes/BarraLateral.jsx";
import TablaOrdenes from "./componentes/TablaOrdenes.jsx";
import PanelVencimientos from "./componentes/PanelVencimientos.jsx";
import { estaAbierta, FILTROS } from "./dominio.js";
import { HOY, KPIS, ORDENES, POR_VENCER, USUARIO_DEMO } from "./datosDemo.js";
import "./Tablero.css";

/** Iniciales para el avatar. "María Pérez" -> "MP"; un solo nombre -> "MA". */
function iniciales(nombre) {
  const partes = String(nombre ?? "").trim().split(/\s+/).filter(Boolean);
  if (partes.length === 0) return "··";
  if (partes.length === 1) return partes[0].slice(0, 2).toUpperCase();
  return (partes[0][0] + partes[partes.length - 1][0]).toUpperCase();
}

/**
 * Búsqueda multicriterio. El mismo cuadro busca por número de orden, nombre,
 * cédula/RIF, equipo o serial, porque quien atiende el mostrador tiene UNA
 * cosa en la mano —un papel, un equipo, una cédula— y no sabe en qué columna
 * cae. Obligarle a elegir el campo antes de escribir es trabajo de más.
 */
function coincide(orden, termino) {
  if (!termino) return true;
  const t = termino.trim().toLowerCase();
  if (!t) return true;
  return [orden.numero, orden.cliente, orden.documento, orden.equipo, orden.serie]
    .filter(Boolean)
    .some((campo) => campo.toLowerCase().includes(t));
}

export default function Tablero() {
  const { perfil, salir } = useAuth();
  const [filtro, setFiltro] = useState("TODAS");
  const [busqueda, setBusqueda] = useState("");
  const [aviso, setAviso] = useState(null);

  const usuario = {
    nombre: perfil?.full_name ?? USUARIO_DEMO.nombre,
    iniciales: iniciales(perfil?.full_name ?? USUARIO_DEMO.nombre),
    rol: "Administración",
  };

  /* Los avisos se van solos a los 3,5 s (regla: un toast que hay que cerrar a
     mano interrumpe dos veces). El temporizador se limpia al desmontar y al
     llegar un aviso nuevo, o se acumulan. */
  useEffect(() => {
    if (!aviso) return undefined;
    const id = setTimeout(() => setAviso(null), 3500);
    return () => clearTimeout(id);
  }, [aviso]);

  const avisar = (texto) => setAviso({ texto, en: Date.now() });

  const cuentas = useMemo(() => {
    const mapa = {};
    for (const f of FILTROS) {
      mapa[f.clave] = f.estados
        ? ORDENES.filter((o) => f.estados.includes(o.estado)).length
        : ORDENES.length;
    }
    return mapa;
  }, []);

  const visibles = useMemo(() => {
    const def = FILTROS.find((f) => f.clave === filtro);
    return ORDENES.filter(
      (o) => (!def?.estados || def.estados.includes(o.estado)) && coincide(o, busqueda)
    );
  }, [filtro, busqueda]);

  const hayFiltro = filtro !== "TODAS" || busqueda.trim() !== "";
  const abiertas = ORDENES.filter((o) => estaAbierta(o.estado)).length;

  const fechaHoy = HOY.toLocaleDateString("es-VE", {
    weekday: "long",
    day: "numeric",
    month: "long",
    year: "numeric",
  });

  return (
    <div className="tg">
      <BarraLateral
        actual="tablero"
        usuario={usuario}
        onIr={(_, etiqueta) => avisar(`«${etiqueta}» todavía no está construida.`)}
      />

      <div className="tg-main">
        <header className="tg-topbar">
          <p className="tg-ruta">
            Taller / <strong>Tablero</strong>
          </p>
          <div className="tg-topbar-acciones">
            <button
              type="button"
              className="tg-btn tg-btn--suave tg-btn--icono"
              aria-label="Notificaciones: hay avisos sin leer"
              onClick={() => avisar("El centro de notificaciones todavía no está construido.")}
            >
              <Bell size={18} strokeWidth={1.8} aria-hidden="true" />
              <span className="tg-punto" aria-hidden="true" />
            </button>
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
                {fechaHoy.charAt(0).toUpperCase() + fechaHoy.slice(1)} · {abiertas} órdenes
                abiertas
              </p>
            </div>
            <button
              type="button"
              className="tg-btn tg-btn--principal"
              onClick={() => avisar("El alta de órdenes todavía no está construida.")}
            >
              <Plus size={17} strokeWidth={2.4} aria-hidden="true" />
              Nueva orden
            </button>
          </div>

          <ul className="tg-kpis">
            {KPIS.map((k) => (
              <li className="tg-card tg-kpi" key={k.clave}>
                <p className="tg-kpi-etiqueta">{k.etiqueta}</p>
                <p className="tg-kpi-valor">{k.valor}</p>
                <p className="tg-kpi-nota" data-tendencia={k.tendencia ?? undefined}>
                  {k.nota}
                </p>
              </li>
            ))}
          </ul>

          <div className="tg-cuerpo">
            <section aria-label="Órdenes de servicio">
              <div className="tg-buscador">
                <label className="tg-sr" htmlFor="tg-busqueda">
                  Buscar órdenes por número, cliente, cédula o RIF, equipo o serial
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
                  placeholder="Buscar por serial, cédula/RIF, cliente o nº de orden…"
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
                {FILTROS.map((f) => (
                  <button
                    key={f.clave}
                    type="button"
                    className="tg-chip"
                    aria-pressed={filtro === f.clave}
                    onClick={() => setFiltro(f.clave)}
                  >
                    {f.etiqueta}
                    <span className="tg-chip-cuenta">{cuentas[f.clave]}</span>
                  </button>
                ))}
              </div>

              {/* El recuento se anuncia al filtrar; sin esto, quien usa lector
                  de pantalla pulsa un chip y no recibe ninguna señal. */}
              <p className="tg-sr" role="status" aria-live="polite">
                {visibles.length} de {ORDENES.length} órdenes visibles
              </p>

              <TablaOrdenes
                ordenes={visibles}
                total={ORDENES.length}
                hayFiltro={hayFiltro}
                onLimpiar={() => {
                  setFiltro("TODAS");
                  setBusqueda("");
                }}
                onVerTodas={() => avisar("El listado completo todavía no está construido.")}
              />
            </section>

            <PanelVencimientos
              items={POR_VENCER}
              hoy={HOY}
              onRecordatorios={() =>
                avisar("El envío de recordatorios todavía no está construido.")
              }
            />
          </div>
        </main>
      </div>

      {aviso ? (
        <p className="tg-aviso" role="status" aria-live="polite">
          {aviso.texto}
        </p>
      ) : null}
    </div>
  );
}
