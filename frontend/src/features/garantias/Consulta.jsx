/**
 * Consulta de garantía (spec §8, Tarea 14): un buscador sobre `buscar_equipo`
 * (serial, cédula/RIF, factura u orden), la ficha de cada equipo con su
 * cobertura e historial de órdenes, y los saltos a registrar o abrir orden.
 * Los colores salen de `cobertura()` del dominio del Tablero: mismo tono.
 */
import { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { cobertura } from "../tablero/dominio.js";
import { useAuth } from "../auth/AuthContext.jsx";
import { AVISO_ATENCION } from "./avisos.js";
import { buscarGarantia, confirmarCompra, desestimarCompra } from "./garantiasService.js";
import "./garantias.css";

const CRITERIOS = [
  ["serial", "Serial"],
  ["documento", "Cédula / RIF"],
  ["factura", "Factura"],
  ["orden", "Orden"],
];

const ordenAbierta = (o) => !["ENTREGADO", "ANULADO"].includes(o.estado);

function diasTexto(dias) {
  if (typeof dias !== "number") return null;
  return dias >= 0 ? `${dias} días restantes` : "Vencida";
}

const MOTIVO_MIN = 10;

/** Confirmar / desestimar la compra de un equipo registrado desde el taller (jefatura). */
function AccionesCompra({ e, onListo }) {
  const [modo, setModo] = useState(null);
  const [numero, setNumero] = useState(e.numero_soporte ?? "");
  const [fecha, setFecha] = useState(e.fecha_emision ?? "");
  const [plazo, setPlazo] = useState(e.plazo_dias ?? "");
  const [motivo, setMotivo] = useState("");
  const [error, setError] = useState(null);
  const [enviando, setEnviando] = useState(false);

  async function enviar(llamada) {
    setEnviando(true);
    setError(null);
    const r = await llamada();
    setEnviando(false);
    if (r.ok) onListo();
    else setError(r.mensaje || "No se pudo guardar");
  }

  return (
    <div className="cs-compra">
      {!modo && (
        <>
          <button type="button" onClick={() => setModo("confirmar")}>
            Confirmar compra
          </button>
          <button type="button" onClick={() => setModo("desestimar")}>
            Desestimar compra
          </button>
        </>
      )}
      {modo === "confirmar" && (
        <form
          onSubmit={(ev) => {
            ev.preventDefault();
            enviar(() =>
              confirmarCompra({
                equipoId: e.equipo_id,
                tipoSoporte: "FACTURA",
                numeroSoporte: numero.trim(),
                fechaEmision: fecha,
                plazoDias: Number(plazo),
              }),
            );
          }}
        >
          <label htmlFor={`num-${e.equipo_id}`}>
            Número de factura
            <input id={`num-${e.equipo_id}`} value={numero} onChange={(ev) => setNumero(ev.target.value)} />
          </label>
          <label htmlFor={`fec-${e.equipo_id}`}>
            Fecha de emisión
            <input id={`fec-${e.equipo_id}`} type="date" value={fecha} onChange={(ev) => setFecha(ev.target.value)} />
          </label>
          <label htmlFor={`pla-${e.equipo_id}`}>
            Plazo (días)
            <input id={`pla-${e.equipo_id}`} type="number" min="1" value={plazo} onChange={(ev) => setPlazo(ev.target.value)} />
          </label>
          <button type="submit" disabled={enviando || !numero.trim() || !fecha || !plazo}>
            Confirmar
          </button>
        </form>
      )}
      {modo === "desestimar" && (
        <form
          onSubmit={(ev) => {
            ev.preventDefault();
            enviar(() => desestimarCompra({ equipoId: e.equipo_id, motivo: motivo.trim() }));
          }}
        >
          <label htmlFor={`mot-${e.equipo_id}`}>
            Motivo
            <textarea id={`mot-${e.equipo_id}`} value={motivo} onChange={(ev) => setMotivo(ev.target.value)} />
          </label>
          <button type="submit" disabled={enviando || motivo.trim().length < MOTIVO_MIN}>
            Desestimar
          </button>
        </form>
      )}
      {error && <p role="alert">{error}</p>}
    </div>
  );
}

const ROLES_JEFATURA = ["ADMIN", "JEFE_SERVICIO"];

function Ficha({ e, navigate, rol, onCambio }) {
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
      {e.estado_compra === "PENDIENTE" && ROLES_JEFATURA.includes(rol) && (
        <AccionesCompra e={e} onListo={onCambio} />
      )}
      <button type="button" className="cs-principal" onClick={() => navigate(`/taller/nueva?equipo=${e.equipo_id}`)}>
        Abrir orden de servicio
      </button>
    </article>
  );
}

export default function Consulta() {
  const navigate = useNavigate();
  const { rol } = useAuth();
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
    setEstado(r.ok ? { fase: "listo", filas: r.datos, buscado: t, clave } : { fase: "error", mensaje: r.mensaje });
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
        estado.filas.map((e) => (
          <Ficha
            key={e.equipo_id}
            e={e}
            navigate={navigate}
            rol={rol}
            onCambio={() => ejecutar(estado.clave, estado.buscado)}
          />
        ))}
    </section>
  );
}
