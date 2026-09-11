/**
 * Tablero del taller — pantalla de aterrizaje de ADMIN.
 *
 * ===========================================================================
 * CONECTADO (Fase 2, P4-P7). `datosDemo.js` ya no se importa en producción:
 * se movió a `__fixtures__/ordenes.js` para los tests de Vitest (contiene a
 * propósito los casos incómodos -- nombre larguísimo, sin serial, cobertura
 * POR_DETERMINAR, los cuatro tonos -- que un mock bonito esconde).
 * ===========================================================================
 *
 * Cambios respecto a la versión de solo interfaz:
 *   - KPIs, tabla y vencimientos vienen de `datos/hooks.js`
 *     (`useKpis`, `useOrdenes`, `usePorVencer`), que a su vez consultan
 *     `kpis_tablero()` y `v_ordenes_tablero`.
 *   - El filtro por estado y la búsqueda pasan a la consulta (parámetros de
 *     PostgREST), no se hacen más en memoria.
 *   - "Agregar nueva garantía" abre `ModalNuevaGarantia` (reemplaza al
 *     antiguo "Nueva orden" / `ModalNuevaOrden`, ahora sin uso); el botón se
 *     oculta para `TECNICO` como cortesía (§6.1) -- la restricción real la
 *     hace la RLS de `crear_orden()`.
 *   - Los demás botones sin acción (campana, recordatorios, nav lateral,
 *     "ver todas") siguen avisando que no están construidos: son
 *     Fase 2.1/Fase 4, fuera de este alcance.
 * Ningún componente de presentación (`TablaOrdenes`, `PanelVencimientos`,
 * `BarraLateral`) cambió su contrato de props.
 */
import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { Bell, LogOut, Plus } from "lucide-react";
import { useAuth } from "../auth/AuthContext.jsx";
import BarraLateral from "./componentes/BarraLateral.jsx";
import TablaOrdenes from "./componentes/TablaOrdenes.jsx";
import PanelVencimientos from "./componentes/PanelVencimientos.jsx";
import TarjetasKpi from "./componentes/TarjetasKpi.jsx";
import FiltrosEstado from "./componentes/FiltrosEstado.jsx";
import BuscadorOrdenes from "./componentes/BuscadorOrdenes.jsx";
import ModalNuevaGarantia from "./nueva-garantia/ModalNuevaGarantia.jsx";
import { useKpis, useOrdenes, usePorVencer } from "./datos/hooks.js";
import "./Tablero.css";

/** Iniciales para el avatar. "María Pérez" -> "MP"; un solo nombre -> "MA". */
function iniciales(nombre) {
  const partes = String(nombre ?? "").trim().split(/\s+/).filter(Boolean);
  if (partes.length === 0) return "··";
  if (partes.length === 1) return partes[0].slice(0, 2).toUpperCase();
  return (partes[0][0] + partes[partes.length - 1][0]).toUpperCase();
}

export default function Tablero() {
  const { perfil, rol, salir } = useAuth();
  const navigate = useNavigate();
  const [filtro, setFiltro] = useState("TODAS");
  const [terminoBusqueda, setTerminoBusqueda] = useState("");
  const [terminoDebounced, setTerminoDebounced] = useState("");
  const [aviso, setAviso] = useState(null);
  const [modalAbierto, setModalAbierto] = useState(false);

  const usuario = {
    nombre: perfil?.full_name ?? "",
    iniciales: iniciales(perfil?.full_name),
    rol: rol ?? "",
  };

  // Búsqueda con retardo de 300 ms (§5.1 del spec): se consulta la base
  // cuando el usuario deja de teclear, no en cada tecla.
  useEffect(() => {
    const id = setTimeout(() => setTerminoDebounced(terminoBusqueda), 300);
    return () => clearTimeout(id);
  }, [terminoBusqueda]);

  const {
    ordenes,
    total,
    cargando: cargandoOrdenes,
    error: errorOrdenes,
    recargar: recargarOrdenes,
  } = useOrdenes({ estado: filtro, termino: terminoDebounced });

  const { kpis, cargando: cargandoKpis, error: errorKpis, recargar: recargarKpis } = useKpis();

  const {
    ordenes: porVencer,
    cargando: cargandoPorVencer,
    recargar: recargarPorVencer,
  } = usePorVencer({ dias: 30 });

  /* Los avisos se van solos a los 3,5 s (regla: un toast que hay que cerrar a
     mano interrumpe dos veces). */
  useEffect(() => {
    if (!aviso) return undefined;
    const id = setTimeout(() => setAviso(null), 3500);
    return () => clearTimeout(id);
  }, [aviso]);

  const avisar = (texto) => setAviso({ texto, en: Date.now() });

  const hayFiltro = filtro !== "TODAS" || terminoBusqueda.trim() !== "";

  const fechaHoy = useMemo(
    () =>
      new Date().toLocaleDateString("es-VE", {
        weekday: "long",
        day: "numeric",
        month: "long",
        year: "numeric",
      }),
    []
  );

  function alCrearGarantia() {
    recargarOrdenes();
    recargarKpis();
    recargarPorVencer();
  }

  return (
    <div className="tg">
      <BarraLateral
        actual="tablero"
        usuario={usuario}
        onIr={(clave, etiqueta) => {
          if (clave === "garantias") return navigate("/garantias");
          avisar(`«${etiqueta}» todavía no está construida.`);
        }}
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
            <button type="button" className="tg-btn tg-btn--suave" onClick={salir}>
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
                {fechaHoy.charAt(0).toUpperCase() + fechaHoy.slice(1)}
                {!cargandoKpis && kpis ? ` · ${kpis.ordenes_abiertas} órdenes abiertas` : null}
              </p>
            </div>
            {/* CU-05/§6.1: se oculta como cortesía. La RLS de crear_orden()
                es la restricción real -- un TECNICO que la fuerce igual
                recibe 42501. */}
            {rol !== "TECNICO" ? (
              <button
                type="button"
                className="tg-btn tg-btn--principal"
                onClick={() => setModalAbierto(true)}
              >
                <Plus size={17} strokeWidth={2.4} aria-hidden="true" />
                Agregar nueva garantía
              </button>
            ) : null}
          </div>

          <TarjetasKpi kpis={kpis} cargando={cargandoKpis} error={errorKpis} />

          <div className="tg-cuerpo">
            <section aria-label="Órdenes de servicio">
              <BuscadorOrdenes valor={terminoBusqueda} onCambiar={setTerminoBusqueda} />

              <FiltrosEstado filtro={filtro} termino={terminoDebounced} onCambiar={setFiltro} />

              <p className="tg-sr" role="status" aria-live="polite">
                {cargandoOrdenes ? "Cargando órdenes…" : `${ordenes.length} de ${total} órdenes visibles`}
              </p>

              {errorOrdenes ? (
                <div className="tg-card tg-vacio" role="alert">
                  <p className="tg-vacio-titulo">No se pudieron cargar las órdenes</p>
                  <button type="button" className="tg-btn tg-btn--suave" onClick={recargarOrdenes}>
                    Reintentar
                  </button>
                </div>
              ) : (
                <TablaOrdenes
                  ordenes={ordenes}
                  total={total}
                  hayFiltro={hayFiltro}
                  onLimpiar={() => {
                    setFiltro("TODAS");
                    setTerminoBusqueda("");
                  }}
                  onVerTodas={() => avisar("El listado completo todavía no está construido.")}
                />
              )}
            </section>

            <PanelVencimientos
              items={cargandoPorVencer ? [] : porVencer}
              hoy={new Date()}
              onRecordatorios={() =>
                avisar("El envío de recordatorios todavía no está construido.")
              }
            />
          </div>
        </main>
      </div>

      {modalAbierto ? (
        <ModalNuevaGarantia
          onCerrar={() => setModalAbierto(false)}
          onOrdenCreada={alCrearGarantia}
        />
      ) : null}

      {aviso ? (
        <p className="tg-aviso" role="status" aria-live="polite">
          {aviso.texto}
        </p>
      ) : null}
    </div>
  );
}
