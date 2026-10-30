// Servicio del Taller (Tarea 15 del plan): abrir la orden de un equipo ya
// registrado, leer ese equipo y subir los adjuntos de la recepción.
import { supabase } from "../../lib/supabaseClient.js";
import { rpc, subirAdjunto } from "../registro/registroService.js";

/** Abre la orden del equipo (0019). La fecha de ingreso nunca la manda el navegador. */
export async function abrirOrden({ equipoId, falla, accesorios, checklist, observaciones, claveEnvio }) {
  const r = await rpc("abrir_orden", {
    p_equipo_id: equipoId,
    p_falla: falla,
    p_accesorios: accesorios ?? null,
    p_checklist: checklist ?? null,
    p_observaciones: observaciones ?? null,
    p_clave_envio: claveEnvio,
  });
  return r.ok ? { ok: true, datos: r.datos?.[0] ?? null } : r;
}

/** El equipo por id, tal como lo ve la lista de garantías (vigencia incluida). */
export async function leerEquipo(equipoId) {
  try {
    const { data, error } = await supabase.from("v_garantias").select("*").eq("equipo_id", equipoId).maybeSingle();
    if (error) return { ok: false, codigo: error.code === "42501" ? "SIN_PERMISO" : "DESCONOCIDO", mensaje: error.message };
    if (!data) return { ok: false, codigo: "NO_ENCONTRADO", mensaje: "No existe ese equipo" };
    return { ok: true, datos: data };
  } catch {
    return { ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" };
  }
}

/** Sube la lista y devuelve los que fallaron, para reintentarlos sin recrear la orden. */
export async function subirAdjuntos(ordenId, lista) {
  const pendientes = [];
  for (const a of lista) {
    const r = await subirAdjunto(ordenId, a.archivo, { tipo: a.tipo, etiqueta: a.etiqueta });
    if (!r.ok) pendientes.push(a);
  }
  return pendientes;
}

function falloDeLectura(err) {
  if (err instanceof TypeError || String(err?.name ?? "").startsWith("Fetch")) {
    return { ok: false, codigo: "SIN_CONEXION", mensaje: "Sin conexión" };
  }
  return { ok: false, codigo: err?.code === "42501" ? "SIN_PERMISO" : "DESCONOCIDO", mensaje: err?.message ?? "Error inesperado" };
}

/** Lee una lista de una tabla de la orden: ok con las filas o el error mapeado. */
async function lista(consulta) {
  try {
    const { data, error } = await consulta;
    return error ? falloDeLectura(error) : { ok: true, datos: data ?? [] };
  } catch (err) {
    return falloDeLectura(err);
  }
}

const COLUMNAS_ORDEN =
  "id, tipo_atencion, falla_reportada, accesorios, diagnostico, costo_reparacion, motivo_rechazo, tecnico_asignado_id";

/**
 * La orden completa para el detalle: lo que ya resuelve `v_tablero` (equipo,
 * titular, estado, vigencia) más las columnas propias de la orden y el nombre
 * del técnico. Tres lecturas simples en vez de un embed que dependa de las FK.
 */
export async function obtenerOrden(ordenId) {
  try {
    const [tablero, orden] = await Promise.all([
      supabase.from("v_tablero").select("*").eq("orden_id", ordenId).maybeSingle(),
      supabase.from("ordenes_servicio").select(COLUMNAS_ORDEN).eq("id", ordenId).maybeSingle(),
    ]);
    if (tablero.error) return falloDeLectura(tablero.error);
    if (orden.error) return falloDeLectura(orden.error);
    if (!tablero.data || !orden.data) {
      return { ok: false, codigo: "NO_ENCONTRADO", mensaje: "No existe esa orden" };
    }
    let tecnico = null;
    if (orden.data.tecnico_asignado_id) {
      const t = await supabase.from("profiles").select("full_name").eq("id", orden.data.tecnico_asignado_id).maybeSingle();
      tecnico = t.data?.full_name ?? null;
    }
    return { ok: true, datos: { ...tablero.data, ...orden.data, tecnico } };
  } catch (err) {
    return falloDeLectura(err);
  }
}

/** Cambios de estado y eventos de bitácora de la orden, el más reciente primero. */
export function historialOrden(ordenId) {
  return lista(
    supabase
      .from("historial_ordenes")
      .select("id, evento, estado_anterior, estado_nuevo, comentario, creado_en, autor:modificado_por(full_name)")
      .eq("orden_id", ordenId)
      .order("creado_en", { ascending: false }),
  );
}

/** Notas internas (nunca se filtran al cliente). */
export function notasOrden(ordenId) {
  return lista(
    supabase
      .from("notas_internas")
      .select("id, nota, created_at, autor:autor_id(full_name)")
      .eq("orden_id", ordenId)
      .order("created_at", { ascending: false }),
  );
}

/** Fotos y documentos de la orden. */
export function adjuntosOrden(ordenId) {
  return lista(
    supabase
      .from("adjuntos")
      .select("id, tipo, etiqueta, ruta, mime, bytes, subido_en")
      .eq("orden_id", ordenId)
      .order("subido_en", { ascending: true }),
  );
}
