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
