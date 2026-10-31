/**
 * Registrar garantía (maqueta 02, /garantias/nueva): cliente → productos →
 * compra → documentos → resumen, con resumen en vivo. Solo el registro
 * posterior a la venta: revisar el equipo es cosa del Taller. La base decide
 * los permisos; los avisos del plazo solo adelantan su respuesta.
 * Documentos: se suben a cada garantía registrada (`equipos/{id}/…`) al confirmar;
 * si una subida falla, la garantía ya existe y se reintentan solo los archivos.
 */
import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { Check, Info, Plus, Trash2 } from "lucide-react";
import { useAuth } from "../auth/AuthContext.jsx";
import { normalizarDocumento, normalizarSerie } from "../registro/normalizar.js";
import PasoAdjuntos from "../registro/pasos/PasoAdjuntos.jsx";
import { buscarCliente, guardarCliente, listarProductos } from "../registro/registroService.js";
import { registrarGarantia, subirDocumentosEquipo } from "./garantiasService.js";

const PASOS = ["Cliente", "Productos", "Compra", "Documentos", "Resumen"];
const TIPOS = ["V", "E", "J", "G", "P"];
const ROLES_JEFATURA = ["ADMIN", "JEFE_SERVICIO"];
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const DIA = 86400000;

const hoyIso = () => new Date().toLocaleDateString("sv");
const aMs = (iso) => Date.parse(`${iso}T00:00:00Z`);
const nombreMarca = (p) => p.marca?.nombre ?? p.marca;
let contador = 0;
const nuevoItem = (serial = "") => ({ uid: ++contador, marca: "", productoId: "", serial });

/** Vencimiento (el día exacto cuenta como vigente); la cobertura real la decide la base. */
function vencimiento(fecha, plazo) {
  if (!fecha || !plazo) return null;
  const vence = aMs(fecha) + plazo * DIA;
  return { iso: new Date(vence).toISOString().slice(0, 10), dias: Math.round((vence - aMs(hoyIso())) / DIA) };
}

const fechaLarga = (iso) =>
  iso ? new Date(`${iso}T00:00:00`).toLocaleDateString("es", { day: "numeric", month: "short", year: "numeric" }) : "—";

export default function NuevaGarantia({ origen: origenPorDefecto = "VENTA" }) {
  const { rol } = useAuth();
  const navigate = useNavigate();
  const [params] = useSearchParams();
  // La Consulta manda aquí con ?serial=…&origen=TALLER cuando no halla el equipo.
  const origen = params.get("origen") === "TALLER" ? "TALLER" : origenPorDefecto;
  const esJefatura = ROLES_JEFATURA.includes(rol);

  const [paso, setPaso] = useState(0);
  const [alcanzado, setAlcanzado] = useState(0);
  const [c, setC] = useState({ tipo: "", doc: "", nombre: "", email: "", telefono: "", id: null });
  const [productos, setProductos] = useState([nuevoItem(params.get("serial") ?? "")]);
  const [catalogo, setCatalogo] = useState([]);
  const [compra, setCompra] = useState({ sinSoporte: false, numero: "", fecha: "", plazo: "", otro: "" });
  const [buscando, setBuscando] = useState(false);
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState(null);
  const [hechas, setHechas] = useState(null);
  const [adjuntos, setAdjuntos] = useState([]);
  const [registradas, setRegistradas] = useState([]); // de intentos anteriores: no se repiten
  const [docsPend, setDocsPend] = useState([]); // [{ equipoId, serial, lista }]
  const [reintentando, setReintentando] = useState(false);
  const ultimaBusqueda = useRef("");

  useEffect(() => {
    let vivo = true;
    listarProductos().then((r) => vivo && r.ok && setCatalogo(r.datos));
    return () => {
      vivo = false;
    };
  }, []);

  const marcas = [...new Set(catalogo.map(nombreMarca))];
  const plazoDias = compra.plazo === "otro" ? Number(compra.otro) || null : Number(compra.plazo) || null;
  const venc = compra.sinSoporte ? null : vencimiento(compra.fecha, plazoDias);
  const hoy = hoyIso();

  // ---- validación por paso (la base vuelve a validar todo) ----
  const errCliente = {
    doc: c.doc && c.doc.length < 5 ? "El documento necesita al menos 5 dígitos" : null,
    email: c.email && !EMAIL.test(c.email) ? "Escribe un correo válido" : null,
  };
  const clienteOk =
    c.doc.length >= 5 && c.nombre.trim().length >= 2 && Boolean(c.tipo) && (c.id ? true : EMAIL.test(c.email));
  const seriales = productos.map((p) => normalizarSerie(p.serial));
  const repetido = (i) => seriales[i] && seriales.indexOf(seriales[i]) !== i;
  const productosOk = productos.every((p, i) => p.productoId && p.serial.trim().length >= 3 && !repetido(i));
  const compraOk =
    compra.sinSoporte ||
    (compra.numero.trim() && compra.fecha && compra.fecha <= hoy && plazoDias && (esJefatura || [7, 15].includes(plazoDias)));
  const validos = [clienteOk, productosOk, Boolean(compraOk), true, true];

  function ir(n) {
    setPaso(n);
    setAlcanzado((a) => Math.max(a, n));
    setError(null);
  }

  async function alEscribirDocumento(valor) {
    const { tipo, documento } = normalizarDocumento(valor);
    setC((s) => ({ ...s, doc: documento, tipo: tipo ?? s.tipo, id: null }));
    ultimaBusqueda.current = documento;
    if (documento.length < 5) return;
    setBuscando(true);
    const r = await buscarCliente(documento);
    setBuscando(false);
    // Una respuesta tardía de un documento que ya se cambió no debe pisar el actual.
    if (ultimaBusqueda.current !== documento || !r.ok || !r.datos) return;
    setC((s) => ({
      ...s,
      id: r.datos.id,
      tipo: r.datos.tipo_documento ?? s.tipo,
      nombre: r.datos.nombre ?? "",
      email: r.datos.email ?? "",
      telefono: r.datos.telefono ?? "",
    }));
  }

  const cambiarItem = (uid, parcial) =>
    setProductos((ps) => ps.map((p) => (p.uid === uid ? { ...p, ...parcial } : p)));

  async function registrar() {
    setEnviando(true);
    setError(null);
    let clienteId = c.id;
    if (!clienteId) {
      const r = await guardarCliente({
        tipo: c.tipo,
        documento: c.doc,
        nombre: c.nombre.trim(),
        telefono: c.telefono.trim() || null,
        email: c.email.trim() || null,
      });
      if (!r.ok) {
        setEnviando(false);
        return setError(r.mensaje || "No se pudo guardar el titular");
      }
      clienteId = r.datos;
      setC((s) => ({ ...s, id: clienteId }));
    }
    const hechasAhora = [];
    const fallidos = [];
    for (const p of productos) {
      const r = await registrarGarantia({
        clienteId,
        productoId: p.productoId,
        serial: p.serial.trim(),
        tipoSoporte: compra.sinSoporte ? null : "FACTURA",
        numeroSoporte: compra.sinSoporte ? null : compra.numero.trim(),
        fechaEmision: compra.sinSoporte ? null : compra.fecha,
        plazoDias: compra.sinSoporte ? null : plazoDias,
        origen,
      });
      if (r.ok) {
        hechasAhora.push({
          serial: p.serial.trim(),
          producto: `${p.marca} ${catalogo.find((x) => x.id === p.productoId)?.modelo ?? ""}`.trim(),
          equipoId: r.datos?.equipo_id ?? null,
          vence: r.datos?.vence_el ?? null,
          nuevo: r.datos?.equipo_nuevo !== false,
        });
      }
      else fallidos.push({ p, mensaje: r.mensaje || "No se pudo registrar" });
    }
    const acumuladas = [...registradas, ...hechasAhora];
    if (fallidos.length === 0) {
      // Todo registrado: ahora los documentos, a cada garantía.
      const pendientes = [];
      for (const h of acumuladas) {
        if (!h.equipoId || adjuntos.length === 0) continue;
        const lista = await subirDocumentosEquipo(h.equipoId, adjuntos);
        if (lista.length) pendientes.push({ equipoId: h.equipoId, serial: h.serial, lista });
      }
      setDocsPend(pendientes);
      setEnviando(false);
      return setHechas(acumuladas);
    }
    setEnviando(false);
    // Los que sí se registraron salen de la lista: reintentar no los repite (sus documentos suben al final).
    setRegistradas(acumuladas);
    setProductos(fallidos.map((f) => f.p));
    setError(
      `${fallidos.map((f) => `${f.p.serial}: ${f.mensaje}`).join(" · ")}` +
        (hechasAhora.length ? ` (ya registradas: ${hechasAhora.map((h) => h.serial).join(", ")})` : ""),
    );
  }

  async function reintentarDocumentos() {
    setReintentando(true);
    const quedan = [];
    for (const d of docsPend) {
      const lista = await subirDocumentosEquipo(d.equipoId, d.lista);
      if (lista.length) quedan.push({ ...d, lista });
    }
    setDocsPend(quedan);
    setReintentando(false);
  }

  function reiniciar() {
    setHechas(null);
    setPaso(0);
    setAlcanzado(0);
    setC({ tipo: "", doc: "", nombre: "", email: "", telefono: "", id: null });
    setProductos([nuevoItem()]);
    setCompra({ sinSoporte: false, numero: "", fecha: "", plazo: "", otro: "" });
    setAdjuntos([]);
    setRegistradas([]);
    setDocsPend([]);
    setError(null);
  }

  if (hechas) {
    const porConfirmar = origen === "TALLER" || compra.sinSoporte;
    const estadoDe = (h) => {
      if (porConfirmar || !h.vence) return ["neutro", "Por confirmar"];
      const dias = Math.round((aMs(h.vence) - aMs(hoyIso())) / DIA);
      return dias < 0 ? ["mal", "Vencida"] : dias <= 3 ? ["ambar", "Por vencer"] : ["ok", "Vigente"];
    };
    const primera = hechas[0];
    return (
      <>
        <p className="ruta">
          <Link to="/garantias">Garantías</Link> / <strong>Registrar garantía</strong>
        </p>
        <section className="exito" aria-label="Garantía registrada">
          <div className="exito-sello">
            <Check size={40} strokeWidth={3} aria-hidden="true" />
          </div>
          <h1>{hechas.length === 1 ? "Garantía registrada" : `${hechas.length} garantías registradas`}</h1>
          <p className="exito-sub">
            {porConfirmar
              ? "Quedó por confirmar: un jefe debe validar la compra con Ventas antes de darla por cubierta."
              : "La cobertura ya corre desde la fecha de emisión. Puedes consultarla o abrir una orden en Taller cuando haga falta."}
          </p>

          {docsPend.length > 0 && (
            <p className="aviso ambar exito-aviso" role="status">
              <Info size={16} aria-hidden="true" />
              <span>
                Las garantías quedaron registradas, pero {docsPend.reduce((n, d) => n + d.lista.length, 0)} documento(s) no se subieron.{" "}
                <button type="button" className="btn chico" disabled={reintentando} onClick={reintentarDocumentos}>
                  {reintentando ? "Reintentando…" : "Reintentar documentos"}
                </button>
              </span>
            </p>
          )}

          <dl className="exito-datos">
            <div>
              <dt>Titular</dt>
              <dd>
                {c.nombre}
                <span className="s">
                  {c.tipo}-{c.doc}
                </span>
              </dd>
            </div>
            <div>
              <dt>Factura</dt>
              <dd>
                {compra.sinSoporte ? "Sin soporte de compra" : compra.numero}
                {!compra.sinSoporte && (
                  <span className="s">
                    Emitida {fechaLarga(compra.fecha)} · plazo {plazoDias} días
                  </span>
                )}
              </dd>
            </div>
            <div>
              <dt>Documentos</dt>
              <dd>{adjuntos.length ? `${adjuntos.length} adjunto${adjuntos.length === 1 ? "" : "s"} vinculado${adjuntos.length === 1 ? "" : "s"}` : "Sin documentos"}</dd>
            </div>
            <div>
              <dt>Origen</dt>
              <dd>{origen === "TALLER" ? "Registrada en taller" : "Registrada tras la venta"}</dd>
            </div>
          </dl>

          <ul className="exito-items" aria-label="Garantías registradas">
            {hechas.map((h) => {
              const [tono, texto] = estadoDe(h);
              return (
                <li key={h.serial}>
                  <div>
                    <b>{h.producto || "Equipo"}</b>
                    <span className="s mono">{h.serial}</span>
                  </div>
                  <div className="exito-vence">
                    <span className="ins" data-t={tono}>
                      <i />
                      {texto}
                    </span>
                    <span className="s">{h.nuevo ? (h.vence ? `Vence el ${fechaLarga(h.vence)}` : "Vencimiento por determinar") : "Ya estaba registrado"}</span>
                  </div>
                </li>
              );
            })}
          </ul>

          <div className="exito-acc">
            <button type="button" className="btn principal" onClick={() => navigate(`/garantias/consulta?serial=${encodeURIComponent(primera.serial)}`)}>
              Ver garantía
            </button>
            {primera.equipoId && hechas.length === 1 && (
              <button type="button" className="btn suave" onClick={() => navigate(`/taller/nueva?equipo=${primera.equipoId}`)}>
                Abrir orden de servicio
              </button>
            )}
            <button type="button" className="btn suave" onClick={reiniciar}>
              Registrar otra garantía
            </button>
            <button type="button" className="btn enlace-texto" onClick={() => navigate("/garantias")}>
              Ir al tablero
            </button>
          </div>
        </section>
      </>
    );
  }

  const modelo = (p) => catalogo.find((x) => x.id === p.productoId);

  return (
    <>
      <p className="ruta">
        <Link to="/garantias">Garantías</Link> / <strong>Nueva garantía</strong>
      </p>
      <div className="wz-enc">
        <h1>Registrar garantía</h1>
        <p className="sub">
          Para equipos ya vendidos: titular, productos, factura y plazo. La revisión del equipo se hace después, al abrir una
          orden en Taller.
        </p>
      </div>

      <div className="wz-grid">
        <section className="card" aria-label="Asistente de registro de garantía">
          <ol className="wz-pasos" aria-label="Pasos">
            {PASOS.map((p, i) => (
              <li key={p} className={i < paso ? "hecho" : undefined} aria-current={i === paso ? "step" : undefined}>
                <button type="button" disabled={i > alcanzado} onClick={() => ir(i)}>
                  {p}
                </button>
              </li>
            ))}
          </ol>

          <div className="wz-panel">
            {paso === 0 && (
              <>
                <h2>Titular de la garantía</h2>
                <p className="wz-ayuda">Si el documento ya existe, se traen sus datos. El correo es obligatorio: ahí llegan los avisos.</p>
                {c.id && (
                  <p className="aviso ok" role="status">
                    <Check size={16} aria-hidden="true" />
                    <span>
                      Titular encontrado: <b>{c.nombre}</b>
                    </span>
                  </p>
                )}
                <div className="wz-cols">
                  <div className="wz-f">
                    <span className="wz-lbl">Documento</span>
                    <div className="wz-doc">
                      <select className="campo" aria-label="Tipo de documento" value={c.tipo} onChange={(e) => setC({ ...c, tipo: e.target.value, id: null })}>
                        <option value="">Tipo</option>
                        {TIPOS.map((t) => (
                          <option key={t} value={t}>
                            {t}
                          </option>
                        ))}
                      </select>
                      <input
                        className="campo"
                        aria-label="Número de documento"
                        inputMode="numeric"
                        autoComplete="off"
                        value={c.doc}
                        onChange={(e) => alEscribirDocumento(e.target.value)}
                        aria-invalid={Boolean(errCliente.doc)}
                      />
                    </div>
                    {errCliente.doc && <p className="wz-err">{errCliente.doc}</p>}
                    {buscando && <p className="wz-hint">Buscando titular…</p>}
                  </div>
                  <div className="wz-f">
                    <label htmlFor="ng-nombre">Nombre o razón social</label>
                    <input id="ng-nombre" className="campo" value={c.nombre} disabled={Boolean(c.id)} onChange={(e) => setC({ ...c, nombre: e.target.value })} />
                  </div>
                  <div className="wz-f">
                    <label htmlFor="ng-email">Correo electrónico</label>
                    <input
                      id="ng-email"
                      type="email"
                      className="campo"
                      autoComplete="off"
                      value={c.email}
                      disabled={Boolean(c.id)}
                      onChange={(e) => setC({ ...c, email: e.target.value })}
                      aria-invalid={Boolean(errCliente.email)}
                    />
                    {errCliente.email && <p className="wz-err">{errCliente.email}</p>}
                    {c.id && !c.email && <p className="wz-hint">Este titular no tiene correo registrado.</p>}
                  </div>
                  <div className="wz-f">
                    <label htmlFor="ng-tel">
                      Teléfono <span className="op">(opcional)</span>
                    </label>
                    <input id="ng-tel" type="tel" className="campo" value={c.telefono} disabled={Boolean(c.id)} onChange={(e) => setC({ ...c, telefono: e.target.value })} />
                  </div>
                </div>
              </>
            )}

            {paso === 1 && (
              <>
                <h2>Productos</h2>
                <p className="wz-ayuda">Cada equipo genera su propia garantía; comparten factura y plazo.</p>
                {productos.map((p, i) => (
                  <div className="wz-item" key={p.uid}>
                    <div className="wz-item-cab">
                      <h3>Producto {i + 1}</h3>
                      {productos.length > 1 && (
                        <button type="button" className="btn chico" onClick={() => setProductos(productos.filter((x) => x.uid !== p.uid))}>
                          <Trash2 size={14} aria-hidden="true" />
                          Quitar<span className="sr"> producto {i + 1}</span>
                        </button>
                      )}
                    </div>
                    <div className="wz-cols3">
                      <div className="wz-f">
                        <label htmlFor={`ng-marca-${p.uid}`}>Marca</label>
                        <select id={`ng-marca-${p.uid}`} className="campo" value={p.marca} onChange={(e) => cambiarItem(p.uid, { marca: e.target.value, productoId: "" })}>
                          <option value="">—</option>
                          {marcas.map((m) => (
                            <option key={m} value={m}>
                              {m}
                            </option>
                          ))}
                        </select>
                      </div>
                      <div className="wz-f">
                        <label htmlFor={`ng-modelo-${p.uid}`}>Modelo</label>
                        <select id={`ng-modelo-${p.uid}`} className="campo" value={p.productoId} disabled={!p.marca} onChange={(e) => cambiarItem(p.uid, { productoId: e.target.value })}>
                          <option value="">—</option>
                          {catalogo
                            .filter((x) => nombreMarca(x) === p.marca)
                            .map((x) => (
                              <option key={x.id} value={x.id}>
                                {x.modelo}
                              </option>
                            ))}
                        </select>
                      </div>
                      <div className="wz-f">
                        <label htmlFor={`ng-serial-${p.uid}`}>Serial</label>
                        <input
                          id={`ng-serial-${p.uid}`}
                          className="campo mono"
                          autoComplete="off"
                          placeholder="Escanea o escribe el serial"
                          value={p.serial}
                          onChange={(e) => cambiarItem(p.uid, { serial: e.target.value })}
                          aria-invalid={Boolean(repetido(i))}
                        />
                        {repetido(i) && <p className="wz-err">Este serial está repetido en la lista</p>}
                      </div>
                    </div>
                  </div>
                ))}
                <button type="button" className="btn punteado" onClick={() => setProductos([...productos, nuevoItem()])}>
                  <Plus size={16} aria-hidden="true" />
                  Agregar otro producto
                </button>
              </>
            )}

            {paso === 2 && (
              <>
                <h2>Datos de la compra</h2>
                <p className="wz-ayuda">Factura y plazo valen para todos los productos. El plazo es de 7 o 15 días desde la emisión.</p>
                <label className="wz-check">
                  <input
                      type="checkbox"
                      checked={compra.sinSoporte}
                    onChange={(e) => setCompra({ ...compra, sinSoporte: e.target.checked })}
                  />
                  No trae la factura ni la nota de entrega
                </label>
                {compra.sinSoporte ? (
                  <p className="aviso ambar" role="status">
                    <Info size={16} aria-hidden="true" />
                    <span>Sin soporte de compra la cobertura queda por determinar hasta que un jefe la confirme con Ventas.</span>
                  </p>
                ) : (
                  <>
                    <div className="wz-cols">
                      <div className="wz-f">
                        <label htmlFor="ng-factura">N.º de factura</label>
                        <input id="ng-factura" className="campo mono" autoComplete="off" value={compra.numero} onChange={(e) => setCompra({ ...compra, numero: e.target.value })} />
                      </div>
                      <div className="wz-f">
                        <label htmlFor="ng-fecha">Fecha de emisión</label>
                        <input
                          id="ng-fecha"
                          type="date"
                          className="campo"
                          max={hoy}
                          value={compra.fecha}
                          onChange={(e) => setCompra({ ...compra, fecha: e.target.value })}
                          aria-invalid={Boolean(compra.fecha && compra.fecha > hoy)}
                        />
                        {compra.fecha > hoy && <p className="wz-err">La fecha no puede ser futura</p>}
                      </div>
                      <div className="wz-f wz-ancho">
                        <span className="wz-lbl" id="ng-plazo-et">
                          Plazo de garantía
                        </span>
                        <div className="seg eq" role="radiogroup" aria-labelledby="ng-plazo-et">
                          {[
                            ["7", "7 días", "plazo estándar"],
                            ["15", "15 días", "plazo extendido"],
                          ].map(([v, t, s]) => (
                            <label key={v}>
                              <input type="radio" name="plazo" value={v} checked={compra.plazo === v} onChange={() => setCompra({ ...compra, plazo: v })} />
                              <span>
                                {t}
                                <small>{s}</small>
                              </span>
                            </label>
                          ))}
                          <label title={esJefatura ? undefined : "Solo ADMIN o JEFE_SERVICIO fijan otro plazo"}>
                            <input type="radio" name="plazo" value="otro" disabled={!esJefatura} checked={compra.plazo === "otro"} onChange={() => setCompra({ ...compra, plazo: "otro" })} />
                            <span>
                              Otro plazo
                              <small>{esJefatura ? "de 1 a 365 días" : "solo jefatura"}</small>
                            </span>
                          </label>
                        </div>
                      </div>
                      {compra.plazo === "otro" && (
                        <div className="wz-f wz-ancho">
                          <label htmlFor="ng-otro">Días de garantía</label>
                          <input id="ng-otro" type="number" min="1" max="365" className="campo" value={compra.otro} onChange={(e) => setCompra({ ...compra, otro: e.target.value })} />
                        </div>
                      )}
                    </div>
                    {venc && (
                      <div className="vence" data-t={venc.dias < 0 ? "mal" : venc.dias <= 3 ? "ambar" : "ok"} role="status">
                        <span className="n">{venc.dias < 0 ? Math.abs(venc.dias) : venc.dias}</span>
                        <p>
                          {venc.dias < 0 ? (
                            <>
                              días desde que <strong>venció el {fechaLarga(venc.iso)}</strong>: nace vencida y se atenderá como servicio pago.
                            </>
                          ) : (
                            <>
                              días restantes · <strong>vence el {fechaLarga(venc.iso)}</strong>
                            </>
                          )}
                        </p>
                      </div>
                    )}
                  </>
                )}
              </>
            )}

            {paso === 3 && (
              <>
                <h2>Documentos</h2>
                <p className="wz-ayuda">
                  Factura escaneada, PDF de la venta con el plazo y fotos. Son recomendados, no obligatorios: PDF, JPG o PNG de hasta 8 MB
                  (fotos: hasta 8; documentos: hasta 6). Se vinculan a {productos.length > 1 ? "cada una de las garantías" : "la garantía"}.
                </p>
                <PasoAdjuntos estado={{ archivosAdjuntos: adjuntos }} actualizar={(p) => setAdjuntos(p.archivosAdjuntos)} />
              </>
            )}

            {paso === 4 && (
              <>
                <h2>Revisa y confirma</h2>
                <p className="wz-ayuda">Comprueba los datos. Con «Editar» vuelves al paso correspondiente.</p>
                {origen === "TALLER" && (
                  <p className="aviso ambar">
                    <Info size={16} aria-hidden="true" />
                    <span>Registro desde el taller: queda por confirmar hasta que un jefe lo valide con Ventas.</span>
                  </p>
                )}
                <dl className="wz-res">
                  <div>
                    <dt>
                      Titular
                      <button type="button" className="wz-ed" onClick={() => ir(0)}>
                        Editar<span className="sr"> titular</span>
                      </button>
                    </dt>
                    <dd>
                      {c.nombre}
                      <span className="s">
                        {c.tipo}-{c.doc} · {c.email || "sin correo"}
                      </span>
                    </dd>
                  </div>
                  <div>
                    <dt>
                      Productos
                      <button type="button" className="wz-ed" onClick={() => ir(1)}>
                        Editar<span className="sr"> productos</span>
                      </button>
                    </dt>
                    <dd>
                      <ul>
                        {productos.map((p) => (
                          <li key={p.uid}>
                            {p.marca} {modelo(p)?.modelo}
                            <span className="s mono">{p.serial}</span>
                          </li>
                        ))}
                      </ul>
                    </dd>
                  </div>
                  <div>
                    <dt>
                      Compra
                      <button type="button" className="wz-ed" onClick={() => ir(2)}>
                        Editar<span className="sr"> compra</span>
                      </button>
                    </dt>
                    <dd>
                      {compra.sinSoporte ? (
                        "Sin soporte de compra"
                      ) : (
                        <>
                          Factura {compra.numero}
                          <span className="s">
                            Emitida {fechaLarga(compra.fecha)} · plazo {plazoDias} días{venc ? ` · vence ${fechaLarga(venc.iso)}` : ""}
                          </span>
                        </>
                      )}
                    </dd>
                  </div>
                  <div>
                    <dt>
                      Documentos
                      <button type="button" className="wz-ed" onClick={() => ir(3)}>
                        Editar<span className="sr"> documentos</span>
                      </button>
                    </dt>
                    <dd>
                      {adjuntos.length
                        ? `${adjuntos.filter((a) => a.tipo === "DOCUMENTO").length} documentos · ${adjuntos.filter((a) => a.tipo === "FOTO").length} fotos`
                        : "Sin documentos"}
                    </dd>
                  </div>
                </dl>
                {error && (
                  <p role="alert" className="aviso mal">
                    {error}
                  </p>
                )}
              </>
            )}
          </div>

          <div className="wz-pie">
            <button type="button" className="btn suave" disabled={paso === 0} onClick={() => ir(paso - 1)}>
              Atrás
            </button>
            <div className="bt">
              {paso < 4 ? (
                <button type="button" className="btn principal" disabled={!validos[paso]} onClick={() => ir(paso + 1)}>
                  Siguiente
                </button>
              ) : (
                <button type="button" className="btn principal" disabled={enviando} onClick={registrar}>
                  {enviando ? "Registrando…" : productos.length > 1 ? `Registrar ${productos.length} garantías` : "Registrar garantía"}
                </button>
              )}
            </div>
          </div>
        </section>

        <aside className="card wz-vivo" aria-label="Resumen de la garantía">
          <h2>Resumen</h2>
          <dl>
            <div>
              <dt>Titular</dt>
              <dd>{c.nombre ? <>{c.nombre}<span className="s">{c.tipo}-{c.doc}</span></> : <span className="nada">Sin completar</span>}</dd>
            </div>
            <div>
              <dt>Productos</dt>
              <dd>
                {productos.some((p) => p.productoId || p.serial) ? (
                  productos.map((p) => (
                    <div key={p.uid}>
                      {p.marca} {modelo(p)?.modelo ?? ""}
                      <span className="s mono">{p.serial || "sin serial"}</span>
                    </div>
                  ))
                ) : (
                  <span className="nada">Sin completar</span>
                )}
              </dd>
            </div>
            <div>
              <dt>Compra</dt>
              <dd>
                {compra.sinSoporte ? "Sin soporte" : compra.numero ? <>Factura {compra.numero}<span className="s">{compra.fecha ? `Emitida ${fechaLarga(compra.fecha)}` : ""}</span></> : <span className="nada">Sin completar</span>}
              </dd>
            </div>
            <div>
              <dt>Vigencia</dt>
              <dd>
                {venc ? (
                  <span className="ins" data-t={venc.dias < 0 ? "mal" : venc.dias <= 3 ? "ambar" : "ok"}>
                    <i />
                    {venc.dias < 0 ? "Vencida" : `Vence el ${fechaLarga(venc.iso)}`}
                  </span>
                ) : (
                  <span className="nada">{compra.sinSoporte ? "Por determinar" : "Sin completar"}</span>
                )}
              </dd>
            </div>
          </dl>
        </aside>
      </div>
    </>
  );
}
