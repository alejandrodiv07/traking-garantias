/**
 * Consulta de garantía (spec §8, Tarea 14): un buscador sobre `buscar_equipo`
 * (serial, cédula/RIF, factura u orden), la ficha de cada equipo con su
 * cobertura e historial de órdenes, y los saltos a registrar o abrir orden.
 * Los colores salen de `cobertura()` del dominio del Tablero: mismo tono.
 */
import { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { cobertura } from "../tablero/dominio.js";
import { buscarGarantia } from "./garantiasService.js";
import "./garantias.css";

const CRITERIOS = [
  ["serial", "Serial"],
  ["documento", "Cédula / RIF"],
  ["factura", "Factura"],
  ["orden", "Orden"],
];

const AVISO_ATENCION = {
  FUERA_DE_GARANTIA: "Fuera de garantía: se atenderá como servicio pago.",
  POR_DETERMINAR: "Aviso: cobertura pendiente de confirmar, la orden quedará por determinar.",
};

const ordenAbierta = (o) => !["ENTREGADO", "ANULADO"].includes(o.estado);

function diasTexto(dias) {
  if (typeof dias !== "number") return null;
  return dias >= 0 ? `${dias} días restantes` : "Vencida";
}

function Ficha({ e, navigate }) {
  const c = cobertura(e.vigencia);
  const ordenes = e.ordenes ?? [];
  return (
    <article className="cs-ficha">
      <h2>{e.producto}</h2>
      <p className="cs-serial">{e.numero_serie}</p>
      <p>
        Titular: {e.titular} ({e.documento})
      </p>
      <p>
        <span className="cs-insignia" data-tono={c.tono}>
          {c.nombre}
        </span>{" "}
        {diasTexto(e.dias_restantes)}
      </p>
      {e.vence_el && (
        <p>
          Periodo: {e.fecha_emision} → {e.vence_el}
        </p>
      )}
      {e.estado_compra === "DESESTIMADA" && <p>Compra desestimada: {e.motivo_desestimacion}</p>}
      {e.estado_compra === "PENDIENTE" && <p>Compra por confirmar (registrada desde el taller).</p>}

      {ordenes.length > 0 && (
        <ol className="cs-historial" aria-label="Órdenes del equipo">
          {ordenes.map((o) => (
            <li key={o.numero_orden}>
              <span className="cs-serial">{o.numero_orden}</span> <span>{o.estado_nombre}</span>{" "}
              <time>{String(o.fecha_ingreso).slice(0, 10)}</time>
            </li>
          ))}
        </ol>
      )}

      {AVISO_ATENCION[e.vigencia] && <p role="note">{AVISO_ATENCION[e.vigencia]}</p>}
      {ordenes.some(ordenAbierta) && <p role="note">Este equipo ya tiene una orden abierta.</p>}
      <button type="button" className="cs-principal" onClick={() => navigate(`/taller/nueva?equipo=${e.equipo_id}`)}>
        Abrir orden de servicio
      </button>
    </article>
  );
}

export default function Consulta() {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const serialInicial = params.get("serial") ?? "";
  const [criterio, setCriterio] = useState("serial");
  const [valor, setValor] = useState(serialInicial);
  const [estado, setEstado] = useState({ fase: "inicio" });

  async function ejecutar(clave, texto) {
    const t = texto.trim();
    if (!t) return;
    setEstado({ fase: "buscando" });
    const r = await buscarGarantia({ [clave]: t });
    setEstado(r.ok ? { fase: "listo", filas: r.datos, buscado: t } : { fase: "error", mensaje: r.mensaje });
  }

  // Llegar con ?serial= (tras registrar la garantía) busca sin pulsar nada.
  useEffect(() => {
    if (serialInicial) ejecutar("serial", serialInicial);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serialInicial]);

  return (
    <section className="cs">
      <h1>Consulta de garantía</h1>
      <form
        className="cs-buscador"
        onSubmit={(ev) => {
          ev.preventDefault();
          ejecutar(criterio, valor);
        }}
      >
        <label htmlFor="criterio">
          Buscar por
          <select id="criterio" value={criterio} onChange={(ev) => setCriterio(ev.target.value)}>
            {CRITERIOS.map(([k, n]) => (
              <option key={k} value={k}>
                {n}
              </option>
            ))}
          </select>
        </label>
        <label htmlFor="valor">
          Valor
          <input id="valor" value={valor} onChange={(ev) => setValor(ev.target.value)} autoComplete="off" />
        </label>
        <button type="submit">Buscar</button>
      </form>

      {estado.fase === "error" && <p role="alert">{estado.mensaje || "No se pudo consultar"}</p>}

      {estado.fase === "listo" && estado.filas.length === 0 && (
        <div>
          <p>No hay garantía registrada</p>
          <button
            type="button"
            onClick={() =>
              navigate(`/garantias/nueva?serial=${encodeURIComponent(estado.buscado)}&origen=TALLER`)
            }
          >
            Registrar ahora
          </button>
        </div>
      )}

      {estado.fase === "listo" &&
        estado.filas.map((e) => <Ficha key={e.equipo_id} e={e} navigate={navigate} />)}
    </section>
  );
}
