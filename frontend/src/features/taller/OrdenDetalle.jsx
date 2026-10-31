/**
 * Detalle de la orden (spec §8, Tarea 16): encabezado, acciones por rol y
 * barra de estados con cinco pestañas. En las acciones la UI ANTICIPA con el
 * espejo de `transiciones_estado` (dominio.js) y la base DECIDE dentro de la
 * RPC 0021; en las pestañas cada una lee lo suyo al abrirse, así un fallo en
 * una no tumba el resto.
 */
import { useCallback, useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useAuth } from "../auth/AuthContext.jsx";
import { cobertura, estado as estadoDe, estaAbierta, transicionesDesde } from "../tablero/dominio.js";
import HistorialRevisiones from "../revisiones/HistorialRevisiones.jsx";
import RevisionForm from "../revisiones/RevisionForm.jsx";
import BarraEstados from "./componentes/BarraEstados.jsx";
import {
  adjuntosOrden,
  agregarNota,
  asignarTecnico,
  actualizarDiagnostico,
  cambiarEstado,
  historialOrden,
  listarTecnicos,
  notasOrden,
  obtenerOrden,
  registrarPresupuesto,
} from "./tallerService.js";
import "./taller.css";

const ATENCION = { GARANTIA: "garantía", PAGO: "pago", PENDIENTE: "pendiente" };

const PESTANAS = ["Resumen", "Auditoría", "Diagnóstico y presupuesto", "Documentos", "Bitácora"];

/** Mismo mínimo que la base exige (`ck_rechazo_motivado`, migración 0015). */
const MOTIVO_MIN = 10;

/** Jefatura: quienes deciden el rechazo del taller y asignan técnico. */
const JEFE = ["ADMIN", "JEFE_SERVICIO"];

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
    <dl className="od-kv">
      <div>
        <dt>Equipo</dt>
        <dd>{o.producto}</dd>
      </div>
      <div>
        <dt>Serial</dt>
        <dd className="mono">{o.serial}</dd>
      </div>
      <div>
        <dt>Titular</dt>
        <dd>
          {o.cliente} ({o.documento})
        </dd>
      </div>
      <div>
        <dt>Ingreso</dt>
        <dd>{String(o.fecha_ingreso).slice(0, 10)}</dd>
      </div>
      <div>
        <dt>Técnico</dt>
        <dd>{o.tecnico ? `Técnico: ${o.tecnico}` : "Sin técnico asignado"}</dd>
      </div>
      <div>
        <dt>Accesorios</dt>
        <dd>{o.accesorios || "—"}</dd>
      </div>
      <div className="ancho">
        <dt>Falla reportada</dt>
        <dd>{o.falla_reportada}</dd>
      </div>
      {o.motivo_rechazo && (
        <div className="ancho">
          <dt>Motivo del rechazo</dt>
          <dd>{o.motivo_rechazo}</dd>
        </div>
      )}
    </dl>
  );
}

/**
 * Pestaña "Diagnóstico y presupuesto": el diagnóstico va por UPDATE directo
 * de la columna que sigue abierta (la 0021 cerró estado y costo, no esta);
 * el presupuesto SOLO en servicio pago, por la RPC 0021; y, con la orden en
 * PRESUPUESTADO, la recepción de la decisión del cliente por cambiar_estado.
 * La UI anticipa (montos/decisión); la base decide en todos los casos.
 */
function DiagnosticoPresupuesto({ orden, onCambio }) {
  const [texto, setTexto] = useState(orden.diagnostico ?? "");
  const [monto, setMonto] = useState(orden.costo_reparacion ?? "");
  const [enviando, setEnviando] = useState(false);
  const [aviso, setAviso] = useState(null);
  const [error, setError] = useState(null);

  async function enviar(ejecutar, alGuardar) {
    setEnviando(true);
    setError(null);
    setAviso(null);
    const r = await ejecutar();
    setEnviando(false);
    if (r.ok) {
      alGuardar();
      onCambio();
    } else {
      setError(r.mensaje || "No se pudo guardar");
    }
  }

  function guardarDiagnostico(ev) {
    ev.preventDefault();
    return enviar(
      () => actualizarDiagnostico(orden.orden_id, texto),
      () => setAviso("Diagnóstico guardado"),
    );
  }

  function presupuestar(ev) {
    ev.preventDefault();
    return enviar(
      () => registrarPresupuesto(orden.orden_id, Number(monto)),
      () => setAviso("Presupuesto registrado"),
    );
  }

  function decidir(estado) {
    return enviar(
      () => cambiarEstado(orden.orden_id, { estado }),
      () => setAviso("Decisión registrada"),
    );
  }

  return (
    <div className="od-dx">
      {aviso && (
        <p role="status" className="aviso ok">
          {aviso}
        </p>
      )}
      <form className="od-forma" onSubmit={guardarDiagnostico}>
        <label htmlFor="od-dx">
          Diagnóstico
          <textarea
            id="od-dx"
            className="campo"
            rows={4}
            placeholder="Aún no hay diagnóstico"
            value={texto}
            onChange={(ev) => setTexto(ev.target.value)}
          />
        </label>
        <button type="submit" className="btn principal" disabled={enviando}>
          Guardar diagnóstico
        </button>
      </form>

      {orden.tipo_atencion === "PAGO" ? (
        <form className="od-forma" onSubmit={presupuestar}>
          <label htmlFor="od-monto">
            Presupuesto (monto)
            <input
              id="od-monto"
              className="campo"
              type="number"
              min="0"
              step="0.01"
              value={monto}
              onChange={(ev) => setMonto(ev.target.value)}
            />
          </label>
          <button type="submit" className="btn principal" disabled={enviando}>
            Registrar presupuesto
          </button>
        </form>
      ) : (
        <p role="note" className="aviso">
          Solo se presupuesta un servicio pago.
        </p>
      )}

      {orden.estado === "PRESUPUESTADO" && (
        <div className="od-decision">
          <p>Decisión del cliente:</p>
          <button type="button" className="btn principal" onClick={() => decidir("EN_REPARACION")}>
            Aceptó el presupuesto
          </button>
          <button type="button" className="btn suave" onClick={() => decidir("RECHAZADO_POR_CLIENTE")}>
            No aceptó el presupuesto
          </button>
        </div>
      )}
      {error && (
        <p role="alert" className="aviso mal">
          {error}
        </p>
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
    <ul className="od-lista">
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

/** Lo leído de la bitácora: cambios de estado, eventos y notas internas. */
function LecturaBitacora({ ordenId }) {
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
          <time>{String(e.fecha).slice(0, 10)}</time>
          <div>
            <span>{e.texto}</span>
            {e.autor && <small> — {e.autor}</small>}
          </div>
        </li>
      ))}
    </ol>
  );
}

/** Pestaña Bitácora: lo leído + el formulario de notas internas (INSERT con
 * el autor de la sesión; la RLS lo exige). Al anotar se relee la bitácora. */
function Bitacora({ ordenId }) {
  const [version, setVersion] = useState(0);
  const [nota, setNota] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState(null);

  async function agregar(ev) {
    ev.preventDefault();
    const t = nota.trim();
    if (!t) return;
    setEnviando(true);
    setError(null);
    const r = await agregarNota(ordenId, t);
    setEnviando(false);
    if (r.ok) {
      setNota("");
      setVersion((v) => v + 1);
    } else {
      setError(r.mensaje || "No se pudo guardar la nota");
    }
  }

  return (
    <div className="od-bitacora-panel">
      <LecturaBitacora key={version} ordenId={ordenId} />
      <form className="od-forma" onSubmit={agregar}>
        <label htmlFor="od-nota">
          Nota interna
          <textarea
            id="od-nota"
            className="campo"
            rows={3}
            placeholder="Visible solo para el taller"
            value={nota}
            onChange={(ev) => setNota(ev.target.value)}
          />
        </label>
        <button type="submit" className="btn principal" disabled={enviando || !nota.trim()}>
          Agregar nota
        </button>
      </form>
      {error && (
        <p role="alert" className="aviso mal">
          {error}
        </p>
      )}
    </div>
  );
}

/** Modal del detalle: un div `role="dialog"` con nombre accesible y desechable. */
function Modal({ titulo, cerrar, children }) {
  return (
    <div className="od-velo">
      <div className="od-modal" role="dialog" aria-label={titulo}>
        <h2>{titulo}</h2>
        {children}
        <button type="button" className="btn suave" onClick={cerrar}>
          Cancelar
        </button>
      </div>
    </div>
  );
}

/**
 * Pestaña Auditoría: la lista de revisiones SIEMPRE se muestra (incluso para
 * RECEPCION) y el formulario de revisión técnica se lo deja a `RevisionForm`
 * (la base decide con `registrar_revision`). Al guardar, la lista se releerá
 * y la orden se recarga (la revisión técnica puede mover la cobertura).
 */
function Auditoria({ ordenId, rol, onCambio }) {
  const [version, setVersion] = useState(0);
  return (
    <div className="od-auditoria">
      <HistorialRevisiones key={version} ordenId={ordenId} />
      <RevisionForm
        ordenId={ordenId}
        rol={rol}
        onRegistrada={() => {
          setVersion((v) => v + 1);
          onCambio();
        }}
      />
    </div>
  );
}

/**
 * Las acciones de la orden, filtradas por el rol que ANUNCIA profiles (la
 * base lo vuelve a imponer dentro de las RPC): "Avanzar a: X" con las
 * transiciones válidas del estado actual, "Rechazar" solo jefatura y desde
 * los estados que la matriz admite (con motivo de al menos 10 caracteres),
 * y "Asignar técnico" solo jefatura. Tras un cambio con éxito se recarga la
 * orden para que la barra y la bitácora muestren el avance.
 */
function Acciones({ orden, rol, onCambio }) {
  const opciones = transicionesDesde(orden.estado, rol);
  const puedeRechazar = JEFE.includes(rol) && ["RECIBIDO", "EN_DIAGNOSTICO", "PRESUPUESTADO"].includes(orden.estado);

  const [dialogo, setDialogo] = useState(null); // null | "rechazar" | "tecnico"
  const [destino, setDestino] = useState("");
  const [comentario, setComentario] = useState("");
  const [motivo, setMotivo] = useState("");
  const [tecnico, setTecnico] = useState("");
  const [tecnicos, setTecnicos] = useState([]);
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState(null);

  async function aplicar(llamada, alTerminar) {
    setEnviando(true);
    setError(null);
    const r = await llamada();
    setEnviando(false);
    if (r.ok) alTerminar();
    else setError(r.mensaje || "No se pudo guardar");
  }

  function avanzar(ev) {
    ev.preventDefault();
    if (!destino) return;
    return aplicar(
      () => cambiarEstado(orden.orden_id, { estado: destino, comentario: comentario.trim() || null }),
      () => {
        setDestino("");
        setComentario("");
        onCambio();
      },
    );
  }

  function rechazar(ev) {
    ev.preventDefault();
    return aplicar(
      () => cambiarEstado(orden.orden_id, { estado: "RECHAZADO", motivo: motivo.trim() }),
      () => {
        setMotivo("");
        setDialogo(null);
        onCambio();
      },
    );
  }

  function asignar(ev) {
    ev.preventDefault();
    if (!tecnico) return;
    return aplicar(
      () => asignarTecnico(orden.orden_id, tecnico),
      () => {
        setTecnico("");
        setDialogo(null);
        onCambio();
      },
    );
  }

  async function abrirTecnicos() {
    setError(null);
    const r = await listarTecnicos();
    if (r.ok) {
      setTecnicos(r.datos);
      setDialogo("tecnico");
    } else {
      setError(r.mensaje || "No se pudo cargar la lista de técnicos");
    }
  }

  // Cerrada (ENTREGADO, ANULADO) no se mueve, no se rechaza y no se asigna.
  if (!estaAbierta(orden.estado)) return null;

  return (
    <div className="card od-acciones">
      {opciones.length > 0 && (
        <form className="od-avanzar" onSubmit={avanzar}>
          <label htmlFor="avanzar-a">
            Avanzar a:
            <select id="avanzar-a" className="campo" value={destino} onChange={(ev) => setDestino(ev.target.value)}>
              <option value="">Elegir estado</option>
              {opciones.map((e) => (
                <option key={e.codigo} value={e.codigo}>
                  {e.nombre}
                </option>
              ))}
            </select>
          </label>
          <label htmlFor="avanzar-cmt">
            Comentario
            <input
              id="avanzar-cmt"
              className="campo"
              value={comentario}
              onChange={(ev) => setComentario(ev.target.value)}
              placeholder="Va a la bitácora (opcional)"
            />
          </label>
          <button type="submit" className="btn principal" disabled={!destino || enviando}>
            Avanzar
          </button>
        </form>
      )}

      {puedeRechazar && (
        <button type="button" className="btn peligro" onClick={() => setDialogo("rechazar")}>
          Rechazar
        </button>
      )}
      {JEFE.includes(rol) && (
        <button type="button" className="btn suave" onClick={abrirTecnicos}>
          Asignar técnico
        </button>
      )}
      {error && (
        <p role="alert" className="aviso mal">
          {error}
        </p>
      )}

      {dialogo === "rechazar" && (
        <Modal titulo="Rechazar orden" cerrar={() => setDialogo(null)}>
          <form onSubmit={rechazar}>
            <label htmlFor="rechazar-motivo">
              Motivo
              <textarea
                id="rechazar-motivo"
                className="campo"
                rows={3}
                placeholder="Motivo del rechazo"
                value={motivo}
                onChange={(ev) => setMotivo(ev.target.value)}
              />
            </label>
            <button type="submit" className="btn peligro" disabled={enviando || motivo.trim().length < MOTIVO_MIN}>
              Rechazar orden
            </button>
          </form>
        </Modal>
      )}

      {dialogo === "tecnico" && (
        <Modal titulo="Asignar técnico" cerrar={() => setDialogo(null)}>
          <form onSubmit={asignar}>
            <label htmlFor="asignar-tecnico">
              Técnico
              <select id="asignar-tecnico" className="campo" value={tecnico} onChange={(ev) => setTecnico(ev.target.value)}>
                <option value="">Elegir técnico</option>
                {tecnicos.map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.full_name}
                  </option>
                ))}
              </select>
            </label>
            <button type="submit" className="btn principal" disabled={enviando || !tecnico}>
              Asignar
            </button>
          </form>
        </Modal>
      )}
    </div>
  );
}

export default function OrdenDetalle() {
  const { id } = useParams();
  const { rol } = useAuth();
  const [orden, setOrden] = useState(null);
  const [error, setError] = useState(null);
  const [pestana, setPestana] = useState("Resumen");

  const cargar = useCallback(() => {
    obtenerOrden(id).then((r) => {
      if (r.ok) {
        setOrden(r.datos);
        setError(null);
      } else {
        setError(r.mensaje || "No se pudo cargar la orden");
      }
    });
  }, [id]);

  useEffect(() => {
    cargar();
  }, [cargar]);

  if (error) {
    return (
      <p role="alert" className="aviso-error">
        {error}
      </p>
    );
  }
  if (!orden) return <p role="status">Cargando orden…</p>;

  const cob = cobertura(orden.cobertura);
  const tonoCob = { resuelto: "ok", adverso: "mal", progreso: "ambar", neutro: "neutro" }[cob.tono] ?? "neutro";
  const iniciales =
    (orden.cliente ?? "")
      .replace(/[^A-Za-zÁÉÍÓÚáéíóúÑñ ]/g, "")
      .trim()
      .split(/\s+/)
      .slice(0, 2)
      .map((x) => x[0])
      .join("")
      .toUpperCase() || "?";
  return (
    <>
      <p className="ruta">
        <Link to="/taller">Taller</Link> / <strong>{orden.numero_orden}</strong>
      </p>
      <header className="od-cab">
        <div>
          <h1>{orden.numero_orden}</h1>
          <p className="sub">
            {orden.producto} · <span className="mono">{orden.serial}</span>
          </p>
        </div>
        <div className="od-badges">
          <p className="ins" data-t="neutro">
            <i />
            {orden.estado_nombre}
          </p>
          <span className="ins" data-t={tonoCob}>
            <i />
            {cob.nombre}
          </span>
          <span className="ins" data-t="neutro">
            <i />
            Atención: {ATENCION[orden.tipo_atencion] ?? orden.tipo_atencion}
          </span>
        </div>
      </header>

      <Acciones orden={orden} rol={rol} onCambio={cargar} />

      <BarraEstados estado={orden.estado} tipoAtencion={orden.tipo_atencion} tieneDiagnostico={Boolean(orden.diagnostico)} />

      <div className="od-dos">
        <section className="card" aria-label="Detalle de la orden">
          <div role="tablist" aria-label="Secciones de la orden" className="od-pestanas">
            {PESTANAS.map((p) => (
              <button key={p} type="button" role="tab" aria-selected={p === pestana} onClick={() => setPestana(p)}>
                {p}
              </button>
            ))}
          </div>

          <div role="tabpanel" className="od-panel">
            {pestana === "Resumen" && <Resumen o={orden} />}
            {pestana === "Auditoría" && <Auditoria ordenId={orden.orden_id} rol={rol} onCambio={cargar} />}
            {pestana === "Diagnóstico y presupuesto" && <DiagnosticoPresupuesto orden={orden} onCambio={cargar} />}
            {pestana === "Documentos" && <Documentos ordenId={orden.orden_id} />}
            {pestana === "Bitácora" && <Bitacora ordenId={orden.orden_id} />}
          </div>
        </section>

        <aside className="od-lado">
          <section className="card" aria-label="Garantía de la orden">
            <h2>Garantía</h2>
            <p className="gar-n">{cob.nombre}</p>
            <p className="s">Atención {ATENCION[orden.tipo_atencion] ?? orden.tipo_atencion}</p>
          </section>
          <section className="card" aria-label="Cliente de la orden">
            <h2>Cliente</h2>
            <div className="od-cli-cab">
              <span className="avatar" aria-hidden="true">
                {iniciales}
              </span>
              <div>
                <b>{orden.cliente}</b>
                <small>{orden.documento}</small>
              </div>
            </div>
          </section>
        </aside>
      </div>
    </>
  );
}
