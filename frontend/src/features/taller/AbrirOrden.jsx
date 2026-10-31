/**
 * Abrir la orden de un equipo ya registrado (maqueta 04, /taller/nueva): equipo
 * → falla → auditoría de recepción (fotos y documentos incluidos), con resumen
 * en vivo. Lo que se exige aquí lo impone la base; el formulario solo lo adelanta.
 * La orden se crea primero y los adjuntos después: si una subida falla se
 * reintenta solo ella, sin crear otra orden (misma clave de envío).
 * La clave de envío y el estado viven en el BORRADOR de 24 h del módulo
 * 'orden' (borrador.js): cerrar la pestaña no fabrica una segunda orden —
 * la restauración se OFRECE (no se impone) y el éxito total la limpia.
 */
import { useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { Box } from "lucide-react";
import { useAuth } from "../auth/AuthContext.jsx";
import { AVISO_ATENCION } from "../garantias/avisos.js";
import { ESTADOS, estadoDe } from "../garantias/estado.js";
import PasoAdjuntos from "../registro/pasos/PasoAdjuntos.jsx";
import { cobertura as nombreCobertura } from "../tablero/dominio.js";
import AuditoriaRecepcion from "./AuditoriaRecepcion.jsx";
import { auditoriaCompleta, checklistParaBase } from "./auditoria.js";
import { guardarBorrador, leerBorrador, limpiarBorrador } from "./borrador.js";
import { abrirOrden, leerEquipo, subirAdjuntos } from "./tallerService.js";

const FALLA_MIN = 5;
const FALLA_MAX = 2000;
const MODULO = "orden";
const PASOS = ["Equipo", "Falla", "Auditoría"];

export default function AbrirOrden() {
  const navigate = useNavigate();
  const { perfil } = useAuth();
  const userId = perfil?.id ?? null;
  const [params] = useSearchParams();
  const equipoId = params.get("equipo");
  const [equipo, setEquipo] = useState(null);
  const [error, setError] = useState(null);
  const [estado, setEstado] = useState({});
  const [paso, setPaso] = useState(0);
  const [alcanzado, setAlcanzado] = useState(0);
  // La clave de envío nace al montar (lazy); restaurar el borrador la REUTILIZA.
  const [claveExtra] = useState(() => crypto.randomUUID());
  const [claveRestaurada, setClaveRestaurada] = useState(null);
  const claveEnvio = claveRestaurada ?? claveExtra;
  const [resuelto, setResuelto] = useState(false); // ¿ya se decidió lo del borrador?
  const [orden, setOrden] = useState(null);
  const [pendientes, setPendientes] = useState([]);
  const [enviando, setEnviando] = useState(false);

  const actualizar = (parcial) => setEstado((s) => ({ ...s, ...parcial }));

  // El borrador se lee UNA VEZ al montar: si es del MISMO equipo, la
  // restauración se OFRECE (no se impone); si no hay borrador o es de otro
  // equipo, se usa la clave de envío recién generada.
  const borradorPrevio = useMemo(
    () => (userId && equipoId ? leerBorrador(userId, MODULO) : null),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [userId, equipoId],
  );
  const ofrecido = !resuelto && borradorPrevio && borradorPrevio.equipoId === equipoId ? borradorPrevio : null;

  // Cada cambio se amarra al borrador (guardarBorrador descarta archivos): falla,
  // accesorios, checklist, la clave de envío y, si ya se abrió una orden con
  // pendientes, esa orden.
  useEffect(() => {
    if (!userId || !claveEnvio) return;
    if (!estado.falla && pendientes.length === 0) return; // nada que reanudar
    guardarBorrador(
      userId,
      {
        equipoId,
        serial: equipo?.numero_serie ?? null,
        falla: estado.falla ?? "",
        accesorios: estado.accesorios ?? null,
        checklist: estado.checklist ?? null,
        observaciones: estado.observaciones ?? null,
        diagnostico: estado.diagnostico ?? null,
        claveEnvio,
        ordenId: orden?.orden_id ?? null,
        numero_orden: orden?.numero_orden ?? null,
        pendientes,
      },
      MODULO,
    );
  }, [userId, claveEnvio, estado, equipoId, equipo, orden, pendientes]);

  useEffect(() => {
    let vivo = true;
    if (!equipoId) return undefined;
    leerEquipo(equipoId).then((r) => {
      if (!vivo) return;
      if (r.ok) {
        setEquipo(r.datos);
        actualizar({ venceEl: r.datos.vence_el });
      } else {
        setError(r.mensaje || "No se pudo leer el equipo");
      }
    });
    return () => {
      vivo = false;
    };
  }, [equipoId]);

  const adjuntos = estado.archivosAdjuntos ?? [];
  const falla = (estado.falla ?? "").trim();
  const hayFoto = adjuntos.some((a) => a.tipo === "FOTO");
  const hayDocumento = adjuntos.some((a) => a.tipo === "DOCUMENTO");
  const exigeDocumento = equipo?.estado_compra === "PENDIENTE";
  const auditada = auditoriaCompleta(estado.checklist);
  const puedeAbrir = falla.length >= FALLA_MIN && auditada && hayFoto && (!exigeDocumento || hayDocumento) && !enviando;
  const validos = [true, falla.length >= FALLA_MIN, puedeAbrir];

  function ir(n) {
    setPaso(n);
    setAlcanzado((a) => Math.max(a, n));
  }

  async function terminar(ordenId, lista) {
    const faltan = await subirAdjuntos(ordenId, lista);
    setPendientes(faltan);
    if (faltan.length === 0) {
      if (userId) limpiarBorrador(userId, MODULO); // éxito completo: muere el borrador
      navigate(`/taller/${ordenId}`);
    }
    // Con pendientes el borrador PERMANECE: reabrir ofrece reintentar contra la misma orden.
  }

  function restaurar() {
    const g = ofrecido;
    setResuelto(true);
    setEstado({
      falla: g.falla ?? "",
      accesorios: g.accesorios ?? "",
      checklist: g.checklist ?? {},
      observaciones: g.observaciones ?? null,
      diagnostico: g.diagnostico ?? null,
      venceEl: equipo?.vence_el ?? null,
    });
    setClaveRestaurada(g.claveEnvio ?? crypto.randomUUID());
    if (g.ordenId) {
      setOrden({ orden_id: g.ordenId, numero_orden: g.numero_orden });
      setPendientes(g.pendientes ?? []);
    }
  }

  function descartar() {
    if (userId) limpiarBorrador(userId, MODULO);
    setResuelto(true);
  }

  async function abrir() {
    setEnviando(true);
    setError(null);
    const r = await abrirOrden({
      equipoId,
      falla,
      accesorios: estado.accesorios?.trim() || null,
      checklist: estado.checklist ? checklistParaBase(estado.checklist) : null,
      observaciones: null,
      claveEnvio,
    });
    if (!r.ok) {
      setError(r.mensaje || "No se pudo abrir la orden");
      setEnviando(false);
      return;
    }
    setOrden(r.datos);
    await terminar(
      r.datos.orden_id,
      adjuntos.map(({ archivo, tipo, etiqueta }) => ({ archivo, tipo, etiqueta })),
    );
    setEnviando(false);
  }

  async function reintentar() {
    setEnviando(true);
    await terminar(orden.orden_id, pendientes);
    setEnviando(false);
  }

  const cabecera = (
    <>
      <p className="ruta">
        <Link to="/taller">Taller</Link> / <strong>Nueva orden</strong>
      </p>
      <div className="wz-enc">
        <h1>Abrir orden de servicio</h1>
        <p className="sub">Valida el equipo, anota la falla y completa la auditoría de recepción. La cobertura la calcula el sistema.</p>
      </div>
    </>
  );

  const errorVisible = equipoId ? error : "Falta el equipo: ábrela desde la Consulta de garantía";
  if (!equipo) {
    return (
      <>
        {cabecera}
        {errorVisible ? (
          <div className="card wz-borrador">
            <p role="alert" className="aviso mal">
              {errorVisible}
            </p>
            <div>
              <button type="button" className="btn principal" onClick={() => navigate("/garantias/consulta")}>
                Buscar el equipo
              </button>
            </div>
          </div>
        ) : (
          <p>Cargando…</p>
        )}
      </>
    );
  }

  const clave = estadoDe(equipo);
  const tonoEstado = ESTADOS[clave].t;

  if (ofrecido && !orden) {
    return (
      <>
        {cabecera}
        <div className="card wz-borrador">
          <div className="wz-eqc">
            <span className="ico">
              <Box size={22} aria-hidden="true" />
            </span>
            <div className="tx">
              <b>{equipo.producto}</b>
              <span className="mono">{equipo.numero_serie}</span> · {equipo.titular}
            </div>
          </div>
          <div role="dialog" aria-label="Borrador de la orden" className="wz-borrador">
            <p>Tienes un borrador de hace poco. ¿Lo restauras?</p>
            <div className="bt">
              <button type="button" className="btn principal" onClick={restaurar}>
                Restaurar
              </button>
              <button type="button" className="btn suave" onClick={descartar}>
                Empezar de cero
              </button>
            </div>
          </div>
        </div>
      </>
    );
  }

  return (
    <>
      {cabecera}
      <div className="wz-grid">
        <section className="card" aria-label="Asistente de apertura de orden">
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
                <h2>Equipo</h2>
                <p className="wz-ayuda">Comprueba que es el equipo del cliente y revisa su vigencia antes de abrir la orden.</p>
                <div className="wz-eqc">
                  <span className="ico">
                    <Box size={22} aria-hidden="true" />
                  </span>
                  <div className="tx">
                    <b>{equipo.producto}</b>
                    <span className="mono">{equipo.numero_serie}</span> · Titular: {equipo.titular}
                  </div>
                  <span className="ins" data-t={tonoEstado}>
                    <i />
                    {ESTADOS[clave].n}
                  </span>
                </div>
                {AVISO_ATENCION[equipo.vigencia] && (
                  <p className="aviso ambar" role="note">
                    {AVISO_ATENCION[equipo.vigencia]}
                  </p>
                )}
                <p className="wz-hint">
                  ¿No es este equipo? <Link to="/garantias/consulta">Busca otro en la Consulta</Link>.
                </p>
              </>
            )}

            {paso === 1 && (
              <fieldset disabled={Boolean(orden)} className="wz-nofs">
                <h2>Falla y accesorios</h2>
                <p className="wz-ayuda">Describe lo que reporta el cliente y los accesorios que entrega con el equipo.</p>
                <div className="wz-cols">
                  <div className="wz-f wz-ancho">
                    <label htmlFor="falla">Falla reportada</label>
                    <textarea
                      id="falla"
                      className="campo"
                      rows={4}
                      value={estado.falla ?? ""}
                      maxLength={FALLA_MAX}
                      onChange={(e) => actualizar({ falla: e.target.value })}
                    />
                    <p className="wz-hint">
                      {falla.length < FALLA_MIN ? `Mínimo ${FALLA_MIN} caracteres (${falla.length}/${FALLA_MIN})` : `${falla.length}/${FALLA_MAX}`}
                    </p>
                  </div>
                  <div className="wz-f wz-ancho">
                    <label htmlFor="accesorios">
                      Accesorios <span className="op">(opcional)</span>
                    </label>
                    <input id="accesorios" className="campo" value={estado.accesorios ?? ""} onChange={(e) => actualizar({ accesorios: e.target.value })} />
                  </div>
                </div>
              </fieldset>
            )}

            {paso === 2 && (
              <fieldset disabled={Boolean(orden)} className="wz-nofs">
                <h2>Auditoría de recepción</h2>
                <p className="wz-ayuda">Todos los puntos son obligatorios: responde Sí o No en cada uno.</p>
                <AuditoriaRecepcion estado={estado} actualizar={actualizar} />
                <h2 className="wz-sub">Fotos y documentos</h2>
                <p className="wz-ayuda">Al menos una foto{exigeDocumento ? " y el documento presentado" : ""}. PDF, JPG o PNG de hasta 8 MB.</p>
                <PasoAdjuntos estado={estado} actualizar={actualizar} />
                {exigeDocumento && (
                  <p role="note" className="aviso ambar">
                    Un equipo sin compra confirmada exige el documento presentado.
                  </p>
                )}
              </fieldset>
            )}

            {error && (
              <p role="alert" className="aviso mal">
                {error}
              </p>
            )}
            {pendientes.length > 0 && (
              <div role="status" className="aviso ambar wz-pend">
                <p>
                  La orden {orden?.numero_orden} ya existe; falló la subida de {pendientes.length} archivo(s).
                </p>
                <button type="button" className="btn chico" onClick={reintentar} disabled={enviando}>
                  Reintentar adjuntos
                </button>
              </div>
            )}
          </div>

          <div className="wz-pie">
            <button type="button" className="btn suave" disabled={paso === 0} onClick={() => ir(paso - 1)}>
              Atrás
            </button>
            <div className="bt">
              {paso < 2 ? (
                <button type="button" className="btn principal" disabled={!validos[paso]} onClick={() => ir(paso + 1)}>
                  Siguiente
                </button>
              ) : (
                !orden && (
                  <button type="button" className="btn principal" onClick={abrir} disabled={!puedeAbrir}>
                    {enviando ? "Abriendo…" : "Abrir orden"}
                  </button>
                )
              )}
            </div>
          </div>
        </section>

        <aside className="card wz-vivo" aria-label="Resumen de la orden">
          <h2>Resumen</h2>
          <dl>
            <div>
              <dt>Equipo</dt>
              <dd>
                {equipo.producto}
                <span className="s mono">{equipo.numero_serie}</span>
              </dd>
            </div>
            <div>
              <dt>Titular</dt>
              <dd>{equipo.titular}</dd>
            </div>
            <div>
              <dt>Falla</dt>
              <dd>{falla ? falla : <span className="nada">Sin completar</span>}</dd>
            </div>
            <div>
              <dt>Cobertura</dt>
              <dd>
                {estado.cobertura && auditada ? (
                  <span className="ins" data-t={estado.cobertura === "EN_GARANTIA" ? "ok" : estado.cobertura === "ANULADA_POR_USO" ? "mal" : "neutro"}>
                    <i />
                    {nombreCobertura(estado.cobertura).nombre}
                  </span>
                ) : (
                  <span className="nada">Se calcula con la auditoría</span>
                )}
              </dd>
            </div>
            <div>
              <dt>Adjuntos</dt>
              <dd>
                {adjuntos.length ? `${adjuntos.filter((a) => a.tipo === "FOTO").length} fotos · ${adjuntos.filter((a) => a.tipo === "DOCUMENTO").length} documentos` : <span className="nada">Ninguno</span>}
              </dd>
            </div>
          </dl>
        </aside>
      </div>
    </>
  );
}
