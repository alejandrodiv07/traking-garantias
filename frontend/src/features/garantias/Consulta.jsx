/**
 * Consulta de garantía (maqueta 03, /garantias/consulta): un solo buscador
 * (serial, cédula/RIF, factura u orden → `buscar_equipo`, que combina los
 * criterios con OR), la ficha del equipo con su período de cobertura y órdenes,
 * y a la derecha el titular y las acciones (abrir orden; jefatura confirma o
 * desestima la compra). Descarga de documentos: la base no los vincula al
 * equipo todavía (solo a cada orden), así que la tarjeta lo explica.
 */
import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { Box, Download, FileText, Image as ImagenIcono, Info, Lock, Mail, Paperclip, Phone, Search, ShieldCheck, TriangleAlert, User } from "lucide-react";
import { useAuth } from "../auth/AuthContext.jsx";
import { normalizarDocumento } from "../registro/normalizar.js";
import {
  buscarGarantia,
  confirmarCompra,
  desestimarCompra,
  documentosDeEquipo,
  subirDocumentosEquipo,
  urlDocumento,
  verificacionPorEquipo,
} from "./garantiasService.js";
import { ESTADOS, estadoDe } from "./estado.js";
import InsigniaVerificacion from "./InsigniaVerificacion.jsx";
import "./consulta.css";

const ROLES_JEFATURA = ["ADMIN", "JEFE_SERVICIO"];
const MOTIVO_MIN = 10;
const ABIERTAS = ["RECIBIDO", "EN_DIAGNOSTICO", "PRESUPUESTADO", "EN_REPARACION", "REPARADO"];
const TONO_ORDEN = {
  RECIBIDO: "neutro",
  EN_DIAGNOSTICO: "ambar",
  PRESUPUESTADO: "ambar",
  EN_REPARACION: "ambar",
  REPARADO: "ok",
  ENTREGADO: "ok",
  RECHAZADO: "mal",
  ANULADO: "neutro",
};
const MES = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"];

// Las fechas llegan como AAAA-MM-DD (o ISO con hora): se cortan a mano para no mover el día por zona horaria.
function fecha(iso, conAnio = true) {
  if (!iso) return "—";
  const [a, m, d] = iso.slice(0, 10).split("-");
  return `${Number(d)} ${MES[Number(m) - 1]}${conAnio ? ` ${a}` : ""}`;
}

const tamano = (b) => (b >= 1048576 ? `${(b / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(b / 1024))} KB`);
const nombreArchivo = (ruta) => ruta.split("/").pop();

/** Documentos y fotos vinculados a la garantía: lista, descarga con enlace firmado y alta de nuevos. */
function Documentos({ equipoId }) {
  const [estado, setEstado] = useState({ cargando: true });
  const [aviso, setAviso] = useState(null);
  const [subiendo, setSubiendo] = useState(false);

  async function cargar() {
    const r = await documentosDeEquipo(equipoId);
    setEstado(r.ok ? { datos: r.datos } : { error: r.mensaje || "No se pudieron cargar los documentos" });
  }

  useEffect(() => {
    let vivo = true;
    documentosDeEquipo(equipoId).then((r) => {
      if (vivo) setEstado(r.ok ? { datos: r.datos } : { error: r.mensaje || "No se pudieron cargar los documentos" });
    });
    return () => {
      vivo = false;
    };
  }, [equipoId]);

  async function descargar(a) {
    setAviso(null);
    const r = await urlDocumento(a.ruta);
    if (r.ok) window.open(r.datos, "_blank", "noopener");
    else setAviso(r.mensaje || "No se pudo abrir el archivo");
  }

  async function agregar(ev) {
    const archivo = ev.target.files?.[0];
    ev.target.value = "";
    if (!archivo) return;
    setSubiendo(true);
    setAviso(null);
    const fallidos = await subirDocumentosEquipo(equipoId, [{ archivo, tipo: "DOCUMENTO" }]);
    setSubiendo(false);
    if (fallidos.length) setAviso(fallidos[0].mensaje || "No se pudo subir el documento");
    else await cargar();
  }

  const lista = estado.datos ?? [];
  return (
    <section className="card cn-card" aria-label="Documentos vinculados">
      <h2 className="cn-card-h">
        Documentos vinculados
        <span className="cn-cand">
          <Lock size={13} aria-hidden="true" />
          Descarga protegida por rol
        </span>
      </h2>
      {estado.cargando && <p className="cn-vacio-t">Cargando documentos…</p>}
      {estado.error && (
        <p role="alert" className="wz-err">
          {estado.error}
        </p>
      )}
      {estado.datos && lista.length === 0 && <p className="cn-vacio-t">Sin documentos vinculados. Adjunta la factura escaneada o el PDF de la venta.</p>}
      {lista.length > 0 && (
        <ul className="cn-arch" aria-label="Archivos de la garantía">
          {lista.map((a) => {
            const imagen = a.mime?.startsWith("image/");
            return (
              <li key={a.id}>
                <span className={imagen ? "ic img" : "ic"}>
                  {imagen ? <ImagenIcono size={18} aria-hidden="true" /> : <FileText size={18} aria-hidden="true" />}
                </span>
                <span className="tx">
                  <b title={nombreArchivo(a.ruta)}>{nombreArchivo(a.ruta)}</b>
                  <small>
                    {a.tipo === "FOTO" ? "Foto" : "Documento"} · {tamano(a.bytes)} · {fecha(a.subido_en)}
                  </small>
                </span>
                <button type="button" className="ibt" aria-label={`Descargar ${nombreArchivo(a.ruta)}`} onClick={() => descargar(a)}>
                  <Download size={18} aria-hidden="true" />
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {aviso && (
        <p role="alert" className="wz-err cn-arch-err">
          {aviso}
        </p>
      )}
      <label className="btn suave chico cn-agregar">
        <Paperclip size={14} aria-hidden="true" />
        {subiendo ? "Subiendo…" : "Agregar documento"}
        <input type="file" className="sr" accept="application/pdf,image/jpeg,image/png" disabled={subiendo} onChange={agregar} />
      </label>
    </section>
  );
}

const iniciales = (n = "") =>
  n
    .replace(/[^A-Za-zÁÉÍÓÚáéíóúÑñ ]/g, "")
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((p) => p[0])
    .join("")
    .toUpperCase() || "?";

function etiquetaDias(e, clave) {
  const d = e.dias_restantes;
  if (clave === "confirmar") return "Pendiente de confirmar";
  if (clave === "desestimada") return "Fuera de garantía";
  if (d < 0) return `Venció hace ${Math.abs(d)} ${Math.abs(d) === 1 ? "día" : "días"}`;
  if (d === 0) return "Vence hoy";
  return `${d} ${d === 1 ? "día restante" : "días restantes"}`;
}

const pronto = (d) => (d === 0 ? "hoy" : `en ${d} d`);
const AVISO_ORDEN = {
  vigente: () => "La garantía está vigente. Se abre la orden y el equipo se revisa en la recepción.",
  porvencer: (e) => `La garantía está vigente y vence pronto (${pronto(e.dias_restantes)}). Se abre la orden y el equipo se revisa en la recepción.`,
  vencida: (e) => `La garantía venció hace ${Math.abs(e.dias_restantes)} días: la orden se atenderá como servicio pago.`,
  confirmar: () => "La compra todavía no está confirmada: la cobertura queda pendiente. Adjunta la factura que trae el cliente.",
  desestimada: () => "La compra fue desestimada: la orden se atenderá como servicio pago.",
};

/** Confirmar o desestimar la compra de un equipo registrado desde el taller (solo jefatura; la base lo vuelve a exigir). */
function AccionesCompra({ e, puede, onListo }) {
  const [modo, setModo] = useState(null);
  const [numero, setNumero] = useState(e.numero_soporte ?? "");
  const [emision, setEmision] = useState(e.fecha_emision ?? "");
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
    <>
      <button type="button" className="btn suave" disabled={!puede} onClick={() => setModo(modo === "confirmar" ? null : "confirmar")}>
        Confirmar compra
      </button>
      <button type="button" className="btn peligro" disabled={!puede} onClick={() => setModo(modo === "desestimar" ? null : "desestimar")}>
        Desestimar compra
      </button>
      {!puede && (
        <p className="cn-nota">
          <Lock size={13} aria-hidden="true" />
          Confirmar o desestimar lo hace Jefatura o Administración.
        </p>
      )}
      {modo === "confirmar" && (
        <form
          className="cn-conf"
          onSubmit={(ev) => {
            ev.preventDefault();
            enviar(() =>
              confirmarCompra({
                equipoId: e.equipo_id,
                tipoSoporte: "FACTURA",
                numeroSoporte: numero.trim(),
                fechaEmision: emision,
                plazoDias: Number(plazo),
              }),
            );
          }}
        >
          <p>Comprueba la factura contra la venta real. Al confirmar, las órdenes abiertas recalculan su cobertura.</p>
          <div className="wz-f">
            <label htmlFor={`num-${e.equipo_id}`}>Número de factura</label>
            <input id={`num-${e.equipo_id}`} className="campo" value={numero} onChange={(ev) => setNumero(ev.target.value)} />
          </div>
          <div className="wz-f">
            <label htmlFor={`fec-${e.equipo_id}`}>Fecha de emisión</label>
            <input id={`fec-${e.equipo_id}`} type="date" className="campo" value={emision} onChange={(ev) => setEmision(ev.target.value)} />
          </div>
          <div className="wz-f">
            <label htmlFor={`pla-${e.equipo_id}`}>Plazo (días)</label>
            <input id={`pla-${e.equipo_id}`} type="number" min="1" className="campo" value={plazo} onChange={(ev) => setPlazo(ev.target.value)} />
          </div>
          <div className="cn-bt">
            <button type="submit" className="btn principal chico" disabled={enviando || !numero.trim() || !emision || !plazo}>
              Confirmar
            </button>
            <button type="button" className="btn suave chico" onClick={() => setModo(null)}>
              Cancelar
            </button>
          </div>
        </form>
      )}
      {modo === "desestimar" && (
        <form
          className="cn-conf"
          onSubmit={(ev) => {
            ev.preventDefault();
            enviar(() => desestimarCompra({ equipoId: e.equipo_id, motivo: motivo.trim() }));
          }}
        >
          <div className="wz-f">
            <label htmlFor={`mot-${e.equipo_id}`}>Motivo (mínimo {MOTIVO_MIN} caracteres)</label>
            <textarea id={`mot-${e.equipo_id}`} className="campo" rows={3} value={motivo} onChange={(ev) => setMotivo(ev.target.value)} />
            {motivo && motivo.trim().length < MOTIVO_MIN && (
              <p className="wz-err">
                Explica el motivo con al menos {MOTIVO_MIN} caracteres ({motivo.trim().length}/{MOTIVO_MIN}).
              </p>
            )}
          </div>
          <div className="cn-bt">
            <button type="submit" className="btn peligro chico" disabled={enviando || motivo.trim().length < MOTIVO_MIN}>
              Desestimar
            </button>
            <button type="button" className="btn suave chico" onClick={() => setModo(null)}>
              Cancelar
            </button>
          </div>
        </form>
      )}
      {error && (
        <p role="alert" className="wz-err">
          {error}
        </p>
      )}
    </>
  );
}

function Ficha({ e, navigate, rol, onCambio }) {
  const [abierto, setAbierto] = useState(false);
  const clave = estadoDe(e);
  const est = ESTADOS[clave];
  const tono = clave === "vigente" ? "ok" : est.t;
  const total = e.plazo_dias || 1;
  const usados = clave === "confirmar" || typeof e.dias_restantes !== "number" ? 0 : Math.min(total, Math.max(0, total - e.dias_restantes));
  const ordenes = e.ordenes ?? [];
  const abierta = ordenes.find((o) => ABIERTAS.includes(o.estado));
  const jefatura = ROLES_JEFATURA.includes(rol);

  return (
    <div className="cn-dos">
      <div>
        {clave === "confirmar" && (
          <p className="aviso">
            <Info size={18} aria-hidden="true" />
            <span>
              <b>Registrada en taller.</b> La compra no se ha confirmado contra la venta real; hasta entonces la cobertura queda por determinar.
            </span>
          </p>
        )}
        {clave === "desestimada" && (
          <p className="aviso mal">
            <TriangleAlert size={18} aria-hidden="true" />
            <span>
              <b>Compra desestimada.</b> Motivo: {e.motivo_desestimacion}
            </span>
          </p>
        )}
        {abierta && (
          <p className="aviso ambar">
            <TriangleAlert size={18} aria-hidden="true" />
            <span>
              Este equipo ya tiene la orden <b>{abierta.numero_orden}</b> abierta ({abierta.estado_nombre}). Abre otra solo si es un ingreso nuevo.
            </span>
          </p>
        )}

        <section className="card cn-card" aria-label="Equipo">
          <div className="cn-eq-cab">
            <span className="cn-eq-ico">
              <Box size={26} aria-hidden="true" />
            </span>
            <div className="cn-eq-tit">
              <h2>{e.producto}</h2>
              <p>
                {e.origen === "TALLER" ? <span className="etiq">Registrada en taller</span> : "Registrada en la venta"}{" "}
                <InsigniaVerificacion valor={e.verificacion} />
              </p>
            </div>
            <span className="ins lg" data-t={tono}>
              <i />
              {est.ficha}
            </span>
          </div>
          <dl className="cn-datos">
            <div>
              <dt>Serial</dt>
              <dd>{e.numero_serie}</dd>
            </div>
            <div>
              <dt>Factura</dt>
              <dd>{e.numero_soporte ?? "—"}</dd>
            </div>
            <div>
              <dt>Comprado</dt>
              <dd>{fecha(e.fecha_emision)}</dd>
            </div>
            <div>
              <dt>Plazo</dt>
              <dd>{e.plazo_dias ? `${e.plazo_dias} días` : "—"}</dd>
            </div>
          </dl>
          <div className="cn-sep" />
          <div className="cn-prog-cab">
            <span>Período de cobertura · {usados} de {total} días consumidos</span>
            <b data-t={tono}>{etiquetaDias(e, clave)}</b>
          </div>
          <progress className="cn-prog" data-t={tono} max={total} value={usados} aria-label="Período de cobertura consumido" />
          <div className="cn-prog-pie">
            <span>Inicio · {fecha(e.fecha_emision)}</span>
            <span>Fin · {fecha(e.vence_el)}</span>
          </div>
        </section>

        <Documentos equipoId={e.equipo_id} />

        <section className="card cn-card" aria-label="Órdenes de servicio del equipo">
          <h2 className="cn-card-h">Órdenes de servicio del equipo</h2>
          {ordenes.length ? (
            <ul className="cn-ords" aria-label="Órdenes del equipo">
              {ordenes.map((o) => (
                <li key={o.numero_orden}>
                  <Link to={`/taller?buscar=${encodeURIComponent(o.numero_orden)}`} className="cn-num">
                    {o.numero_orden}
                  </Link>
                  <span className="cn-f1">
                    {o.tipo_atencion === "GARANTIA" ? "Atención en garantía" : o.tipo_atencion === "PAGO" ? "Servicio pago" : "Atención por determinar"}
                  </span>
                  <span className="ins" data-t={TONO_ORDEN[o.estado] ?? "neutro"}>
                    <i />
                    {o.estado_nombre}
                  </span>
                  <span className="cn-fe">{fecha(o.fecha_ingreso, false)}</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="cn-vacio-t">Este equipo no ha entrado al taller.</p>
          )}
        </section>
      </div>

      <aside>
        <section className="card cn-card" aria-label="Cliente">
          <h2 className="cn-card-t">Cliente</h2>
          <div className="cn-cli-cab">
            <span className="avatar" aria-hidden="true">
              {iniciales(e.titular)}
            </span>
            <div>
              <b>{e.titular}</b>
              <small>{e.tipo_documento ? `${e.tipo_documento}-${e.documento}` : e.documento}</small>
            </div>
          </div>
          <ul className="cn-cont">
            <li>
              <User size={16} aria-hidden="true" />
              {e.titular}
            </li>
            <li>
              <Mail size={16} aria-hidden="true" />
              {e.email ?? "Sin correo"}
            </li>
            <li>
              <Phone size={16} aria-hidden="true" />
              {e.telefono ?? "Sin teléfono"}
            </li>
          </ul>
        </section>

        <section className="card cn-card" aria-label="Acciones">
          <h2 className="cn-card-t">Acciones</h2>
          <div className="cn-acciones">
            <button type="button" className="btn principal" aria-expanded={abierto} aria-controls={`conf-${e.equipo_id}`} onClick={() => setAbierto(!abierto)}>
              Abrir orden de servicio
            </button>
            {abierto && (
              <div className="cn-conf" id={`conf-${e.equipo_id}`}>
                <p>{AVISO_ORDEN[clave](e)}</p>
                <button type="button" className="btn principal chico" onClick={() => navigate(`/taller/nueva?equipo=${e.equipo_id}`)}>
                  Continuar a Taller
                </button>
              </div>
            )}
            {clave === "confirmar" && <AccionesCompra e={e} puede={jefatura} onListo={onCambio} />}
          </div>
        </section>
      </aside>
    </div>
  );
}

export default function Consulta() {
  const navigate = useNavigate();
  const { rol } = useAuth();
  const [params] = useSearchParams();
  const inicial = params.get("q") ?? params.get("serial") ?? "";
  const [valor, setValor] = useState(inicial);
  const [errorBusqueda, setErrorBusqueda] = useState(null);
  const [estado, setEstado] = useState({ fase: "inicio" });
  const [elegido, setElegido] = useState(null);
  const entrada = useRef(null);

  async function ejecutar(texto) {
    const t = texto.trim();
    setElegido(null);
    if (t.length < 3) {
      setErrorBusqueda("Escribe al menos 3 caracteres: serial, cédula o RIF, factura u orden.");
      return;
    }
    setErrorBusqueda(null);
    setEstado({ fase: "buscando" });
    // Una sola llamada: la base combina serial, documento, factura y orden con OR.
    const doc = normalizarDocumento(t).documento;
    const r = await buscarGarantia({
      serial: t,
      factura: t,
      orden: t,
      documento: /^[VEJGP]?[\s.-]?[\d.\s-]{5,}$/i.test(t) && doc.length >= 5 ? doc : null,
    });
    if (!r.ok) return setEstado({ fase: "error", mensaje: r.mensaje });
    // El respaldo de Ventas es informativo: si falla, la ficha sale sin insignia.
    const v = await verificacionPorEquipo(r.datos.map((e) => e.equipo_id));
    const filas = r.datos.map((e) => ({ ...e, verificacion: v.ok ? (v.datos[e.equipo_id] ?? null) : null }));
    setEstado({ fase: "listo", filas, buscado: t });
  }

  // Llegar con ?q= o ?serial= (tras registrar la garantía o desde el tablero) busca sin pulsar nada.
  useEffect(() => {
    if (inicial) ejecutar(inicial);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [inicial]);

  const lista = estado.fase === "listo" ? estado.filas : [];
  const unico = lista.length === 1 ? lista[0] : (lista.find((e) => e.equipo_id === elegido) ?? null);

  return (
    <>
      <p className="ruta">
        <Link to="/garantias">Garantías</Link> / <strong>Consulta</strong>
      </p>
      <div className="enc cn-enc">
        <div>
          <h1>Consulta de garantía</h1>
          <p className="sub">Localiza un equipo por serial, cédula/RIF, n.º de factura o n.º de orden.</p>
        </div>
      </div>

      <form
        className="cn-busca"
        role="search"
        onSubmit={(ev) => {
          ev.preventDefault();
          ejecutar(valor);
        }}
      >
        <div className="cn-busca-c">
          <label className="sr" htmlFor="cn-q">
            Serial, cédula o RIF, factura o número de orden
          </label>
          <Search size={18} aria-hidden="true" />
          <input
            id="cn-q"
            ref={entrada}
            className="campo"
            type="search"
            autoComplete="off"
            placeholder="Serial, cédula/RIF, n.º de factura o n.º de orden"
            value={valor}
            aria-invalid={errorBusqueda ? true : undefined}
            onChange={(ev) => {
              setValor(ev.target.value);
              setErrorBusqueda(null);
            }}
          />
        </div>
        <button type="submit" className="btn principal">
          Buscar
        </button>
      </form>
      {errorBusqueda && (
        <p role="alert" className="wz-err cn-err">
          {errorBusqueda}
        </p>
      )}
      <p className="sr" role="status" aria-live="polite">
        {estado.fase === "listo" ? (lista.length === 0 ? `Sin resultados para ${estado.buscado}` : `${lista.length} equipos encontrados`) : ""}
      </p>

      {estado.fase === "error" && (
        <p role="alert" className="aviso-error">
          {estado.mensaje || "No se pudo consultar"}
        </p>
      )}

      {estado.fase === "listo" && lista.length === 0 && (
        <div className="card cn-vacio-c">
          <ShieldCheck size={36} strokeWidth={1.5} aria-hidden="true" />
          <h2>No hay garantía registrada para «{estado.buscado}»</h2>
          <p>
            Revisa que el serial, la cédula o el RIF y la factura estén bien escritos. Si el equipo se vendió pero no se registró, puedes
            registrarlo ahora: quedará por confirmar hasta que Jefatura lo valide con la venta.
          </p>
          <div className="cn-bt cn-centro">
            <button
              type="button"
              className="btn suave"
              onClick={() => {
                entrada.current?.focus();
                entrada.current?.select();
              }}
            >
              Revisar la búsqueda
            </button>
            <button type="button" className="btn principal" onClick={() => navigate(`/garantias/nueva?serial=${encodeURIComponent(estado.buscado)}&origen=TALLER`)}>
              Registrar ahora
            </button>
          </div>
        </div>
      )}

      {estado.fase === "listo" && lista.length > 1 && !unico && (
        <div className="card cn-card">
          <h2 className="cn-card-h">
            {lista.length} equipos coinciden con «{estado.buscado}»
          </h2>
          <ul className="cn-elige">
            {lista.map((e) => (
              <li key={e.equipo_id}>
                <button type="button" onClick={() => setElegido(e.equipo_id)}>
                  <span>
                    <span className="p">{e.producto}</span>
                    <span className="s mono">
                      {e.numero_serie} · {e.titular}
                    </span>
                  </span>
                  <span className="ins" data-t={ESTADOS[estadoDe(e)].t}>
                    <i />
                    {ESTADOS[estadoDe(e)].ficha}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

      {unico && <Ficha key={unico.equipo_id} e={unico} navigate={navigate} rol={rol} onCambio={() => ejecutar(estado.buscado)} />}
    </>
  );
}
