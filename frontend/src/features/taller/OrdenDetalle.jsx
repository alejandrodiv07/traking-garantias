/**
 * Detalle de la orden, SOLO LECTURA (spec §8, Tarea 16): encabezado, barra de
 * estados y cinco pestañas. Cada pestaña lee lo suyo al abrirse, así un fallo
 * en una no tumba el resto. Las acciones (avanzar, rechazar, asignar técnico,
 * presupuesto) llegan con la 0021.
 */
import { useEffect, useState } from "react";
import { useParams } from "react-router-dom";
import HistorialRevisiones from "../revisiones/HistorialRevisiones.jsx";
import { cobertura, estado as estadoDe } from "../tablero/dominio.js";
import BarraEstados from "./componentes/BarraEstados.jsx";
import { adjuntosOrden, historialOrden, notasOrden, obtenerOrden } from "./tallerService.js";
import "./taller.css";

const ATENCION = { GARANTIA: "garantía", PAGO: "pago", PENDIENTE: "pendiente" };

const PESTANAS = ["Resumen", "Auditoría", "Diagnóstico y presupuesto", "Documentos", "Bitácora"];

/** Carga una lista al montar la pestaña: { cargando } | { error } | { datos }. */
function useLista(leer, ordenId) {
  const [estado, setEstado] = useState({ cargando: true });
  useEffect(() => {
    let vivo = true;
    leer(ordenId).then((r) => {
      if (vivo) setEstado(r.ok ? { datos: r.datos } : { error: r.mensaje || "No se pudo cargar" });
    });
    return () => {
      vivo = false;
    };
  }, [leer, ordenId]);
  return estado;
}

function Resumen({ o }) {
  return (
    <dl className="od-resumen">
      <dt>Equipo</dt>
      <dd>{o.producto}</dd>
      <dt>Serial</dt>
      <dd className="ao-serial">{o.serial}</dd>
      <dt>Titular</dt>
      <dd>
        {o.cliente} ({o.documento})
      </dd>
      <dt>Falla reportada</dt>
      <dd>{o.falla_reportada}</dd>
      <dt>Accesorios</dt>
      <dd>{o.accesorios || "—"}</dd>
      <dt>Ingreso</dt>
      <dd>{String(o.fecha_ingreso).slice(0, 10)}</dd>
      <dt>Técnico</dt>
      <dd>{o.tecnico ? `Técnico: ${o.tecnico}` : "Sin técnico asignado"}</dd>
      {o.motivo_rechazo && (
        <>
          <dt>Motivo del rechazo</dt>
          <dd>{o.motivo_rechazo}</dd>
        </>
      )}
    </dl>
  );
}

function Diagnostico({ o }) {
  return (
    <div>
      <p>{o.diagnostico || "Aún no hay diagnóstico."}</p>
      {o.tipo_atencion === "PAGO" && (
        <p>Presupuesto: {o.costo_reparacion != null ? o.costo_reparacion : "pendiente"}</p>
      )}
    </div>
  );
}

function Documentos({ ordenId }) {
  const e = useLista(adjuntosOrden, ordenId);
  if (e.cargando) return <p role="status">Cargando documentos…</p>;
  if (e.error) return <p role="alert">{e.error}</p>;
  if (e.datos.length === 0) return <p>Sin documentos.</p>;
  return (
    <ul>
      {e.datos.map((a) => (
        <li key={a.id}>
          {a.tipo === "FOTO" ? "Foto" : "Documento"} — {a.etiqueta || a.ruta.split("/").pop()}
        </li>
      ))}
    </ul>
  );
}

function textoEvento(h) {
  if (h.evento === "BITACORA") return h.comentario;
  const cambio = `${h.estado_anterior ? estadoDe(h.estado_anterior).nombre : "Alta"} → ${estadoDe(h.estado_nuevo).nombre}`;
  return h.comentario ? `${cambio}: ${h.comentario}` : cambio;
}

function Bitacora({ ordenId }) {
  const historial = useLista(historialOrden, ordenId);
  const notas = useLista(notasOrden, ordenId);
  if (historial.cargando || notas.cargando) return <p role="status">Cargando bitácora…</p>;
  const error = historial.error || notas.error;
  if (error) return <p role="alert">{error}</p>;

  const entradas = [
    ...historial.datos.map((h) => ({
      clave: `h${h.id}`,
      fecha: h.creado_en,
      autor: h.autor?.full_name,
      texto: textoEvento(h),
    })),
    ...notas.datos.map((n) => ({
      clave: `n${n.id}`,
      fecha: n.created_at,
      autor: n.autor?.full_name,
      texto: `Nota interna: ${n.nota}`,
    })),
  ].sort((a, b) => String(b.fecha).localeCompare(String(a.fecha)));

  if (entradas.length === 0) return <p>Sin movimientos.</p>;
  return (
    <ol className="od-bitacora">
      {entradas.map((e) => (
        <li key={e.clave}>
          <time>{String(e.fecha).slice(0, 10)}</time> <span>{e.texto}</span>
          {e.autor && <small> — {e.autor}</small>}
        </li>
      ))}
    </ol>
  );
}

export default function OrdenDetalle() {
  const { id } = useParams();
  const [orden, setOrden] = useState(null);
  const [error, setError] = useState(null);
  const [pestana, setPestana] = useState("Resumen");

  useEffect(() => {
    let vivo = true;
    obtenerOrden(id).then((r) => {
      if (!vivo) return;
      if (r.ok) setOrden(r.datos);
      else setError(r.mensaje || "No se pudo cargar la orden");
    });
    return () => {
      vivo = false;
    };
  }, [id]);

  if (error) return <p role="alert">{error}</p>;
  if (!orden) return <p role="status">Cargando orden…</p>;

  const cob = cobertura(orden.cobertura);
  return (
    <section className="od">
      <header className="od-cab">
        <h1>{orden.numero_orden}</h1>
        <p>{orden.estado_nombre}</p>
        <span className="cs-insignia" data-tono={cob.tono}>
          {cob.nombre}
        </span>{" "}
        <span className="cs-insignia" data-tono="neutro">
          Atención: {ATENCION[orden.tipo_atencion] ?? orden.tipo_atencion}
        </span>
      </header>

      <BarraEstados
        estado={orden.estado}
        tipoAtencion={orden.tipo_atencion}
        tieneDiagnostico={Boolean(orden.diagnostico)}
      />

      <div role="tablist" aria-label="Secciones de la orden" className="od-pestanas">
        {PESTANAS.map((p) => (
          <button
            key={p}
            type="button"
            role="tab"
            aria-selected={p === pestana}
            onClick={() => setPestana(p)}
          >
            {p}
          </button>
        ))}
      </div>

      <div role="tabpanel" className="od-panel">
        {pestana === "Resumen" && <Resumen o={orden} />}
        {pestana === "Auditoría" && <HistorialRevisiones ordenId={orden.orden_id} />}
        {pestana === "Diagnóstico y presupuesto" && <Diagnostico o={orden} />}
        {pestana === "Documentos" && <Documentos ordenId={orden.orden_id} />}
        {pestana === "Bitácora" && <Bitacora ordenId={orden.orden_id} />}
      </div>
    </section>
  );
}
