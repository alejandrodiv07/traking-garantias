/**
 * Abrir la orden de un equipo ya registrado, con la auditoría de recepción
 * (spec §8, Tarea 15): falla, accesorios, checklist y fotos/documentos. Una sola
 * pantalla. Lo que se exige aquí lo impone la base; el formulario solo lo adelanta.
 * La orden se crea primero y los adjuntos después: si una subida falla se
 * reintenta solo ella, sin crear otra orden (misma clave de envío).
 * La clave de envío y el estado viven en el BORRADOR de 24 h del módulo
 * 'orden' (borrador.js): cerrar la pestaña no fabrica una segunda orden —
 * la restauración se OFRECE (no se impone) y el éxito total la limpia.
 */
import { useEffect, useMemo, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { useAuth } from "../auth/AuthContext.jsx";
import { AVISO_ATENCION } from "../garantias/avisos.js";
import PasoAdjuntos from "../registro/pasos/PasoAdjuntos.jsx";
import PasoVerificacion from "../registro/pasos/PasoVerificacion.jsx";
import { guardarBorrador, leerBorrador, limpiarBorrador } from "./borrador.js";
import { abrirOrden, leerEquipo, subirAdjuntos } from "./tallerService.js";
import "./taller.css";

const FALLA_MIN = 5;
const FALLA_MAX = 2000;
const MODULO = "orden";

export default function AbrirOrden() {
  const navigate = useNavigate();
  const { perfil } = useAuth();
  const userId = perfil?.id ?? null;
  const [params] = useSearchParams();
  const equipoId = params.get("equipo");
  const [equipo, setEquipo] = useState(null);
  const [error, setError] = useState(null);
  const [estado, setEstado] = useState({});
  // La clave de envío nace al montar (lazy); restaurar el borrador la REUTILIZA.
  const [claveExtra] = useState(() => crypto.randomUUID());
  const [claveRestaurada, setClaveRestaurada] = useState(null);
  const claveEnvio = claveRestaurada ?? claveExtra;
  const [resuelto, setResuelto] = useState(false);   // ¿ya se decidió lo del borrador?
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

  // Cada cambio se amarra al borrador (guardarBorrador descarta archivos) —
  // como el borrador del Hito 1: falla, accesorios, checklist, observaciones,
  // la clave de envío y, si ya se abrió una orden con pendientes, esa orden.
  useEffect(() => {
    if (!userId || !claveEnvio) return;
    if (!estado.falla && pendientes.length === 0) return;   // nada que reanudar
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
  const puedeAbrir =
    falla.length >= FALLA_MIN && hayFoto && (!exigeDocumento || hayDocumento) && !enviando;

  async function terminar(ordenId, lista) {
    const faltan = await subirAdjuntos(ordenId, lista);
    setPendientes(faltan);
    if (faltan.length === 0) {
      if (userId) limpiarBorrador(userId, MODULO);   // éxito completo: muere el borrador
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
      checklist: estado.checklist ?? null,
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

  const errorVisible = equipoId ? error : "Falta el equipo: ábrela desde la Consulta de garantía";
  if (!equipo) {
    return <section className="ao">{errorVisible ? <p role="alert">{errorVisible}</p> : <p>Cargando…</p>}</section>;
  }

  if (ofrecido && !orden) {
    return (
      <section className="ao">
        <h1>Abrir orden de servicio</h1>
        <div className="ao-equipo">
          <h2>{equipo.producto}</h2>
          <p className="ao-serial">{equipo.numero_serie}</p>
          <p>Titular: {equipo.titular}</p>
        </div>
        <div className="ao-borrador" role="dialog" aria-label="Borrador de la orden">
          <p>Tienes un borrador de hace poco. ¿Lo restauras?</p>
          <button type="button" className="ao-principal" onClick={restaurar}>
            Restaurar
          </button>
          <button type="button" onClick={descartar}>
            Empezar de cero
          </button>
        </div>
      </section>
    );
  }

  return (
    <section className="ao">
      <h1>Abrir orden de servicio</h1>
      <div className="ao-equipo">
        <h2>{equipo.producto}</h2>
        <p className="ao-serial">{equipo.numero_serie}</p>
        <p>Titular: {equipo.titular}</p>
        {AVISO_ATENCION[equipo.vigencia] && <p role="note">{AVISO_ATENCION[equipo.vigencia]}</p>}
      </div>

      <fieldset disabled={Boolean(orden)}>
        <label htmlFor="falla">
          Falla reportada
          <textarea
            id="falla"
            value={estado.falla ?? ""}
            maxLength={FALLA_MAX}
            onChange={(e) => actualizar({ falla: e.target.value })}
          />
        </label>
        <label htmlFor="accesorios">
          Accesorios
          <input
            id="accesorios"
            value={estado.accesorios ?? ""}
            onChange={(e) => actualizar({ accesorios: e.target.value })}
          />
        </label>

        <h2>Auditoría de recepción</h2>
        <PasoVerificacion estado={estado} actualizar={actualizar} />
        <PasoAdjuntos estado={estado} actualizar={actualizar} />
        {exigeDocumento && (
          <p role="note">Un equipo sin compra confirmada exige el documento presentado.</p>
        )}
      </fieldset>

      {error && <p role="alert">{error}</p>}
      {pendientes.length > 0 && (
        <div role="status">
          <p>
            La orden {orden?.numero_orden} ya existe; falló la subida de {pendientes.length} archivo(s).
          </p>
          <button type="button" onClick={reintentar} disabled={enviando}>
            Reintentar adjuntos
          </button>
        </div>
      )}
      {!orden && (
        <button type="button" className="ao-principal" onClick={abrir} disabled={!puedeAbrir}>
          Abrir orden
        </button>
      )}
    </section>
  );
}
